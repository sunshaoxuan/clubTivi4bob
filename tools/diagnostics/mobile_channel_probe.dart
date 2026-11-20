// Native offline probe using the production phone widget and player service.
// Does not read user subscriptions, preferences, credentials or production APIs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import 'package:clubtivi/app/theme.dart';
import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:clubtivi/features/channels/mobile_channel_home.dart';
import 'package:clubtivi/features/player/player_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (Platform.isMacOS) await windowManager.ensureInitialized();
  final report = Directory(Platform.environment['BOBTV_MOBILE_REPORT']!);
  await report.create(recursive: true);
  await AppDiagnostics.instance.initialize(
    directoryOverride: Directory('${report.path}/diagnostics'),
  );
  final media = Platform.environment['BOBTV_MOBILE_MEDIA']!;
  if (Platform.isMacOS) {
    await windowManager.setTitle('BobTV Mobile QA · isolated silent probe');
    await windowManager.setMinimumSize(const Size(320, 320));
    await windowManager.setSize(const Size(430, 870));
    await windowManager.show();
  }
  final logoRoot = Platform.environment['BOBTV_MOBILE_LOGOS'];
  final logos = logoRoot == null
      ? <Map<String, dynamic>>[]
      : ((jsonDecode(File('$logoRoot/manifest.json').readAsStringSync())
                    as Map)['channels']
                as List)
            .cast<Map<String, dynamic>>()
            .where((c) => c['file'] != null)
            .toList();
  final service = PlayerService();
  final boundary = GlobalKey();
  final state = GlobalKey<_ProbeState>();
  final errors = <String>[];
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
    File(
      '${report.path}/flutter-errors.json',
    ).writeAsStringSync(jsonEncode(errors));
  };
  void record(String event, Map<String, Object?> fields) {
    File('${report.path}/events.jsonl').writeAsStringSync(
      '${jsonEncode({'event': event, 'time': DateTime.now().toUtc().toIso8601String(), ...fields})}\n',
      mode: FileMode.append,
    );
  }

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ClubTiviTheme.dark,
      locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      supportedLocales: AppLanguage.values.map((l) => l.locale),
      localizationsDelegates: const [
        AppMessages.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: RepaintBoundary(
        key: boundary,
        child: _Probe(
          key: state,
          service: service,
          media: media,
          record: record,
          logos: logos,
          logoRoot: logoRoot,
        ),
      ),
    ),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  File('${report.path}/port').writeAsStringSync('${server.port}');
  record('started', {
    'pid': pid,
    'port': server.port,
    'audioTracksInFixture': 0,
    'installedAppsChanged': false,
  });
  await for (final request in server) {
    try {
      final route = request.uri.path;
      if (route == '/status') {
        request.response.write(
          jsonEncode({
            'positionMs': service.player.state.position.inMilliseconds,
            'width': service.player.state.width,
            'height': service.player.state.height,
            'playing': service.player.state.playing,
            'volume': service.player.state.volume,
            'currentId': service.currentChannelId,
            'flutterErrors': errors,
            'size':
                '${ui.PlatformDispatcher.instance.views.first.physicalSize}',
          }),
        );
      } else if (route == '/landscape' || route == '/portrait') {
        if (Platform.isMacOS) {
          await windowManager.setSize(
            route == '/landscape' ? const Size(884, 440) : const Size(430, 870),
          );
        } else {
          await SystemChrome.setPreferredOrientations(
            route == '/landscape'
                ? [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight,
                  ]
                : [DeviceOrientation.portraitUp],
          );
        }
        request.response.write('resized');
      } else if (route == '/play') {
        await state.currentState!.select('0');
        request.response.write('playing');
      } else if (route == '/capture') {
        await WidgetsBinding.instance.endOfFrame;
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final name = request.uri.queryParameters['name'] ?? 'capture';
        if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(name)) {
          throw ArgumentError('Invalid capture name');
        }
        File(
          '${report.path}/$name.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
        record('capture', {
          'name': name,
          'positionMs': service.player.state.position.inMilliseconds,
        });
        request.response.write('captured');
      } else if (route == '/quit') {
        await service.dispose();
        record('completed', {'flutterErrors': errors});
        request.response.write('closed');
        await request.response.close();
        await server.close(force: true);
        exit(0);
      } else {
        request.response.statusCode = 404;
      }
    } catch (error, stack) {
      record('probe_error', {'error': '$error', 'stack': '$stack'});
      request.response.statusCode = 500;
      request.response.write('$error');
    }
    await request.response.close();
  }
}

class _Probe extends StatefulWidget {
  const _Probe({
    super.key,
    required this.service,
    required this.media,
    required this.record,
    this.logos = const [],
    this.logoRoot,
  });
  final PlayerService service;
  final String media;
  final List<Map<String, dynamic>> logos;
  final String? logoRoot;
  final void Function(String, Map<String, Object?>) record;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  String _category = '央视';
  String _country = '';
  String? _id;
  Future<bool> select(String id) async {
    if (id == '39') {
      widget.record('selection_failed', {'id': id});
      return false;
    }
    final service = widget.service;
    if (service.currentUrl == null) {
      await service.play(
        widget.media,
        channelId: id,
        channelName: '静音测试频道 $id',
      );
    } else {
      final ready = await service.switchChannel(
        widget.media,
        channelId: id,
        channelName: '静音测试频道 $id',
      );
      if (!ready) return false;
    }
    await service.setVolume(0);
    await service.player.setPlaylistMode(PlaylistMode.single);
    if (!mounted) return false;
    setState(() => _id = id);
    widget.record('selected', {
      'id': id,
      'volume': service.player.state.volume,
    });
    return true;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF09101C),
    resizeToAvoidBottomInset: false,
    body: SafeArea(
      child: MobileChannelHome(
        video: ValueListenableBuilder<VideoController?>(
          valueListenable: widget.service.activeVideoController,
          builder: (_, controller, _) => Video(
            controller: controller ?? widget.service.videoController,
            controls: NoVideoControls,
          ),
        ),
        channels: List.generate(
          40,
          (i) => MobileChannelItem(
            id: '$i',
            name: i == 39
                ? '失败状态测试'
                : widget.logos.isEmpty
                ? '静音测试频道 ${i + 1}'
                : widget.logos[i % widget.logos.length]['name'] as String,
            logoImage: widget.logos.isEmpty
                ? null
                : FileImage(
                    File(
                      '${widget.logoRoot}/${widget.logos[i % widget.logos.length]['file']}',
                    ),
                  ),
            sourceId: i.isEven ? 'a' : 'b',
            programme: '本地自制无音轨测试片',
            favorite: i % 3 == 0,
          ),
        ),
        sources: const {'a': '本地测试源 A', 'b': '本地测试源 B'},
        categories: const ['央视', '纪录片', '国际', '地方台'],
        category: _category,
        countries: const ['日本', '法国'],
        country: _country,
        currentId: _id,
        currentName: _id == null ? null : '静音测试频道 ${int.parse(_id!) + 1}',
        programme: '测试环境 · 不读取用户数据',
        muted: true,
        playing: widget.service.player.state.playing,
        onCategory: (category, country) async {
          setState(() {
            _category = category;
            _country = country;
          });
          widget.record('filter_applied', {
            'category': category,
            'country': country,
          });
        },
        onSelect: select,
        onPause: () async {
          await widget.service.player.playOrPause();
          if (mounted) setState(() {});
        },
        onMute: () {},
        onManageSources: () {},
      ),
    ),
  );
}
