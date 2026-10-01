import 'package:flutter/material.dart';

/// The branded splash has already been shown before channel initialization.
/// Keep this stage informational, without replaying another logo screen.
class ChannelStartupProgress extends StatelessWidget {
  const ChannelStartupProgress({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0A0A0F),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFF6C5CE7),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            status.trim().isEmpty ? '正在载入频道…' : status,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
      ),
    ),
  );
}
