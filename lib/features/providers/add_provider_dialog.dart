import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'provider_manager.dart';
import '../../data/services/epg_refresh_service.dart';
import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import '../../data/resource_package/resource_package.dart';
import '../../core/user_source_policy.dart';
import '../../core/i18n/app_language.dart';

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

enum _ProviderType { resource, single, m3u, xtream }

class _AddProviderPage extends ConsumerStatefulWidget {
  const _AddProviderPage();

  @override
  ConsumerState<_AddProviderPage> createState() => _AddProviderPageState();
}

class _AddProviderPageState extends ConsumerState<_AddProviderPage> {
  final _formKey = GlobalKey<FormState>();
  _ProviderType _type = UserSourcePolicy.enabled
      ? _ProviderType.resource
      : _ProviderType.m3u;
  final _category = TextEditingController();

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
    _category.dispose();
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

  Future<void> _importLocalPackage() async {
    await _addProvider(() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withReadStream: true,
        withData: false,
      );
      if (result == null) throw const _ImportCancelled();
      final file = result.files.single;
      if (file.size > ResourcePackage.maxBytes || file.readStream == null) {
        throw const FormatException('Resource file is too large or unreadable');
      }
      final bytes = <int>[];
      await for (final chunk in file.readStream!) {
        if (bytes.length + chunk.length > ResourcePackage.maxBytes) {
          throw const FormatException('Resource file is too large');
        }
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes);
      final value = jsonDecode(text);
      if (value is Map<String, dynamic> &&
          value['format'] == 'bobtv-sync-bootstrap') {
        await ref.read(providerManagerProvider).regionalCatalog.attach(value);
        return;
      }
      final package = ResourcePackage.parse(text);
      await _confirmResource(package, package.updateUrl?.toString() ?? '');
    });
  }

  Future<void> _confirmResource(ResourcePackage package, String address) async {
    if (!mounted) throw const _ImportCancelled();
    setState(() => _loading = false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(package.name),
        content: Text(
          '${AppMessages.text(context, '资源包摘要', [package.categories.length, package.channels.length, package.routeCount])}${address.isEmpty ? '' : '\n\n${Uri.parse(address).host}'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppMessages.text(context, '取消')),
          ),
          FilledButton(
            key: const ValueKey('resource-package-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppMessages.text(context, '导入资源包')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) throw const _ImportCancelled();
    setState(() => _loading = true);
    await ref
        .read(providerManagerProvider)
        .addResourcePackage(
          id: _generateId(package.name),
          address: address,
          package: package,
        );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_type == _ProviderType.resource) {
      await _addProvider(() async {
        final manager = ref.read(providerManagerProvider);
        final address = _m3uUrl.text.trim();
        final package = await manager.previewResourcePackage(address);
        await _confirmResource(package, address);
      });
    } else if (_type == _ProviderType.single) {
      await _addProvider(
        () => ref
            .read(providerManagerProvider)
            .addSingleRoute(
              name: _m3uName.text.trim(),
              address: _m3uUrl.text.trim(),
              category: _category.text.trim(),
            ),
      );
    } else if (_type == _ProviderType.m3u) {
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
      final epg = ref.read(epgRefreshServiceProvider);
      unawaited(() async {
        try {
          await epg.addDefaultSources();
          await epg.refreshAllSources();
        } catch (_) {}
      }());
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppMessages.text(context, "电视源添加成功"))),
      );
    } on _ImportCancelled {
      // Preview was dismissed without writing anything.
    } on ProviderLimitException catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: Text(AppMessages.text(context, "电视源数量已达上限")),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppMessages.text(context, "确定")),
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
          title: Text(AppMessages.text(context, "错误")),
          content: Text(
            AppMessages.text(context, '电视源添加失败：\n{0}', [
              e is FormatException ? e.message : e.runtimeType.toString(),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppMessages.text(context, "确定")),
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
            if (context.mounted) Navigator.of(context).pop();
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
            title: Text(AppMessages.text(context, "添加电视源")),
          ),
          body: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Provider type dropdown — D-pad navigable as a form field
                DropdownButtonFormField<_ProviderType>(
                  key: const ValueKey('source-type'),
                  initialValue: _type,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: AppMessages.text(context, "电视源类型"),
                    prefixIcon: Icon(Icons.live_tv),
                  ),
                  dropdownColor: const Color(0xFF1A1A2E),
                  items: [
                    DropdownMenuItem(
                      value: _ProviderType.resource,
                      child: Text(AppMessages.text(context, 'BobTV 资源包')),
                    ),
                    DropdownMenuItem(
                      value: _ProviderType.single,
                      child: Text(AppMessages.text(context, '单条播放线路')),
                    ),
                    if (!UserSourcePolicy.enabled)
                      DropdownMenuItem(
                        value: _ProviderType.m3u,
                        child: Text(AppMessages.text(context, "M3U 播放列表")),
                      ),
                    if (!UserSourcePolicy.enabled)
                      DropdownMenuItem(
                        value: _ProviderType.xtream,
                        child: Text(AppMessages.text(context, "Xtream Codes")),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _type = v);
                  },
                ),
                const SizedBox(height: 24),
                if (_type == _ProviderType.resource) ...[
                  TextFormField(
                    controller: _m3uUrl,
                    key: const ValueKey('resource-package-url'),
                    decoration: InputDecoration(
                      labelText: AppMessages.text(context, '资源包 URL'),
                    ),
                    keyboardType: TextInputType.url,
                    validator: _validateUrl,
                  ),
                  const SizedBox(height: 12),
                  Text(AppMessages.text(context, '资源包导入说明')),
                  TextButton.icon(
                    onPressed: _loading ? null : _importLocalPackage,
                    icon: const Icon(Icons.upload_file),
                    label: Text(AppMessages.text(context, '选择资源包文件')),
                  ),
                ],
                if (_type == _ProviderType.single) ...[
                  TextFormField(
                    controller: _m3uName,
                    key: const ValueKey('single-route-name'),
                    decoration: InputDecoration(
                      labelText: AppMessages.text(context, '频道名称'),
                    ),
                    validator: _validateRequired,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _m3uUrl,
                    key: const ValueKey('single-route-url'),
                    decoration: InputDecoration(
                      labelText: AppMessages.text(context, '播放地址'),
                    ),
                    validator: _validateRequired,
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _category,
                    decoration: InputDecoration(
                      labelText: AppMessages.text(context, '分类（留空自动识别）'),
                    ),
                  ),
                ],
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
        decoration: InputDecoration(
          labelText: AppMessages.text(context, "电视源名称"),
          hintText: AppMessages.text(context, "例如：BobTV 电视源"),
        ),
        validator: _validateRequired,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _m3uUrl,
        decoration: InputDecoration(
          labelText: AppMessages.text(context, "M3U URL"),
          hintText: AppMessages.text(context, "http://..."),
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
          label: Text(AppMessages.text(context, "粘贴网址")),
        ),
      ),
    ];
  }

  List<Widget> _buildXtreamFields() {
    return [
      TextFormField(
        controller: _xtreamName,
        decoration: InputDecoration(
          labelText: AppMessages.text(context, "电视源名称"),
          hintText: AppMessages.text(context, "例如：我的 Xtream"),
        ),
        validator: _validateRequired,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _xtreamUrl,
        decoration: InputDecoration(
          labelText: AppMessages.text(context, "服务器网址"),
          hintText: AppMessages.text(context, "http://..."),
        ),
        validator: _validateUrl,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _xtreamUser,
        decoration: InputDecoration(
          labelText: AppMessages.text(context, "用户名"),
        ),
        validator: _validateRequired,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _xtreamPass,
        decoration: InputDecoration(labelText: AppMessages.text(context, "密码")),
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
        key: const ValueKey('source-submit'),
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
            : Text(
                AppMessages.text(context, "添加电视源"),
                style: TextStyle(fontSize: 16),
              ),
      ),
    );
  }
}

class _ImportCancelled implements Exception {
  const _ImportCancelled();
}
