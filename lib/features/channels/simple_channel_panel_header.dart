import 'package:flutter/material.dart';

/// Keep the sync badge and category summary together at the panel's right edge.
class SimpleChannelPanelHeader extends StatelessWidget {
  const SimpleChannelPanelHeader({
    super.key,
    required this.syncBadge,
    required this.summary,
  });

  final Widget syncBadge;
  final String summary;

  Widget _title() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 4,
        height: 28,
        decoration: BoxDecoration(
          color: const Color(0xFFA8BFFF),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 11),
      const Text(
        '选台',
        style: TextStyle(
          color: Colors.white,
          fontSize: 23,
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
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
      if (constraints.maxWidth < 280 * textScale) {
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
