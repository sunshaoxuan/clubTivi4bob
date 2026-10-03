import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/datasources/local/database.dart' as db;

/// A compact, read-only schedule for the channel selected in the channel grid.
///
/// Selection uses programme identity and effective airing times, so refreshes,
/// a new grid position, and EPG time shifts do not change which channel is shown.
class ChannelProgrammeStrip extends StatefulWidget {
  const ChannelProgrammeStrip({
    super.key,
    required this.channelName,
    required this.programmes,
    this.timeshiftHours = 0,
    this.now,
    this.embedded = false,
  });

  final String channelName;
  final List<db.EpgProgramme> programmes;
  final int timeshiftHours;
  final DateTime? now;
  final bool embedded;

  @override
  State<ChannelProgrammeStrip> createState() => _ChannelProgrammeStripState();
}

class _ChannelProgrammeStripState extends State<ChannelProgrammeStrip> {
  final _scrollController = ScrollController();
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollChanged);
    _startClock();
  }

  @override
  void didUpdateWidget(ChannelProgrammeStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.now != widget.now) _startClock();
    if (oldWidget.channelName != widget.channelName &&
        _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  void _startClock() {
    _clock?.cancel();
    if (widget.now == null) {
      _clock = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _scrollChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _clock?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  DateTime _effectiveTime(DateTime value) =>
      value.add(Duration(hours: widget.timeshiftHours)).toLocal();

  void _page(double direction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target =
        (position.pixels + direction * position.viewportDimension * .8).clamp(
          0.0,
          position.maxScrollExtent,
        );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = (widget.now ?? DateTime.now()).toLocal();
    final programmes = widget.programmes.where((programme) {
      final start = _effectiveTime(programme.start);
      final stop = _effectiveTime(programme.stop);
      return stop.isAfter(start) && stop.isAfter(now);
    }).toList()..sort((a, b) => a.start.compareTo(b.start));
    final currentProgrammes = programmes
        .where((programme) => !_effectiveTime(programme.start).isAfter(now))
        .toList();
    final upcoming = <db.EpgProgramme>[
      if (currentProgrammes.isNotEmpty) currentProgrammes.last,
      ...programmes.where(
        (programme) => _effectiveTime(programme.start).isAfter(now),
      ),
    ].take(3).toList(growable: false);
    if (upcoming.isEmpty) return const SizedBox.shrink();

    final textScaler = MediaQuery.textScalerOf(context);
    final titleHeight = textScaler.scale(14) * 1.28 * 2;
    final minimumCardWidth =
        188.0 + math.max(0.0, textScaler.scale(14) - 14) * 4;

    return Container(
      key: const ValueKey('channel-programme-strip'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: widget.embedded
          ? null
          : BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF17263A), Color(0xFF0F1B2C)],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFF7183A0).withValues(alpha: .2),
              ),
            ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 0.0;
          final available = constraints.maxWidth;
          final fits =
              available >=
              upcoming.length * minimumCardWidth + (upcoming.length - 1) * gap;
          final cardWidth = fits
              ? (available - (upcoming.length - 1) * gap) / upcoming.length
              : minimumCardWidth;
          final atStart =
              !_scrollController.hasClients || _scrollController.offset <= 1;
          final atEnd =
              _scrollController.hasClients &&
              _scrollController.position.hasContentDimensions &&
              _scrollController.offset >=
                  _scrollController.position.maxScrollExtent - 1;

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.calendar_today_rounded,
                    size: 14,
                    color: Color(0xFFADC5EC),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: widget.channelName,
                            style: const TextStyle(
                              color: Color(0xFFE7EEFC),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const TextSpan(
                            text: '  ·  节目时间轴',
                            style: TextStyle(color: Color(0xFF8FA2BF)),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, height: 1.3),
                    ),
                  ),
                  if (!fits) ...[
                    const SizedBox(width: 4),
                    _scrollButton(
                      key: const ValueKey('programme-scroll-previous'),
                      tooltip: '前面的节目',
                      icon: Icons.chevron_left_rounded,
                      onPressed: atStart ? null : () => _page(-1),
                    ),
                    const SizedBox(width: 3),
                    _scrollButton(
                      key: const ValueKey('programme-scroll-next'),
                      tooltip: '后面的节目',
                      icon: Icons.chevron_right_rounded,
                      onPressed: atEnd ? null : () => _page(1),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(scrollbars: false),
                child: Scrollbar(
                  key: const ValueKey('programme-scrollbar'),
                  controller: _scrollController,
                  thumbVisibility: !fits,
                  trackVisibility: !fits,
                  interactive: true,
                  thickness: 5,
                  radius: const Radius.circular(4),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    padding: EdgeInsets.only(bottom: fits ? 0 : 13),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < upcoming.length; i++) ...[
                            if (i > 0) const SizedBox(width: gap),
                            SizedBox(
                              width: cardWidth,
                              child: _programmeCard(
                                upcoming[i],
                                now: now,
                                index: i,
                                followsCurrent: currentProgrammes.isNotEmpty,
                                titleHeight: titleHeight,
                                last: i == upcoming.length - 1,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _scrollButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
    style: IconButton.styleFrom(
      foregroundColor: const Color(0xFFC9D9F5),
      disabledForegroundColor: const Color(0xFF566780),
      backgroundColor: const Color(0xFF25364D),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );

  Widget _programmeCard(
    db.EpgProgramme programme, {
    required DateTime now,
    required int index,
    required bool followsCurrent,
    required double titleHeight,
    required bool last,
  }) {
    final start = _effectiveTime(programme.start);
    final stop = _effectiveTime(programme.stop);
    final current = !start.isAfter(now) && stop.isAfter(now);
    final label = current
        ? '正在播出'
        : (index == (followsCurrent ? 1 : 0) ? '接下来' : '随后');
    final date = _dateLabel(start, now);
    final progress = current
        ? now.difference(start).inMilliseconds /
              stop.difference(start).inMilliseconds
        : 0.0;

    return Column(
      key: ValueKey('programme-${programme.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12, bottom: 5),
          child: Text(
            _time(start),
            style: TextStyle(
              color: current
                  ? const Color(0xFFD6E6FF)
                  : const Color(0xFF94ABC8),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 16,
          child: CustomPaint(
            key: ValueKey('programme-timeline-node-${programme.id}'),
            painter: _ProgrammeTimelineRail(current: current),
          ),
        ),
        const SizedBox(height: 7),
        Expanded(
          child: Container(
            margin: EdgeInsets.only(right: last ? 0 : 10),
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
            decoration: BoxDecoration(
              gradient: current
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF2D466B), Color(0xFF21324F)],
                    )
                  : null,
              color: current ? null : const Color(0xFF1C2A3E),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: current
                    ? const Color(0xFF9ABBEF).withValues(alpha: .42)
                    : const Color(0xFF7183A0).withValues(alpha: .12),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 7,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: current
                            ? const Color(0xFFBED6FF)
                            : const Color(0xFF98ABC6),
                      ),
                    ),
                    if (date != null)
                      Text(
                        date,
                        style: const TextStyle(
                          fontSize: 10,
                          height: 1.3,
                          color: Color(0xFF98ABC6),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 7),
                SizedBox(
                  height: titleHeight,
                  child: Text(
                    programme.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFF0F4FD),
                      fontSize: 14,
                      height: 1.28,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '${_time(start)} ~ ${_time(stop)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: Color(0xFFA7B9D2),
                  ),
                ),
                const SizedBox(height: 9),
                SizedBox(
                  height: 2,
                  child: current
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress.clamp(0.0, 1.0),
                            minHeight: 2,
                            color: const Color(0xFFB8D2FF),
                            backgroundColor: const Color(0xFF506483),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  String? _dateLabel(DateTime value, DateTime now) {
    final day = DateTime(value.year, value.month, value.day);
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return null;
    if (day == DateTime(now.year, now.month, now.day + 1)) return '明天';
    if (day == DateTime(now.year, now.month, now.day - 1)) return '昨天';
    return '${value.month}月${value.day}日';
  }
}

class _ProgrammeTimelineRail extends CustomPainter {
  const _ProgrammeTimelineRail({required this.current});
  final bool current;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, 8),
      Offset(size.width, 8),
      Paint()
        ..color = const Color(0xFF536D90)
        ..strokeWidth = 1.5,
    );
    if (current) {
      canvas.drawCircle(
        const Offset(12, 8),
        8,
        Paint()..color = const Color(0xFF8AB8FF).withValues(alpha: .18),
      );
    }
    canvas.drawCircle(
      const Offset(12, 8),
      current ? 4 : 3,
      Paint()
        ..color = current ? const Color(0xFFC6DEFF) : const Color(0xFF819AB9),
    );
  }

  @override
  bool shouldRepaint(_ProgrammeTimelineRail oldDelegate) =>
      current != oldDelegate.current;
}
