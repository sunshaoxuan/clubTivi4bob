import '../../core/server_egress.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final serverTaskClientProvider = Provider<ServerTaskClient>(
  (ref) => ServerTaskClient(),
);

/// No provider credentials or arbitrary prompts ever leave the client.
class ServerTaskClient {
  ServerTaskClient({Dio? dio, Uri? baseUri})
    : _provided = dio,
      _baseUri = baseUri ?? Uri.parse('https://bobtv.briconbric.com');
  final Dio? _provided;
  final Uri _baseUri;

  Future<Map<String, dynamic>> status() => _request('GET', '/status');

  Future<Map<String, dynamic>> result(String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('Invalid server task ID');
    }
    return _request('GET', '/$id');
  }

  Future<Map<String, dynamic>> submit(
    String kind,
    List<Map<String, String>> inputs,
  ) => _request('POST', '', data: {'kind': kind, 'inputs': inputs});

  Future<Map<String, dynamic>> classify(
    String kind,
    List<Map<String, String>> inputs,
  ) async {
    var value = await submit(kind, inputs);
    final id = value['id'];
    if (id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) return value;
    for (
      var attempt = 0;
      attempt < 12 &&
          (value['state'] == 'queued' || value['state'] == 'running');
      attempt++
    ) {
      await Future<void>.delayed(const Duration(seconds: 20));
      value = await _request('GET', '/$id');
    }
    return value;
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? data,
  }) async {
    final client =
        _provided ??
        ServerEgress.dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 8),
            followRedirects: false,
          ),
        );
    try {
      final response = await client.request<Map<String, dynamic>>(
        _baseUri.resolve('/api/v1/server-tasks$path').toString(),
        data: data,
        options: Options(
          method: method,
          headers: {'Content-Type': 'application/json'},
        ),
      );
      return response.data ?? <String, dynamic>{};
    } finally {
      if (_provided == null) client.close();
    }
  }
}
