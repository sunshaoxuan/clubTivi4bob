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
    final left = column * (width + 14) + 1;
    final right = left + width - 2;
    final bottom = size.height - 1;
    const guideTop = 184.0;
    final guideRadius = ((bottom - guideTop) / 2).clamp(0.0, 20.0);
    final cardRadius = ((right - left) / 2).clamp(0.0, 20.0);
    const shoulder = 12.0;
    final path = Path()
      ..moveTo(left + cardRadius, 1)
      ..lineTo(right - cardRadius, 1)
      ..arcToPoint(
        Offset(right, 1 + cardRadius),
        radius: Radius.circular(cardRadius),
      );
    // Draw one contour explicitly. Shared outside edges stay straight;
    // inset card edges turn into the guide with a tangent circular shoulder.
    if (column == columns - 1) {
      path.lineTo(right, bottom - guideRadius);
    } else {
      path
        ..lineTo(right, guideTop - shoulder)
        ..arcToPoint(
          Offset(right + shoulder, guideTop),
          radius: const Radius.circular(shoulder),
          clockwise: false,
        )
        ..lineTo(size.width - 1 - guideRadius, guideTop)
        ..arcToPoint(
          Offset(size.width - 1, guideTop + guideRadius),
          radius: Radius.circular(guideRadius),
        )
        ..lineTo(size.width - 1, bottom - guideRadius);
    }
    path
      ..arcToPoint(
        Offset(size.width - 1 - guideRadius, bottom),
        radius: Radius.circular(guideRadius),
      )
      ..lineTo(1 + guideRadius, bottom)
      ..arcToPoint(
        Offset(1, bottom - guideRadius),
        radius: Radius.circular(guideRadius),
      );
    if (column == 0) {
      path.lineTo(left, 1 + cardRadius);
    } else {
      path
        ..lineTo(1, guideTop + guideRadius)
        ..arcToPoint(
          Offset(1 + guideRadius, guideTop),
          radius: Radius.circular(guideRadius),
        )
        ..lineTo(left - shoulder, guideTop)
        ..arcToPoint(
          Offset(left, guideTop - shoulder),
          radius: const Radius.circular(shoulder),
          clockwise: false,
        )
        ..lineTo(left, 1 + cardRadius);
    }
    return path
      ..arcToPoint(
        Offset(left + cardRadius, 1),
        radius: Radius.circular(cardRadius),
      )
      ..close();
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
