import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../data/services/ai_runtime_settings.dart';

class AiConfigurationScreen extends StatefulWidget {
  const AiConfigurationScreen({super.key});

  @override
  State<AiConfigurationScreen> createState() => _AiConfigurationScreenState();
}

class _AiConfigurationScreenState extends State<AiConfigurationScreen> {
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  bool _enabled = false;
  bool _hasKey = false;
  bool _busy = true;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final settings = await AiRuntimeSettings.instance.load();
      if (!mounted) return;
      setState(() {
        _url.text = settings.baseUrl;
        _model.text = settings.model;
        _enabled = settings.enabled;
        _hasKey = settings.apiKey.isNotEmpty;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _notice('无法读取 AI 设置，请检查系统的安全存储');
    }
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _save({bool test = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AiRuntimeSettings.instance.save(
        baseUrl: _url.text,
        model: _model.text,
        enabled: _enabled,
        replacementKey: _key.text.isEmpty ? null : _key.text,
      );
      _key.clear();
      _hasKey = (await AiRuntimeSettings.instance.load()).apiKey.isNotEmpty;
      if (test && _enabled) {
        final values = await AiRuntimeSettings.instance.load();
        final client = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: false,
          headers: {'Authorization': 'Bearer ${values.apiKey}'},
        ));
        try {
          final response = await client.post<Map<String, dynamic>>(
            '${values.baseUrl}/chat/completions',
            data: {
              'model': values.model,
              'messages': [
                {'role': 'user', 'content': 'Reply with OK.'},
              ],
              'max_completion_tokens': 16,
            },
          );
          final choices = response.data?['choices'];
          if (choices is! List || choices.isEmpty) {
            throw const FormatException('Missing model response');
          }
          _notice('连接成功，AI 分类可用');
        } finally {
          client.close();
        }
      } else {
        _notice(_enabled ? 'AI 设置已保存' : 'AI 已关闭，未确认的频道将留在其他');
      }
    } on FormatException {
      _notice('请填写模型和密钥。远程端点须使用 HTTPS，本机可使用 HTTP');
    } catch (_) {
      _notice('连接或安全存储失败，请检查设置后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _removeKey() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AiRuntimeSettings.instance.removeKey();
      await AiRuntimeSettings.instance.save(
        baseUrl: _url.text,
        model: _model.text,
        enabled: false,
      );
      _key.clear();
      if (!mounted) return;
      setState(() {
        _hasKey = false;
        _enabled = false;
      });
      _notice('密钥已删除，AI 已关闭');
    } catch (_) {
      _notice('无法删除密钥，请检查系统的安全存储');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AI 分类设置')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'AI 只处理无法根据明确台名或节目单标识判断的频道。关闭或连接失败时，未确认的地区会保持未识别。',
            ),
            const SizedBox(height: 18),
            SwitchListTile(
              title: const Text('启用 AI 分类与源发现'),
              subtitle: const Text('配置完成后才能发送频道名称和分组信息'),
              value: _enabled,
              onChanged: _busy ? null : (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'OpenAI 兼容端点',
                hintText: 'https://example.com/v1',
                helperText: '填写 API 基址，包含 /v1 或服务商要求的路径',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _model,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '模型名称',
                hintText: '填写服务商提供的模型 ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _key,
              enabled: !_busy,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: _hasKey ? '已保存，留空表示保持原密钥' : '输入 API Key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _showKey ? '隐藏密钥' : '显示密钥',
                  icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text('密钥保存在本机安全存储，不写入备份或诊断日志。'),
            const SizedBox(height: 22),
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: _busy ? null : () => unawaited(_save()),
                  child: const Text('保存设置'),
                ),
                OutlinedButton(
                  onPressed: _busy || !_enabled
                      ? null : () => unawaited(_save(test: true)),
                  child: const Text('保存并测试连接'),
                ),
                TextButton(
                  onPressed: _busy || !_hasKey
                      ? null : () => unawaited(_removeKey()),
                  child: const Text('删除密钥'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
