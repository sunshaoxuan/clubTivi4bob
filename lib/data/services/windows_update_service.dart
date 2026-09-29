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

  final state = ValueNotifier<WindowsUpdateState>(
    const WindowsUpdateState(WindowsUpdatePhase.idle),
  );
  bool _checking = false;
  bool _started = false;
  Directory? _updateDirectory;
  String? _workerLaunchedForVersion;

  void start() {
    if (!Platform.isWindows || _started) return;
    _started = true;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) return;
    _updateDirectory = Directory(p.join(localAppData, 'HotelTV', 'Update'));
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
        utf8.decode(buffer.takeBytes()),
        manifestUri,
      );
      if (UpdateManifest.compareVersions(manifest.version, bobTvVersion) <= 0) {
        return;
      }
      final skipped = File(p.join(_updateDirectory!.path, 'skipped_versions.txt'));
      if (await skipped.exists() &&
          (await skipped.readAsLines()).contains(manifest.version)) {
        AppDiagnostics.instance.log('update_skipped_bad_version', {
          'version': manifest.version,
        });
        return;
      }
      state.value = WindowsUpdateState(
        WindowsUpdatePhase.available,
        version: manifest.version,
      );
      if (_workerLaunchedForVersion == manifest.version) return;
      await _launchWorker(manifest);
      _workerLaunchedForVersion = manifest.version;
    } catch (error, stack) {
      AppDiagnostics.instance.recordError('update_check', error, stack);
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
    await script.writeAsBytes(
      [0xef, 0xbb, 0xbf, ...utf8.encode(source)],
      flush: true,
    );
    final appDirectory = p.dirname(Platform.resolvedExecutable);
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
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
      ],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    AppDiagnostics.instance.log('update_worker_started', {
      'version': manifest.version,
    });
  }

  Future<File> _writeShortcutScript() async {
    final directory = _updateDirectory!;
    await directory.create(recursive: true);
    final script = File(p.join(directory.path, 'ensure_shortcut.ps1'));
    final source = await rootBundle.loadString(
      'assets/updater/ensure_shortcut.ps1',
    );
    await script.writeAsBytes(
      [0xef, 0xbb, 0xbf, ...utf8.encode(source)],
      flush: true,
    );
    return script;
  }

  Future<void> _ensureDesktopShortcut() async {
    try {
      final script = await _writeShortcutScript();
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-ExecutablePath',
          Platform.resolvedExecutable,
        ],
        runInShell: false,
      ).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) {
        throw StateError('Desktop shortcut creation failed: ${result.exitCode}');
      }
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'desktop_shortcut', error, stackTrace,
      );
    }
  }

  Future<void> _readWorkerStatus() async {
    final directory = _updateDirectory;
    if (directory == null) return;
    final file = File(p.join(directory.path, 'status.json'));
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final version = decoded['version'];
      if (version is! String ||
          UpdateManifest.compareVersions(version, bobTvVersion) <= 0) {
        return;
      }
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
      state.value = WindowsUpdateState(
        phase,
        version: version,
        percent: decoded['percent'] is int ? decoded['percent'] as int : null,
        message: decoded['message'] is String ? decoded['message'] as String : null,
      );
    } catch (_) {
      // The writer atomically replaces this file. A transient read can retry.
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
