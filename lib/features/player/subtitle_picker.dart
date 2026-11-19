import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/bobtv_palette.dart';
import '../../core/i18n/app_language.dart';
import 'live_subtitle_session.dart';
import 'subtitle_preferences.dart';
import 'subtitle_status.dart';
import 'subtitle_variants.dart';

class SubtitleMenuButton extends StatelessWidget {
  const SubtitleMenuButton({
    super.key,
    required this.session,
  });

  final LiveSubtitleSession? Function() session;

  @override
  Widget build(BuildContext context) {
    final preferences = SubtitlePreferences.instance;
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) {
        final label = AppMessages.text(context, '字幕');
        final icon = Icon(
          preferences.enabled
              ? Icons.closed_caption
              : Icons.closed_caption_disabled,
          size: 20,
        );
        void open() {
          final current = session();
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            backgroundColor: BobTvPalette.panel,
            builder: (context) => SubtitlePicker(
              preferences: preferences,
              options: current?.variantOptions,
              status: current?.status,
              onVariant: current?.selectVariant,
              onRetry: current?.retrySearch,
            ),
          );
        }

        final color = preferences.enabled ? Colors.white : Colors.white54;
        return IconButton(
          key: const ValueKey('subtitle-menu'),
          tooltip: label,
          icon: icon,
          style: IconButton.styleFrom(
            foregroundColor: color,
            minimumSize: const Size.square(36),
            padding: const EdgeInsets.all(7),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: open,
        );
      },
    );
  }
}

class SubtitlePicker extends StatelessWidget {
  const SubtitlePicker({
    super.key,
    required this.preferences,
    this.options,
    this.status,
    this.onVariant,
    this.onRetry,
  });

  final SubtitlePreferences preferences;
  final ValueListenable<SubtitleVariantOptions>? options;
  final ValueListenable<SubtitlePhase>? status;
  final void Function(String?, int)? onVariant;
  final Future<bool> Function(String)? onRetry;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.min(640, MediaQuery.sizeOf(context).height * .82),
        ),
        child: ListenableBuilder(
          listenable: Listenable.merge([preferences, options, status]),
          builder: (context, _) {
            final current = options?.value ?? const SubtitleVariantOptions();
            final language = preferences.language;
            final preferredGroup = current
                .forLanguage(language.tag)
                .firstOrNull
                ?.language;
            final versions = <String, List<SubtitleVariantCandidate>>{
              if (preferredGroup != null) preferredGroup: [],
            };
            for (final candidate in current.candidates) {
              versions.putIfAbsent(candidate.language, () => []).add(candidate);
            }
            final phase = status?.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    AppMessages.text(context, '字幕'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  trailing: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(AppMessages.text(context, '完成')),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (preferences.enabled && options != null) ...[
                          if (phase?.message case final message?)
                            Text(AppMessages.text(context, message)),
                          if (onRetry != null && current.scope > 0)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                icon: const Icon(Icons.refresh, size: 18),
                                label: Text(
                                  AppMessages.text(context, '重新查找{0}字幕', [
                                    language.label,
                                  ]),
                                ),
                                onPressed:
                                    current.searchingLanguages.contains(
                                      language.tag,
                                    )
                                    ? null
                                    : () async {
                                        final accepted = await onRetry!(
                                          language.tag,
                                        );
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.maybeOf(
                                          context,
                                        )?.showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              AppMessages.text(
                                                context,
                                                accepted
                                                    ? '已请求重新查找字幕'
                                                    : '字幕服务暂不可用',
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                              ),
                            ),
                          if (current.searchingLanguages.contains(
                                language.tag,
                              ) &&
                              phase != SubtitlePhase.searching)
                            Text(AppMessages.text(context, '正在查找字幕…')),
                          if (versions.isEmpty)
                            Text(AppMessages.text(context, '字幕版本'))
                          else ...[
                            _versionTile(
                              title: AppMessages.text(context, '自动选择版本'),
                              selected: current.selectedId == null,
                              onTap: () => onVariant?.call(null, current.scope),
                            ),
                            for (final group in versions.entries) ...[
                              Text(
                                AppMessages.text(context, '{0}字幕版本', [
                                  AppLanguage.fromTag(group.key)?.label ??
                                      group.key,
                                ]),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              for (final candidate in group.value)
                                _versionTile(
                                  title: candidate.label,
                                  provider: candidate.provider,
                                  selected: current.selectedId == candidate.id,
                                  active:
                                      current.activeId == candidate.id &&
                                      (phase == SubtitlePhase.ready ||
                                          phase ==
                                              SubtitlePhase.englishFallback),
                                  onTap: () => onVariant?.call(
                                    candidate.id,
                                    current.scope,
                                  ),
                                ),
                            ],
                          ],
                          const Divider(),
                        ],
                        Text(AppMessages.text(context, '字幕语言及回退')),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            ChoiceChip(
                              label: Text(AppMessages.text(context, '关闭字幕')),
                              selected: !preferences.enabled,
                              onSelected: (_) => preferences.setEnabled(false),
                            ),
                            ChoiceChip(
                              label: Text(AppMessages.text(context, '跟随界面语言')),
                              selected:
                                  preferences.enabled &&
                                  preferences.followsApplication,
                              onSelected: (_) => preferences.choose(null),
                            ),
                            for (final item in AppLanguage.values)
                              ChoiceChip(
                                label: Text(item.label),
                                selected:
                                    preferences.enabled &&
                                    !preferences.followsApplication &&
                                    language == item,
                                onSelected: (_) => preferences.choose(item),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _versionTile({
    required String title,
    required bool selected,
    required VoidCallback onTap,
    String? provider,
    bool active = false,
  }) => Builder(
    builder: (context) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
      ),
      selected: selected,
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: provider == null ? null : Text(provider),
      trailing: active
          ? Tooltip(
              message: AppMessages.text(context, '正在使用此版本'),
              child: const Icon(Icons.check),
            )
          : null,
      onTap: onTap,
    ),
  );
}
