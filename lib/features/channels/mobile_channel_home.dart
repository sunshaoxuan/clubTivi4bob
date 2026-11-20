import '../account/account_button.dart';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/bobtv_palette.dart';
import '../../core/i18n/app_language.dart';
import '../../core/server_image.dart';
import '../../core/server_egress.dart';
import 'channel_logo_surface.dart';
import 'channel_card_feedback.dart';

/// Shared by the phone home and the native, offline presentation probe.
class MobileChannelItem {
  const MobileChannelItem({
    required this.id,
    required this.name,
    required this.sourceId,
    this.programme,
    this.logoUrl,
    this.logoImage,
    this.favorite = false,
  });
  final String id;
  final String name;
  final String sourceId;
  final String? programme;
  final String? logoUrl;

  /// Optional cached image, also used by offline native QA with real logos.
  final ImageProvider<Object>? logoImage;
  final bool favorite;
}

bool useMobileChannelHome({
  required TargetPlatform platform,
  required Size size,
  bool television = false,
}) =>
    !television &&
    (platform == TargetPlatform.iOS || platform == TargetPlatform.android) &&
    size.shortestSide < 600;

class MobileChannelHome extends StatefulWidget {
  const MobileChannelHome({
    super.key,
    required this.video,
    required this.channels,
    required this.sources,
    required this.categories,
    required this.category,
    required this.onCategory,
    required this.onSelect,
    required this.onPause,
    required this.onMute,
    required this.onManageSources,
    this.recentIds = const [],
    this.onRecentChanged,
    this.onMore,
    this.subtitleControl,
    this.details,
    this.onChannelFavorite,
    this.onChannelActions,
    this.countries = const [],
    this.country = '',
    this.currentId,
    this.currentName,
    this.programme,
    this.loading = false,
    this.muted = false,
    this.playing = false,
  });
  final List<String> recentIds;
  final ValueChanged<List<String>>? onRecentChanged;
  final VoidCallback? onMore;
  final Widget? subtitleControl;
  final Widget? details;
  final Future<void> Function(String)? onChannelFavorite;
  final Future<void> Function(String)? onChannelActions;
  final Widget video;
  final List<MobileChannelItem> channels;
  final Map<String, String> sources;
  final List<String> categories;
  final String category;
  final List<String> countries;
  final String country;
  final Future<void> Function(String category, String country) onCategory;

  /// Completes only after the selection is ready; failure keeps the drawer open.
  final Future<bool> Function(String id) onSelect;
  final VoidCallback onPause;
  final VoidCallback onMute;
  final VoidCallback onManageSources;
  final String? currentId;
  final String? currentName;
  final String? programme;
  final bool loading;
  final bool muted;
  final bool playing;

  @override
  State<MobileChannelHome> createState() => _MobileChannelHomeState();
}

class _MobileChannelHomeState extends State<MobileChannelHome>
    with SingleTickerProviderStateMixin {
  bool _open = false;
  bool _filter = false;
  bool _searching = false;
  bool _applying = false;
  String _scope = 'all';
  String? _source;
  String? _draftSource;
  late String _draftCategory;
  late String _draftCountry;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _openFocus = FocusNode();
  final _drawerFocus = FocusNode();
  final _scroll = ScrollController();
  final _recent = <String>[];
  String? _pending;
  String? _failed;
  String? _filterError;
  int _selection = 0;
  int _drawerSession = 0;
  late final AnimationController _slide;

  String t(String value) => AppMessages.text(context, value);

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _recent.addAll(widget.recentIds.take(50));
    _draftCategory = widget.category;
    _draftCountry = widget.country;
  }

  @override
  void didUpdateWidget(MobileChannelHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recentIds != widget.recentIds) {
      _recent
        ..clear()
        ..addAll(widget.recentIds.take(50));
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _openFocus.dispose();
    _drawerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<MobileChannelItem> get _visible {
    final query = _search.text.trim().toLowerCase();
    final items = widget.channels
        .where(
          (c) =>
              (_source == null || c.sourceId == _source) &&
              (_scope != 'favorites' || c.favorite) &&
              (_scope != 'recent' || _recent.contains(c.id)) &&
              (query.isEmpty || c.name.toLowerCase().contains(query)),
        )
        .toList();
    if (_scope == 'recent') {
      items.sort(
        (a, b) => _recent.indexOf(a.id).compareTo(_recent.indexOf(b.id)),
      );
    }
    return items;
  }

  void _close() async {
    final session = ++_drawerSession;
    FocusManager.instance.primaryFocus?.unfocus();
    if (MediaQuery.disableAnimationsOf(context)) {
      _slide.value = 0;
    } else {
      await _slide.reverse();
    }
    if (!mounted || session != _drawerSession) return;
    setState(() {
      _open = false;
      _filter = false;
      _searching = false;
    });
    _openFocus.requestFocus();
  }

  void _back() {
    if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
    } else if (_filter) {
      setState(() => _filter = false);
    } else if (_searching) {
      setState(() {
        _searching = false;
        _search.clear();
      });
    } else {
      _close();
    }
  }

  void _openDrawer() {
    ++_drawerSession;
    setState(() => _open = true);
    if (MediaQuery.disableAnimationsOf(context)) {
      _slide.value = 1;
    } else {
      _slide.forward();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _open) _drawerFocus.requestFocus();
    });
  }

  void _filters() {
    _searchFocus.unfocus();
    setState(() {
      _draftCategory = widget.category;
      _draftCountry = widget.country;
      _draftSource = _source;
      _filterError = null;
      _filter = true;
    });
  }

  Future<void> _apply() async {
    setState(() {
      _applying = true;
      _filterError = null;
    });
    try {
      await widget.onCategory(_draftCategory, _draftCountry);
      if (!mounted) return;
      setState(() {
        _source = _draftSource;
        _filter = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (_) {
      if (mounted) setState(() => _filterError = t('加载失败，请重试'));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _select(MobileChannelItem channel) async {
    if (_pending == channel.id) return;
    if (channel.id == widget.currentId &&
        widget.playing &&
        _failed != channel.id &&
        _pending == null) {
      _close();
      return;
    }
    final request = ++_selection;
    final session = _drawerSession;
    setState(() {
      _pending = channel.id;
      _failed = null;
    });
    var ready = false;
    try {
      ready = await widget.onSelect(channel.id);
    } catch (_) {
      ready = false;
    }
    if (!mounted || request != _selection) return;
    setState(() {
      _pending = null;
      _failed = ready ? null : channel.id;
      if (ready) {
        _recent.remove(channel.id);
        _recent.insert(0, channel.id);
        if (_recent.length > 50) _recent.removeLast();
      }
    });
    if (ready) widget.onRecentChanged?.call(List.unmodifiable(_recent));
    if (ready && _open && session == _drawerSession) _close();
  }

  Widget _button(
    String text,
    VoidCallback? action, {
    IconData? icon,
    Key? key,
  }) => TextButton.icon(
    key: key,
    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    onPressed: action,
    icon: Icon(icon ?? Icons.chevron_right, size: 20),
    label: Text(t(text)),
  );

  Widget _player(bool landscape) => Stack(
    fit: StackFit.expand,
    children: [
      ColoredBox(color: Colors.black, child: widget.video),
      Positioned(
        top: 8,
        left: 12,
        right: 68,
        child: Text(
          widget.currentName ?? t('选择频道'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            shadows: [Shadow(blurRadius: 6)],
          ),
        ),
      ),
      const Positioned(top: 0, right: 8, child: AccountButton(compact: true)),
      Positioned(
        left: 4,
        right: 4,
        bottom: 4,
        child: ColoredBox(
          color: const Color(0xA6000000),
          child: Row(
            children: [
              IconButton(
                tooltip: t(widget.playing ? '暂停' : '播放'),
                onPressed: widget.onPause,
                icon: Icon(widget.playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: t(widget.muted ? '取消静音' : '静音'),
                onPressed: widget.onMute,
                icon: Icon(widget.muted ? Icons.volume_off : Icons.volume_up),
              ),
              if (widget.subtitleControl != null) widget.subtitleControl!,
              const Spacer(),
              if (widget.onMore != null)
                IconButton(
                  key: const ValueKey('mobile-more-actions'),
                  tooltip: t('更多'),
                  onPressed: widget.onMore,
                  icon: const Icon(Icons.more_horiz),
                ),
              TextButton.icon(
                key: const ValueKey('mobile-open-channels'),
                focusNode: _openFocus,
                onPressed: _openDrawer,
                icon: Icon(
                  landscape ? Icons.view_sidebar_outlined : Icons.expand_less,
                ),
                label: Text(t('频道')),
                style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
              ),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _filtersBody() => Column(
    children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            _section('来源', [
              _chip(
                '全部',
                _draftSource == null,
                () => setState(() => _draftSource = null),
              ),
              for (final entry in widget.sources.entries)
                _chip(
                  entry.value,
                  _draftSource == entry.key,
                  () => setState(() => _draftSource = entry.key),
                ),
            ]),
            _section('频道分类', [
              for (final group in widget.categories)
                _chip(
                  AppMessages.category(context, group),
                  _draftCategory == group,
                  () => setState(() {
                    _draftCategory = group;
                    _draftCountry = '';
                  }),
                ),
            ]),
            if (_draftCategory == '国际' && widget.countries.isNotEmpty)
              _section('国家或地区', [
                for (final country in widget.countries)
                  _chip(
                    AppMessages.category(context, country),
                    _draftCountry == country,
                    () => setState(() => _draftCountry = country),
                  ),
              ]),
            if (_filterError != null)
              Text(_filterError!, style: const TextStyle(color: Colors.orange)),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(
          children: [
            _button(
              '重置',
              _applying
                  ? null
                  : () => setState(() {
                      _draftSource = null;
                      _draftCategory = widget.categories.first;
                      _draftCountry = '';
                    }),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const ValueKey('mobile-apply-filter'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _applying ? null : _apply,
                child: Text(t(_applying ? '正在加载…' : '应用')),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t(title),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: children),
      ],
    ),
  );

  Widget _chip(String text, bool selected, VoidCallback onTap) =>
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: FilterChip(
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          selected: selected,
          onSelected: (_) => onTap(),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        ),
      );

  Widget _channelList(bool landscape) {
    final visible = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: _searching
                    ? TextField(
                        key: const ValueKey('mobile-search-field'),
                        controller: _search,
                        focusNode: _searchFocus,
                        decoration: InputDecoration(
                          hintText: t('搜索当前分类'),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      )
                    : _button('搜索', () {
                        setState(() => _searching = true);
                        _searchFocus.requestFocus();
                      }, icon: Icons.search),
              ),
              _button(
                '分类',
                _filters,
                key: const ValueKey('mobile-open-filter'),
                icon: Icons.tune,
              ),
              if (landscape)
                PopupMenuButton<String>(
                  tooltip: t('全部 / 收藏 / 最近'),
                  initialValue: _scope,
                  onSelected: (value) => setState(() => _scope = value),
                  itemBuilder: (_) => [
                    for (final entry in {
                      'all': '全部',
                      'favorites': '收藏',
                      'recent': '最近',
                    }.entries)
                      PopupMenuItem(
                        value: entry.key,
                        child: Text(t(entry.value)),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      t(
                        {
                          'all': '全部',
                          'favorites': '收藏',
                          'recent': '最近',
                        }[_scope]!,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (!landscape)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final entry in {
                  'all': '全部',
                  'favorites': '收藏',
                  'recent': '最近',
                }.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _chip(
                      t(entry.value),
                      _scope == entry.key,
                      () => setState(() => _scope = entry.key),
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${AppMessages.category(context, widget.category)}'
              '${widget.country.isEmpty ? '' : ' / ${AppMessages.category(context, widget.country)}'} · ${visible.length}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
        ),
        Expanded(
          child: widget.loading
              ? const Center(child: CircularProgressIndicator())
              : visible.isEmpty
              ? Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(t('没有匹配的频道')),
                        _button('清除搜索', () => setState(_search.clear)),
                        _button('分类', _filters),
                      ],
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final scale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    final columns = constraints.maxWidth >= 296 && scale < 1.4
                        ? 2
                        : 1;
                    return GridView.builder(
                      key: const PageStorageKey('mobile-channel-grid'),
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        mainAxisExtent: 112 * scale.clamp(1, 2.5),
                      ),
                      itemCount: visible.length,
                      itemBuilder: (context, index) => _card(visible[index]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _logo(MobileChannelItem channel, {bool backdrop = false}) {
    Widget fallback() => Center(
      child: Text(
        channel.name.characters.take(2).toString(),
        style: TextStyle(
          fontSize: backdrop ? 44 : 14,
          fontWeight: FontWeight.w800,
          color: const Color(0xFF243B59),
        ),
      ),
    );
    if (channel.logoImage != null) {
      return Image(
        image: channel.logoImage!,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => fallback(),
      );
    }
    if (channel.logoUrl?.isNotEmpty ?? false) {
      return ServerImage.network(
        channel.logoUrl!,
        fit: BoxFit.contain,
        cacheWidth: backdrop ? 240 : 180,
        errorBuilder: (_, _, _) => fallback(),
      );
    }
    return fallback();
  }

  Widget _card(MobileChannelItem channel) {
    final selected = channel.id == widget.currentId;
    final pending = _pending == channel.id;
    final failed = _failed == channel.id;
    const accents = [
      Color(0xFF6E9DDB),
      Color(0xFF987FCA),
      Color(0xFF5BAFA8),
      Color(0xFFC39072),
    ];
    final accent = accents[channel.name.hashCode.abs() % accents.length];
    return Semantics(
      button: true,
      selected: selected,
      child: DecoratedBox(
        decoration: channelCardDecoration(
          accent: accent,
          selected: selected,
          joinedToProgramme: false,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('mobile-channel-${channel.id}'),
              onTap: () => unawaited(_select(channel)),
              onLongPress: widget.onChannelActions == null
                  ? null
                  : () => unawaited(widget.onChannelActions!(channel.id)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: .15,
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: 10,
                            sigmaY: 10,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: _logo(channel, backdrop: true),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ChannelLogoSurface(
                              key: ValueKey('mobile-logo-${channel.id}'),
                              image:
                                  channel.logoImage ??
                                  ((channel.logoUrl?.isNotEmpty ?? false)
                                      ? ResizeImage(
                                          NetworkImage(
                                            ServerEgress.imageUrl(
                                              channel.logoUrl!,
                                            ),
                                          ),
                                          width: 180,
                                        )
                                      : null),
                              fallback: Center(
                                child: Text(
                                  channel.name.characters.take(2).toString(),
                                  style: const TextStyle(
                                    color: Color(0xFF243B59),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (pending)
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            else if (selected)
                              const Icon(
                                Icons.equalizer_rounded,
                                color: Color(0xFFBCD1FF),
                                size: 18,
                              ),
                            if (widget.onChannelFavorite != null)
                              SizedBox(
                                width: 40,
                                height: 40,
                                child: IconButton(
                                  key: ValueKey(
                                    'mobile-favorite-${channel.id}',
                                  ),
                                  padding: EdgeInsets.zero,
                                  tooltip: t(
                                    channel.favorite ? '取消收藏' : '加入收藏',
                                  ),
                                  onPressed: () => unawaited(
                                    widget.onChannelFavorite!(channel.id),
                                  ),
                                  icon: Icon(
                                    channel.favorite
                                        ? Icons.star_rounded
                                        : Icons.star_outline_rounded,
                                    size: 20,
                                    color: channel.favorite
                                        ? const Color(0xFFF3CE7B)
                                        : Colors.white60,
                                  ),
                                ),
                              )
                            else if (channel.favorite) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.star_rounded,
                                color: Color(0xFFF3CE7B),
                                size: 18,
                              ),
                            ],
                          ],
                        ),
                        const Spacer(),
                        Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.2,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          t(
                            pending
                                ? '正在加载…'
                                : failed
                                ? '失败，请重试'
                                : selected
                                ? '播放中'
                                : channel.programme ?? '暂无节目单',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: failed
                                ? Colors.orange
                                : selected
                                ? const Color(0xFFBCD1FF)
                                : Colors.white60,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _drawer(bool landscape) => Focus(
    focusNode: _drawerFocus,
    child: FocusTraversalGroup(
      child: Material(
        key: ValueKey(
          landscape ? 'mobile-right-drawer' : 'mobile-bottom-drawer',
        ),
        color: BobTvPalette.panel,
        elevation: 16,
        borderRadius: landscape
            ? null
            : const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            if (!landscape)
              GestureDetector(
                key: const ValueKey('mobile-drawer-handle'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0) > 100) _close();
                },
                child: SizedBox(
                  height: 24,
                  width: double.infinity,
                  child: Center(
                    child: Container(
                      width: 48,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white38,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  if (_filter)
                    IconButton(
                      tooltip: t('返回'),
                      onPressed: _applying ? null : _back,
                      icon: const Icon(Icons.arrow_back),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        t(_filter ? '筛选频道' : '频道'),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  _button(
                    '关闭',
                    _close,
                    icon: Icons.close,
                    key: const ValueKey('mobile-close-drawer'),
                  ),
                ],
              ),
            ),
            Expanded(child: _filter ? _filtersBody() : _channelList(landscape)),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final landscape = constraints.maxWidth > constraints.maxHeight;
      final keyboard = MediaQuery.viewInsetsOf(context).bottom;
      final height = (constraints.maxHeight - keyboard).clamp(
        0.0,
        constraints.maxHeight,
      );
      final videoHeight = (constraints.maxWidth * 9 / 16).clamp(
        120.0,
        constraints.maxHeight * .55,
      );
      final drawerHeight = keyboard > 0
          ? height
          : (constraints.maxHeight - videoHeight).clamp(
              constraints.maxHeight * .55,
              constraints.maxHeight * .85,
            );
      return PopScope(
        canPop: !_open,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _open) _back();
        },
        child: Stack(
          children: [
            ExcludeFocus(
              excluding: _open,
              child: ExcludeSemantics(
                excluding: _open,
                child: IgnorePointer(
                  ignoring: _open,
                  child: Column(
                    children: [
                      SizedBox(
                        height: landscape ? constraints.maxHeight : videoHeight,
                        width: double.infinity,
                        child: _player(landscape),
                      ),
                      if (!landscape)
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.all(20),
                            children: [
                              Text(
                                widget.currentName ?? t('欢迎使用 BobTV'),
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                widget.programme ?? t('打开频道选择播放内容'),
                                style: const TextStyle(color: Colors.white60),
                              ),
                              if (widget.details != null) ...[
                                const SizedBox(height: 16),
                                widget.details!,
                              ],
                              const SizedBox(height: 24),
                              _button(
                                '管理播放源',
                                widget.onManageSources,
                                icon: Icons.playlist_add,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_open) ...[
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('mobile-drawer-barrier'),
                  onTap: _close,
                  child: const ColoredBox(color: Color(0x55000000)),
                ),
              ),
              Positioned(
                right: 0,
                bottom: keyboard,
                width: landscape
                    ? (constraints.maxWidth * .48).clamp(296.0, 420.0)
                    : constraints.maxWidth,
                height: landscape ? height : drawerHeight,
                child: SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: landscape
                            ? const Offset(1, 0)
                            : const Offset(0, 1),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: _slide,
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                  child: _drawer(landscape),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
