import 'package:flutter/material.dart';

/// Keeps the card grid lazy while inserting one full-width guide below the
/// clicked card's row. A connected outline encloses only that card and guide.
/// Selection follows channel IDs across scans and filters.
class InlineExpandedChannelGrid extends StatelessWidget {
  const InlineExpandedChannelGrid({
    super.key,
    required this.channelIds,
    required this.columns,
    required this.cardBuilder,
    this.expandedChannelId,
    this.expandedContent,
  }) : assert(columns > 0);

  final List<String> channelIds;
  final int columns;
  final Widget Function(BuildContext, int) cardBuilder;
  final String? expandedChannelId;
  final Widget? expandedContent;

  @override
  Widget build(BuildContext context) {
    final expandedIndex = expandedChannelId == null
        ? -1
        : channelIds.indexOf(expandedChannelId!);
    final expandedRow = expandedIndex < 0 ? -1 : expandedIndex ~/ columns;
    final rows = (channelIds.length + columns - 1) ~/ columns;
    final rowIndices = <String, int>{
      for (var index = 0; index < channelIds.length; index += columns)
        'channel-row-${channelIds[index]}': index ~/ columns,
    };
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: rows,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        return rowIndices[key.value];
      },
      itemBuilder: (context, row) {
        final first = row * columns;
        final expanded = row == expandedRow && expandedContent != null;
        return Padding(
          key: ValueKey('channel-row-${channelIds[first]}'),
          padding: const EdgeInsets.only(bottom: 14),
          child: LayoutBuilder(
            builder: (context, constraints) => CustomPaint(
              painter: expanded
                  ? ChannelGuideOutline(
                      column: expandedIndex % columns,
                      columns: columns,
                    )
                  : null,
              foregroundPainter: expanded
                  ? ChannelGuideOutline(
                      column: expandedIndex % columns,
                      columns: columns,
                      foreground: true,
                    )
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var column = 0; column < columns; column++) ...[
                        if (column > 0) const SizedBox(width: 14),
                        Expanded(
                          child: SizedBox(
                            height: 172,
                            child: first + column < channelIds.length
                                ? KeyedSubtree(
                                    key: ValueKey(
                                      'grid-card-${channelIds[first + column]}',
                                    ),
                                    child: cardBuilder(context, first + column),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ],
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: expanded
                        ? Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: expandedContent!,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The guide spans the row, while its upper outline includes just one card.
/// Neighbouring cards occupy the excluded area above the guide.
class ChannelGuideOutline extends CustomPainter {
  const ChannelGuideOutline({
    required this.column,
    required this.columns,
    this.foreground = false,
  });
  final int column;
  final int columns;
  final bool foreground;

  Path outline(Size size) {
    if (size.isEmpty) return Path();
    final width = (size.width - (columns - 1) * 14) / columns;
    final card = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            column * (width + 14) + 1,
            1,
            column * (width + 14) + width - 1,
            size.height < 203 ? size.height - 1 : 202,
          ),
          const Radius.circular(20),
        ),
      );
    if (size.height <= 186) return card;
    final guide = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(1, 184, size.width - 1, size.height - 1),
          const Radius.circular(20),
        ),
      );
    return Path.combine(PathOperation.union, card, guide);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = outline(size);
    if (!foreground) {
      canvas.drawPath(path, Paint()..color = const Color(0xFF132338));
      return;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFADCFFF).withValues(alpha: .65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(ChannelGuideOutline oldDelegate) =>
      column != oldDelegate.column ||
      columns != oldDelegate.columns ||
      foreground != oldDelegate.foreground;
}
