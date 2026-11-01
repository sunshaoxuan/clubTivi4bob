import 'package:flutter/material.dart';

import '../../core/app_diagnostics.dart';
import '../../data/datasources/local/database.dart' as db;

/// A star is a direct toggle. List assignment remains a separate action.
Future<void> toggleChannelFavorite({
  required BuildContext context,
  required db.AppDatabase database,
  required String channelId,
  required bool isFavorite,
  required Future<void> Function() onChanged,
}) async {
  try {
    final removed = isFavorite
        ? await database.removeChannelFromAllFavorites(channelId)
        : <String>[];
    if (!isFavorite) await database.addChannelToDefaultFavorites(channelId);
    await onChanged();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(isFavorite ? '已取消收藏' : '已加入我的收藏'),
          action: isFavorite && removed.isNotEmpty
              ? SnackBarAction(
                  label: '撤销',
                  onPressed: () async {
                    try {
                      await database.restoreChannelFavoriteLists(
                        channelId,
                        removed,
                      );
                      await onChanged();
                    } catch (error, stack) {
                      AppDiagnostics.instance.recordError(
                        'favorites_undo',
                        error,
                        stack,
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('撤销失败，请稍后重试')),
                        );
                      }
                    }
                  },
                )
              : null,
        ),
      );
  } catch (error, stack) {
    AppDiagnostics.instance.recordError('favorites_toggle', error, stack);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('修改收藏失败，请稍后重试')));
    }
  }
}

/// Opening management never adds the channel back to an empty selection.
Future<void> showChannelFavoriteListSheet({
  required BuildContext context,
  required db.AppDatabase database,
  required String channelId,
  required String channelName,
  required Future<String?> Function() createListName,
  required Future<void> Function() onChanged,
}) async {
  final lists = await database.getAllFavoriteLists();
  final selected = await database.getListsForChannel(channelId);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A2E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => ChannelFavoriteListSheet(
      channelName: channelName,
      lists: lists,
      selectedIds: selected.map((l) => l.id).toSet(),
      onMembershipChanged: (id, checked) async {
        if (checked) {
          await database.addChannelToList(id, channelId);
        } else {
          await database.removeChannelFromList(id, channelId);
        }
        await onChanged();
      },
      onRemoveAll: () async {
        await database.removeChannelFromAllFavorites(channelId);
        await onChanged();
      },
      onCreate: () async {
        final name = await createListName();
        if (name == null || name.trim().isEmpty) return null;
        final list = await database.transaction(() async {
          final list = await database.createFavoriteList(name.trim());
          await database.addChannelToList(list.id, channelId);
          return list;
        });
        await onChanged();
        return list;
      },
    ),
  );
}

/// Shared pointer/keyboard/touch UI. Writes are serialized; checkboxes paint
/// immediately, failures roll back visibly, and dismissal never drops a write.
class ChannelFavoriteListSheet extends StatefulWidget {
  const ChannelFavoriteListSheet({
    super.key,
    required this.channelName,
    required this.lists,
    required this.selectedIds,
    required this.onMembershipChanged,
    required this.onRemoveAll,
    required this.onCreate,
  });

  final String channelName;
  final List<db.FavoriteList> lists;
  final Set<String> selectedIds;
  final Future<void> Function(String, bool) onMembershipChanged;
  final Future<void> Function() onRemoveAll;
  final Future<db.FavoriteList?> Function() onCreate;

  @override
  State<ChannelFavoriteListSheet> createState() =>
      _ChannelFavoriteListSheetState();
}

class _ChannelFavoriteListSheetState extends State<ChannelFavoriteListSheet> {
  late final _lists = List<db.FavoriteList>.of(widget.lists);
  late final _selected = Set<String>.of(widget.selectedIds);
  final _pending = <String>{};
  Future<void> _writes = Future.value();
  bool _busy = false;
  String? _error;

  void _setMembership(String id, bool checked) {
    final before = _selected.contains(id);
    final write = widget.onMembershipChanged;
    setState(() {
      checked ? _selected.add(id) : _selected.remove(id);
      _pending.add(id);
      _error = null;
    });
    final painted = WidgetsBinding.instance.endOfFrame;
    _writes = _writes.then((_) async {
      try {
        await painted;
        await write(id, checked);
      } catch (error, stack) {
        AppDiagnostics.instance.recordError(
          'favorites_membership',
          error,
          stack,
        );
        if (mounted) {
          setState(() {
            before ? _selected.add(id) : _selected.remove(id);
            _error = '修改收藏失败，请重试';
          });
        }
      } finally {
        if (mounted) setState(() => _pending.remove(id));
      }
    });
  }

  Future<void> _removeAll() async {
    final before = Set<String>.of(_selected);
    final remove = widget.onRemoveAll;
    setState(() {
      _selected.clear();
      _busy = true;
      _error = null;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      await remove();
    } catch (error, stack) {
      AppDiagnostics.instance.recordError('favorites_remove_all', error, stack);
      if (mounted) {
        setState(() {
          _selected.addAll(before);
          _error = '取消收藏失败，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final list = await widget.onCreate();
      if (list != null && mounted) {
        setState(() {
          _lists.add(list);
          _selected.add(list.id);
        });
      }
    } catch (error, stack) {
      AppDiagnostics.instance.recordError('favorites_create', error, stack);
      if (mounted) setState(() => _error = '新建收藏夹失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.star_rounded, color: Colors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '管理收藏夹：${widget.channelName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (_pending.isNotEmpty || _busy)
              const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_lists.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('暂无收藏夹'),
                      ),
                    for (final list in _lists)
                      CheckboxListTile(
                        key: ValueKey('favorite-list-${list.id}'),
                        dense: true,
                        value: _selected.contains(list.id),
                        title: Text(list.name),
                        onChanged: _busy || _pending.contains(list.id)
                            ? null
                            : (value) => _setMembership(list.id, value == true),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(),
            Wrap(
              spacing: 12,
              children: [
                TextButton.icon(
                  onPressed: _busy || _pending.isNotEmpty ? null : _create,
                  icon: const Icon(Icons.add),
                  label: const Text('新建收藏夹'),
                ),
                TextButton.icon(
                  onPressed: _busy || _pending.isNotEmpty || _selected.isEmpty
                      ? null
                      : _removeAll,
                  icon: const Icon(Icons.star_outline_rounded),
                  label: const Text('取消全部收藏'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
