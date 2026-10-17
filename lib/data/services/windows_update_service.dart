import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/app_diagnostics.dart';
import '../../core/desktop_app_exit.dart';
import '../../core/app_version.dart';
import '../../core/server_egress.dart';
import '../../core/windows_binary_architecture.dart';
import 'desktop_update_state.dart';
import 'update_manifest.dart';
export 'desktop_update_state.dart';

class WindowsUpdateService {
  WindowsUpdateService._();

  @visibleForTesting
  WindowsUpdateService.forTesting({
    required Directory directory,
    required String version,
    required String runId,
    required int workerPid,
    String? installRequestId,
  }) : _updateDirectory = directory,
       _workerLaunchedForVersion = version,
       _runId = runId,
       _workerPid = workerPid,
       _installRequested = installRequestId != null,
       _installRequestId = installRequestId;

  @visibleForTesting
  Future<void> pollWorkerStatusForTesting() => _readWorkerStatus();

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
  bool _managed = false;
  bool _installRequested = false;
  String? _installRequestId;

  void start() {
    if (!Platform.isWindows || _started) return;
    _started = true;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      state.value = const WindowsUpdateState(
        WindowsUpdatePhase.failed,
        message: '无法找到用户更新目录，请检查 LOCALAPPDATA 设置。',
      );
      return;
    }
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
    if (!Platform.isWindows || _checking || !state.value.canCheck) return;
    if (!_started) start();
    if (_checking) return;
    if (_updateDirectory == null) return;
    _checking = true;
    state.value = const WindowsUpdateState(WindowsUpdatePhase.checking);
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
      if (response.statusCode == HttpStatus.notFound) {
        throw const HttpException('更新服务尚未提供此平台的版本清单（404）');
      }
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
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.upToDate,
          version: bobTvVersion,
        );
        return;
      }
      final installation = File(
        p.join(p.dirname(Platform.resolvedExecutable), 'installation.ini'),
      );
      _managed = await installation.exists();
      WindowsInstallerPackage? previousInstaller;
      if (_managed && manifest.installer == null) {
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.manualRequired,
          version: manifest.version,
          message:
              '发现新版本 ${manifest.version}，更新服务尚未提供已签章的安装包。'
              '稍后会自动重试，当前版本可继续使用，无需到浏览器下载。',
        );
        return;
      }
      if (_managed) {
        final previousUri = manifestUri.resolve('versions/$bobTvVersion.json');
        final previousRequest = await client
            .getUrl(previousUri)
            .timeout(const Duration(seconds: 10));
        previousRequest.followRedirects = false;
        final previousResponse = await previousRequest.close().timeout(
          const Duration(seconds: 10),
        );
        if (previousResponse.statusCode != 200) {
          throw const FormatException('当前版本的安全回退安装包尚未提供，升级已暂停，当前版本可继续使用');
        }
        final previousBytes = BytesBuilder();
        await for (final chunk in previousResponse.timeout(
          const Duration(seconds: 10),
        )) {
          if (previousBytes.length + chunk.length > _maxManifestBytes) {
            throw const FormatException('Rollback manifest too large');
          }
          previousBytes.add(chunk);
        }
        final previous = UpdateManifest.parse(
          utf8.decode(previousBytes.takeBytes()),
          previousUri,
        );
        if (previous.version != bobTvVersion || previous.installer == null) {
          throw const FormatException('安全回退安装包不匹配，升级已暂停');
        }
        previousInstaller = previous.installer;
      }
      final skipped = File(
        p.join(_updateDirectory!.path, 'skipped_versions.txt'),
      );
      if (await skipped.exists() &&
          (await skipped.readAsLines()).contains(manifest.version)) {
        AppDiagnostics.instance.log('update_skipped_bad_version', {
          'version': manifest.version,
        });
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.failed,
          version: manifest.version,
          message: '版本 ${manifest.version} 曾启动失败，已跳过。等待后续修复版本，当前版本可继续使用。',
        );
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
      await _launchWorker(manifest, previousInstaller: previousInstaller);
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
        : 'https://$_mirrorHost/updates/windows-${await WindowsBinaryArchitecture.read(File(Platform.resolvedExecutable))}/latest.json';
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

  Future<void> _launchWorker(
    UpdateManifest manifest, {
    WindowsInstallerPackage? previousInstaller,
  }) async {
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
    if (_managed) {
      for (final name in [
        'installer_worker.ps1',
        'publisher_signature.ps1',
        'update-signing-public.pem',
      ]) {
        await File(p.join(directory.path, name)).writeAsBytes([
          if (name.endsWith('.ps1')) ...[0xef, 0xbb, 0xbf],
          ...utf8.encode(await rootBundle.loadString('assets/updater/$name')),
        ], flush: true);
      }
    }
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
    _installRequested = false;
    _installRequestId = null;
    _workerPid = await _launcher.invokeMethod<int>('launch', {
      'logPath': p.join(directory.path, 'launcher.log'),
      'arguments': [
        '-File',
        _managed ? p.join(directory.path, 'installer_worker.ps1') : script.path,
        '-Mode',
        'Update',
        '-AppDir',
        appDirectory,
        '-CurrentPid',
        '$pid',
        '-Version',
        manifest.version,
        if (_managed) ...[
          '-OldVersion',
          bobTvVersion,
          '-Signature',
          manifest.installer!.signature,
          '-PreviousUrl',
          (await ServerEgress.nodes.resolve(
            previousInstaller!.archive,
          )).toString(),
          '-PreviousSha256',
          previousInstaller.sha256,
          '-PreviousBytes',
          '${previousInstaller.bytes}',
          '-PreviousSignature',
          previousInstaller.signature,
        ],
        '-ArchiveUrl',
        (await ServerEgress.nodes.resolve(
          _managed ? manifest.installer!.archive : manifest.archive,
        )).toString(),
        '-Sha256',
        _managed ? manifest.installer!.sha256 : manifest.sha256,
        '-Bytes',
        '${_managed ? manifest.installer!.bytes : manifest.bytes}',
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
      String? reportedRequestId;
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          final requestId = decoded['authorizationRequestId'];
          reportedRequestId = requestId is String ? requestId : null;
          reported = WindowsUpdateState.fromWorkerStatus(
            decoded,
            version: _workerLaunchedForVersion!,
            runId: _runId,
            workerPid: _workerPid,
          );
        }
      }
      final terminal =
          reported?.phase == WindowsUpdatePhase.failed ||
          reported?.phase == WindowsUpdatePhase.installed;
      // Check liveness before ignoring an old consent receipt. Otherwise a dead
      // helper can leave the application displaying authorization forever.
      if (!terminal && !await _isWorkerRunning()) {
        _installRequested = false;
        _installRequestId = null;
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.failed,
          version: _workerLaunchedForVersion,
          message: '更新助手已退出，授权或安装尚未完成。当前版本保留，下载和备份不会删除，请点击重试。',
        );
        AppDiagnostics.instance.log('update_worker_exited', {
          'version': _workerLaunchedForVersion,
          'pid': _workerPid,
          'runId': _runId,
        });
        return;
      }
      if (reported != null) {
        // A poll may still read the previous ready/cancelled state immediately
        // after a new request. Keep the consent UI busy until this request is
        // acknowledged, and never close for an older authorization attempt.
        if (_installRequested &&
            reportedRequestId != _installRequestId &&
            const {
              WindowsUpdatePhase.ready,
              WindowsUpdatePhase.authorizing,
              WindowsUpdatePhase.awaitingExit,
            }.contains(reported.phase)) {
          return;
        }
        state.value = reported;
        if (_installRequested &&
            reported.phase == WindowsUpdatePhase.awaitingExit) {
          _installRequested = false;
          _installRequestId = null;
          await DesktopAppExit.request('windows_update_authorized');
        }
      }
      if (reported?.phase == WindowsUpdatePhase.failed ||
          reported?.phase == WindowsUpdatePhase.installed) {
        return;
      }
      if (reported == null &&
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

  /// Request consent without closing playback before Windows authorization.
  Future<void> installReady() async {
    final current = state.value;
    if (current.phase == WindowsUpdatePhase.awaitingExit) {
      await DesktopAppExit.request('windows_update_awaiting_exit');
      return;
    }
    if (current.phase != WindowsUpdatePhase.ready || _updateDirectory == null) {
      return;
    }
    if (!current.requiresAuthorization) {
      await DesktopAppExit.request('windows_portable_update_install');
      return;
    }
    if (_runId == null || !await _isWorkerRunning()) {
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.failed,
        version: current.version,
        message: '更新助手未运行，请点击重试。当前版本保留。',
      );
      return;
    }
    _installRequested = true;
    _installRequestId = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    try {
      await File(
        p.join(_updateDirectory!.path, 'install-request-$_runId.txt'),
      ).writeAsString(
        jsonEncode({'runId': _runId, 'requestId': _installRequestId}),
        flush: true,
      );
    } catch (error, stack) {
      _installRequested = false;
      _installRequestId = null;
      AppDiagnostics.instance.recordError(
        'update_install_request',
        error,
        stack,
      );
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.failed,
        version: current.version,
        message: '未能提交安装请求，当前版本保留。请重试或查看更新日志。',
      );
      return;
    }
    state.value = WindowsUpdateState(
      WindowsUpdatePhase.authorizing,
      version: current.version,
      requiresAuthorization: true,
      message: '请在 Windows 授权窗口中确认。授权成功后 BobTV 会自动关闭并安装；取消后可继续使用。',
    );
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
