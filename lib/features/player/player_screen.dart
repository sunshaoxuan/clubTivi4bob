import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/app_diagnostics.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/services/channel_category_classifier.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../../features/providers/provider_manager.dart' show databaseProvider;
import '../casting/cast_service.dart';
import '../casting/cast_dialog.dart';
import '../channels/channel_debug_dialog.dart';
import 'player_control_bar.dart';
import 'player_service.dart';
import 'stream_info_badges.dart';

/// Full-screen video player with overlay controls and keyboard navigation.
class PlayerScreen extends ConsumerStatefulWidget {
  final String streamUrl;
  final String channelName;
  final String? channelLogo;
  final List<String> alternativeUrls;
  final List<Map<String, dynamic>> channels;
  final int currentIndex;

  const PlayerScreen({
    super.key,
    required this.streamUrl,
    required this.channelName,
    this.channelLogo,
    this.alternativeUrls = const [],
    this.channels = const [],
    this.currentIndex = 0,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  bool _showOverlay = true;
  int _currentUrlIndex = 0;
  bool _showChannelList = false;
  bool _isFavorite = false;
  int _channelSwitchGeneration = 0;
  bool _nativeFullscreen = false;
  bool _leavingPlayer = false;
  Rect? _windowBoundsBeforeFullscreen;
  bool _windowWasMaximized = false;
  bool _showCursor = true;
  Timer? _cursorTimer;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<Player>? _activePlayerSubscription;
  StreamSubscription<String?>? _castStatusSubscription;
  bool _castBusy = false;

  // Channel switching state
  late int _channelIndex;
  late String _currentChannelName;
  late String? _currentChannelLogo;

  // Volume state
  double _volume = 100.0;
  bool _showVolumeOverlay = false;
  Timer? _volumeTimer;

  // Overlay timer
  Timer? _overlayTimer;

  // EPG state
  String? _nowPlayingTitle;
  String? _nowPlayingTime;
  String? _nowDescription;
  String? _nextTitle;
  String? _nextTime;
  String? _groupTitle;
  String? _providerName;

  bool _allowsAudioOnly(Map<String, dynamic> channel) =>
      ChannelCategoryClassifier.isRadioChannel(
        name: channel['name']?.toString() ?? '',
        groupTitle: channel['groupTitle']?.toString(),
        tvgId: channel['tvgId']?.toString(),
        streamUrl: channel['streamUrl']?.toString(),
      );

  // Favorite lists
  List<db.FavoriteList> _favoriteLists = [];

  // Track selection state
  bool _subtitlesEnabled = false;
  List<SubtitleTrack> _subtitleTracks = [];
  List<AudioTrack> _audioTracks = [];

  @override
  void initState() {
    super.initState();
    _channelIndex = widget.currentIndex;
    _currentChannelName = widget.channelName;
    _currentChannelLogo = widget.channelLogo;
    if (widget.channels.isNotEmpty) {
      final ch = widget.channels[_channelIndex];
      _groupTitle = ch['groupTitle']?.toString();
      _providerName = ref
          .read(streamAlternativesProvider)
          .providerName(ch['providerId']?.toString() ?? '');
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setNativeFullscreen(true);
    });
    _startPlayback();
    _activePlayerSubscription = ref.read(playerServiceProvider)
        .activePlayerStream.listen((_) {
      _bindActivePlayerStreams();
      if (mounted) {
        _loadTrackInfo();
        setState(() {});
      }
    });
    _castStatusSubscription = ref.read(castServiceProvider).statusStream.listen(
      (message) {
        if (!mounted) return;
        setState(() {});
        if (message != null) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      },
    );
    _autoHideOverlay();
    _scheduleCursorHide();
    _loadEpgInfo();
    _loadFavoriteState();
  }

  Future<void> _loadFavoriteState() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final channelId = ch['id'] as String? ?? '';
    if (channelId.isEmpty) return;
    final database = ref.read(databaseProvider);
    final lists = await database.getAllFavoriteLists();
    final listsForChannel = await database.getListsForChannel(channelId);
    if (mounted) {
      setState(() {
        _favoriteLists = lists;
        _isFavorite = listsForChannel.isNotEmpty;
      });
    }
  }

  Future<void> _loadEpgInfo() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final epgId = ch['epgId'] as String?;
    if (epgId == null || epgId.isEmpty) {
      if (mounted) {
        setState(() {
          _nowPlayingTitle = null;
          _nowPlayingTime = null;
          _nowDescription = null;
          _nextTitle = null;
          _nextTime = null;
        });
      }
      return;
    }

    final database = ref.read(databaseProvider);
    final now = DateTime.now();
    final programmes = await database.getProgrammes(
      epgChannelId: epgId,
      start: now.subtract(const Duration(hours: 1)),
      end: now.add(const Duration(hours: 6)),
    );

    if (!mounted) return;

    db.EpgProgramme? current;
    db.EpgProgramme? next;
    for (final p in programmes) {
      if (now.isAfter(p.start) && now.isBefore(p.stop)) {
        current = p;
      } else if (current != null && next == null && now.isBefore(p.start)) {
        next = p;
        break;
      }
    }

    setState(() {
      _nowPlayingTitle = current?.title;
      _nowPlayingTime = current != null
          ? '${_fmtTime(current.start)} – ${_fmtTime(current.stop)}'
          : null;
      _nowDescription = current?.description;
      _nextTitle = next?.title;
      _nextTime = next != null
          ? '${_fmtTime(next.start)} – ${_fmtTime(next.stop)}'
          : null;
    });
  }

  String _fmtTime(DateTime t) {
    final tod = TimeOfDay.fromDateTime(t);
    final hour = tod.hourOfPeriod == 0 ? 12 : tod.hourOfPeriod;
    final min = tod.minute.toString().padLeft(2, '0');
    final period = tod.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$min $period';
  }

  void _startPlayback() {
    final playerService = ref.read(playerServiceProvider);
    final urls = [widget.streamUrl, ...widget.alternativeUrls];

    // If channels list is empty, this is a show/VOD stream — always start fresh
    final isShowStream = widget.channels.isEmpty;

    if (isShowStream ||
        !(playerService.player.state.playing ||
            playerService.player.state.buffering)) {
      playerService.play(
        urls[_currentUrlIndex],
        channelId: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['id'] as String?
            : null,
        epgChannelId: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['epgChannelId'] as String?
            : null,
        tvgId: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['tvgId'] as String?
            : null,
        channelName: _currentChannelName,
        vanityName: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['vanityName'] as String?
            : null,
        originalName: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['originalName'] as String? ??
                  widget.channels[_channelIndex]['tvgName'] as String?
            : null,
        failoverGroupUrls: widget.alternativeUrls,
        allowAudioOnly: widget.channels.isNotEmpty
            ? _allowsAudioOnly(widget.channels[_channelIndex])
            : false,
      );
    }

    _bindActivePlayerStreams();
  }

  void _bindActivePlayerStreams() {
    final playerService = ref.read(playerServiceProvider);
    // Load track info once tracks become available
    _tracksSubscription?.cancel();
    _tracksSubscription = playerService.player.stream.tracks.listen((tracks) {
      if (mounted) _loadTrackInfo();
    });

    _bufferingSubscription?.cancel();
    _bufferingSubscription = playerService.bufferingStream.listen((buffering) {
      playerService.onBufferingChanged(buffering);
    });
  }

  Future<void> _showCastPicker() async {
    if (_castBusy) return;
    final device = await showCastDialog(context, ref);
    if (device != null && mounted) {
      final castService = ref.read(castServiceProvider);
      final playerService = ref.read(playerServiceProvider);
      final url = castService.relayAirPlay
          ? playerService.castUrl
          : playerService.currentUrl;
      if (url == null) return;
      setState(() => _castBusy = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正在準備視頻並連接投屏設備…'),
          duration: Duration(seconds: 30),
        ),
      );
      final success = await castService.castTo(
        device,
        url,
        title: _currentChannelName,
      );
      if (mounted) setState(() => _castBusy = false);
      if (success && mounted) {
        final latestUrl = castService.relayAirPlay
            ? playerService.castUrl
            : playerService.currentUrl;
        if (latestUrl != null && latestUrl != url) {
          unawaited(
            castService.switchChannel(latestUrl, title: _currentChannelName),
          );
        }
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已向 ${device.name} 發送播放請求，請確認電視畫面'),
            backgroundColor: Colors.green.shade800,
            duration: const Duration(seconds: 2),
          ),
        );
        setState(() {});
      }
    }
  }

  void _loadTrackInfo() {
    final player = ref.read(playerServiceProvider).player;
    final tracks = player.state.tracks;
    setState(() {
      _subtitleTracks = tracks.subtitle
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      _audioTracks = tracks.audio
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      _subtitlesEnabled =
          player.state.track.subtitle.id != 'no' &&
          player.state.track.subtitle.id != 'auto';
    });
  }

  void _toggleSubtitles() {
    final player = ref.read(playerServiceProvider).player;
    if (_subtitlesEnabled) {
      player.setSubtitleTrack(SubtitleTrack.no());
      setState(() => _subtitlesEnabled = false);
    } else if (_subtitleTracks.isNotEmpty) {
      player.setSubtitleTrack(_subtitleTracks.first);
      setState(() => _subtitlesEnabled = true);
    }
  }

  void _showSubtitlePicker() {
    _loadTrackInfo();
    final player = ref.read(playerServiceProvider).player;
    final currentId = player.state.track.subtitle.id;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.closed_caption, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    '字幕',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.block,
                  color: currentId == 'no'
                      ? Colors.greenAccent
                      : Colors.white54,
                  size: 20,
                ),
                title: const Text(
                  '关闭',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                trailing: currentId == 'no'
                    ? const Icon(
                        Icons.check,
                        color: Colors.greenAccent,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  player.setSubtitleTrack(SubtitleTrack.no());
                  setState(() => _subtitlesEnabled = false);
                  Navigator.of(ctx).pop();
                },
              ),
              ..._subtitleTracks.map((t) {
                final isActive = t.id == currentId;
                return ListTile(
                  dense: true,
                  title: Text(
                    t.title ?? t.language ?? t.id,
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: t.language != null
                      ? Text(
                          t.language!,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        )
                      : null,
                  trailing: isActive
                      ? const Icon(
                          Icons.check,
                          color: Colors.greenAccent,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    player.setSubtitleTrack(t);
                    setState(() => _subtitlesEnabled = true);
                    Navigator.of(ctx).pop();
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _showAudioPicker() {
    _loadTrackInfo();
    final player = ref.read(playerServiceProvider).player;
    final currentId = player.state.track.audio.id;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.audiotrack, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    '音轨',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._audioTracks.map((t) {
                final isActive = t.id == currentId;
                return ListTile(
                  dense: true,
                  title: Text(
                    t.title ?? t.language ?? t.id,
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: t.language != null
                      ? Text(
                          t.language!,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        )
                      : null,
                  trailing: isActive
                      ? const Icon(
                          Icons.check,
                          color: Colors.greenAccent,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    player.setAudioTrack(t);
                    Navigator.of(ctx).pop();
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _autoHideOverlay() {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showOverlay = false);
    });
  }

  void _scheduleCursorHide() {
    _cursorTimer?.cancel();
    _cursorTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showCursor = false);
    });
  }

  void _onPointerActivity() {
    if (!_showCursor && mounted) setState(() => _showCursor = true);
    if (!_showOverlay && mounted) setState(() => _showOverlay = true);
    _autoHideOverlay();
    _scheduleCursorHide();
  }

  void _toggleOverlay() {
    setState(() => _showOverlay = !_showOverlay);
    if (_showOverlay) _autoHideOverlay();
  }

  bool get _supportsNativeFullscreen =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> _setNativeFullscreen(bool value) async {
    if (!_supportsNativeFullscreen) return;
    if (value) {
      _windowWasMaximized = await windowManager.isMaximized();
      _windowBoundsBeforeFullscreen = await windowManager.getBounds();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setFullScreen(true);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.focus();
    } else {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setFullScreen(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      if (_windowWasMaximized) {
        await windowManager.maximize();
      } else if (_windowBoundsBeforeFullscreen != null) {
        await windowManager.setBounds(_windowBoundsBeforeFullscreen!);
      }
      _windowBoundsBeforeFullscreen = null;
    }
    if (mounted) setState(() => _nativeFullscreen = value);
  }

  Future<void> _toggleNativeFullscreen() async {
    if (_nativeFullscreen) {
      await _leavePlayer();
    } else {
      await _setNativeFullscreen(true);
    }
  }

  Future<void> _leavePlayer() async {
    if (_leavingPlayer) return;
    _leavingPlayer = true;
    if (_supportsNativeFullscreen) await _setNativeFullscreen(false);
    if (!mounted) return;
    GoRouter.of(context).canPop()
        ? GoRouter.of(context).pop()
        : GoRouter.of(context).go('/');
  }

  // ---- Keyboard controls ----

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final isAndroid = Platform.isAndroid;

    // Escape / Backspace / Back → close channel list first, then exit
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.goBack) {
      if (_showChannelList) {
        setState(() => _showChannelList = false);
        return KeyEventResult.handled;
      }
      if (_nativeFullscreen) {
        unawaited(_leavePlayer());
        return KeyEventResult.handled;
      }
      _leavePlayer();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      _toggleNativeFullscreen();
      return KeyEventResult.handled;
    }

    // Select / Enter → toggle overlay
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      _toggleOverlay();
      return KeyEventResult.handled;
    }

    // Channel switching: use channelUp/Down on Android, arrows elsewhere
    if (key == LogicalKeyboardKey.channelUp ||
        (!isAndroid && key == LogicalKeyboardKey.arrowUp)) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.channelDown ||
        (!isAndroid && key == LogicalKeyboardKey.arrowDown)) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }

    // Volume: only on non-Android (D-pad arrows needed for focus on Android)
    if (!isAndroid && key == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    }

    if (!isAndroid && key == LogicalKeyboardKey.arrowRight) {
      _adjustVolume(5);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _switchChannel(int delta) async {
    if (widget.channels.isEmpty) return;
    final switchGeneration = ++_channelSwitchGeneration;
    var targetIndex = (_channelIndex + delta) % widget.channels.length;
    if (targetIndex < 0) targetIndex += widget.channels.length;
    final ch = widget.channels[targetIndex];
    setState(() => _showOverlay = true);
    try {
      final switched = await ref
          .read(playerServiceProvider)
          .switchChannel(
            ch['streamUrl'] as String? ?? '',
            channelId: ch['id'] as String?,
            epgChannelId: ch['epgChannelId'] as String?,
            tvgId: ch['tvgId'] as String?,
            channelName: ch['name'] as String?,
            vanityName: ch['vanityName'] as String?,
            originalName:
                ch['originalName'] as String? ?? ch['tvgName'] as String?,
            failoverGroupUrls: (ch['alternativeUrls'] as List?)?.cast<String>(),
            allowAudioOnly: _allowsAudioOnly(ch),
          );
      if (!mounted || switchGeneration != _channelSwitchGeneration) return;
      if (!switched) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('新频道暂时无法播放，已保留原频道'),
          duration: Duration(seconds: 3),
        ));
        return;
      }
      setState(() {
        _channelIndex = targetIndex;
        _currentChannelName = ch['name'] as String? ?? '';
        _currentChannelLogo = ch['tvgLogo'] as String?;
        _groupTitle = ch['groupTitle']?.toString();
        _providerName = ref.read(streamAlternativesProvider)
            .providerName(ch['providerId']?.toString() ?? '');
        _currentUrlIndex = 0;
      });
      _autoHideOverlay();
      _loadEpgInfo();
      _loadFavoriteState();
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError('channel_switch', error, stackTrace);
    }
  }

  Future<void> _showRouteMenu(Offset position) async {
    if (widget.channels.isEmpty) return;
    final service = ref.read(playerServiceProvider);
    final currentUrl = service.currentUrl;
    if (currentUrl == null) return;
    final alternatives = service.currentAlternativeUrls.take(12).toList();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: [
        const PopupMenuItem<int>(
          enabled: false,
          child: Text('切换当前频道的线路'),
        ),
        PopupMenuItem<int>(
          value: -3,
          enabled: alternatives.isNotEmpty,
          child: const Text('切换到下一条线路'),
        ),
        for (var index = 0; index < alternatives.length; index++)
          PopupMenuItem<int>(
            value: index,
            child: Text('线路 ${index + 1} · '
                '${Uri.tryParse(alternatives[index])?.host ?? '候选来源'}'),
          ),
        if (alternatives.isEmpty)
          const PopupMenuItem<int>(
            enabled: false,
            child: Text('暂无其他候选线路'),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<int>(
          value: -2,
          child: Text(_isFavorite ? '管理收藏' : '加入收藏'),
        ),
        const PopupMenuItem<int>(
          value: -1,
          child: Text('淘汰当前线路'),
        ),
      ],
    );
    if (!mounted || choice == null || service.currentUrl != currentUrl) return;
    if (choice == -2) {
      _toggleFavorite();
      return;
    }
    if (choice >= 0 || choice == -3) {
      final selectedUrl = choice == -3
          ? alternatives.first
          : alternatives[choice];
      final switched = await service.switchCurrentRoute(selectedUrl);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(switched ? '已切换到可播放线路' : '候选线路不可用，已保留当前画面'),
      ));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('淘汰当前线路？'),
        content: const Text('将屏蔽这个信号地址，其他线路会保留。此操作无法在界面中撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认淘汰'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || service.currentUrl != currentUrl) {
      return;
    }
    service.rejectCurrentRoute();
    final deleted = await ref.read(databaseProvider).blockAndDeleteStreamUrl(
      currentUrl,
      reason: 'user_reported_wrong_content',
    );
    final switched = alternatives.isNotEmpty &&
        await service.switchCurrentRoute(alternatives.first);
    if (!switched) await service.stop();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已淘汰当前线路，移除 $deleted 条重复记录'),
    ));
  }

  void _adjustVolume(double delta) {
    setState(() {
      _volume = (_volume + delta).clamp(0.0, 100.0);
      _showVolumeOverlay = true;
    });
    ref.read(playerServiceProvider).setVolume(_volume);
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showVolumeOverlay = false);
    });
  }

  Widget _mouseActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black.withValues(alpha: 0.55),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 36),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        side: const BorderSide(color: Colors.white24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  void dispose() {
    _activePlayerSubscription?.cancel();
    _castStatusSubscription?.cancel();
    _overlayTimer?.cancel();
    _cursorTimer?.cancel();
    _volumeTimer?.cancel();
    _tracksSubscription?.cancel();
    _bufferingSubscription?.cancel();
    if (_supportsNativeFullscreen && _nativeFullscreen) {
      unawaited(_setNativeFullscreen(false));
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerService = ref.watch(playerServiceProvider);
    final initialVideoController = playerService.videoController;

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          cursor: _showCursor ? MouseCursor.defer : SystemMouseCursors.none,
          onEnter: (_) => _onPointerActivity(),
          onHover: (_) => _onPointerActivity(),
          child: GestureDetector(
            onTap: _toggleOverlay,
            onDoubleTap: _toggleNativeFullscreen,
            onSecondaryTapUp: (details) =>
                _showRouteMenu(details.globalPosition),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Video — fill entire screen
                ValueListenableBuilder<VideoController?>(
                  valueListenable: playerService.activeVideoController,
                  builder: (context, controller, _) => Video(
                    key: ValueKey(controller ?? initialVideoController),
                    controller: controller ?? initialVideoController,
                    controls: NoVideoControls,
                  ),
                ),

                ValueListenableBuilder<bool>(
                  valueListenable: playerService.channelSwitching,
                  builder: (context, preparing, _) {
                    if (!preparing) return const SizedBox.shrink();
                    return IgnorePointer(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 18),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(width: 16, height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white)),
                                    SizedBox(width: 10),
                                    Text('新频道正在后台载入，当前播放保持不变',
                                        style: TextStyle(color: Colors.white)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),

                StreamBuilder<bool>(
                  stream: playerService.failoverSwitchingStream,
                  initialData: playerService.failoverSwitching,
                  builder: (context, snapshot) {
                    if (snapshot.data != true) return const SizedBox.shrink();
                    return IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black54,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white70,
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  '正在切换线路，可继续选择其他频道',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),

                // TiviMate-style control bar overlay
                PlayerControlBar(
                  isCasting: ref.read(castServiceProvider).isCasting,
                  isFavorite: _isFavorite,
                  hasSubtitles: _subtitleTracks.isNotEmpty,
                  subtitlesEnabled: _subtitlesEnabled,
                  onSubtitleToggle: _toggleSubtitles,
                  onSubtitleSelect: _showSubtitlePicker,
                  audioTrackCount: _audioTracks.length,
                  onAudioSelect: _showAudioPicker,
                  onCastTap: () => _showCastPicker(),
                  onBackTap: () {
                    _leavePlayer();
                  },
                  onScreenshot: _takeScreenshot,
                  onFavorite: _toggleFavorite,
                  onPip: _enterPip,
                  onInfo: _showInfoDialog,
                  onRename: _renameCurrentChannel,
                  onSettings: () => GoRouter.of(context).push('/settings'),
                  onChannelList: () =>
                      setState(() => _showChannelList = !_showChannelList),
                  onFullscreenToggle: _toggleNativeFullscreen,
                  isFullscreen: _nativeFullscreen,
                ),

                // Channel info overlay (top, shown alongside control bar)
                if (_showOverlay) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(48, 4, 12, 12),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black87,
                            Colors.black54,
                            Colors.transparent,
                          ],
                          stops: [0.0, 0.7, 1.0],
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Col 1: Channel name + group
                          if (_currentChannelLogo != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Image.network(
                                _currentChannelLogo!,
                                width: 24,
                                height: 24,
                                errorBuilder: (c, e, s) => const SizedBox(),
                              ),
                            ),
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _currentChannelName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (_groupTitle != null &&
                                    _groupTitle!.isNotEmpty)
                                  Text(
                                    _groupTitle!,
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Col 2: Programme name + time + next
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_nowPlayingTitle != null) ...[
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.play_circle_outline,
                                        size: 14,
                                        color: Colors.cyanAccent,
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          _nowPlayingTitle!,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (_nowPlayingTime != null)
                                    Text(
                                      _nowPlayingTime!,
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 11,
                                      ),
                                    ),
                                ],
                                if (_nextTitle != null) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    '接下来：$_nextTitle${_nextTime != null ? '  $_nextTime' : ''}',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 10,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Col 3: Description
                          Expanded(
                            flex: 3,
                            child:
                                (_nowDescription != null &&
                                    _nowDescription!.isNotEmpty)
                                ? Text(
                                    _nowDescription!,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          const SizedBox(width: 16),
                          // Col 4: Stream badges + provider + time
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  StreamInfoBadges(
                                    playerService: ref.read(
                                      playerServiceProvider,
                                    ),
                                  ),
                                  if (_providerName != null &&
                                      _providerName!.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFF6C5CE7,
                                        ).withValues(alpha: 0.3),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: const Color(0xFF6C5CE7),
                                          width: 0.5,
                                        ),
                                      ),
                                      child: Text(
                                        _providerName!,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFFA29BFE),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                TimeOfDay.now().format(context),
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _mouseActionButton(
                                    icon: _nativeFullscreen
                                        ? Icons.fullscreen_exit
                                        : Icons.fullscreen,
                                    label: _nativeFullscreen ? '退出全屏' : '全屏',
                                    onPressed: _toggleNativeFullscreen,
                                  ),
                                  const SizedBox(width: 8),
                                  _mouseActionButton(
                                    icon: Icons.arrow_back,
                                    label: '返回频道',
                                    onPressed: _leavePlayer,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                // Volume overlay
                if (_showVolumeOverlay)
                  Positioned(
                    top: 80,
                    right: 24,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _volume == 0
                                ? Icons.volume_off
                                : _volume < 50
                                ? Icons.volume_down
                                : Icons.volume_up,
                            color: Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${_volume.round()}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Channel list overlay
                if (_showChannelList && widget.channels.isNotEmpty)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: 320,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.85),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.fromLTRB(16, 40, 8, 8),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.list,
                                  color: Colors.white70,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  '频道',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.white54,
                                    size: 20,
                                  ),
                                  onPressed: () =>
                                      setState(() => _showChannelList = false),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, color: Colors.white10),
                          Expanded(
                            child: ListView.builder(
                              itemCount: widget.channels.length,
                              itemBuilder: (ctx, i) {
                                final ch = widget.channels[i];
                                final name = ch['name'] as String? ?? '';
                                final isCurrent = i == _channelIndex;
                                return ListTile(
                                  dense: true,
                                  selected: isCurrent,
                                  selectedTileColor: const Color(
                                    0xFF6C5CE7,
                                  ).withValues(alpha: 0.3),
                                  leading: ch['tvgLogo'] != null
                                      ? Image.network(
                                          ch['tvgLogo'] as String,
                                          width: 28,
                                          height: 28,
                                          errorBuilder: (_, __, ___) =>
                                              const Icon(
                                                Icons.tv,
                                                size: 28,
                                                color: Colors.white30,
                                              ),
                                        )
                                      : const Icon(
                                          Icons.tv,
                                          size: 28,
                                          color: Colors.white30,
                                        ),
                                  title: Text(
                                    name,
                                    style: TextStyle(
                                      color: isCurrent
                                          ? Colors.white
                                          : Colors.white70,
                                      fontWeight: isCurrent
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      fontSize: 13,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    setState(() => _showChannelList = false);
                                    if (i != _channelIndex) {
                                      _switchChannel(i - _channelIndex);
                                    }
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Action handlers ----

  Future<void> _takeScreenshot() async {
    final ps = ref.read(playerServiceProvider);
    try {
      final dir = Platform.isMacOS || Platform.isLinux || Platform.isWindows
          ? (await getDownloadsDirectory()) ?? await getTemporaryDirectory()
          : await getTemporaryDirectory();
      final path =
          '${dir.path}/clubtivi_screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      final result = await ps.takeScreenshot(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result != null ? '截图已保存：$path' : '当前无法截图')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图失败：$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _toggleFavorite() {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final channelId = ch['id'] as String? ?? '';
    final channelName = ch['name'] as String? ?? '';
    if (channelId.isEmpty) return;
    _showFavoriteListSheet(channelId, channelName);
  }

  Future<void> _showFavoriteListSheet(
    String channelId,
    String channelName,
  ) async {
    final database = ref.read(databaseProvider);
    final listsForChannel = await database.getListsForChannel(channelId);
    final checkedIds = listsForChannel.map((l) => l.id).toSet();

    if (checkedIds.isEmpty) {
      final lists = await database.addChannelToDefaultFavorites(channelId);
      checkedIds.add('default');
      if (mounted) {
        setState(() {
          _favoriteLists = lists;
          _isFavorite = true;
        });
      }
    }

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        color: Colors.amber,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '收藏「$channelName」',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_favoriteLists.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          '暂无收藏列表',
                          style: TextStyle(color: Colors.white38),
                        ),
                      ),
                    ),
                  ..._favoriteLists.map((list) {
                    final isInList = checkedIds.contains(list.id);
                    return CheckboxListTile(
                      dense: true,
                      value: isInList,
                      activeColor: const Color(0xFFE17055),
                      title: Text(
                        '★ ${list.name}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      onChanged: (val) async {
                        if (val == true) {
                          await database.addChannelToList(list.id, channelId);
                          checkedIds.add(list.id);
                        } else {
                          await database.removeChannelFromList(
                            list.id,
                            channelId,
                          );
                          checkedIds.remove(list.id);
                        }
                        setSheetState(() {});
                      },
                    );
                  }),
                  const Divider(color: Colors.white12),
                  TextButton.icon(
                    onPressed: () async {
                      final name = await _showCreateListDialog();
                      if (name != null && name.isNotEmpty) {
                        final newList = await database.createFavoriteList(name);
                        await database.addChannelToList(newList.id, channelId);
                        checkedIds.add(newList.id);
                        final updated = await database.getAllFavoriteLists();
                        setState(() => _favoriteLists = updated);
                        setSheetState(() {});
                      }
                    },
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('新建列表'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.cyanAccent,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
    // Refresh favorite state after sheet closes
    final listsAfter = await database.getListsForChannel(channelId);
    if (mounted) {
      setState(() => _isFavorite = listsAfter.isNotEmpty);
    }
  }

  Future<String?> _showCreateListDialog() async {
    String name = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('新建收藏列表', style: TextStyle(color: Colors.white)),
        content: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '例如：体育、新闻、少儿',
            hintStyle: TextStyle(color: Colors.white38),
          ),
          onChanged: (v) => name = v,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(name.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  Future<void> _enterPip() async {
    // PiP not yet available on desktop — show a message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('画中画功能可在移动设备上使用'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _renameCurrentChannel() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final channelId = ch['id'] as String?;
    if (channelId == null) return;

    // Load current vanity names
    final prefs = await SharedPreferences.getInstance();
    final vanityJson = prefs.getString('channel_vanity_names');
    Map<String, String> vanityNames = {};
    if (vanityJson != null) {
      try {
        final decoded = jsonDecode(vanityJson) as Map<String, dynamic>;
        vanityNames = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {}
    }

    final originalName =
        ch['tvgName']?.toString() ??
        ch['originalName']?.toString() ??
        ch['name']?.toString() ??
        '';
    final currentVanity = vanityNames[channelId];
    final controller = TextEditingController(
      text: currentVanity ?? ch['name']?.toString() ?? originalName,
    );

    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置显示名称'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '原始名称：$originalName',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: '显示名称'),
            ),
          ],
        ),
        actions: [
          if (currentVanity != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, '\x00RESET'),
              child: const Text('恢复原始名称'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;

    if (result == '\x00RESET') {
      vanityNames.remove(channelId);
    } else if (result.isNotEmpty && result != originalName) {
      vanityNames[channelId] = result;
    } else {
      return;
    }

    await prefs.setString('channel_vanity_names', jsonEncode(vanityNames));

    // Update in-memory channel map and displayed name
    if (!mounted) return;
    setState(() {
      widget.channels[_channelIndex]['vanityName'] = vanityNames[channelId];
      widget.channels[_channelIndex]['name'] =
          vanityNames[channelId] ?? originalName;
      _currentChannelName = vanityNames[channelId] ?? originalName;
    });
  }

  void _showInfoDialog() {
    if (widget.channels.isEmpty) return;
    try {
      final ch = widget.channels[_channelIndex];
      final channel = db.Channel(
        id: ch['id']?.toString() ?? '',
        providerId: ch['providerId']?.toString() ?? '',
        name: ch['name']?.toString() ?? '',
        groupTitle: ch['groupTitle']?.toString() ?? '',
        streamUrl: ch['streamUrl']?.toString() ?? '',
        streamType: ch['streamType']?.toString() ?? 'live',
        tvgId: ch['tvgId']?.toString(),
        tvgName: ch['tvgName']?.toString(),
        tvgLogo: ch['tvgLogo']?.toString(),
        favorite: false,
        hidden: false,
        sortOrder: 0,
      );
      final ps = ref.read(playerServiceProvider);
      final epgId = ch['epgId']?.toString();
      final alts = ref
          .read(streamAlternativesProvider)
          .getAlternativeDetails(
            channelId: ch['id']?.toString() ?? '',
            epgChannelId: epgId,
            tvgId: ch['tvgId']?.toString(),
            channelName: ch['name']?.toString(),
            vanityName: ch['vanityName']?.toString(),
            originalName: ch['tvgName']?.toString(),
            excludeUrl: ch['streamUrl']?.toString() ?? '',
          );
      ChannelDebugDialog.show(
        context,
        channel,
        ps,
        mappedEpgId: epgId,
        originalName:
            ch['tvgName']?.toString() ??
            ch['originalName']?.toString() ??
            ch['name']?.toString(),
        currentProviderName: ref
            .read(streamAlternativesProvider)
            .providerName(ch['providerId']?.toString() ?? ''),
        alternatives: alts,
      );
    } catch (e) {
      debugPrint('Error showing info dialog: $e');
    }
  }
}
