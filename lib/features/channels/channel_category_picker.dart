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
  int _pathRevision = 0;
  bool _finished = false;

  void _selectOption(String option, int revision) {
    if (!mounted ||
        _finished ||
        revision != _pathRevision ||
        !ChannelCategoryDestination.children(_path).contains(option)) {
      return;
    }
    setState(() {
      _path = [..._path, option];
      _query = '';
      _pathRevision++;
    });
  }

  void _backTo(int depth, int revision) {
    if (!mounted ||
        _finished ||
        revision != _pathRevision ||
        depth < 0 ||
        depth >= _path.length) {
      return;
    }
    setState(() {
      _path = _path.take(depth).toList();
      _query = '';
      _pathRevision++;
    });
  }

  void _finish({int? revision}) {
    if (_finished || !mounted) return;
    final destination = ChannelCategoryDestination(_path);
    if (revision != null && (revision != _pathRevision || !destination.valid)) {
      return;
    }
    _finished = true;
    Navigator.pop(context, revision == null ? null : destination);
  }

  @override
  Widget build(BuildContext context) {
    final destination = ChannelCategoryDestination(_path);
    final revision = _pathRevision;
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
                    onPressed: () => _finish(),
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
                      onPressed: _path.isEmpty
                          ? null
                          : () => _backTo(0, revision),
                      child: const Text('全部地区'),
                    ),
                    for (var index = 0; index < _path.length; index++) ...[
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Icon(Icons.chevron_right_rounded, size: 18),
                      ),
                      TextButton(
                        onPressed: index == _path.length - 1
                            ? null
                            : () => _backTo(index + 1, revision),
                        child: Text(_path[index]),
                      ),
                    ],
                  ],
                ),
              ),
              if (ChannelCategoryDestination.children(_path).isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _path.isEmpty
                          ? '选择国家或地区'
                          : destination.valid
                          ? '可应用当前分类，也可继续细分'
                          : '选择下一级分类',
                      style: const TextStyle(
                        color: Color(0xFFADCFFF),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                TextField(
                  onChanged: (value) {
                    if (!_finished && revision == _pathRevision) {
                      setState(() => _query = value);
                    }
                  },
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
                        if (options.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Text(
                              '没有匹配的分类',
                              style: TextStyle(color: Colors.white60),
                            ),
                          ),
                        for (final option in options)
                          OutlinedButton(
                            key: ValueKey('category-option-$revision-$option'),
                            style: ButtonStyle(
                              animationDuration: const Duration(
                                milliseconds: 100,
                              ),
                              minimumSize: const WidgetStatePropertyAll(
                                Size(96, 48),
                              ),
                              padding: const WidgetStatePropertyAll(
                                EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                              shape: WidgetStatePropertyAll(
                                RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              foregroundColor: const WidgetStatePropertyAll(
                                Colors.white,
                              ),
                              backgroundColor: WidgetStateProperty.resolveWith(
                                (states) => states.contains(WidgetState.pressed)
                                    ? const Color(0xFF45688D)
                                    : states.contains(WidgetState.hovered)
                                    ? const Color(0xFF314D6D)
                                    : const Color(0xFF1E3048),
                              ),
                              side: WidgetStateProperty.resolveWith(
                                (states) => BorderSide(
                                  color:
                                      states.contains(WidgetState.pressed) ||
                                          states.contains(
                                            WidgetState.hovered,
                                          ) ||
                                          states.contains(WidgetState.focused)
                                      ? const Color(0xFFB7D7FF)
                                      : const Color(0xFF435A73),
                                  width:
                                      states.contains(WidgetState.hovered) ||
                                          states.contains(WidgetState.focused)
                                      ? 1.5
                                      : 1,
                                ),
                              ),
                            ),
                            onPressed: () => _selectOption(option, revision),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(option),
                                const SizedBox(width: 8),
                                Icon(
                                  ChannelCategoryDestination.children([
                                        ..._path,
                                        option,
                                      ]).isEmpty
                                      ? Icons.check_rounded
                                      : Icons.chevron_right_rounded,
                                  size: 17,
                                ),
                              ],
                            ),
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
                    onPressed: () => _finish(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: destination.valid
                        ? () => _finish(revision: revision)
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
