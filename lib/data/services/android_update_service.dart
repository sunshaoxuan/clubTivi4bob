import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/app_diagnostics.dart';
import '../../core/app_version.dart';
import 'desktop_update_state.dart';
import 'update_manifest.dart';
import 'apk_download_policy.dart';

/// Android owns APK installation. A system confirmation is always required.
/// Neither an APK nor credentials are fetched from GitHub by the application.
class AndroidUpdateService {
  AndroidUpdateService._();
  static final instance = AndroidUpdateService._();
  static const _installer = MethodChannel(
    'io.github.clubanderson.clubtivi/installer',
  );
  final state = ValueNotifier(
    const WindowsUpdateState(WindowsUpdatePhase.idle),
  );
  bool _started = false;
  bool _checking = false;
  bool _stopped = false;
  Timer? _checkTimer;
  HttpClient? _activeClient;
  Future<void>? _checkRun;
  File? _ready;

  void start() {
    if (!Platform.isAndroid || _started || _stopped) return;
    _started = true;
    if (kReleaseMode) {
      unawaited(checkNow());
      _checkTimer = Timer.periodic(
        const Duration(hours: 6),
        (_) => unawaited(checkNow()),
      );
    }
  }

  Future<void> checkNow() =>
      _checkRun ??= _checkNow().whenComplete(() => _checkRun = null);

  Future<void> _checkNow() async {
    if (!Platform.isAndroid || _checking || _stopped || !state.value.canCheck) {
      return;
    }
    _checking = true;
    state.value = const WindowsUpdateState(WindowsUpdatePhase.checking);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _activeClient = client;
    try {
      final info = await const MethodChannel(
        'bobtv/device',
      ).invokeMapMethod<String, dynamic>('info');
      final platform = info?['updatePlatform'];
      if (!const {
        'android-arm',
        'android-arm64',
        'android-x64',
      }.contains(platform)) {
        throw const FormatException('Unsupported Android package architecture');
      }
      final uri = Uri.https(
        'bobtv.briconbric.com',
        '/updates/$platform/latest.json',
      );
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'BobTV/$bobTvVersion');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw HttpException('当前 Android 更新服务尚不可用（${response.statusCode}）');
      }
      final content = BytesBuilder();
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        if (content.length + chunk.length > 65536) {
          throw const FormatException('Update manifest too large');
        }
        content.add(chunk);
      }
      final manifest = UpdateManifest.parse(
        utf8.decode(content.takeBytes()),
        uri,
        extension: '.apk',
      );
      if (!manifest.archive.path.endsWith('-$platform.apk')) {
        throw const FormatException('APK architecture mismatch');
      }
      if (UpdateManifest.compareVersions(manifest.version, bobTvVersion) <= 0) {
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.upToDate,
          version: bobTvVersion,
        );
        return;
      }
      final root = Directory(
        p.join((await getApplicationCacheDirectory()).path, 'BobTVUpdates'),
      );
      await root.create(recursive: true);
      final file = File(p.join(root.path, '${manifest.sha256}.apk'));
      if (!await _matches(file, manifest)) {
        final partial = File('${file.path}.part');
        var offset = await partial.exists() ? await partial.length() : 0;
        if (offset == manifest.bytes && await _matches(partial, manifest)) {
          await partial.rename(file.path);
        } else {
          if (offset >= manifest.bytes) {
            await partial.delete();
            offset = 0;
          }
          state.value = WindowsUpdateState(
            WindowsUpdatePhase.downloading,
            version: manifest.version,
            percent: (offset * 100 ~/ manifest.bytes).clamp(0, 100),
            receivedBytes: offset,
            totalBytes: manifest.bytes,
            message: '正在连接下载服务，已保存的进度会继续使用。',
          );
          final download = await client
              .getUrl(manifest.archive)
              .timeout(const Duration(seconds: 15));
          download.followRedirects = false;
          download.headers.set(
            HttpHeaders.userAgentHeader,
            'BobTV/$bobTvVersion',
          );
          if (offset > 0) {
            download.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
          }
          final data = await download.close().timeout(
            const Duration(seconds: 20),
          );
          offset = ApkDownloadPolicy.initialOffset(
            statusCode: data.statusCode,
            contentRange: data.headers.value('content-range'),
            requestedOffset: offset,
            totalBytes: manifest.bytes,
            contentLength: data.contentLength,
          );
          final sink = partial.openWrite(
            mode: offset > 0 ? FileMode.append : FileMode.write,
          );
          var received = offset;
          var lastPaint = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            await for (final chunk in data.timeout(
              const Duration(seconds: 30),
            )) {
              if (_stopped) {
                throw StateError('Update download stopped for exit');
              }
              received += chunk.length;
              if (received > manifest.bytes) {
                throw const FormatException('APK exceeds manifest size');
              }
              sink.add(chunk);
              final now = DateTime.now();
              if (now.difference(lastPaint).inMilliseconds >= 250) {
                state.value = WindowsUpdateState(
                  WindowsUpdatePhase.downloading,
                  version: manifest.version,
                  percent: (received * 100 ~/ manifest.bytes).clamp(0, 100),
                  receivedBytes: received,
                  totalBytes: manifest.bytes,
                  message: '正在下载并保存进度。网络中断后可重试；下载完成后需确认系统安装。',
                );
                lastPaint = now;
              }
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
          state.value = WindowsUpdateState(
            WindowsUpdatePhase.verifying,
            version: manifest.version,
          );
          if (!await _matches(partial, manifest)) {
            await partial.delete();
            throw const FormatException('APK length or SHA-256 mismatch');
          }
          await partial.rename(file.path);
        }
      }
      final validated = await _installer.invokeMethod<bool>('validateApk', {
        'filePath': file.path,
      });
      if (validated != true) {
        throw const FormatException(
          'APK publisher validation was not confirmed',
        );
      }
      _ready = file;
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.ready,
        version: manifest.version,
        receivedBytes: manifest.bytes,
        totalBytes: manifest.bytes,
        message: '更新包和发布者签名已校验。点击“安装更新”，在 Android 系统窗口确认。关闭应用不会触发静默安装。',
      );
    } catch (error, stack) {
      if (_stopped) return;
      AppDiagnostics.instance.recordError('android_update', error, stack);
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.failed,
        version: state.value.version,
        message: '更新未完成：$error。现有版本可继续播放，点击重试会续传已保存的下载。',
      );
    } finally {
      client.close(force: true);
      if (identical(_activeClient, client)) _activeClient = null;
      _checking = false;
    }
  }

  Future<bool> _matches(File file, UpdateManifest manifest) async =>
      await file.exists() &&
      await file.length() == manifest.bytes &&
      (await sha256.bind(file.openRead()).first).toString() == manifest.sha256;

  Future<void> installReady() async {
    if (_stopped ||
        _ready == null ||
        state.value.phase != WindowsUpdatePhase.ready) {
      return;
    }
    try {
      final result = await _installer.invokeMapMethod<String, dynamic>(
        'installApk',
        {'filePath': _ready!.path},
      );
      if (result?['permissionRequired'] == true) {
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.ready,
          version: state.value.version,
          message: '请允许 BobTV 安装应用，然后返回并再次点击“安装更新”。',
        );
      }
    } catch (error, stack) {
      AppDiagnostics.instance.recordError('android_install', error, stack);
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.failed,
        version: state.value.version,
        message: '系统安装未启动：$error。现有版本保持不变。',
      );
    }
  }

  /// Exit cancels network work and waits for the APK's partial-file sink to
  /// close. The partial file remains available for the next launch to resume.
  Future<void> stop() async {
    _stopped = true;
    _checkTimer?.cancel();
    _activeClient?.close(force: true);
    try {
      await _checkRun?.timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}
