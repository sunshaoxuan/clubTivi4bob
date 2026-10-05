import 'package:flutter/material.dart';

class DesktopPipControls extends StatelessWidget {
  const DesktopPipControls({
    super.key,
    required this.title,
    required this.volume,
    required this.onVolume,
    required this.onExpand,
    required this.onReturn,
    required this.onClose,
    required this.onDrag,
    this.busy = false,
  });
  final String title;
  final double volume;
  final ValueChanged<double> onVolume;
  final VoidCallback onExpand, onReturn, onClose, onDrag;
  final bool busy;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => onDrag(),
          child: Container(
            color: Colors.black54,
            height: 36,
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: '放大播放',
                  onPressed: busy ? null : onExpand,
                  icon: const Icon(
                    Icons.open_in_full,
                    color: Colors.white,
                    size: 17,
                  ),
                ),
                IconButton(
                  tooltip: '退出 BobTV',
                  onPressed: busy ? null : onClose,
                  icon: const Icon(Icons.close, color: Colors.white, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: Container(
          color: Colors.black87,
          height: 40,
          child: Row(
            children: [
              TextButton(
                onPressed: busy ? null : onReturn,
                child: const Text('返回频道'),
              ),
              IconButton(
                tooltip: volume == 0 ? '取消静音' : '静音',
                onPressed: () => onVolume(volume == 0 ? 50 : 0),
                icon: Icon(
                  volume == 0 ? Icons.volume_off : Icons.volume_up,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              Expanded(
                child: Slider(
                  value: volume.clamp(0, 100),
                  min: 0,
                  max: 100,
                  onChanged: onVolume,
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}
