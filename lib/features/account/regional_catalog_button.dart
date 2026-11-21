import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_language.dart';
import '../../data/services/channel_category_classifier.dart';
import '../providers/provider_manager.dart';
import 'account_service.dart';
import 'regional_catalog_service.dart';

class RegionalCatalogButton extends ConsumerWidget {
  const RegionalCatalogButton({super.key, required this.onSignIn});
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    key: const ValueKey('regional-catalog-entry'),
    tooltip: AppMessages.text(context, '选择频道地区'),
    icon: const Icon(Icons.public),
    onPressed: () async {
      final service = ref.read(providerManagerProvider).regionalCatalog;
      await service.initialize();
      if (!context.mounted) return;
      if (!AccountService.instance.loggedIn) {
        onSignIn();
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (_) => _RegionDialog(service),
      );
    },
  );
}

class _RegionDialog extends StatefulWidget {
  const _RegionDialog(this.service);
  final RegionalCatalogService service;
  @override
  State<_RegionDialog> createState() => _RegionDialogState();
}

class _RegionDialogState extends State<_RegionDialog> {
  Set<String> selected = {};
  bool loading = true;
  String? error;
  String t(String text) => AppMessages.text(context, text);

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      await widget.service.loadRegions();
      if (mounted) setState(() => selected = Set.of(widget.service.selected));
    } catch (_) {
      if (mounted) setState(() => error = t('地区目录暂时不可用，请稍后重试'));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> save() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await widget.service.select(selected);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(() {
          loading = false;
          error = t('同步失败，已保留原有频道');
        });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('选择频道地区')),
    content: SizedBox(
      width: 440,
      height: 380,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (error != null) Text(error!),
                Expanded(
                  child: ListView(
                    children: [
                      for (final region in widget.service.available.entries)
                        CheckboxListTile(
                          value: selected.contains(region.key),
                          title: Text(
                            ChannelCategoryClassifier
                                    .internationalCountryNames[region.key
                                    .toLowerCase()] ??
                                region.key,
                          ),
                          subtitle: Text(
                            AppMessages.text(context, '共 {0} 个频道', [
                              region.value,
                            ]),
                          ),
                          onChanged: (checked) => setState(() {
                            checked == true
                                ? selected.add(region.key)
                                : selected.remove(region.key);
                          }),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    ),
    actions: [
      TextButton(
        onPressed: loading ? null : () => Navigator.pop(context),
        child: Text(t('取消')),
      ),
      if (error != null)
        TextButton(onPressed: loading ? null : load, child: Text(t('重试'))),
      FilledButton(
        onPressed: loading || widget.service.available.isEmpty ? null : save,
        child: Text(t('同步所选地区')),
      ),
    ],
  );
}
