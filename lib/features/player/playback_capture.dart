import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/i18n/app_language.dart';
import 'player_service.dart';

Future<void> capturePlaybackFrame(
  BuildContext context,
  PlayerService service,
) async {
  String t(String value) => AppMessages.text(context, value);
  try {
    final mobile = Platform.isIOS || Platform.isAndroid;
    final directory = mobile
        ? await getTemporaryDirectory()
        : (await getDownloadsDirectory()) ?? await getTemporaryDirectory();
    final name = 'BobTV_${DateTime.now().millisecondsSinceEpoch}.png';
    final path = await service.takeScreenshot('${directory.path}/$name');
    if (!context.mounted) return;
    if (path == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('当前无法截图'))));
      return;
    }
    if (!mobile) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppMessages.text(context, '截图已保存：{0}', [path]))),
      );
      return;
    }
    final bytes = await File(path).readAsBytes();
    if (!context.mounted) return;
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t('截图')),
        content: Image.memory(bytes, fit: BoxFit.contain),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t('关闭')),
          ),
          FilledButton(
            key: const ValueKey('save-playback-capture'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t('保存')),
          ),
        ],
      ),
    );
    if (save == true) {
      final saved = await FilePicker.platform.saveFile(
        fileName: name,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['png'],
      );
      if (context.mounted && saved != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('截图已保存'))));
      }
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('当前无法截图'))));
    }
  }
}
