import 'package:flutter/material.dart';

import '../../core/tablet_presentation.dart';

/// Size policy shared by Windows, macOS and Android. Use the route's available
/// area after native chrome / app-wide controls, including during live resize.
class ResponsiveHomeLayout extends StatelessWidget {
  const ResponsiveHomeLayout({super.key, required this.builder});

  final Widget Function(BuildContext context, bool tiny) builder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final padding = MediaQuery.paddingOf(context);
      final height = constraints.maxHeight - padding.vertical;
      return builder(context, height <= 450);
    },
  );
}

class SimpleHomeContent extends StatelessWidget {
  const SimpleHomeContent({
    super.key,
    required this.preview,
    required this.channels,
  });
  final Widget preview;
  final Widget channels;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final split = TabletPresentation.splitLayout(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        child: split
            ? Row(
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: const ValueKey('simple-main-pane'),
                      child: preview,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: KeyedSubtree(
                      key: const ValueKey('simple-channel-pane'),
                      child: channels,
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  SizedBox(
                    height: (constraints.maxHeight * .25).clamp(90.0, 220.0),
                    child: preview,
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: channels),
                ],
              ),
      );
    },
  );
}
