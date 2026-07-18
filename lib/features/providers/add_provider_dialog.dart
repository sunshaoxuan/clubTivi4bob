import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'provider_manager.dart';

/// Shows the Add Provider dialog.
/// Uses a full-screen page (navigable via D-pad) instead of a bottom sheet.
Future<bool?> showAddProviderDialog(BuildContext context) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const _AddProviderPage(),
    ),
  );
}

enum _ProviderType { m3u, xtream }

class _AddProviderPage extends ConsumerStatefulWidget {
  const _AddProviderPage();

  @override
  ConsumerState<_AddProviderPage> createState() => _AddProviderPageState();
}

class _AddProviderPageState extends ConsumerState<_AddProviderPage> {
  final _formKey = GlobalKey<FormState>();
  _ProviderType _type = _ProviderType.m3u;

  // M3U fields
  final _m3uName = TextEditingController();
  final _m3uUrl = TextEditingController();

  // Xtream fields
  final _xtreamName = TextEditingController();
  final _xtreamUrl = TextEditingController();
  final _xtreamUser = TextEditingController();
  final _xtreamPass = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
    _m3uName.dispose();
    _m3uUrl.dispose();
    _xtreamName.dispose();
    _xtreamUrl.dispose();
    _xtreamUser.dispose();
    _xtreamPass.dispose();
    super.dispose();
  }

  String _slugify(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String _generateId(String name) {
    final slug = _slugify(name);
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${slug.isEmpty ? 'provider' : slug}-$ts';
  }

  String? _validateRequired(String? value) {
    if (value == null || value.trim().isEmpty) return '必填';
    return null;
  }

  String? _validateUrl(String? value) {
    if (value == null || value.trim().isEmpty) return '必填';
    if (!value.trim().startsWith('http')) return '网址必须以 http 开头';
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_type == _ProviderType.m3u) {
      await _addProvider(() {
        final manager = ref.read(providerManagerProvider);
        return manager.addM3uProvider(
          id: _generateId(_m3uName.text.trim()),
          name: _m3uName.text.trim(),
          url: _m3uUrl.text.trim(),
        );
      });
    } else {
      await _addProvider(() {
        final manager = ref.read(providerManagerProvider);
        return manager.addXtreamProvider(
          id: _generateId(_xtreamName.text.trim()),
          name: _xtreamName.text.trim(),
          url: _xtreamUrl.text.trim(),
          username: _xtreamUser.text.trim(),
          password: _xtreamPass.text.trim(),
        );
      });
    }
  }

  Future<void> _addProvider(Future<void> Function() action) async {
    setState(() => _loading = true);
    try {
      await action();
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('电视源添加成功')));
    } on ProviderLimitException catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('电视源数量已达上限'),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('错误'),
          content: Text('电视源添加失败：\n$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pasteUrl(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      controller.text = data!.text!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final pf = FocusManager.instance.primaryFocus;
          if (pf?.context?.findAncestorWidgetOfExactType<EditableText>() !=
              null) {
            pf!.unfocus();
            return;
          }
          Future.microtask(() {
            Navigator.of(context).pop();
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xFF0A0A0F),
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: const Text('添加电视源'),
          ),
          body: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Provider type dropdown — D-pad navigable as a form field
                DropdownButtonFormField<_ProviderType>(
                  value: _type,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '电视源类型',
                    prefixIcon: Icon(Icons.live_tv),
                  ),
                  dropdownColor: const Color(0xFF1A1A2E),
                  items: const [
                    DropdownMenuItem(
                      value: _ProviderType.m3u,
                      child: Text('M3U 播放列表'),
                    ),
                    DropdownMenuItem(
                      value: _ProviderType.xtream,
                      child: Text('Xtream Codes'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _type = v);
                  },
                ),
                const SizedBox(height: 24),
                // Fields change based on type
                if (_type == _ProviderType.m3u) ..._buildM3uFields(),
                if (_type == _ProviderType.xtream) ..._buildXtreamFields(),
                const SizedBox(height: 24),
                _buildSubmitButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildM3uFields() {
    return [
      TextFormField(
        controller: _m3uName,
        decoration: const InputDecoration(
          labelText: '电视源名称',
          hintText: '例如：酒店电视源',
        ),
        validator: _validateRequired,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _m3uUrl,
        decoration: const InputDecoration(
          labelText: 'M3U URL',
          hintText: 'http://...',
        ),
        validator: _validateUrl,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => _pasteUrl(_m3uUrl),
          icon: const Icon(Icons.paste, size: 18),
          label: const Text('粘贴网址'),
        ),
      ),
    ];
  }

  List<Widget> _buildXtreamFields() {
    return [
      TextFormField(
        controller: _xtreamName,
        decoration: const InputDecoration(
          labelText: '电视源名称',
          hintText: '例如：我的 Xtream',
        ),
        validator: _validateRequired,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _xtreamUrl,
        decoration: const InputDecoration(
          labelText: '服务器网址',
          hintText: 'http://...',
        ),
        validator: _validateUrl,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _xtreamUser,
        decoration: const InputDecoration(labelText: '用户名'),
        validator: _validateRequired,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _xtreamPass,
        decoration: const InputDecoration(labelText: '密码'),
        obscureText: true,
        validator: _validateRequired,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _submit(),
      ),
    ];
  }

  Widget _buildSubmitButton() {
    const accent = Color(0xFF6C5CE7);
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: _loading ? null : _submit,
        style: FilledButton.styleFrom(backgroundColor: accent),
        child: _loading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('添加电视源', style: TextStyle(fontSize: 16)),
      ),
    );
  }
}
