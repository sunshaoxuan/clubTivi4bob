import 'package:flutter/material.dart';
import '../../data/datasources/local/database.dart' as db;
import 'desktop_exit_button.dart';

/// Lightweight text over the video, matching the original fullscreen guide.
class FullscreenProgrammeOverlay extends StatelessWidget {
  const FullscreenProgrammeOverlay({
    super.key,
    required this.channelName,
    required this.programmes,
    required this.onReturn,
    this.timeshiftHours = 0,
    this.now,
  });
  final String channelName;
  final List<db.EpgProgramme> programmes;
  final VoidCallback onReturn;
  final int timeshiftHours;
  final DateTime? now;

  DateTime _time(DateTime value) =>
      value.add(Duration(hours: timeshiftHours)).toLocal();

  @override
  Widget build(BuildContext context) {
    final clock = (now ?? DateTime.now()).toLocal();
    final rows =
        programmes
            .where(
              (p) =>
                  _time(p.stop).isAfter(_time(p.start)) &&
                  _time(p.stop).isAfter(clock),
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    final current = rows
        .where((p) => !_time(p.start).isAfter(clock))
        .lastOrNull;
    final next = rows
        .where((p) => _time(p.start).isAfter(clock))
        .take(2)
        .toList();
    String range(db.EpgProgramme p) =>
        '${TimeOfDay.fromDateTime(_time(p.start)).format(context)} / ${TimeOfDay.fromDateTime(_time(p.stop)).format(context)}';
    const shadow = [Shadow(color: Colors.black87, blurRadius: 4)];
    Widget future(db.EpgProgramme p, String label) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        '$label：${p.title}  ${range(p)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 11,
          shadows: shadow,
        ),
      ),
    );
    final guide = Column(
      key: const ValueKey('fullscreen-programme-text'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (current != null) ...[
          Semantics(
            label: '正在播出',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 5),
                  child: Icon(
                    Icons.play_circle_outline,
                    size: 14,
                    color: Colors.cyanAccent,
                  ),
                ),
                Expanded(
                  child: Text(
                    current.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      shadows: shadow,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            range(current),
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              shadows: shadow,
            ),
          ),
        ] else
          const Text(
            '当前节目：暂无节目单',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              shadows: shadow,
            ),
          ),
        for (var i = 0; i < 2; i++)
          if (i < next.length)
            future(next[i], i == 0 ? '接下来' : '随后')
          else
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '${i == 0 ? '接下来' : '随后'}：暂无节目单',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  shadows: shadow,
                ),
              ),
            ),
      ],
    );
    final name = Text(
      channelName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        shadows: shadow,
      ),
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: onReturn,
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('返回频道'),
        ),
        const DesktopExitButton(),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          final sideWidth = (constraints.maxWidth / 4)
              .clamp(220 * textScale, double.infinity)
              .toDouble();
          if (constraints.maxWidth <
              680 * MediaQuery.textScalerOf(context).scale(1)) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: name),
                    controls,
                  ],
                ),
                if (rows.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 4), child: guide),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: sideWidth,
                child: Padding(
                  key: const ValueKey('fullscreen-channel-region'),
                  padding: const EdgeInsets.only(top: 6),
                  child: name,
                ),
              ),
              Expanded(
                child: Padding(
                  key: const ValueKey('fullscreen-programme-region'),
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Center(
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: rows.isEmpty ? const SizedBox.shrink() : guide,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: sideWidth,
                child: Align(
                  key: const ValueKey('fullscreen-actions-region'),
                  heightFactor: 1,
                  alignment: Alignment.topRight,
                  child: controls,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
