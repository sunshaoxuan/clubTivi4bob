import 'package:flutter/material.dart';

/// Keep the existing desktop row; touch-tablet portrait actions wrap below it.
class AdaptiveHomeToolbar extends StatelessWidget {
  const AdaptiveHomeToolbar({
    super.key,
    required this.brand,
    required this.actions,
  });
  final Widget brand;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      if (size.maxWidth >= 780) {
        return Row(children: [brand, const Spacer(), ...actions]);
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
