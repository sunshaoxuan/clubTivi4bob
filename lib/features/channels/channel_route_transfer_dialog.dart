import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/services/channel_merge.dart';

class ChannelRouteTransferDialog extends StatefulWidget {
  const ChannelRouteTransferDialog({
    super.key,
    required this.database,
    required this.channel,
    required this.routeUrl,
  });
  final db.AppDatabase database;
  final db.Channel channel;
  final String routeUrl;

  @override
  State<ChannelRouteTransferDialog> createState() =>
      _ChannelRouteTransferDialogState();
}

class _ChannelRouteTransferDialogState
    extends State<ChannelRouteTransferDialog> {
  final _search = TextEditingController();
  List<ChannelMergeChoice> _choices = [];
  List<String> _groups = [];
  ChannelMergeChoice? _selected;
  String? _group;
  String? _error;
  Timer? _debounce;
  int _generation = 0;
  bool _loading = true;
  bool _saving = false;
  bool _more = false;

  String get _routeLabel {
    final uri = Uri.tryParse(widget.routeUrl);
    if (uri == null || uri.host.isEmpty) return widget.routeUrl;
    final tail = uri.pathSegments.where((p) => p.isNotEmpty).lastOrNull;
    return tail == null ? uri.host : '${uri.host} / $tail';
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final groups = await widget.database.channelMergeGroups();
      if (!mounted) return;
      setState(() => _groups = groups);
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
      final choices = await widget.database.searchChannelMergeChoices(
        query: _search.text,
        group: _group,
        offset: more ? _choices.length : 0,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _choices = more ? [..._choices, ...choices] : choices;
        _more = choices.length == 80;
        _loading = false;
      });
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() {
          _loading = false;
          _error = '频道读取失败，请重试';
        });
    }
  }

  Future<void> _save() async {
    final destination = _selected;
    if (_saving || destination == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.database.transferRoute(
        widget.routeUrl,
        destination,
      );
      if (mounted) Navigator.pop(context, result);
    } catch (_) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = '转移未完成。请确认目标频道仍存在、线路未淘汰，公共线路需转入公共频道。';
        });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Dialog(
      backgroundColor: const Color(0xFF142238),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFF506584)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 650),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.drive_file_move_rounded,
                    color: Color(0xFFB7CCFF),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '转移线路到…',
                      style: TextStyle(
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
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1D304B),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前频道：${widget.channel.name}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Tooltip(
                      message: widget.routeUrl,
                      child: Text(
                      _routeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '只移动这条线路，保留测速、权重和来源记录。',
                      style: TextStyle(color: Color(0xFFB7CCFF), fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _search,
                enabled: !_saving,
                decoration: const InputDecoration(
                  hintText: '搜索目标频道，可跨分类查找',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (_) {
                  _debounce?.cancel();
                  ++_generation;
                  _debounce = Timer(
                    const Duration(milliseconds: 180),
                    () => _load(),
                  );
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey(_group),
                initialValue: _group ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '查找范围'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部分类')),
                  for (final group in _groups)
                    DropdownMenuItem(
                      value: group,
                      child: Text(group, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        _debounce?.cancel();
                        setState(() => _group = value == '' ? null : value);
                        unawaited(_load());
                      },
              ),
              const SizedBox(height: 12),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: _choices.isEmpty && !_loading
                    ? const Center(child: Text('没有匹配的频道，试试其他名称或分类'))
                    : ListView.builder(
                        itemCount: _choices.length + (_more ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _choices.length)
                            return TextButton(
                              onPressed: _loading || _saving
                                  ? null
                                  : () => _load(more: true),
                              child: const Text('显示更多频道'),
                            );
                          final choice = _choices[index];
                          final source =
                              choice.name == widget.channel.name &&
                              choice.group ==
                                  (widget.channel.groupTitle ?? '其他');
                          final selected = _selected?.id == choice.id;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ListTile(
                              enabled: !source && !_saving,
                              selected: selected,
                              selectedTileColor: const Color(0xFF2A4166),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              leading: Icon(
                                selected
                                    ? Icons.check_circle_rounded
                                    : Icons.tv_rounded,
                                color: selected
                                    ? const Color(0xFFB7CCFF)
                                    : Colors.white54,
                              ),
                              title: Text(choice.name),
                              subtitle: Text(
                                '${choice.group} · ${choice.routeCount} 条线路',
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                              trailing: source
                                  ? const Text(
                                      '当前频道',
                                      style: TextStyle(fontSize: 12),
                                    )
                                  : null,
                              onTap: source || _saving
                                  ? null
                                  : () => setState(() => _selected = choice),
                            ),
                          );
                        },
                      ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Color(0xFFFFA4A4)),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _selected == null ? '请选择一个目标频道' : '转入：${_selected!.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _saving || _selected == null ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.drive_file_move_rounded),
                    label: Text(_saving ? '正在转移' : '转移线路'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
