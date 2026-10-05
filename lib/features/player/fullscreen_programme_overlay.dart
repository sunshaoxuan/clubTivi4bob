import 'package:flutter/material.dart';
import '../../data/datasources/local/database.dart' as db;
import '../channels/channel_programme_strip.dart';
import 'desktop_exit_button.dart';

/// Shares the channel browser's exact current/next/third timeline presentation.
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

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    heightFactor: 1,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xD9101929),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x447183A0)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.live_tv_rounded,
                    color: Color(0xFFADC5EC),
                    size: 18,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      channelName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onReturn,
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('返回频道'),
                  ),
                  const DesktopExitButton(),
                ],
              ),
            ),
            if (programmes.isNotEmpty)
              ChannelProgrammeStrip(
                channelName: channelName,
                programmes: programmes,
                embedded: true,
                showHeader: false,
                compact: true,
                timeshiftHours: timeshiftHours,
                now: now,
              ),
          ],
        ),
      ),
    ),
  );
}
