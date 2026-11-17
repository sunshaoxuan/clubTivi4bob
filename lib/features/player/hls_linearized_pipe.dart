import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../core/app_diagnostics.dart';

/// One local stream-copy pipe. It shares the existing HLS fetches and never
/// decodes audio/video or sends media to a subtitle server.
class HlsLinearizedPipe {
  Process? _process;
  HttpServer? _server;
  StreamSubscription<String>? _errors;
  int _generation = 0;
  StreamIterator<List<int>>? _output;

  Future<String> start(String source) async {
    await stop();
    final generation = _generation;
    final executable = File(Platform.resolvedExecutable).parent.parent.path;
    final helper = File('$executable/Resources/ClientASR/bobtv-client-remux');
    if (!await helper.exists()) {
      throw StateError('Client timestamp normalizer is unavailable');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final process = await Process.start(helper.path, [source]);
    if (generation != _generation) {
      process.kill();
      await server.close(force: true);
      throw const HttpException('Client playback pipe was superseded');
    }
    _server = server;
    _process = process;
    _errors = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.length > 2048) return;
          try {
            final decoded = jsonDecode(line);
            if (decoded is! Map<String, dynamic>) return;
            final data = decoded;
            if (data['event'] == 'remux_discontinuity' ||
                data['event'] == 'remux_error') {
              AppDiagnostics.instance.log(
                'client_${data.remove('event')}',
                data,
              );
            }
          } on FormatException {
            // FFmpeg diagnostics can contain signed URLs; keep them out of logs.
          }
        });
    final output = _output = StreamIterator<List<int>>(process.stdout);
    try {
      if (!await output.moveNext().timeout(const Duration(seconds: 20))) {
        throw StateError('Client timestamp normalizer closed before media');
      }
    } on Object {
      await stop();
      rethrow;
    }
    Stream<List<int>> media() async* {
      yield output.current;
      while (await output.moveNext()) {
        yield output.current;
      }
    }

    var claimed = false;
    server.listen((request) async {
      try {
        if (request.uri.path != '/playback.ts') {
          request.response.statusCode = 404;
          return;
        }
        request.response.headers.contentType = ContentType('video', 'mp2t');
        request.response.headers.set('Cache-Control', 'no-store');
        if (request.method == 'HEAD') return;
        if (request.method != 'GET' || claimed) {
          request.response.statusCode = 409;
          return;
        }
        claimed = true;
        await request.response.addStream(media());
      } on Object catch (error) {
        AppDiagnostics.instance.log('client_remux_reader_closed', {
          'errorType': error.runtimeType.toString(),
        });
        // Closing/switching the player cancels its single owned local pipe.
      } finally {
        try {
          await request.response.close();
        } on Object {
          /* Closed socket. */
        }
      }
    });
    unawaited(
      process.exitCode.then((code) {
        AppDiagnostics.instance.log('client_remux_exit', {
          'code': code,
          'current': identical(_process, process),
        });
      }),
    );
    AppDiagnostics.instance.log('client_remux_started', {
      'streamCopy': true,
      'serverMedia': false,
    });
    return 'http://127.0.0.1:${server.port}/playback.ts';
  }

  Future<void> stop() async {
    ++_generation;
    final process = _process;
    _process = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    await _output?.cancel();
    _output = null;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    await _errors?.cancel();
    _errors = null;
  }
}
