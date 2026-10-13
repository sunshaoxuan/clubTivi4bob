import 'package:flutter/material.dart';

/// Keep the existing desktop row; touch-tablet portrait actions wrap below it.
class AdaptiveHomeToolbar extends StatelessWidget {
  const AdaptiveHomeToolbar({
    super.key,
    required this.brand,
    required this.actions,
    this.compact = false,
  });
  final Widget brand;
  final List<Widget> actions;
  final bool compact;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      if (size.maxWidth >= (compact ? 480 : 780)) {
        return Row(
          children: [
            Expanded(
              child: Align(alignment: Alignment.centerLeft, child: brand),
            ),
            ...actions,
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          brand,
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: actions,
            ),
          ),
        ],
      );
    },
  );
}
