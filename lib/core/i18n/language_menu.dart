import 'package:flutter/material.dart';

import 'app_language.dart';

class LanguageScope extends InheritedWidget {
  const LanguageScope({
    super.key,
    required this.selected,
    required this.onSelected,
    required super.child,
  });

  final AppLanguage? selected;
  final ValueChanged<String> onSelected;

  static LanguageScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanguageScope>();

  @override
  bool updateShouldNotify(LanguageScope oldWidget) =>
      oldWidget.selected != selected;
}

class LanguageMenu extends StatelessWidget {
  const LanguageMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = LanguageScope.of(context);
    if (scope == null) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: AppMessages.text(context, '语言'),
      icon: const Icon(Icons.language, size: 20),
      initialValue: scope.selected?.tag ?? 'system',
      onSelected: scope.onSelected,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'system',
          child: Text(AppMessages.text(context, '跟随系统')),
        ),
        for (final language in AppLanguage.values)
          PopupMenuItem(value: language.tag, child: Text(language.label)),
      ],
    );
  }
}
