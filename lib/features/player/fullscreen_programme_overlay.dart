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
        ],
        for (var i = 0; i < next.length; i++)
          future(next[i], i == 0 ? '接下来' : '随后'),
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
    return Align(
      alignment: Alignment.topLeft,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 680) {
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
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: guide,
                      ),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: name,
                    ),
                  ),
                  if (rows.isNotEmpty) ...[
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: guide,
                      ),
                    ),
                  ],
                  const SizedBox(width: 16),
                  controls,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
