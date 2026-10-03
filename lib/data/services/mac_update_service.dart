import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_diagnostics.dart';
import '../../core/app_version.dart';
import 'desktop_update_state.dart';
import 'update_manifest.dart';

/// macOS update transport. The detached shell worker performs installation
/// only after the app exits and verifies the publisher's update signature.
class MacUpdateService {
  MacUpdateService._();

  static final instance = MacUpdateService._();
  static const _mirrorHost = 'bobtv.briconbric.com';
  static const _maxManifestBytes = 64 * 1024;

  final state = ValueNotifier<WindowsUpdateState>(
    const WindowsUpdateState(WindowsUpdatePhase.idle),
  );
  Directory? _directory;
  bool _started = false;
  bool _checking = false;
  String? _workerLaunchedForVersion;
  String? _reportedFailureVersion;
  String? _runId;
  int? _workerPid;
  DateTime? _workerStartedAt;
  bool _readingStatus = false;
  final Completer<void> _healthMonitorReady = Completer<void>();

  void start() {
    if (!Platform.isMacOS || _started) return;
    _started = true;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final support = await getApplicationSupportDirectory();
      _directory = Directory(p.join(support.path, 'Update'));
      await _directory!.create(recursive: true);
      await _readInstalledStatus();
      await _startHealthMonitor();
      _healthMonitorReady.complete();
      Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_readWorkerStatus());
      });
      await checkNow();
      Timer.periodic(const Duration(hours: 6), (_) {
        unawaited(checkNow());
      });
    } catch (error, stackTrace) {
      if (!_healthMonitorReady.isCompleted) _healthMonitorReady.complete();
      AppDiagnostics.instance.recordError('mac_update_init', error, stackTrace);
    }
  }

  Future<void> checkNow() async {
    if (!Platform.isMacOS || _checking || _directory == null) return;
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
      if (manifest.signature == null) {
        throw const FormatException('Mac update has no publisher signature');
      }
      if (UpdateManifest.compareVersions(manifest.version, bobTvVersion) <= 0) {
        return;
      }
      final skipped = File(p.join(_directory!.path, 'skipped_versions.txt'));
      if (await skipped.exists() &&
          (await skipped.readAsLines()).contains(manifest.version)) {
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
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'mac_update_check',
        error,
        stackTrace,
      );
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
    final configured = File(
      p.join(_directory!.path, 'update-manifest-url.txt'),
    );
    final machine = await Process.run('/usr/bin/uname', ['-m']);
    if (machine.exitCode != 0) {
      throw const FormatException('Cannot determine Mac architecture');
    }
    final architecture = machine.stdout.toString().trim() == 'arm64'
        ? 'arm64'
        : 'x64';
    final address = await configured.exists()
        ? (await configured.readAsString()).trim()
        : 'https://$_mirrorHost/updates/macos-$architecture/latest.json';
    final candidate = Uri.tryParse(address);
    if (candidate == null ||
        candidate.scheme != 'https' ||
        candidate.host != _mirrorHost ||
        candidate.userInfo.isNotEmpty ||
        candidate.hasPort ||
        candidate.hasQuery ||
        candidate.hasFragment ||
        !candidate.path.startsWith('/updates/') ||
        !candidate.path.endsWith('.json')) {
      throw const FormatException('Invalid Mac update manifest URL');
    }
    return candidate;
  }

  String get _appPath =>
      p.normalize(p.join(p.dirname(Platform.resolvedExecutable), '..', '..'));

  Future<File> _writeWorker() async {
    final file = File(p.join(_directory!.path, 'mac_worker-$bobTvVersion.sh'));
    final source = await rootBundle.loadString('assets/updater/mac_worker.sh');
    await _writeAtomic(file, source);
    await _writeAtomic(File(p.join(_directory!.path, 'mac_worker.sh')), source);
    final publicKey = await rootBundle.loadString(
      'assets/updater/update-signing-public.pem',
    );
    await _writeAtomic(
      File(p.join(_directory!.path, 'update-signing-public.pem')),
      publicKey,
    );
    return file;
  }

  Future<void> _launchWorker(UpdateManifest manifest) async {
    final script = await _writeWorker();
    _runId = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    _workerStartedAt = DateTime.now();
    _workerLaunchedForVersion = manifest.version;
    // Prepare the observer before downloading can reach ready. A fast download
    // must not let app exit interrupt copying or launching the status window.
    await _launchProgressWindow(manifest);
    final process = await Process.start(
      '/bin/bash',
      [
        script.path,
        'update',
        _directory!.path,
        _appPath,
        '$pid',
        manifest.version,
        manifest.archive.toString(),
        manifest.sha256,
        '${manifest.bytes}',
        manifest.signature!,
        _runId!,
      ],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    _workerPid = process.pid;
    AppDiagnostics.instance.log('mac_update_worker_started', {
      'version': manifest.version,
      'pid': _workerPid,
      'runId': _runId,
    });
    await _readWorkerStatus();
  }

  Future<void> _launchProgressWindow(UpdateManifest manifest) async {
    try {
      final source = p.join(
        _appPath,
        'Contents',
        'Resources',
        'Updater',
        'BobTVUpdateProgress.app',
      );
      final destination = p.join(_directory!.path, 'Progress-$_runId.app');
      final copy = await Process.run('/usr/bin/ditto', [source, destination]);
      if (copy.exitCode != 0) throw StateError('无法准备独立更新窗口');
      final observer = await Process.run('/usr/bin/open', [
        '-n',
        '-a',
        destination,
        '--args',
        _directory!.path,
        _appPath,
        '$pid',
        '0', // The observer reads the real worker PID from its run status.
        manifest.version,
        _runId!,
      ], runInShell: false);
      if (observer.exitCode != 0) {
        throw ProcessException(
          '/usr/bin/open',
          [],
          observer.stderr.toString(),
          observer.exitCode,
        );
      }
      AppDiagnostics.instance.log('mac_update_progress_started', {
        'launcherExitCode': observer.exitCode,
        'runId': _runId,
      });
    } catch (error, stack) {
      AppDiagnostics.instance.recordError(
        'mac_update_progress_window',
        error,
        stack,
      );
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.starting,
        version: manifest.version,
        message: '更新助手已启动，但独立进度窗口未能启动，详情已写入日志。',
      );
    }
  }

  Future<void> _writeAtomic(File file, String source) async {
    if (await file.exists() && await file.readAsString() == source) return;
    final temporary = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    await temporary.writeAsString(source, flush: true);
    await temporary.rename(file.path);
  }

  Future<bool> _attachExistingWorker(String version) async {
    final file = File(p.join(_directory!.path, 'status.json'));
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
    if ((await Process.run('/bin/kill', [
          '-0',
          '${data['workerPid']}',
        ])).exitCode !=
        0) {
      return false;
    }
    _workerPid = data['workerPid'] as int;
    _runId = data['runId'] as String;
    _workerLaunchedForVersion = version;
    _workerStartedAt = DateTime.now();
    state.value = reported;
    AppDiagnostics.instance.log('mac_update_worker_attached', {
      'version': version,
      'pid': _workerPid,
    });
    return true;
  }

  Future<bool> _isWorkerRunning() async {
    if (_workerPid == null) return false;
    final result = await Process.run('/bin/kill', ['-0', '$_workerPid']);
    return result.exitCode == 0;
  }

  Future<void> _readInstalledStatus() async {
    try {
      final file = File(p.join(_directory!.path, 'status.json'));
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map<String, dynamic> ||
          data['phase'] != 'installed' ||
          data['version'] != bobTvVersion ||
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
        'mac_update_installed_status',
        error,
        stack,
      );
    }
  }

  Future<void> _startHealthMonitor() async {
    final candidate = File(p.join(_directory!.path, 'candidate.txt'));
    if (!await candidate.exists()) return;
    final marker = File(p.join(_directory!.path, 'startup.marker'));
    if (await marker.exists() &&
        (await marker.readAsString()).trim() == '$pid') {
      return;
    }
    await marker.writeAsString('$pid', flush: true);
    final script = await _writeWorker();
    await Process.start(
      '/bin/bash',
      [script.path, 'monitor', _directory!.path, _appPath, '$pid'],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }

  Future<void> markStartupHealthy() async {
    if (!Platform.isMacOS) return;
    if (_started) await _healthMonitorReady.future;
    if (_directory == null) {
      final support = await getApplicationSupportDirectory();
      _directory = Directory(p.join(support.path, 'Update'));
    }
    final marker = File(p.join(_directory!.path, 'startup.marker'));
    if (!await marker.exists()) return;
    await File(
      p.join(_directory!.path, 'startup.healthy'),
    ).writeAsString('$pid', flush: true);
    await marker.delete();
  }

  Future<void> _readWorkerStatus() async {
    final directory = _directory;
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
          );
        }
      }
      if (reported != null) state.value = reported;
      if (reported?.phase == WindowsUpdatePhase.failed ||
          reported?.phase == WindowsUpdatePhase.installed) {
        if (_reportedFailureVersion != reported!.version &&
            reported.phase == WindowsUpdatePhase.failed) {
          _reportedFailureVersion = reported.version;
          AppDiagnostics.instance.log('mac_update_failed', {
            'version': reported.version,
          });
        }
        return;
      }
      if (!await _isWorkerRunning()) {
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.failed,
          version: _workerLaunchedForVersion,
          message: '更新助手意外退出，下载或安装尚未完成。请查看 worker.log 后重试。',
        );
        AppDiagnostics.instance.log('mac_update_failed', {
          'version': _workerLaunchedForVersion,
          'pid': _workerPid,
        });
      } else if (reported == null &&
          _workerStartedAt != null &&
          DateTime.now().difference(_workerStartedAt!) >
              const Duration(seconds: 30)) {
        state.value = WindowsUpdateState(
          WindowsUpdatePhase.failed,
          version: _workerLaunchedForVersion,
          message: '更新助手启动后 30 秒仍未返回工作状态，请查看 worker.log 或重试。',
        );
      }
    } catch (error, stack) {
      AppDiagnostics.instance.recordError(
        'mac_update_status_read',
        error,
        stack,
      );
    } finally {
      _readingStatus = false;
    }
  }
}
