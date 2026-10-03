import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../player/player_service.dart';

/// Global route notifications only rebuild the card they actually affect.
class ChannelCardPlaybackBinding extends StatefulWidget {
  const ChannelCardPlaybackBinding({
    super.key,
    required this.channelId,
    required this.selected,
    required this.pending,
    required this.preparedChannelId,
    required this.previewController,
    required this.mainProgress,
    required this.previewProgress,
    required this.builder,
  });

  final String channelId;
  final bool selected;
  final bool pending;
  final String? Function() preparedChannelId;
  final ValueNotifier<VideoController?> previewController;
  final ValueNotifier<RouteSearchProgress?> mainProgress;
  final ValueNotifier<RouteSearchProgress?> previewProgress;
  final Widget Function(VideoController?, RouteSearchProgress?, bool) builder;

  @override
  State<ChannelCardPlaybackBinding> createState() =>
      _ChannelCardPlaybackBindingState();
}

class _ChannelCardPlaybackBindingState
    extends State<ChannelCardPlaybackBinding> {
  late (VideoController?, RouteSearchProgress?, bool) _snapshot;

  (VideoController?, RouteSearchProgress?, bool) _read() => (
    widget.preparedChannelId() == widget.channelId
        ? widget.previewController.value
        : null,
    widget.pending
        ? widget.previewProgress.value ?? widget.mainProgress.value
        : widget.selected
        ? widget.mainProgress.value
        : null,
    widget.pending ||
        (widget.selected &&
            widget.mainProgress.value?.active == true &&
            widget.mainProgress.value?.background != true),
  );

  void _listen(ChannelCardPlaybackBinding target, bool add) {
    for (final notifier in <Listenable>[
      target.previewController,
      target.mainProgress,
      target.previewProgress,
    ]) {
      if (add) {
        notifier.addListener(_changed);
      } else {
        notifier.removeListener(_changed);
      }
    }
  }

  void _changed() {
    final next = _read();
    if (next == _snapshot) return;
    setState(() => _snapshot = next);
  }

  @override
  void initState() {
    super.initState();
    _snapshot = _read();
    _listen(widget, true);
  }

  @override
  void didUpdateWidget(ChannelCardPlaybackBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    _listen(oldWidget, false);
    _listen(widget, true);
    _snapshot = _read();
  }

  @override
  void dispose() {
    _listen(widget, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: widget.builder(_snapshot.$1, _snapshot.$2, _snapshot.$3),
  );
}
