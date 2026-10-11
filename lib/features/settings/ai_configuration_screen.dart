import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/services/server_task_client.dart';
import 'settings_design.dart';

class AiConfigurationScreen extends StatefulWidget {
  const AiConfigurationScreen({super.key, this.client});
  final ServerTaskClient? client;
  @override
  State<AiConfigurationScreen> createState() => _AiConfigurationScreenState();
}

class _AiConfigurationScreenState extends State<AiConfigurationScreen> {
  bool _busy = true;
  bool _personalAi = false;
  Map<String, dynamic>? _status;
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    unawaited(_loadConsent());
  }

  Future<void> _loadConsent() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(
        () => _personalAi = prefs.getBool('bobtv_ai_enabled_v1') == true,
      );
    }
  }

  Future<void> _saveConsent(bool value) async {
    setState(() => _personalAi = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bobtv_ai_enabled_v1', value);
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    Map<String, dynamic>? result;
    try {
      result = await (widget.client ?? ServerTaskClient()).status();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _status = result;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SettingsDetailPage(
    title: '服务器智能服务',
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.cloud_outlined, size: 48),
            const SizedBox(height: 20),
            Text(
              '线路发现与 AI 分类',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              '由 BobTV 服务器统一查找、刷新和分析。客户端只接收结果，无需配置模型或密钥，也不会直接访问 GitHub 或 AI 服务。',
            ),
            const SizedBox(height: 24),
            SwitchListTile.adaptive(
              title: const Text('辅助识别个人频道'),
              subtitle: const Text(
                '开启后仅发送频道名称、分组和节目单标识到服务器，不发送订阅地址或密钥。默认关闭，公共频道同步不受影响。',
              ),
              value: _personalAi,
              onChanged: _saveConsent,
            ),
            const SizedBox(height: 16),
            if (_busy)
              const LinearProgressIndicator()
            else
              Text(
                _status == null
                    ? '暂时无法连接服务器，已有频道仍可使用'
                    : _status!['aiAvailable'] == true
                    ? '服务器 AI 已就绪'
                    : '服务器 AI 暂未就绪',
              ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新服务状态'),
            ),
          ],
        ),
      ),
    ),
  );
}
