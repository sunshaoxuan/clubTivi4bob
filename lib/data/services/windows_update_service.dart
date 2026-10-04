import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/app_diagnostics.dart';
import '../../core/app_version.dart';
import 'desktop_update_state.dart';
import 'update_manifest.dart';
export 'desktop_update_state.dart';

class WindowsUpdateService {
  WindowsUpdateService._();

  static final instance = WindowsUpdateService._();
  static const _mirrorHost = 'bobtv.briconbric.com';
  static const _maxManifestBytes = 64 * 1024;
  static const _launcher = MethodChannel('bobtv/updater');

  final state = ValueNotifier<WindowsUpdateState>(
    const WindowsUpdateState(WindowsUpdatePhase.idle),
  );
  bool _checking = false;
  bool _started = false;
  Directory? _updateDirectory;
  String? _workerLaunchedForVersion;
  String? _runId;
  int? _workerPid;
  DateTime? _workerStartedAt;
  bool _readingStatus = false;

  void start() {
    if (!Platform.isWindows || _started) return;
    _started = true;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) return;
    _updateDirectory = Directory(p.join(localAppData, 'HotelTV', 'Update'));
    unawaited(_readInstalledStatus());
    if (kReleaseMode) unawaited(_ensureDesktopShortcut());
    Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_readWorkerStatus()),
    );
    if (kReleaseMode) {
      unawaited(checkNow());
      Timer.periodic(const Duration(hours: 6), (_) => unawaited(checkNow()));
    }
  }

  Future<void> checkNow() async {
    if (_checking || _updateDirectory == null) return;
    _checking = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final manifestUri = await _resolveManifestUri();
      if (manifestUri == null) return;
      final request = await client
          .getUrl(manifestUri)
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode == HttpStatus.notFound) return;
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Mirror returned ${response.statusCode}');
      }
      final buffer = BytesBuilder();
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        if (buffer.length + chunk.length > _maxManifestBytes) {
          throw const FormatException('Update manifest too large');
        }
        buffer.add(chunk);
      }
      final manifest = UpdateManifest.parse(
        utf8.decode(buffer.takeBytes()),
        manifestUri,
      );
      if (UpdateManifest.compareVersions(manifest.version, bobTvVersion) <= 0) {
        return;
      }
      final installation = File(
        p.join(p.dirname(Platform.resolvedExecutable), 'installation.ini'),
      );
      if (await installation.exists()) {
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.failed,
          version: manifest.version,
          message: '发现新版本 ${manifest.version}。安装版需要管理员授权，请从 '
              'https://bobtv.briconbric.com/downloads 下载并运行 Setup 升级。'
              '当前版本可继续使用。',
        );
        return;
      }
      final skipped = File(
        p.join(_updateDirectory!.path, 'skipped_versions.txt'),
      );
      if (await skipped.exists() &&
          (await skipped.readAsLines()).contains(manifest.version)) {
        AppDiagnostics.instance.log('update_skipped_bad_version', {
          'version': manifest.version,
        });
        return;
      }
      if (_workerLaunchedForVersion == manifest.version &&
          _workerPid != null &&
          await _isWorkerRunning()) {
        await _readWorkerStatus();
        return;
      }
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.starting,
        version: manifest.version,
        message: '正在启动更新助手，尚未开始下载。',
      );
      if (await _attachExistingWorker(manifest.version)) return;
      await _launchWorker(manifest);
    } catch (error, stack) {
      AppDiagnostics.instance.recordError('update_check', error, stack);
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.failed,
        version: state.value.version,
        message: '更新未完成：$error。当前版本可继续使用，点击重试更新。',
      );
    } finally {
      client.close(force: true);
      _checking = false;
    }
  }

  Future<Uri?> _resolveManifestUri() async {
    final directory = _updateDirectory;
    if (directory == null) return null;
    final configured = File(p.join(directory.path, 'update-manifest-url.txt'));
    final address = await configured.exists()
        ? (await configured.readAsString()).trim()
        : 'https://$_mirrorHost/updates/windows-x64/latest.json';
    final candidate = Uri.tryParse(address);
    if (candidate == null ||
        candidate.scheme != 'https' ||
        candidate.host != _mirrorHost ||
        candidate.hasPort ||
        candidate.userInfo.isNotEmpty ||
        candidate.hasQuery ||
        candidate.hasFragment ||
        !candidate.path.startsWith('/updates/') ||
        !candidate.path.endsWith('.json')) {
      throw const FormatException('Invalid update manifest URL');
    }
    return candidate;
  }

  Future<void> _launchWorker(UpdateManifest manifest) async {
    final directory = _updateDirectory!;
    await directory.create(recursive: true);
    await _writeShortcutScript();
    final script = File(p.join(directory.path, 'worker.ps1'));
    final source = await rootBundle.loadString('assets/updater/worker.ps1');
    await script.writeAsBytes([
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode(source),
    ], flush: true);
    final progressScript = File(p.join(directory.path, 'progress_ui.ps1'));
    await progressScript.writeAsBytes([
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode(
        await rootBundle.loadString('assets/updater/progress_ui.ps1'),
      ),
    ], flush: true);
    final appDirectory = p.dirname(Platform.resolvedExecutable);
    _runId = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    _workerStartedAt = DateTime.now();
    _workerLaunchedForVersion = manifest.version;
    _workerPid = await _launcher.invokeMethod<int>('launch', {
      'logPath': p.join(directory.path, 'launcher.log'),
      'arguments': [
        '-File',
        script.path,
        '-Mode',
        'Update',
        '-AppDir',
        appDirectory,
        '-CurrentPid',
        '$pid',
        '-Version',
        manifest.version,
        '-ArchiveUrl',
        manifest.archive.toString(),
        '-Sha256',
        manifest.sha256,
        '-Bytes',
        '${manifest.bytes}',
        '-RunId',
        _runId!,
      ],
    });
    if (_workerPid == null || _workerPid! <= 0) {
      throw StateError('更新助手未返回有效的进程编号');
    }
    AppDiagnostics.instance.log('update_worker_started', {
      'version': manifest.version,
      'pid': _workerPid,
      'runId': _runId,
    });
    // The independent progress window waits for this BobTV process to exit.
    // It remains alive when Flutter exits and does not hold player files open.
    try {
      await _launcher.invokeMethod<int>('launch', {
        'logPath': p.join(directory.path, 'progress-ui-launcher.log'),
        'arguments': [
          '-File',
          progressScript.path,
          '-CurrentPid',
          '$pid',
          '-Version',
          manifest.version,
          '-RunId',
          _runId!,
          '-WorkerPid',
          '$_workerPid',
          '-AppDir',
          appDirectory,
        ],
      });
    } catch (error, stack) {
      AppDiagnostics.instance.recordError(
        'update_progress_window',
        error,
        stack,
      );
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.starting,
        version: manifest.version,
        message: '更新助手已启动，但独立进度窗口启动失败。详情已写入更新日志。',
      );
    }
    // Do not claim download has started merely because CreateProcess succeeded.
    await _readWorkerStatus();
  }

  Future<bool> _isWorkerRunning() async =>
      _workerPid != null &&
      await _launcher.invokeMethod<bool>('isRunning', {'pid': _workerPid}) ==
          true;

  Future<void> _readInstalledStatus() async {
    try {
      final file = File(p.join(_updateDirectory!.path, 'status.json'));
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map<String, dynamic> ||
          data['phase'] != 'installed' ||
          data['version'] != bobTvVersion ||
          _workerPid != null ||
          state.value.phase != WindowsUpdatePhase.idle) {
        return;
      }
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.installed,
        version: bobTvVersion,
        message: '已成功升级至 $bobTvVersion，旧版备份已保留。',
      );
      Timer(const Duration(seconds: 40), () {
        if (state.value.phase == WindowsUpdatePhase.installed) {
          state.value = const WindowsUpdateState(WindowsUpdatePhase.idle);
        }
      });
    } catch (error, stack) {
      AppDiagnostics.instance.recordError(
        'update_installed_status',
        error,
        stack,
      );
    }
  }

  Future<bool> _attachExistingWorker(String version) async {
    final file = File(p.join(_updateDirectory!.path, 'status.json'));
    if (!await file.exists()) return false;
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, dynamic> ||
        data['version'] != version ||
        data['runId'] is! String ||
        !RegExp(r'^[A-Za-z0-9-]{1,100}$').hasMatch(data['runId'] as String) ||
        data['workerPid'] is! int ||
        (data['workerPid'] as int) <= 0) {
      return false;
    }
    final reported = WindowsUpdateState.fromWorkerStatus(
      data,
      version: version,
    );
    if (reported == null ||
        reported.phase == WindowsUpdatePhase.failed ||
        reported.phase == WindowsUpdatePhase.installed) {
      return false;
    }
    if (await _launcher.invokeMethod<bool>('isRunning', {
          'pid': data['workerPid'],
        }) !=
        true) {
      return false;
    }
    _workerPid = data['workerPid'] as int;
    _runId = data['runId'] as String;
    _workerLaunchedForVersion = version;
    _workerStartedAt = DateTime.now();
    state.value = reported;
    AppDiagnostics.instance.log('update_worker_attached', {
      'version': version,
      'pid': _workerPid,
    });
    return true;
  }

  Future<File> _writeShortcutScript() async {
    final directory = _updateDirectory!;
    await directory.create(recursive: true);
    final script = File(p.join(directory.path, 'ensure_shortcut.ps1'));
    final source = await rootBundle.loadString(
      'assets/updater/ensure_shortcut.ps1',
    );
    await script.writeAsBytes([
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode(source),
    ], flush: true);
    return script;
  }

  Future<void> _ensureDesktopShortcut() async {
    try {
      final script = await _writeShortcutScript();
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-ExecutablePath',
        Platform.resolvedExecutable,
      ], runInShell: false).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) {
        throw StateError(
          'Desktop shortcut creation failed: ${result.exitCode}',
        );
      }
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'desktop_shortcut',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _readWorkerStatus() async {
    final directory = _updateDirectory;
    if (directory == null || _workerPid == null || _readingStatus) return;
    _readingStatus = true;
    final file = File(p.join(directory.path, 'status-$_runId.json'));
    try {
      WindowsUpdateState? reported;
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          reported = WindowsUpdateState.fromWorkerStatus(
            decoded,
            version: _workerLaunchedForVersion!,
            runId: _runId,
            workerPid: _workerPid,
          );
        }
      }
      if (reported != null) state.value = reported;
      if (reported?.phase == WindowsUpdatePhase.failed ||
          reported?.phase == WindowsUpdatePhase.installed) {
        return;
      }
      if (!await _isWorkerRunning()) {
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.failed,
          version: _workerLaunchedForVersion,
          message: '更新助手意外退出，下载或安装尚未完成。点击重试；启动错误记录在 launcher.log。',
        );
        AppDiagnostics.instance.log('update_worker_exited', {
          'version': _workerLaunchedForVersion,
          'pid': _workerPid,
          'runId': _runId,
        });
      } else if (reported == null &&
          _workerStartedAt != null &&
          DateTime.now().difference(_workerStartedAt!) >
              const Duration(seconds: 30)) {
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.failed,
          version: _workerLaunchedForVersion,
          message: '更新助手启动后 30 秒仍未返回工作状态，请查看 launcher.log 或重试。',
        );
      }
    } catch (error, stack) {
      AppDiagnostics.instance.recordError('update_status_read', error, stack);
    } finally {
      _readingStatus = false;
    }
  }

  /// A visible channel browser is the earliest reliable startup-health signal.
  Future<void> markStartupHealthy() async {
    if (!Platform.isWindows || _updateDirectory == null) return;
    final marker = File(p.join(_updateDirectory!.path, 'startup.marker'));
    if (await marker.exists()) {
      try {
        final healthy = File(p.join(_updateDirectory!.path, 'startup.healthy'));
        await healthy.writeAsString('$pid', flush: true);
        await marker.delete();
        AppDiagnostics.instance.log('update_startup_healthy', {
          'version': bobTvVersion,
        });
      } catch (_) {}
    }
  }
}
