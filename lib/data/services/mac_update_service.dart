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
/// only after the app exits and verifies the replacement's Apple signature.
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
      final request = await client.getUrl(manifestUri).timeout(
        const Duration(seconds: 10),
      );
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
        utf8.decode(buffer.takeBytes()), manifestUri,
      );
      if (UpdateManifest.compareVersions(manifest.version, bobTvVersion) <= 0) {
        return;
      }
      final skipped = File(p.join(_directory!.path, 'skipped_versions.txt'));
      if (await skipped.exists() &&
          (await skipped.readAsLines()).contains(manifest.version)) {
        return;
      }
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.available, version: manifest.version,
      );
      if (_workerLaunchedForVersion == manifest.version) return;
      await _launchWorker(manifest);
      _workerLaunchedForVersion = manifest.version;
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError('mac_update_check', error, stackTrace);
    } finally {
      client.close(force: true);
      _checking = false;
    }
  }

  Future<Uri?> _resolveManifestUri() async {
    final configured = File(p.join(_directory!.path, 'update-manifest-url.txt'));
    final machine = await Process.run('/usr/bin/uname', ['-m']);
    if (machine.exitCode != 0) {
      throw const FormatException('Cannot determine Mac architecture');
    }
    final architecture = machine.stdout.toString().trim() == 'arm64'
        ? 'arm64' : 'x64';
    final address = await configured.exists()
        ? (await configured.readAsString()).trim()
        : 'https://$_mirrorHost/updates/macos-$architecture/latest.json';
    final candidate = Uri.tryParse(address);
    if (candidate == null || candidate.scheme != 'https' ||
        candidate.host != _mirrorHost || candidate.userInfo.isNotEmpty ||
        candidate.hasQuery || candidate.hasFragment ||
        !candidate.path.startsWith('/updates/') ||
        !candidate.path.endsWith('.json')) {
      throw const FormatException('Invalid Mac update manifest URL');
    }
    return candidate;
  }

  String get _appPath => p.normalize(p.join(
    p.dirname(Platform.resolvedExecutable), '..', '..',
  ));

  Future<File> _writeWorker() async {
    final file = File(p.join(_directory!.path, 'mac_worker.sh'));
    final source = await rootBundle.loadString('assets/updater/mac_worker.sh');
    await file.writeAsString(source, flush: true);
    return file;
  }

  Future<void> _launchWorker(UpdateManifest manifest) async {
    final script = await _writeWorker();
    await Process.start('/bin/bash', [
      script.path, 'update', _directory!.path, _appPath, '$pid',
      manifest.version, manifest.archive.toString(), manifest.sha256,
      '${manifest.bytes}',
    ], mode: ProcessStartMode.detached, runInShell: false);
    AppDiagnostics.instance.log('mac_update_worker_started', {
      'version': manifest.version,
    });
  }

  Future<void> _startHealthMonitor() async {
    final candidate = File(p.join(_directory!.path, 'candidate.txt'));
    if (!await candidate.exists()) return;
    final marker = File(p.join(_directory!.path, 'startup.marker'));
    await marker.writeAsString('$pid', flush: true);
    final script = await _writeWorker();
    await Process.start('/bin/bash', [
      script.path, 'monitor', _directory!.path, _appPath, '$pid',
    ], mode: ProcessStartMode.detached, runInShell: false);
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
    await File(p.join(_directory!.path, 'startup.healthy'))
        .writeAsString('$pid', flush: true);
    await marker.delete();
  }

  Future<void> _readWorkerStatus() async {
    final directory = _directory;
    if (directory == null) return;
    final file = File(p.join(directory.path, 'status.json'));
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final version = decoded['version'];
      if (version is! String ||
          UpdateManifest.compareVersions(version, bobTvVersion) <= 0) return;
      final phase = switch (decoded['phase']) {
        'downloading' => WindowsUpdatePhase.downloading,
        'ready' => WindowsUpdatePhase.ready,
        'installing' => WindowsUpdatePhase.installing,
        'failed' => WindowsUpdatePhase.failed,
        _ => WindowsUpdatePhase.available,
      };
      if (phase == WindowsUpdatePhase.failed &&
          _workerLaunchedForVersion == version) {
        _workerLaunchedForVersion = null;
      }
      if (phase == WindowsUpdatePhase.failed &&
          _reportedFailureVersion != version) {
        _reportedFailureVersion = version;
        AppDiagnostics.instance.log('mac_update_failed', {
          'version': version,
        });
      }
      state.value = WindowsUpdateState(phase, version: version,
        percent: decoded['percent'] is int ? decoded['percent'] as int : null);
    } catch (_) {
      // A concurrent status replacement can be read again on the next tick.
    }
  }
}
