import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/services/country_name_index.dart';

class CompactCategoryOption {
  const CompactCategoryOption({
    required this.id,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onContextMenu,
  });

  final String id;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onContextMenu;
}

/// Each hierarchy level occupies exactly one row. Countries use a searchable
/// dialog; other overflow menus remain joined to their navigation button.
class CompactCategoryRow extends StatefulWidget {
  const CompactCategoryRow({
    super.key,
    required this.level,
    required this.title,
    required this.options,
    this.tiny = false,
    this.countryIndex = false,
  });

  final int level;
  final String title;
  final List<CompactCategoryOption> options;
  final bool tiny;
  final bool countryIndex;

  @override
  State<CompactCategoryRow> createState() => _CompactCategoryRowState();
}

class _CompactCategoryRowState extends State<CompactCategoryRow> {
  final _moreKey = GlobalKey();
  bool _menuOpen = false;
  bool _opensUpwards = false;
  double _rowWidth = 480;

  Future<void> _showOptions() async {
    if (_menuOpen) return;
    if (widget.countryIndex) {
      setState(() => _menuOpen = true);
      final choice = await showDialog<CompactCategoryOption>(
        context: context,
        builder: (context) => _CountryMenu(
          title: widget.title,
          level: widget.level,
          options: List<CompactCategoryOption>.of(widget.options),
        ),
      );
      if (!mounted) return;
      setState(() => _menuOpen = false);
      choice?.onTap();
      return;
    }
    final box = _moreKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final media = MediaQuery.of(context);
    final width = math.min(_rowWidth, math.min(480.0, media.size.width - 24));
    final left = (anchor.right - width).clamp(
      media.padding.left,
      media.size.width - width - media.padding.right,
    );
    final bottom =
        media.size.height - media.padding.bottom - media.viewInsets.bottom - 12;
    final below = bottom - anchor.bottom;
    final above = anchor.top - media.padding.top - 12;
    final upwards = below < 160 && above > below;
    final choices = List<CompactCategoryOption>.of(widget.options);
    final maxHeight = math.min(360.0, math.max(80.0, upwards ? above : below));
    final layout = _CategoryMenuLayout.resolve(
      width: width,
      maxHeight: maxHeight,
      options: choices,
      textStyle: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
      textScaler: media.textScaler,
      direction: Directionality.of(context),
    );
    final height = math.min(maxHeight, layout.contentHeight);
    final top = upwards ? anchor.top - height : anchor.bottom;
    setState(() {
      _menuOpen = true;
      _opensUpwards = upwards;
    });
    final choice = await showGeneralDialog<CompactCategoryOption>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭${widget.title}菜单',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (dialogContext, animation, secondaryAnimation) => Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: width,
            height: height,
            child: RepaintBoundary(
              key: ValueKey('category-menu-surface-${widget.level}'),
              child: Material(
                key: ValueKey('category-menu-${widget.level}'),
                color: const Color(0xFF1A2B43),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: Radius.circular(upwards ? 16 : 0),
                    bottomLeft: const Radius.circular(16),
                    bottomRight: Radius.circular(upwards ? 0 : 16),
                  ),
                  side: const BorderSide(color: Color(0xFF829CC8)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    SizedBox(
                      height: layout.headerHeight,
                      child: Row(
                        children: [
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              widget.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭分类菜单',
                            constraints: BoxConstraints.tightFor(
                              width: layout.headerHeight,
                              height: layout.headerHeight,
                            ),
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => Navigator.pop(dialogContext),
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white12),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(layout.padding),
                        child: Wrap(
                          spacing: layout.spacing,
                          runSpacing: layout.spacing,
                          children: [
                            for (final option in choices)
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: width - layout.padding * 2,
                                ),
                                child: SizedBox(
                                  width: layout.optionWidths[option],
                                  child: _button(
                                    option,
                                    onTap: () =>
                                        Navigator.pop(dialogContext, option),
                                    menuLayout: layout,
                                  ),
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
        ],
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    choice?.onTap();
  }

  Widget _button(
    CompactCategoryOption option, {
    VoidCallback? onTap,
    _CategoryMenuLayout? menuLayout,
  }) {
    final menu = menuLayout != null;
    return GestureDetector(
      onLongPressStart: option.onContextMenu == null
          ? null
          : (d) => option.onContextMenu!(d.globalPosition),
      child: Material(
        color: option.selected
            ? const Color(0xFFAFC7FF)
            : const Color(0xFF26374F),
        borderRadius: BorderRadius.circular(menu ? 12 : 18),
        child: InkWell(
          key: ValueKey(
            '${menu ? 'menu' : 'row'}-category-${widget.level}-${option.id}',
          ),
          borderRadius: BorderRadius.circular(menu ? 12 : 18),
          onTap: onTap ?? option.onTap,
          onSecondaryTapUp: option.onContextMenu == null
              ? null
              : (d) => option.onContextMenu!(d.globalPosition),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: menuLayout?.buttonHeight ?? 0,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: menuLayout?.horizontalPadding ?? 10,
                vertical: menu
                    ? menuLayout.verticalPadding
                    : widget.tiny
                    ? 6
                    : 8,
              ),
              child: Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    (menu
                            ? Theme.of(context).textTheme.bodyMedium ??
                                  const TextStyle()
                            : const TextStyle())
                        .copyWith(
                          fontSize:
                              menuLayout?.fontSize ?? (widget.tiny ? 10 : 12),
                          height: 1.2,
                          fontWeight: option.selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: option.selected
                              ? const Color(0xFF14213B)
                              : Colors.white70,
                        ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: ValueKey('category-level-${widget.level}'),
    height: math.max(
      widget.tiny ? 24 : 32,
      MediaQuery.textScalerOf(context).scale(widget.tiny ? 10 : 12) * 1.2 +
          (widget.tiny ? 12 : 16),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        _rowWidth = constraints.maxWidth;
        double optionWidth(CompactCategoryOption option) {
          final painter = TextPainter(
            text: TextSpan(
              text: option.label,
              style: DefaultTextStyle.of(context).style.merge(
                TextStyle(
                  fontSize: widget.tiny ? 10 : 12,
                  height: 1.2,
                  fontWeight: option.selected
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
              ),
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final width = (painter.width + 20).ceilToDouble();
          painter.dispose();
          return width;
        }

        final widths = widget.options.map(optionWidth).toList();
        final total =
            widths.fold(0.0, (a, b) => a + b) +
            math.max(0, widths.length - 1) * 5;
        if (total <= constraints.maxWidth) {
          return Row(
            children: [
              for (var i = 0; i < widget.options.length; i++) ...[
                if (i > 0) const SizedBox(width: 5),
                SizedBox(width: widths[i], child: _button(widget.options[i])),
              ],
            ],
          );
        }
        final moreWidth = math.min(80.0, constraints.maxWidth * .4);
        final remaining = math.max(0.0, constraints.maxWidth - moreWidth - 5);
        // Keep the selected category visible even when it is deep in the catalog.
        final selected = widget.options.indexWhere((o) => o.selected);
        final visible = <int>[];
        var used = 0.0;
        if (selected >= 0 && remaining > 0) {
          visible.add(selected);
          used = math.min(widths[selected], remaining);
        }
        for (var i = 0; i < widget.options.length; i++) {
          if (i == selected) continue;
          final extra = widths[i] + (visible.isEmpty ? 0 : 5);
          if (used + extra <= remaining) {
            visible.add(i);
            used += extra;
          }
        }
        visible.sort();
        return Row(
          children: [
            for (var i = 0; i < visible.length; i++) ...[
              if (i > 0) const SizedBox(width: 5),
              SizedBox(
                width: math.min(widths[visible[i]], remaining),
                child: _button(widget.options[visible[i]]),
              ),
            ],
            const Spacer(),
            SizedBox(
              width: moreWidth,
              child: Material(
                key: _moreKey,
                color: _menuOpen
                    ? const Color(0xFF1A2B43)
                    : const Color(0xFF26374F),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(
                      _menuOpen && !widget.countryIndex && _opensUpwards
                          ? 0
                          : 16,
                    ),
                    bottom: Radius.circular(
                      _menuOpen && !widget.countryIndex && !_opensUpwards
                          ? 0
                          : 16,
                    ),
                  ),
                  side: BorderSide(
                    color: _menuOpen ? const Color(0xFF829CC8) : Colors.white12,
                  ),
                ),
                child: InkWell(
                  key: ValueKey('category-more-${widget.level}'),
                  onTap: _showOptions,
                  child: SizedBox(
                    height: widget.tiny ? 24 : 32,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '更多',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: widget.tiny ? 10 : 12,
                          ),
                        ),
                        const Icon(
                          Icons.expand_more,
                          color: Colors.white70,
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _CountryMenu extends StatefulWidget {
  const _CountryMenu({
    required this.title,
    required this.level,
    required this.options,
  });

  final String title;
  final int level;
  final List<CompactCategoryOption> options;

  @override
  State<_CountryMenu> createState() => _CountryMenuState();
}

class _CountryMenuState extends State<_CountryMenu> {
  final _search = TextEditingController();
  final _bodyScroll = ScrollController();
  final _listScroll = ScrollController();
  final _indexScroll = ScrollController();
  String? _initial;

  @override
  void dispose() {
    _search.dispose();
    _bodyScroll.dispose();
    _listScroll.dispose();
    _indexScroll.dispose();
    super.dispose();
  }

  void _resetScroll() {
    if (_bodyScroll.hasClients) _bodyScroll.jumpTo(0);
    if (_listScroll.hasClients) _listScroll.jumpTo(0);
  }

  Widget _letter(String? initial) {
    final selected = _initial == initial;
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: initial == null ? 60 : 44),
      child: TextButton(
        key: ValueKey('country-initial-${initial ?? 'all'}'),
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? const Color(0xFF14213B)
              : const Color(0xFFDCE6F8),
          backgroundColor: selected
              ? const Color(0xFFAFC7FF)
              : const Color(0xFF26374F),
          minimumSize: const Size(44, 44),
          visualDensity: VisualDensity.standard,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
        onPressed: () {
          setState(() {
            _initial = initial;
            _search.clear();
          });
          _resetScroll();
        },
        child: Text(initial ?? '全部'),
      ),
    );
  }

  Widget _country(CompactCategoryOption option) => GestureDetector(
    onLongPressStart: option.onContextMenu == null
        ? null
        : (details) => option.onContextMenu!(details.globalPosition),
    onSecondaryTapUp: option.onContextMenu == null
        ? null
        : (details) => option.onContextMenu!(details.globalPosition),
    child: TextButton(
      key: ValueKey('menu-category-${widget.level}-${option.id}'),
      style: TextButton.styleFrom(
        foregroundColor: option.selected
            ? const Color(0xFF14213B)
            : const Color(0xFFDCE6F8),
        backgroundColor: option.selected
            ? const Color(0xFFAFC7FF)
            : const Color(0xFF26374F),
        minimumSize: const Size(44, 44),
        visualDensity: VisualDensity.standard,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: TextStyle(
          fontSize: 14,
          height: 1.2,
          fontWeight: option.selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      onPressed: () => Navigator.pop(context, option),
      child: Text(option.label, textAlign: TextAlign.center),
    ),
  );

  Widget _results(Map<String, List<CompactCategoryOption>> groups) {
    if (groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            '没有匹配的国家或地区',
            style: TextStyle(color: Color(0xFFDCE6F8), fontSize: 14),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              entry.key,
              style: const TextStyle(
                color: Color(0xFFAFC7FF),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final option in entry.value) _country(option)],
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final initials =
        widget.options
            .map((o) => CountryNameIndex.initial(o.label))
            .toSet()
            .toList()
          ..sort(CountryNameIndex.compareInitials);
    final visible =
        widget.options
            .where(
              (option) =>
                  (_initial == null ||
                      CountryNameIndex.initial(option.label) == _initial) &&
                  CountryNameIndex.matches(option.label, _search.text),
            )
            .toList()
          ..sort((a, b) {
            final group = CountryNameIndex.compareInitials(
              CountryNameIndex.initial(a.label),
              CountryNameIndex.initial(b.label),
            );
            return group != 0 ? group : a.label.compareTo(b.label);
          });
    final groups = <String, List<CompactCategoryOption>>{};
    for (final option in visible) {
      groups
          .putIfAbsent(CountryNameIndex.initial(option.label), () => [])
          .add(option);
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: const Color(0xFF1A2B43),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF829CC8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        key: ValueKey('category-menu-${widget.level}'),
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 620),
        child: SizedBox(
          width: 480,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: IconButton(
                        key: const ValueKey('country-menu-close'),
                        tooltip: '关闭国家菜单',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final scale = MediaQuery.textScalerOf(context);
                      final letterHeight = math.max(
                        44.0,
                        scale.scale(14) * 1.2 + 20,
                      );
                      final columns = math.max(
                        1,
                        ((constraints.maxWidth + 6) / 50).floor(),
                      );
                      final rows = ((initials.length + 2) / columns).ceil();
                      final indexHeight = rows * (letterHeight + 6) - 6;
                      final compactIndex =
                          constraints.maxHeight < indexHeight + 190;
                      final letters = <Widget>[
                        _letter(null),
                        for (final initial in initials) _letter(initial),
                      ];
                      final scrollWholeBody =
                          constraints.maxHeight <
                          scale.scale(14) * 1.2 * 3 + 220;
                      // Keep the editor's ancestry stable while insets resize
                      // the dialog, including its native/web input connection.
                      final body = SizedBox(
                        height: scrollWholeBody ? null : constraints.maxHeight,
                        child: Column(
                          mainAxisSize: scrollWholeBody
                              ? MainAxisSize.min
                              : MainAxisSize.max,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              key: const ValueKey('country-search'),
                              controller: _search,
                              textAlignVertical: TextAlignVertical.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                height: 1.2,
                              ),
                              decoration: InputDecoration(
                                visualDensity: VisualDensity.standard,
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                hintText: '搜索国家或地区',
                                hintStyle: const TextStyle(
                                  color: Color(0xFFAABAD2),
                                ),
                                filled: true,
                                fillColor: const Color(0xFF111F34),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 14,
                                ),
                                isDense: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                suffixIcon: _search.text.isEmpty
                                    ? null
                                    : IconButton(
                                        key: const ValueKey(
                                          'country-search-clear',
                                        ),
                                        tooltip: '清空搜索',
                                        visualDensity: VisualDensity.standard,
                                        onPressed: () {
                                          setState(() => _search.clear());
                                          _resetScroll();
                                        },
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                        ),
                                      ),
                              ),
                              onChanged: (_) {
                                setState(() => _initial = null);
                                _resetScroll();
                              },
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              '按拼音首字母',
                              style: TextStyle(
                                color: Color(0xFFAABAD2),
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 6),
                            if (compactIndex)
                              SizedBox(
                                height: letterHeight + 8,
                                child: Scrollbar(
                                  controller: _indexScroll,
                                  thumbVisibility: true,
                                  child: SingleChildScrollView(
                                    controller: _indexScroll,
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        for (
                                          var i = 0;
                                          i < letters.length;
                                          i++
                                        ) ...[
                                          if (i > 0) const SizedBox(width: 6),
                                          letters[i],
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            else
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: letters,
                              ),
                            const SizedBox(height: 10),
                            Text(
                              '${_initial ?? '全部'} · ${visible.length} 个国家或地区',
                              style: const TextStyle(
                                color: Color(0xFFAABAD2),
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 6),
                            if (scrollWholeBody)
                              _results(groups)
                            else
                              Expanded(
                                child: Scrollbar(
                                  controller: _listScroll,
                                  thumbVisibility: true,
                                  child: SingleChildScrollView(
                                    controller: _listScroll,
                                    padding: const EdgeInsets.only(
                                      right: 10,
                                      bottom: 4,
                                    ),
                                    child: _results(groups),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                      return Scrollbar(
                        controller: _bodyScroll,
                        thumbVisibility: scrollWholeBody,
                        child: SingleChildScrollView(
                          controller: _bodyScroll,
                          physics: const ClampingScrollPhysics(),
                          padding: scrollWholeBody
                              ? const EdgeInsets.only(right: 10, bottom: 4)
                              : EdgeInsets.zero,
                          child: body,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Prefer larger menu controls when the choices fit. Navigation rows retain
/// their compact dimensions, and long menus remain scrollable at readable sizes.
class _CategoryMenuLayout {
  const _CategoryMenuLayout({
    required this.fontSize,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.buttonHeight,
    required this.spacing,
    required this.padding,
    required this.headerHeight,
    required this.contentHeight,
    required this.optionWidths,
  });

  final double fontSize;
  final double horizontalPadding;
  final double verticalPadding;
  final double buttonHeight;
  final double spacing;
  final double padding;
  final double headerHeight;
  final double contentHeight;
  final Map<CompactCategoryOption, double> optionWidths;

  static _CategoryMenuLayout resolve({
    required double width,
    required double maxHeight,
    required List<CompactCategoryOption> options,
    required TextStyle textStyle,
    required TextScaler textScaler,
    required TextDirection direction,
  }) {
    _CategoryMenuLayout? layout;
    for (final size in [16.0, 15.0, 14.0]) {
      final horizontal = size == 16 ? 14.0 : 12.0;
      final vertical = size - 4;
      final padding = size == 16 ? 14.0 : 12.0;
      final spacing = size == 16 ? 10.0 : 8.0;
      final buttonHeight = math.max(
        40 + (size - 14) * 4,
        textScaler.scale(size) * 1.2 + vertical * 2,
      );
      final headerHeight = math.max(44.0, textScaler.scale(16) * 1.2 + 16);
      final innerWidth = math.max(1.0, width - padding * 2);
      var rows = options.isEmpty ? 0 : 1;
      var used = 0.0;
      final widths = <CompactCategoryOption, double>{};
      for (final option in options) {
        final painter = TextPainter(
          text: TextSpan(
            text: option.label,
            style: textStyle.copyWith(
              fontSize: size,
              height: 1.2,
              fontWeight: option.selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          textDirection: direction,
          textScaler: textScaler,
        )..layout();
        final buttonWidth = math.min(
          innerWidth,
          (painter.width + horizontal * 2).ceilToDouble(),
        );
        widths[option] = buttonWidth;
        painter.dispose();
        if (used > 0 && used + spacing + buttonWidth > innerWidth) {
          rows++;
          used = 0;
        }
        used += buttonWidth + (used > 0 ? spacing : 0);
      }
      layout = _CategoryMenuLayout(
        fontSize: size,
        horizontalPadding: horizontal,
        verticalPadding: vertical,
        buttonHeight: buttonHeight,
        spacing: spacing,
        padding: padding,
        headerHeight: headerHeight,
        contentHeight:
            headerHeight +
            1 +
            padding * 2 +
            rows * buttonHeight +
            math.max(0, rows - 1) * spacing,
        optionWidths: widths,
      );
      if (layout.contentHeight <= maxHeight) return layout;
    }
    return layout!;
  }
}
