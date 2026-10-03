import 'package:flutter/material.dart';

import '../../data/services/manual_channel_category.dart';

class ChannelCategoryPicker extends StatefulWidget {
  const ChannelCategoryPicker({super.key, required this.channelName});
  final String channelName;

  @override
  State<ChannelCategoryPicker> createState() => _ChannelCategoryPickerState();
}

class _ChannelCategoryPickerState extends State<ChannelCategoryPicker> {
  List<String> _path = [];
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final destination = ChannelCategoryDestination(_path);
    final options = ChannelCategoryDestination.children(_path)
        .where((name) => name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return Dialog(
      backgroundColor: const Color(0xFF172439),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFF536683)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.folder_open_rounded,
                    color: Color(0xFFADCFFF),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '变更分类 · ${widget.channelName}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _path = [];
                        _query = '';
                      }),
                      child: const Text('全部地区'),
                    ),
                    for (var index = 0; index < _path.length; index++) ...[
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Icon(Icons.chevron_right_rounded, size: 18),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          _path = _path.take(index + 1).toList();
                          _query = '';
                        }),
                        child: Text(_path[index]),
                      ),
                    ],
                  ],
                ),
              ),
              if (ChannelCategoryDestination.children(_path).isNotEmpty) ...[
                TextField(
                  onChanged: (value) => setState(() => _query = value),
                  key: ValueKey(_path.join('/')),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: '查找分类',
                  ),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in options)
                          OutlinedButton(
                            onPressed: () => setState(() {
                              _path = [..._path, option];
                              _query = '';
                            }),
                            child: Text(option),
                          ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 24),
                const Icon(
                  Icons.check_circle_outline_rounded,
                  color: Color(0xFFADCFFF),
                  size: 36,
                ),
                const SizedBox(height: 12),
                Text(_path.join(' / '), style: const TextStyle(fontSize: 18)),
              ],
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: destination.valid
                        ? () => Navigator.pop(context, destination)
                        : null,
                    child: const Text('应用分类'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
