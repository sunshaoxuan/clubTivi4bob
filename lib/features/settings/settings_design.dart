import 'package:flutter/material.dart';

Future<T?> showSettingsDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (context) => SettingsDesign(child: Builder(builder: builder)),
);

class SettingsDetailPage extends StatelessWidget {
  const SettingsDetailPage({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.floatingActionButton,
  });
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  @override
  Widget build(BuildContext context) => SettingsDesign(
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          tooltip: '返回设置',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: actions,
      ),
      floatingActionButton: floatingActionButton,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1C2945), Color(0xFF101A2C), Color(0xFF070B14)],
          ),
        ),
        child: SizedBox.expand(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: body,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Shared desktop settings language, aligned with the channel browser.
class SettingsDesign extends StatelessWidget {
  const SettingsDesign({super.key, required this.child});
  final Widget child;
  static const accent = Color(0xFFB7CAFF);

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: accent,
          onPrimary: const Color(0xFF122039),
          secondaryContainer: const Color(0xFF26354A),
          onSecondaryContainer: accent,
          surface: const Color(0xFF142034),
        ),
        scaffoldBackgroundColor: const Color(0xFF0B1321),
        hoverColor: accent.withValues(alpha: .09),
        focusColor: accent.withValues(alpha: .16),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1321),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF19283D),
          elevation: 0,
          shape: shape,
        ),
        listTileTheme: ListTileThemeData(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 6,
          ),
          iconColor: accent,
          titleTextStyle: TextStyle(
            fontFamily: base.textTheme.bodyMedium?.fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
          subtitleTextStyle: TextStyle(
            fontFamily: base.textTheme.bodyMedium?.fontFamily,
            fontSize: 12,
            height: 1.5,
            color: Color(0xFFA8B8D1),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: const Color(0xFF122039),
            minimumSize: const Size(64, 42),
            shape: shape,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.white
                : const Color(0xFF8C9DB8),
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? const Color(0xFF688CCD)
                : const Color(0xFF29394E),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF101B2B),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF3B4B65)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF3B4B65)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: accent),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF172439),
          shape: shape,
        ),
      ),
      child: child,
    );
  }
}

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFFB2C3DE),
            ),
          ),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1E2D45), Color(0xFF111B2C)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF50617E).withValues(alpha: .42),
            ),
          ),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: Divider(height: 1, color: Color(0xFF2B3B52)),
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class SettingsCategory {
  const SettingsCategory(
    this.title,
    this.description,
    this.icon,
    this.sections,
  );
  final String title;
  final String description;
  final IconData icon;
  final List<int> sections;
}

const settingsCategories = [
  SettingsCategory('频道与节目', '管理频道来源，让节目单与频道准确对应。', Icons.live_tv_rounded, [
    0,
    3,
  ]),
  SettingsCategory(
    '播放体验',
    '调整缓冲和换线策略，找到适合当前网络的观看方式。',
    Icons.play_circle_outline_rounded,
    [4],
  ),
  SettingsCategory('显示与遥控', '时间、天气和遥控方式，按你的使用习惯调整。', Icons.tune_rounded, [
    5,
    6,
  ]),
  SettingsCategory('同步与隐私', '公共频道库与诊断分享，所有选项由你控制。', Icons.cloud_sync_outlined, [
    1,
  ]),
  SettingsCategory(
    'AI 与影视',
    '连接智能分类和影视信息服务。密钥沿用现有存储方式。',
    Icons.auto_awesome_rounded,
    [2, 10],
  ),
  SettingsCategory('录像与备份', '保存喜欢的节目，备份频道和个人设置。', Icons.folder_open_rounded, [
    7,
    8,
  ]),
  SettingsCategory('更新与关于', '查看当前版本、下载进度与开源项目。', Icons.info_outline_rounded, [
    9,
  ]),
];

/// Lazily mounts categories on first visit and retains their form state.
class SettingsWorkspace extends StatefulWidget {
  const SettingsWorkspace({
    super.key,
    required this.sections,
    required this.onBack,
  });
  final List<Widget> sections;
  final VoidCallback onBack;
  @override
  State<SettingsWorkspace> createState() => _SettingsWorkspaceState();
}

class _SettingsWorkspaceState extends State<SettingsWorkspace> {
  int _selected = 0;
  final _visited = <int>{0};

  void _select(int value) {
    if (value == _selected) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selected = value;
      _visited.add(value);
    });
  }

  Widget _navigation(bool compact) {
    final items = [
      for (var i = 0; i < settingsCategories.length; i++)
        Padding(
          padding: EdgeInsets.only(
            bottom: compact ? 0 : 6,
            right: compact ? 6 : 0,
          ),
          child: Material(
            color: _selected == i
                ? const Color(0xFFB7CAFF)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              key: ValueKey('settings-category-$i'),
              borderRadius: BorderRadius.circular(14),
              onTap: () => _select(i),
              child: Semantics(
                selected: _selected == i,
                button: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: Row(
                    mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                    children: [
                      Icon(
                        settingsCategories[i].icon,
                        size: 19,
                        color: _selected == i
                            ? const Color(0xFF122039)
                            : const Color(0xFF9EAFCC),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        settingsCategories[i].title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _selected == i
                              ? const Color(0xFF122039)
                              : const Color(0xFFB8C6DD),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
    if (compact) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: items),
      );
    }
    return ListView(children: items);
  }

  @override
  Widget build(BuildContext context) => SettingsDesign(
    child: Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1C2945), Color(0xFF101A2C), Color(0xFF070B14)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1320),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 24, 16),
                    child: Row(
                      children: [
                        IconButton.filledTonal(
                          onPressed: widget.onBack,
                          tooltip: '返回频道',
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const SizedBox(width: 16),
                        const Text(
                          '设置',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const Spacer(),
                        const Text(
                          'BobTV',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFB7CAFF),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final compact = constraints.maxWidth < 760;
                        final pages = IndexedStack(
                          index: _selected,
                          children: [
                            for (var i = 0; i < settingsCategories.length; i++)
                              ExcludeFocus(
                                excluding: i != _selected,
                                child: TickerMode(
                                  enabled: i == _selected,
                                  child: _visited.contains(i)
                                      ? SingleChildScrollView(
                                          key: PageStorageKey(
                                            'settings-page-$i',
                                          ),
                                          padding: EdgeInsets.fromLTRB(
                                            compact ? 20 : 36,
                                            18,
                                            compact ? 20 : 36,
                                            36,
                                          ),
                                          child: Align(
                                            alignment: Alignment.topLeft,
                                            child: ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxWidth: 880,
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    settingsCategories[i].title,
                                                    style: const TextStyle(
                                                      fontSize: 28,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 10),
                                                  Text(
                                                    settingsCategories[i]
                                                        .description,
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                      height: 1.6,
                                                      color: Color(0xFF9EAFCC),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 28),
                                                  for (final index
                                                      in settingsCategories[i]
                                                          .sections)
                                                    widget.sections[index],
                                                ],
                                              ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                          ],
                        );
                        if (compact) {
                          return Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: _navigation(true),
                              ),
                              const SizedBox(height: 8),
                              Expanded(child: pages),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 236,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  18,
                                  8,
                                  20,
                                ),
                                child: _navigation(false),
                              ),
                            ),
                            const VerticalDivider(
                              width: 1,
                              color: Color(0xFF2A3950),
                            ),
                            Expanded(child: pages),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
