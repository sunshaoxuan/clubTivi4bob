import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../core/player_resources.dart';
import 'subtitle_picker.dart';
import 'subtitle_status_badge.dart';
import 'subtitle_status.dart';

class BobtvVideo extends StatelessWidget {
  const BobtvVideo({
    super.key,
    required this.controller,
    this.controls = AdaptiveVideoControls,
    this.fit = BoxFit.contain,
    this.fill = Colors.black,
    this.showSubtitleMenu = false,
    this.showSubtitleStatus = true,
    this.channelName,
  });
  final VideoController controller;
  final VideoControlsBuilder? controls;
  final BoxFit fit;
  final Color fill;
  final bool showSubtitleMenu;
  final bool showSubtitleStatus;
  final String? channelName;

  @override
  Widget build(BuildContext context) {
    final player = controller.player;
    return Stack(
      fit: StackFit.expand,
      children: [
        Video(controller: controller, controls: controls, fit: fit, fill: fill),
        if (channelName?.trim().isNotEmpty ?? false)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) => Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * .6,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x99081220),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        channelName!.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (player is ManagedPlayer)
          Positioned.fill(
            child: VideoSubtitleViewport(
              controller: controller,
              fit: fit,
              child: ValueListenableBuilder<String>(
                valueListenable: player.liveSubtitles.text,
                builder: (context, text, _) => LayoutBuilder(
                  builder: (context, constraints) => Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        12,
                        0,
                        12,
                        (constraints.maxHeight * .04).clamp(4, 24),
                      ),
                      child: Text(
                        text,
                        textAlign: TextAlign.center,
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          fontSize: (constraints.maxWidth / 38).clamp(11, 32),
                          height: 1.3,
                          color: Colors.white,
                          backgroundColor: const Color(0xaa000000),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (player is ManagedPlayer && showSubtitleStatus)
          Positioned.fill(
            child: ValueListenableBuilder<SubtitlePhase>(
              valueListenable: player.liveSubtitles.status,
              builder: (context, phase, _) => SubtitleStatusBadge(phase: phase),
            ),
          ),
        if (player is ManagedPlayer && showSubtitleMenu)
          Positioned(
            left: 8,
            bottom: 52,
            child: SubtitleMenuButton(session: () => player.liveSubtitles),
          ),
      ],
    );
  }
}
