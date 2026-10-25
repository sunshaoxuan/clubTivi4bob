import 'package:flutter/material.dart';

class ChannelProgrammeStatus extends StatelessWidget {
  const ChannelProgrammeStatus({
    super.key,
    required this.loading,
    required this.failed,
    required this.hasMapping,
  });
  final bool loading, failed, hasMapping;

  @override
  Widget build(BuildContext context) {
    final title = loading
        ? '正在读取节目表'
        : failed
        ? '节目表暂时无法读取'
        : hasMapping
        ? '当前暂无节目数据'
        : '暂无可用节目表';
    final detail = loading
        ? '节目数据加载后会显示在这里'
        : failed
        ? '请再次点击频道重试'
        : hasMapping
        ? '节目源更新后会自动显示'
        : '可在设置中检查节目源与频道匹配';
    return Container(
      height: 96,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF18263B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          if (loading)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.event_note_outlined, color: Color(0xFFAFC8EE)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Color(0xFFB6C4D8),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
