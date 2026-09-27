import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/app_diagnostics.dart';
import '../../core/app_version.dart';
import 'update_manifest.dart';

enum WindowsUpdatePhase { idle, available, downloading, ready, installing, failed }

class WindowsUpdateState {
  const WindowsUpdateState(this.phase, {this.version, this.percent, this.message});

  final WindowsUpdatePhase phase;
  final String? version;
  final int? percent;
  final String? message;

  bool get visible => phase != WindowsUpdatePhase.idle;
}

class WindowsUpdateService {
  WindowsUpdateService._();

  static final instance = WindowsUpdateService._();
  static final manifestUri =
      Uri.parse('https://bobtv.briconbric.com/updates/latest.json');
  static const _maxManifestBytes = 64 * 1024;

  final state = ValueNotifier<WindowsUpdateState>(
    const WindowsUpdateState(WindowsUpdatePhase.idle),
  );
  bool _checking = false;
  bool _started = false;
  Directory? _updateDirectory;

  void start() {
    if (!Platform.isWindows || _started) return;
    _started = true;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) return;
    _updateDirectory = Directory(p.join(localAppData, 'HotelTV', 'Update'));
    Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_readWorkerStatus()),
    );
    Timer.periodic(
      const Duration(hours: 6),
      (_) => unawaited(checkNow()),
    );
    Future.delayed(const Duration(seconds: 10), () => unawaited(checkNow()));
  }

  Future<void> checkNow() async {
    if (_checking || _updateDirectory == null) return;
    _checking = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(manifestUri).timeout(
        const Duration(seconds: 10),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
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
      await _launchWorker(manifest);
    } catch (error, stack) {
      AppDiagnostics.instance.recordError('update_check', error, stack);
    } finally {
      client.close(force: true);
      _checking = false;
      unawaited(_flushQueuedFailureReports());
    }
  }

  Future<void> _flushQueuedFailureReports() async {
    final directory = _updateDirectory;
    if (directory == null || !await directory.exists()) return;
    try {
      var endpoint =
          Uri.parse('https://bobtv.briconbric.com/api/update-failures');
      final configured = File(
        p.join(directory.path, 'failure-upload-url.txt'),
      );
      if (await configured.exists()) {
        endpoint = Uri.parse((await configured.readAsString()).trim());
      }
      if (endpoint.scheme != 'https' ||
          endpoint.host != 'bobtv.briconbric.com' ||
          endpoint.userInfo.isNotEmpty) {
        return;
      }
      final reports = await directory
          .list()
          .where((entry) =>
              entry is File &&
              p.basename(entry.path).startsWith('failure-') &&
              p.extension(entry.path) == '.json')
          .cast<File>()
          .take(5)
          .toList();
      for (final report in reports) {
        if (await report.length() > 256 * 1024) continue;
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 8);
        try {
          final request = await client.postUrl(endpoint)
              .timeout(const Duration(seconds: 10));
          request.followRedirects = false;
          request.headers.contentType = ContentType.json;
          request.add(await report.readAsBytes());
          final response = await request.close()
              .timeout(const Duration(seconds: 15));
          await response.drain<void>();
          if (response.statusCode >= 200 && response.statusCode < 300) {
            await report.delete();
          }
        } catch (_) {
          return;
        } finally {
          client.close(force: true);
        }
      }
    } catch (_) {}
  }

  Future<void> _launchWorker(UpdateManifest manifest) async {
    final directory = _updateDirectory!;
    await directory.create(recursive: true);
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
        await marker.delete();
        AppDiagnostics.instance.log('update_startup_healthy', {
          'version': bobTvVersion,
        });
      } catch (_) {}
    }
  }
}
