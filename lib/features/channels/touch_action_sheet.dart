import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/i18n/app_language.dart';

class TouchAction {
  const TouchAction(
    this.id,
    this.label,
    this.icon,
    this.run, {
    this.selected = false,
  });
  final String id;
  final String label;
  final IconData icon;
  final FutureOr<void> Function()? run;
  final bool selected;
}

/// Close the sheet before navigating or starting another dialog.
Future<void> showTouchActionSheet(
  BuildContext context, {
  required String title,
  required List<TouchAction> actions,
}) async {
  final action = await showModalBottomSheet<TouchAction>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              for (final action in actions)
                ListTile(
                  key: ValueKey('touch-action-${action.id}'),
                  minVerticalPadding: 12,
                  enabled: action.run != null,
                  leading: Icon(
                    action.icon,
                    color: action.selected ? Colors.amber : null,
                  ),
                  title: Text(AppMessages.text(context, action.label)),
                  onTap: action.run == null
                      ? null
                      : () => Navigator.pop(sheetContext, action),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  if (context.mounted && action?.run != null) await action!.run!();
}
