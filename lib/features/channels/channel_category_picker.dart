import 'package:flutter/material.dart';

import '../../data/services/manual_channel_category.dart';

class ChannelCategoryPicker extends StatefulWidget {
  const ChannelCategoryPicker({
    super.key,
    required this.channelName,
    this.existingGroups = const [],
  });
  final String channelName;
  final List<String> existingGroups;

  @override
  State<ChannelCategoryPicker> createState() => _ChannelCategoryPickerState();
}

class _ChannelCategoryPickerState extends State<ChannelCategoryPicker> {
  List<String> _path = [];
  final _input = TextEditingController();
  String _query = '';
  int _pathRevision = 0;
  bool _finished = false;
  final List<ChannelCategoryDestination> _drafts = [];

  late final List<ChannelCategoryDestination> _existing = widget.existingGroups
      .map(ChannelCategoryDestination.fromGroup)
      .whereType<ChannelCategoryDestination>()
      .toList();

  List<String> _children(List<String> path) =>
      ChannelCategoryDestination.children(
        path,
        existing: [..._existing, ..._drafts],
      );

  String? _entryError(String value) {
    final error = ChannelCategoryDestination.nameError(value);
    if (error != null) return error;
    final path = [..._path, ChannelCategoryDestination.normalizeName(value)];
    final destination = ChannelCategoryDestination(path);
    final unfinishedChina =
        path.first == '中国' &&
        (path.length == 1 || (path.length == 2 && path[1] == '地方'));
    if (!destination.valid && !unfinishedChina) {
      return '分类路径过长或名称不可用，请换一个名称';
    }
    return null;
  }

  void _submitName(String name, int revision) {
    if (!mounted ||
        _finished ||
        revision != _pathRevision ||
        _entryError(name) != null) {
      return;
    }
    final normalized = ChannelCategoryDestination.normalizeName(name);
    final existing = _children(_path)
        .where((option) => option.toLowerCase() == normalized.toLowerCase())
        .firstOrNull;
    _advance(existing ?? normalized);
  }

  void _advance(String option) {
    setState(() {
      _path = [..._path, option];
      _query = '';
      _input.clear();
      _pathRevision++;
      final destination = ChannelCategoryDestination(_path);
      if (destination.valid &&
          !_drafts.any((d) => d.group == destination.group)) {
        _drafts.add(destination);
      }
    });
  }

  void _selectOption(String option, int revision) {
    if (!mounted ||
        _finished ||
        revision != _pathRevision ||
        !_children(_path).contains(option)) {
      return;
    }
    _submitName(option, revision);
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
      _input.clear();
      _pathRevision++;
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _finish({int? revision}) {
    if (_finished || !mounted) return;
    final destination = ChannelCategoryDestination(_path);
    if (revision != null &&
        (revision != _pathRevision ||
            _query.isNotEmpty ||
            !destination.valid)) {
      return;
    }
    _finished = true;
    Navigator.pop(context, revision == null ? null : destination);
  }

  @override
  Widget build(BuildContext context) {
    final destination = ChannelCategoryDestination(_path);
    final revision = _pathRevision;
    final typedName = ChannelCategoryDestination.normalizeName(_query);
    final inputError = _query.isEmpty ? null : _entryError(_query);
    final children = _children(_path);
    final canCreate =
        typedName.isNotEmpty &&
        inputError == null &&
        !children.any(
          (option) => option.toLowerCase() == typedName.toLowerCase(),
        );
    final options = children
        .where((name) => name.toLowerCase().contains(typedName.toLowerCase()))
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
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                            for (
                              var index = 0;
                              index < _path.length;
                              index++
                            ) ...[
                              const Padding(
                                padding: EdgeInsets.only(top: 12),
                                child: Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                ),
                              ),
                              TextButton(
                                onPressed: index == _path.length - 1
                                    ? null
                                    : () => _backTo(index + 1, revision),
                                child: Tooltip(
                                  message: _path[index],
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 160,
                                    ),
                                    child: Text(
                                      _path[index],
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (_path.isNotEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _path.join(' / '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      if (_path.length <
                          ChannelCategoryDestination.maxDepth) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              _path.isEmpty
                                  ? '选择国家或地区，也可输入名称新建'
                                  : destination.valid
                                  ? '可应用当前分类，也可输入名称继续细分'
                                  : '选择下一级分类，也可输入名称新建',
                              style: const TextStyle(
                                color: Color(0xFFADCFFF),
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                        TextField(
                          controller: _input,
                          onChanged: (value) {
                            if (!_finished && revision == _pathRevision) {
                              setState(() => _query = value);
                            }
                          },
                          onSubmitted: (value) => _submitName(value, revision),
                          key: const ValueKey('category-name-input'),
                          textInputAction: TextInputAction.done,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search_rounded),
                            hintText: _path.isEmpty
                                ? '搜索或输入国家、地区名称'
                                : '搜索或输入分类名称',
                            errorText: inputError,
                            errorMaxLines: 2,
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清空输入',
                                    onPressed: () {
                                      if (!mounted ||
                                          _finished ||
                                        revision != _pathRevision) {
                                        return;
                                    }
                                      _input.clear();
                                      setState(() => _query = '');
                                    },
                                    icon: const Icon(Icons.clear_rounded),
                                  ),
                          ),
                        ),
                        if (canCreate) ...[
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton.tonalIcon(
                              key: const ValueKey('category-create'),
                              onPressed: () => _submitName(_query, revision),
                              icon: const Icon(Icons.add_rounded),
                              label: Text(
                                '创建“$typedName”',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (options.isEmpty && _query.isNotEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 20),
                                child: Text(
                                  '没有匹配的分类',
                                  style: TextStyle(color: Colors.white60),
                                ),
                              ),
                            for (final option in options)
                              OutlinedButton(
                                key: ValueKey(
                                  'category-option-$revision-$option',
                                ),
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
                                  backgroundColor:
                                      WidgetStateProperty.resolveWith(
                                        (states) =>
                                            states.contains(WidgetState.pressed)
                                            ? const Color(0xFF45688D)
                                            : states.contains(
                                                WidgetState.hovered,
                                              )
                                            ? const Color(0xFF314D6D)
                                            : const Color(0xFF1E3048),
                                      ),
                                  side: WidgetStateProperty.resolveWith(
                                    (states) => BorderSide(
                                      color:
                                          states.contains(
                                                WidgetState.pressed,
                                              ) ||
                                              states.contains(
                                                WidgetState.hovered,
                                              ) ||
                                              states.contains(
                                                WidgetState.focused,
                                              )
                                          ? const Color(0xFFB7D7FF)
                                          : const Color(0xFF435A73),
                                      width:
                                          states.contains(
                                                WidgetState.hovered,
                                              ) ||
                                              states.contains(
                                                WidgetState.focused,
                                              )
                                          ? 1.5
                                          : 1,
                                    ),
                                  ),
                                ),
                                onPressed: () =>
                                    _selectOption(option, revision),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        option,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      _children([..._path, option]).isEmpty
                                          ? Icons.check_rounded
                                          : Icons.chevron_right_rounded,
                                      size: 17,
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ] else ...[
                        const SizedBox(height: 24),
                        const Icon(
                          Icons.check_circle_outline_rounded,
                          color: Color(0xFFADCFFF),
                          size: 36,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '已到最深一层，可应用当前分类',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
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
                    onPressed: destination.valid && _query.isEmpty
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
