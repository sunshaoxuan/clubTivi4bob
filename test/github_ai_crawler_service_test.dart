import 'dart:convert';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/github_ai_crawler_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpenAiRuntimeConfig', () {
    test('is disabled when either required value is missing', () {
      expect(OpenAiRuntimeConfig.fromEnvironment({}).enabled, isFalse);
      expect(
        OpenAiRuntimeConfig.fromEnvironment({
          'OPENAI_BASE_URL': 'http://127.0.0.1:60813/v1',
        }).enabled,
        isFalse,
      );
    });

    test('is enabled when base URL and key are present', () {
      final config = OpenAiRuntimeConfig.fromEnvironment({
        'OPENAI_BASE_URL': 'http://127.0.0.1:60813/v1',
        'OPENAI_API_KEY': 'test-only-key',
        'OPENAI_MODEL': 'gpt-test',
      });
      expect(config.enabled, isTrue);
      expect(config.model, 'gpt-test');
    });
  });

  group('GitHub recursive link policy', () {
    test('accepts a relative child document', () {
      expect(
        normalizeGitHubDocumentLink(
          'lists/china/source.data',
          owner: 'sample',
          repo: 'iptv',
          ref: 'main',
        ),
        'lists/china/source.data',
      );
    });

    test('accepts same repository raw and blob links', () {
      expect(
        normalizeGitHubDocumentLink(
          'https://raw.githubusercontent.com/sample/iptv/main/data/live.any',
          owner: 'sample',
          repo: 'iptv',
          ref: 'main',
        ),
        'data/live.any',
      );
      expect(
        normalizeGitHubDocumentLink(
          'https://github.com/sample/iptv/blob/main/data/live.any',
          owner: 'sample',
          repo: 'iptv',
          ref: 'main',
        ),
        'data/live.any',
      );
    });

    test('rejects traversal and links to another repository', () {
      expect(
        normalizeGitHubDocumentLink(
          '../secret',
          owner: 'sample',
          repo: 'iptv',
          ref: 'main',
        ),
        isNull,
      );
      expect(
        normalizeGitHubDocumentLink(
          'https://github.com/other/repo/blob/main/list.txt',
          owner: 'sample',
          repo: 'iptv',
          ref: 'main',
        ),
        isNull,
      );
    });
  });

  test('discovered channel IDs are stable and route specific', () {
    final first = discoveredChannelId(
      owner: 'sample',
      repo: 'iptv',
      path: 'unusual/source.data',
      name: 'CCTV5',
      url: 'https://example.com/live.m3u8',
    );
    final repeated = discoveredChannelId(
      owner: 'sample',
      repo: 'iptv',
      path: 'unusual/source.data',
      name: 'CCTV5',
      url: 'https://example.com/live.m3u8',
    );
    final alternative = discoveredChannelId(
      owner: 'sample',
      repo: 'iptv',
      path: 'unusual/source.data',
      name: 'CCTV5',
      url: 'https://example.com/backup.m3u8',
    );
    expect(first, repeated);
    expect(first, isNot(alternative));
  });

  test('stream URL validation permits player protocols', () {
    expect(isSupportedStreamUrl('https://example.com/live.m3u8'), isTrue);
    expect(isSupportedStreamUrl('rtmp://example.com/live'), isTrue);
    expect(isSupportedStreamUrl('javascript:alert(1)'), isFalse);
  });

  test(
    'AI selected arbitrary document imports a candidate with provenance',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final openAi = Dio();
      openAi.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/models')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'data': [
                      <String, dynamic>{'id': 'gpt-test'},
                    ],
                  },
                ),
              );
              return;
            }
            final data = options.data as Map;
            final schemaName =
                ((data['response_format'] as Map)['json_schema']
                    as Map)['name'];
            final content = switch (schemaName) {
              'github_iptv_search_queries' => '{"queries":["iptv"]}',
              'github_candidate_documents' =>
                '{"paths":["odd/location/data.bin"]}',
              _ => jsonEncode({
                'containsStreams': true,
                'format': 'custom binary export rendered as text',
                'confidence': 0.91,
                'streams': [
                  {
                    'name': 'CCTV5',
                    'url': 'https://example.com/cctv5/live.m3u8',
                    'group': '体育',
                    'logo': '',
                    'tvgId': 'CCTV5',
                  },
                ],
                'followLinks': <String>[],
              }),
            };
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'choices': [
                    {
                      'message': {'content': content},
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
      final github = Dio();
      github.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            Object data;
            if (options.path.endsWith('/search/repositories')) {
              data = <String, dynamic>{
                'items': [
                  {
                    'owner': {'login': 'sample'},
                    'name': 'iptv',
                    'default_branch': 'main',
                  },
                ],
              };
            } else if (options.path.contains('/git/trees/main')) {
              data = <String, dynamic>{
                'sha': 'commit-1',
                'truncated': false,
                'tree': [
                  {
                    'type': 'blob',
                    'path': 'odd/location/data.bin',
                    'size': 200,
                  },
                ],
              };
            } else {
              data = 'opaque data with a stream record';
            }
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: data),
            );
          },
        ),
      );

      final service = GitHubAiCrawlerService(
        database: database,
        config: const OpenAiRuntimeConfig(
          baseUrl: 'http://127.0.0.1:60813/v1',
          apiKey: 'test-only-key',
          model: 'gpt-test',
        ),
        githubDio: github,
        openAiDio: openAi,
      );
      await service.run();

      final channels = await database.getChannelsForProvider(
        GitHubAiCrawlerService.providerId,
      );
      final provenance = await database.getDiscoveredStreamSources();
      expect(channels, hasLength(1));
      expect(channels.single.name, 'CCTV5');
      expect(provenance, hasLength(1));
      expect(provenance.single.githubPath, 'odd/location/data.bin');
      expect(provenance.single.githubRepo, 'iptv');

      service.dispose();
      github.close(force: true);
      openAi.close(force: true);
      await database.close();
    },
  );

  test('selected M3U imports locally without document AI expansion', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    var documentAnalysisRequests = 0;
    final openAi = Dio();
    openAi.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/models')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'data': [
                    <String, dynamic>{'id': 'gpt-test'},
                  ],
                },
              ),
            );
            return;
          }
          final data = options.data as Map;
          final schemaName =
              ((data['response_format'] as Map)['json_schema'] as Map)['name'];
          if (schemaName == 'github_playlist_document_analysis') {
            documentAnalysisRequests++;
          }
          final content = schemaName == 'github_iptv_search_queries'
              ? '{"queries":["iptv"]}'
              : '{"paths":["generated/channels.payload"]}';
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'choices': [
                  {
                    'message': {'content': content},
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    final github = Dio();
    github.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          Object data;
          if (options.path.endsWith('/search/repositories')) {
            data = <String, dynamic>{
              'items': [
                {
                  'owner': {'login': 'sample'},
                  'name': 'iptv',
                  'default_branch': 'main',
                },
              ],
            };
          } else if (options.path.contains('/git/trees/main')) {
            data = <String, dynamic>{
              'sha': 'commit-m3u',
              'truncated': false,
              'tree': [
                {
                  'type': 'blob',
                  'path': 'generated/channels.payload',
                  'size': 200,
                },
              ],
            };
          } else {
            data =
                '#EXTM3U\n'
                '#EXTINF:-1 tvg-id="CCTV5",CCTV5\n'
                'https://example.com/cctv5/live.m3u8\n';
          }
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: data),
          );
        },
      ),
    );

    final service = GitHubAiCrawlerService(
      database: database,
      config: const OpenAiRuntimeConfig(
        baseUrl: 'http://127.0.0.1:60813/v1',
        apiKey: 'test-only-key',
        model: 'gpt-test',
      ),
      githubDio: github,
      openAiDio: openAi,
    );
    await service.run();

    final channels = await database.getChannelsForProvider(
      GitHubAiCrawlerService.providerId,
    );
    expect(documentAnalysisRequests, 0);
    expect(channels, hasLength(1));
    expect(channels.single.name, 'CCTV5');

    service.dispose();
    github.close(force: true);
    openAi.close(force: true);
    await database.close();
  });
}
