import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/services/channel_merge.dart';
import '../../data/services/route_identity.dart';
import '../../data/services/manual_channel_category.dart';
import 'channel_category_picker.dart';

class ChannelMergeDialog extends StatefulWidget {
  const ChannelMergeDialog({
    super.key,
    required this.database,
    required this.channel,
    required this.seedUrls,
  });
  final db.AppDatabase database;
  final db.Channel channel;
  final List<String> seedUrls;

  @override
  State<ChannelMergeDialog> createState() => _ChannelMergeDialogState();
}

class _ChannelMergeDialogState extends State<ChannelMergeDialog> {
  final _selected = <String, ChannelMergeChoice>{};
  final _name = TextEditingController();
  final _search = TextEditingController();
  List<ChannelMergeChoice> _choices = [];
  String? _seedId;
  Map<String, List<db.Channel>>? _choiceSnapshot;
  List<String> _groups = [];
  String? _group;
  String _destination = '';
  Timer? _debounce;
  int _generation = 0;
  bool _loading = true;
  bool _review = false;
  bool _saving = false;
  bool _more = false;
  String? _error;
  List<db.Channel> _members = [];
  List<String> _urls = [];

  @override
  void initState() {
    super.initState();
    _name.text = widget.channel.name;
    _destination = widget.channel.groupTitle ?? '其他';
    _group = _destination;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final snapshot = await widget.database.channelMergeSnapshot();
      final seed = await widget.database.channelMergeChoiceForChannel(widget.channel, snapshot: snapshot);
      final groups = await widget.database.channelMergeGroups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _choiceSnapshot = snapshot;
        _seedId = seed.id;
        _selected[seed.id] = seed;
      });
      await _load();
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = '频道读取失败，请重试';
        });
    }
  }

  Future<void> _load({bool more = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.database.searchChannelMergeChoices(
        snapshot: _choiceSnapshot,
        query: _search.text,
        group: _group,
        offset: more ? _choices.length : 0,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _choices = more ? [..._choices, ...rows] : rows;
        _more = rows.length == 80;
        _loading = false;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = '频道读取失败，请重试';
        });
      }
    }
  }

  Future<void> _prepareReview() async {
    if (_saving || _selected.length < 2) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final members = <String, db.Channel>{};
      for (final channel in await widget.database.channelsForMergeChoices(_selected.values)) {
        members[channel.id] = channel;
      }
      final seed = await widget.database.getChannelsByStreamUrls(
        widget.seedUrls,
      );
      for (final channel in seed) members[channel.id] = channel;
      if (!mounted) return;
      setState(() {
        _members = members.values.toList();
        _urls = members.values.map((c) => canonicalRouteUrl(c.streamUrl)).toSet().toList();
        _review = true;
        _saving = false;
      });
    } catch (_) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = '线路读取失败，请重试';
        });
    }
  }

  Future<void> _chooseDestination() async {
    final destination = await showDialog<ChannelCategoryDestination>(
      context: context,
      builder: (_) => ChannelCategoryPicker(
        channelName: _name.text,
        existingGroups: _groups,
      ),
    );
    if (mounted && destination != null)
      setState(() => _destination = destination.group);
  }

  Future<void> _save() async {
    if (_saving) return;
    final metadata =
        _members.where((c) => c.name == _name.text.trim()).firstOrNull ??
        widget.channel;
    final plan = ChannelMergePlan(
      name: _name.text,
      group: _destination,
      urls: _urls,
      epgId: metadata.tvgId,
      logoUrl: metadata.tvgLogo,
    );
    if (!plan.valid) {
      setState(() => _error = '请输入 1 至 128 字的频道名称，并选择有效分类；一次最多合并 1000 条线路');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.database.mergeChannels(plan);
      if (mounted) Navigator.pop(context, plan);
    } catch (_) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = '合并保存失败，本次未完成，请重试';
        });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: const Color(0xFF142238),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: const BorderSide(color: Color(0xFF506584)),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 700),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.merge_rounded, color: Color(0xFFB7CCFF)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _review ? '确认合并频道' : '选择要合并的频道',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '取消',
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _review ? '合并后共用一个名称和分类，重复地址只保留一条。' : '确认内容相同后再合并，可跨分类选择多个频道。',
                style: const TextStyle(color: Colors.white60),
              ),
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 92),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final choice in _selected.values)
                      InputChip(
                        label: Text(choice.name),
                        onDeleted:
                            _saving || _review || choice.id == _seedId
                            ? null
                            : () => setState(() => _selected.remove(choice.id)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!_review) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                        hintText: '搜索频道名称',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                      onChanged: (_) {
                        _debounce?.cancel();
                        _debounce = Timer(
                          const Duration(milliseconds: 180),
                          () => _load(),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 230,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(_group),
                      initialValue: _group ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '查找范围'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('全部分类')),
                        for (final group in {_destination, ..._groups})
                          DropdownMenuItem(
                            value: group,
                            child: Text(group, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) {
                              setState(
                                () => _group = value == '' ? null : value,
                              );
                              unawaited(_load());
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: ListView.builder(
                  itemCount: _choices.length + (_more ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _choices.length)
                      return TextButton(
                        onPressed: _loading ? null : () => _load(more: true),
                        child: const Text('显示更多频道'),
                      );
                    final choice = _choices[index];
                    final selected = _selected.containsKey(choice.id);
                    final isSeed =
                        choice.id == _seedId;
                    return CheckboxListTile(
                      value: selected || isSeed,
                      onChanged: isSeed || _saving
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                _selected[choice.id] = choice;
                              } else {
                                _selected.remove(choice.id);
                              }
                            }),
                      title: Text(choice.name),
                      subtitle: Text(
                        '${choice.group} · ${choice.routeCount} 条线路',
                        style: const TextStyle(color: Colors.white54),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      selected: selected || isSeed,
                    );
                  },
                ),
              ),
            ] else ...[
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      TextField(
                        controller: _name,
                        maxLength: 128,
                        decoration: const InputDecoration(
                          labelText: '合并后的频道名称',
                          hintText: '选择原名称或输入新名称',
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final name
                              in _selected.values.map((c) => c.name).toSet())
                            ActionChip(
                              label: Text(name),
                              onPressed: _saving
                                  ? null
                                  : () => setState(() => _name.text = name),
                            ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.folder_open_rounded,
                          color: Color(0xFFB7CCFF),
                        ),
                        title: const Text('归入分类'),
                        subtitle: Text(_destination),
                        trailing: OutlinedButton(
                          onPressed: _saving ? null : _chooseDestination,
                          child: const Text('选择分类'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${_selected.length} 个频道 · ${_urls.length} 条去重线路',
                        style: const TextStyle(
                          color: Color(0xFFB7CCFF),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '线路权重、来源记录和淘汰状态会保留。公共线路的合并在后台同步；个人订阅保持私有。',
                        style: TextStyle(color: Colors.white60),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.amber),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_review)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _review = false),
                    child: const Text('返回选择'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _saving || (!_review && _selected.length < 2)
                      ? null
                      : _review
                      ? _save
                      : _prepareReview,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.merge_rounded),
                  label: Text(
                    _saving
                        ? '正在保存'
                        : _review
                        ? '合并频道'
                        : '下一步',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
