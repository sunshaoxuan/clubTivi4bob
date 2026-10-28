# macOS 数据库退出顺序修复与本机验收

日期：2026-10-24，日本时间。修复已安装在 `/Users/shou/Applications/BobTV.app`，版本保留为 `1.1.10+103`。未发布新的公共版本。

原故障由 `mac_update_install` 触发。原生窗口关闭后，Flutter VM 清理与 Drift 后台 SQLite 关闭重叠，`sqlite3_close_v2` 的函数销毁回调进入 Dart FFI 后触发 SIGABRT。

修复后的顺序为：分离渲染器，停止并等待后台同步任务，清理播放器等资源，等待数据库关闭，确认 SQLite 所属 isolate 已退出，最后允许窗口和 Flutter 引擎关闭。

数据库关闭 Future 被缓存，显式退出与 Riverpod 的释放回调共用同一关闭操作。当前 Drift 2.28.2 的 terminateAll 请求可能在原生 executor 关闭前回复，因此另外通过 isolate 的退出通知确认完整结束。数据库尚未关闭或关闭失败时，不放行原生关闭。

代码涉及 `lib/app/desktop_app_lifecycle.dart`、`lib/core/desktop_app_exit.dart`、`lib/data/datasources/local/database.dart`、`lib/features/providers/source_maintenance_coordinator.dart` 和 EPG、网站目录、频道同步、收藏同步、线路同步相关服务。既有工作区改动保留。构建使用的 11 个修复源码文件均与工作区哈希一致，见 `fixed-source-manifest.json`。

相关自动化测试共 93 项通过。包含真实后台 SQLite 连续打开和关闭、重复关闭共用 Future、数据库关闭未完成时保持原生关闭阻止状态、关闭失败保留窗口、后台 EPG 请求退出时等待完成。静态分析为 0 错误、0 警告，另有 25 项代码风格提示。

三轮原生 Release 验证使用独立的 CFFIXED_USER_HOME，未改动 HOME 环境变量。每轮从本机数据库在线备份建立测试数据，备份各含 22,086 条频道记录。测试入口调用完整应用，将测试版本标记为 1.1.9+102，实际下载并校验正式签名的 1.1.10+103 更新包，进入原生全屏后调用生产代码 DesktopUpdateService.installReady()。退出后更新程序完成安装。测试入口仅用于独立测试副本，已安装修复版使用普通 lib/main.dart。

| 轮次 | PID | 退出码 | 原生全屏 | 更新安装 | 新增崩溃报告 |
|---|---|---|---|---|---|
| 1 | 67911 | 0 | 是 | 完成 | 0 |
| 2 | 68297 | 0 | 是 | 完成 | 0 |
| 3 | 68549 | 0 | 是 | 完成 | 0 |

已安装修复版 PID 69649 完成正常应用退出，退出码为 0。日志先记录 desktop_database_close_completed，再记录 desktop_exit_cleanup_completed 和 application_stopped。重新打开后的 PID 为 69674，已确认 flutter_ready 与 player_ready，保留运行。

安装后原数据库 integrity_check 为 ok，频道记录保持 22,086 条。原安装包和数据库备份保留在验收输出目录的 original-install。

验收过程中另有替换前启动的旧实例 PID 69549 在 MPV 的 m_config_cache_from_shadow 路径发生 SIGABRT，时间为日本时间 01:49:45。其 App.framework UUID 为 B1851545-C52D-13F4-277A-5290E37E6288，与原安装备份一致；已安装修复版 UUID 为 B1851545-2CE2-61C1-277A-5290D1D0F354。该事件单独保留，不计入修复版的更新退出验证。普通退出验收改用 NSRunningApplication 按 PID 定向退出，避免同名实例的应用路径寻址干扰。

已有网站目录 FormatException: Non-television website route 在验收时仍有记录。此次修复覆盖数据库退出顺序，该目录数据错误尚未处理。

验收证据目录：

`/Users/shou/Documents/Codex/2026-07-18/git/outputs/BobTV-macos-exit-fix-20261024`

主要证据文件：`native-update-exit-results.json`、三个 native-run 目录内的 receipt.json、`installed-verification.json`、`post-install-database-check.json`、`regression-tests.log`、`static-analysis.log`、`fixed-source-manifest.json`。原始更新状态、日志、进程标准输出和构建日志均已保留。
