import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/bobtv_api_client.dart';
import '../../data/services/bobtv_community_service.dart';
import '../../data/services/device_favorites_privacy.dart';
import 'settings_design.dart';

class BobTvServiceSettings extends ConsumerStatefulWidget {
  const BobTvServiceSettings({super.key});

  @override
  ConsumerState<BobTvServiceSettings> createState() =>
      _BobTvServiceSettingsState();
}

class _BobTvServiceSettingsState extends ConsumerState<BobTvServiceSettings> {
  bool _busy = false;
  bool? _favoritesBackupEnabled;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFavoritePrivacy());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(bobTvCommunityProvider).start());
    });
  }

  Future<void> _loadFavoritePrivacy() async {
    final value = await DeviceFavoritesPrivacy.enabled();
    if (mounted) setState(() => _favoritesBackupEnabled = value);
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on BobTvApiException catch (error) {
      _notice('服务暂时不可用（HTTP ${error.statusCode ?? '连接失败'}）');
    } on FormatException {
      _notice('提交内容不符合服务要求，请检查名称和 HTTPS 地址');
    } catch (_) {
      _notice('操作未完成，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String detail) async {
    return await showSettingsDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(detail),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('同意开启'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _submitCandidate(BobTvCommunityService service) async {
    final name = TextEditingController();
    final url = TextEditingController();
    var consent = false;
    try {
      final input = await showSettingsDialog<(String, String)>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('提交候选电视源'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: name,
                      maxLength: 64,
                      onChanged: (_) => update(() {}),
                      decoration: const InputDecoration(labelText: '频道名称'),
                    ),
                    TextField(
                      controller: url,
                      onChanged: (_) => update(() {}),
                      decoration: const InputDecoration(
                        labelText: '公开 HTTPS 播放地址',
                      ),
                    ),
                    CheckboxListTile(
                      value: consent,
                      onChanged: (value) =>
                          update(() => consent = value ?? false),
                      title: const Text('我有权分享此地址，并同意提交审核'),
                    ),
                    const Text(
                      '提交时会发送播放地址、设备类型、网络 IP、地区和客户端指纹哈希。服务端会留存资料并人工审核。审核前不会加入公共源。',
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed:
                    consent &&
                        name.text.trim().isNotEmpty &&
                        url.text.trim().isNotEmpty
                    ? () => Navigator.pop(dialogContext, (
                        name.text.trim(),
                        url.text.trim(),
                      ))
                    : null,
                child: const Text('提交审核'),
              ),
            ],
          ),
        ),
      );
      if (input == null) return;
      await _run(() async {
        await service.submitCandidate(
          name: input.$1,
          url: input.$2,
          consent: true,
        );
        _notice('已提交审核，审核通过后才会进入公共源');
      });
    } finally {
      name.dispose();
      url.dispose();
    }
  }

  Future<void> _showReleases(BobTvCommunityService service) async {
    BobTvRelease? selected;
    await _run(() async {
      final releases = await service.fetchReleases();
      if (!mounted) return;
      await showSettingsDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('BobTV 发布版本'),
          content: SizedBox(
            width: 480,
            child: releases.isEmpty
                ? const Text('当前没有可下载版本')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: releases.length,
                    itemBuilder: (context, index) {
                      final release = releases[index];
                      return ListTile(
                        title: Text(release.version),
                        subtitle: Text('${release.date} · ${release.size}'),
                        trailing: const Icon(Icons.download_rounded),
                        onTap: () {
                          selected = release;
                          Navigator.pop(dialogContext);
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    });
    if (selected != null && mounted) {
      await _downloadRelease(service, selected!);
    }
  }

  Future<void> _downloadRelease(
    BobTvCommunityService service,
    BobTvRelease release,
  ) async {
    await _run(() async {
      _notice('正在下载并校验安装包');
      final file = await service.downloadRelease(release);
      _notice('校验完成，已保存至 ${file.path}。当前不会自动安装。');
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(bobTvCommunityProvider);
    return ValueListenableBuilder<BobTvCatalogState>(
      valueListenable: service.state,
      builder: (context, catalog, _) => SettingsPanel(
        title: '公共频道库',
        children: [
          ListTile(
            leading: const Icon(Icons.verified_rounded),
            title: const Text('已审核电视源'),
            subtitle: Text(
              catalog.loading
                  ? '正在同步，已缓存 ${catalog.count} 条'
                  : catalog.error
                  ? '网络不可用，使用缓存 ${catalog.count} 条'
                  : '当前 ${catalog.count} 条${catalog.fresh ? '，已同步' : '，等待同步'}',
            ),
            trailing: IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _busy
                  ? null
                  : () => unawaited(_run(service.refreshCatalog)),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.bookmark_added_outlined),
            title: const Text('本机收藏在线备份'),
            subtitle: const Text('仅原设备可恢复。关闭后收藏仍保存在本机，不再上传或读取备份'),
            value: _favoritesBackupEnabled ?? true,
            onChanged: _busy || _favoritesBackupEnabled == null
                ? null
                : (enabled) => unawaited(
                    _run(() async {
                      await DeviceFavoritesPrivacy.setEnabled(enabled);
                      if (mounted) {
                        setState(() => _favoritesBackupEnabled = enabled);
                      }
                      _notice(enabled ? '收藏将在后台恢复私有备份' : '在线备份已关闭，本机收藏已保留');
                    }),
                  ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.monitor_heart_rounded),
            title: const Text('分享播放状态'),
            subtitle: const Text('仅上报已审核源的可播结果，默认关闭'),
            value: service.healthFeedbackEnabled,
            onChanged: _busy
                ? null
                : (enabled) => unawaited(
                    _run(() async {
                      if (enabled &&
                          !await _confirm(
                            '分享播放状态',
                            '每个已审核源最多五分钟上报一次。会发送源编号、可播结果及客户端指纹哈希，不发送播放地址。',
                          )) {
                        return;
                      }
                      await service.setHealthFeedbackEnabled(enabled);
                      if (mounted) setState(() {});
                    }),
                  ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.bug_report_outlined),
            title: const Text('最近 30 天诊断同步'),
            subtitle: const Text('首次同意后定期增量上传，可随时关闭；国内经 cndrp 中继'),
            value: service.automaticLogsEnabled,
            onChanged: _busy
                ? null
                : (enabled) => unawaited(
                    _run(() async {
                      if (enabled &&
                          !await _confirm(
                            '同意同步最近 30 天的脱敏诊断',
                            '将同步本机最近 30 天仍可用的事件、版本、平台、请求阶段、节点、耗时、状态码及资源统计。原始异常、堆栈、播放地址、私人订阅、凭据、收藏和观看内容不会上传。国内经 cndrp 私有队列转交主节点，两个节点最多保留 30 天。可随时关闭并停止后续上传；已发出的请求不能撤回。存储容量保护可能缩短本机可用历史。',
                          )) {
                        return;
                      }
                      await service.setAutomaticLogsEnabled(enabled);
                      if (mounted) setState(() {});
                    }),
                  ),
          ),
          ValueListenableBuilder<String>(
            valueListenable: service.diagnostics.status,
            builder: (context, value, _) => ListTile(
              leading: const Icon(Icons.sync_rounded),
              title: Text(value),
              subtitle: const Text('中继暂存与主节点接收分别显示，关闭上传不影响播放'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file_rounded),
            title: const Text('手动上传诊断摘要'),
            onTap: _busy
                ? null
                : () => unawaited(
                    _run(() async {
                      await service.uploadLogSnapshot();
                      _notice('诊断摘要已上传');
                    }),
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.add_link_rounded),
            title: const Text('提交候选电视源'),
            subtitle: const Text('需要分享权利与隐私确认，提交后等待人工审核'),
            onTap: _busy ? null : () => unawaited(_submitCandidate(service)),
          ),
          ListTile(
            leading: const Icon(Icons.new_releases_rounded),
            title: const Text('查看发布版本'),
            subtitle: const Text('可下载并校验安装包，暂不自动安装'),
            onTap: _busy ? null : () => unawaited(_showReleases(service)),
          ),
        ],
      ),
    );
  }
}
