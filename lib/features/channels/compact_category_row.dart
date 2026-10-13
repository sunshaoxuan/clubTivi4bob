import 'dart:math' as math;

import 'package:flutter/material.dart';

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

/// Each hierarchy level occupies exactly one row. Overflow opens a menu joined
/// to its button, so catalog size never increases the navigation's height.
class CompactCategoryRow extends StatefulWidget {
  const CompactCategoryRow({
    super.key,
    required this.level,
    required this.title,
    required this.options,
    this.tiny = false,
  });

  final int level;
  final String title;
  final List<CompactCategoryOption> options;
  final bool tiny;

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
    final height = math.min(360.0, math.max(80.0, upwards ? above : below));
    final top = upwards ? anchor.top - height : anchor.bottom;
    final choices = List<CompactCategoryOption>.of(widget.options);
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
                    height: 40,
                    child: Row(
                      children: [
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭分类菜单',
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(10),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final option in choices)
                            ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: width - 20),
                              child: _button(
                                option,
                                onTap: () =>
                                    Navigator.pop(dialogContext, option),
                                menu: true,
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
    bool menu = false,
  }) => GestureDetector(
    onLongPressStart: option.onContextMenu == null
        ? null
        : (d) => option.onContextMenu!(d.globalPosition),
    child: Material(
      color: option.selected
          ? const Color(0xFFAFC7FF)
          : const Color(0xFF26374F),
      borderRadius: BorderRadius.circular(menu ? 10 : 18),
      child: InkWell(
        key: ValueKey(
          '${menu ? 'menu' : 'row'}-category-${widget.level}-${option.id}',
        ),
        borderRadius: BorderRadius.circular(menu ? 10 : 18),
        onTap: onTap ?? option.onTap,
        onSecondaryTapUp: option.onContextMenu == null
            ? null
            : (d) => option.onContextMenu!(d.globalPosition),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: menu
                ? 10
                : widget.tiny
                ? 6
                : 8,
          ),
          child: Text(
            option.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: widget.tiny && !menu ? 10 : 12,
              height: 1.2,
              fontWeight: option.selected ? FontWeight.w700 : FontWeight.w500,
              color: option.selected ? const Color(0xFF14213B) : Colors.white70,
            ),
          ),
        ),
      ),
    ),
  );

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
                    top: Radius.circular(_menuOpen && _opensUpwards ? 0 : 16),
                    bottom: Radius.circular(
                      _menuOpen && !_opensUpwards ? 0 : 16,
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
