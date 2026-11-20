import 'package:flutter/material.dart';

import '../../core/tablet_presentation.dart';

/// Size policy shared by desktop and touch tablets. Use the route's available
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
      final platform = Theme.of(context).platform;
      final touchPortrait =
          MediaQuery.sizeOf(context).shortestSide >= 600 &&
          (platform == TargetPlatform.iOS ||
              platform == TargetPlatform.android) &&
          MediaQuery.orientationOf(context) == Orientation.portrait;
      final split = TabletPresentation.splitLayout(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        touchPortrait: touchPortrait,
      );
      final previewHeight = touchPortrait
          ? TabletPresentation.portraitPreviewHeight(
              constraints.maxWidth,
              constraints.maxHeight - 14,
            )
          : (constraints.maxHeight * .25).clamp(90.0, 220.0);
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        child: Flex(
          direction: split ? Axis.horizontal : Axis.vertical,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Retain the video subtree when changing the layout axis.
            Flexible(
              flex: split ? 1 : 0,
              fit: split ? FlexFit.tight : FlexFit.loose,
              child: SizedBox(
                height: split ? null : previewHeight,
                child: KeyedSubtree(
                  key: const ValueKey('simple-main-pane'),
                  child: preview,
                ),
              ),
            ),
            SizedBox(width: split ? 10 : 0, height: split ? 0 : 8),
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey('simple-channel-pane'),
                child: channels,
              ),
            ),
          ],
        ),
      );
    },
  );
}
