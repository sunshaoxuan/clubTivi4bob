import 'package:flutter/material.dart';

/// Keep navigation intrinsic and the preview viewport expanded. On very short
/// windows search opens separately, preserving a complete card and its guide.
class SimpleChannelPanelFrame extends StatelessWidget {
  const SimpleChannelPanelFrame({
    super.key,
    required this.compact,
    required this.header,
    required this.navigation,
    required this.search,
    required this.body,
    required this.onSearch,
    this.tiny = false,
  });

  final bool compact;
  final bool tiny;
  final Widget header;
  final Widget navigation;
  final Widget search;
  final Widget body;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
      final dense = compact && tiny;
      final short = compact && constraints.maxHeight < 430 * textScale;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (short)
            SizedBox(
              height: (dense ? 24 : 32) * textScale,
              child: Row(
                children: [
                  Expanded(child: header),
                  IconButton(
                    key: const ValueKey('compact-search-button'),
                    tooltip: '搜索当前分类',
                    onPressed: onSearch,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            )
          else
            header,
          SizedBox(height: compact ? (dense ? 4 : 6) : 18),
          navigation,
          if (!short) ...[SizedBox(height: compact ? 6 : 16), search],
          SizedBox(height: compact ? (dense ? 4 : 6) : 12),
          Expanded(child: body),
        ],
      );
    },
  );
}
