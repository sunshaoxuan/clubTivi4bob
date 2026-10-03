import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player_service.dart';

/// A muted alternative route that never interrupts the current programme.
class AlternativePreviewOverlay extends StatelessWidget {
  const AlternativePreviewOverlay({
    super.key,
    required this.service,
  });

  final PlayerService service;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AlternativePreviewState?>(
      valueListenable: service.alternativePreviewState,
      builder: (context, state, _) {
        if (state == null) return const SizedBox.shrink();
        return Material(
          color: Colors.transparent,
          child: Container(
            width: 252,
            decoration: BoxDecoration(
              color: const Color(0xFF111B2B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF8CAAF0)),
              boxShadow: const [BoxShadow(
                color: Color(0x99000000),
                blurRadius: 20,
                offset: Offset(0, 6),
              )],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 140,
                    child: state.controller == null
                        ? Center(child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(width: 22, height: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                              const SizedBox(height: 12),
                              Text(state.stage,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 12)),
                              if (state.total > 0)
                                Text('${state.index}/${state.total} 路',
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 11)),
                            ],
                          ))
                        : IgnorePointer(child: RepaintBoundary(child: Video(
                            key: ValueKey(state.controller),
                            controller: state.controller!,
                            controls: NoVideoControls,
                            fill: Colors.black,
                          ))),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 7, 5, 7),
                    child: Row(
                      children: [
                        Expanded(child: Text(
                          state.ready ? '备用线路 ${state.index}/${state.total}'
                              : '正在寻找更流畅线路',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11),
                        )),
                        if (state.ready)
                          TextButton(
                            onPressed: () async {
                              final switched =
                                  await service.commitAlternativePreview();
                              if (context.mounted && !switched) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text(
                                      '备用线路暂时无法切换，请稍后重试')),
                                );
                              }
                            },
                            style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFFB8CCFF),
                                minimumSize: const Size(48, 30),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6)),
                            child: const Text('切换'),
                          ),
                        IconButton(
                          tooltip: '关闭备用画面',
                          onPressed: service.dismissAlternativePreview,
                          icon: const Icon(Icons.close_rounded, size: 17),
                          color: Colors.white70,
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
