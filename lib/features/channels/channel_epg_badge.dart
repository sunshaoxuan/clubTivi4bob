import 'package:flutter/material.dart';

import '../../core/i18n/app_language.dart';

class ChannelEpgBadge extends StatelessWidget {
  const ChannelEpgBadge({super.key, this.size = 15});

  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: AppMessages.text(context, '节目单'),
    child: Icon(
      Icons.list_alt_rounded,
      size: size,
      color: const Color(0xFF94D8B2),
    ),
  );
}
