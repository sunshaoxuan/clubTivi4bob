import 'package:flutter/material.dart';

/// Keep the sync badge and category summary together at the panel's right edge.
class SimpleChannelPanelHeader extends StatelessWidget {
  const SimpleChannelPanelHeader({
    super.key,
    required this.syncBadge,
    required this.summary,
    this.compact = false,
  });

  final Widget syncBadge;
  final String summary;
  final bool compact;

  Widget _title() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 4,
        height: compact ? 18 : 28,
        decoration: BoxDecoration(
          color: const Color(0xFFA8BFFF),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      SizedBox(width: compact ? 7 : 11),
      Text(
        '选台',
        style: TextStyle(
          color: Colors.white,
          fontSize: compact ? 16 : 23,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
        ),
      ),
    ],
  );

  Widget _status() => Row(
    key: const ValueKey('simple-channel-panel-status'),
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      syncBadge,
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          summary,
          key: const ValueKey('simple-channel-panel-summary'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Colors.white60, fontSize: compact ? 10 : 12),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
      if (!compact && constraints.maxWidth < 280 * textScale) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [_title(), const SizedBox(height: 10), _status()],
        );
      }
      return Row(
        children: [
          _title(),
          const SizedBox(width: 12),
          Expanded(child: _status()),
        ],
      );
    },
  );
}
