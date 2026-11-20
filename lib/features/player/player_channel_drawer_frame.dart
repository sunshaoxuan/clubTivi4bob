import 'package:flutter/material.dart';

/// Touch channel lists follow the window direction and leave the video mounted.
class PlayerChannelDrawerFrame extends StatelessWidget {
  const PlayerChannelDrawerFrame({super.key, required this.child, this.touch});
  final Widget child;
  final bool? touch;
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final platform = Theme.of(context).platform;
    final isTouch =
        touch ??
        (platform == TargetPlatform.iOS || platform == TargetPlatform.android);
    final bottom = isTouch && size.height > size.width;
    return Positioned(
      key: ValueKey(
        bottom ? 'touch-player-bottom-channels' : 'touch-player-right-channels',
      ),
      right: 0,
      bottom: 0,
      top: bottom ? null : 0,
      width: bottom
          ? size.width
          : isTouch
          ? (size.width * .48).clamp(296.0, 420.0)
          : 320,
      height: bottom ? size.height * .68 : null,
      child: TweenAnimationBuilder<Offset>(
        duration: const Duration(milliseconds: 200),
        tween: Tween(
          begin: bottom ? const Offset(0, 1) : const Offset(1, 0),
          end: Offset.zero,
        ),
        builder: (context, value, child) =>
            FractionalTranslation(translation: value, child: child),
        child: ClipRRect(
          borderRadius: bottom
              ? const BorderRadius.vertical(top: Radius.circular(24))
              : BorderRadius.zero,
          child: child,
        ),
      ),
    );
  }
}
