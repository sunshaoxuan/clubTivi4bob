# 右上角同步状态反复切换修复

日期：2026-10-24，日本时间。本机安装路径为 `/Users/shou/Applications/BobTV.app`，本地修复版保持 `1.1.10+103`。未发布公共版本。

已确认两个原因：

1. 目录 API 请求成功，但客户端将命中内容过滤规则的单条记录视为整份快照错误，抛出 `FormatException: Non-television website route`。本机目录版本无法前进，随后线路状态检查反复触发目录同步。捕获的线上快照共 8,999 个频道、9,972 条线路，其中 53 条购物线路与 1 条平台线路命中既有本机过滤规则。
2. 服务器因写入竞争返回 `202` 和 `queued: true` 时，事件已经持久化入队；客户端仍把保留在本机 outbox 的事件标记为失败，轮询前又改为同步中。

修复采用现有过滤策略逐条排除不接受的线路，保留快照原始线路计数校验、地址限制与结构检查。损坏的数据仍原子拒收；全部被过滤的非空快照也不会清空原可用目录。真正失败的目录请求按 30、60、120 秒逐步退避，最大常规间隔 15 分钟，并尊重服务端更长的 Retry-After。退避期间不会重新发送请求或清除错误状态。

收到服务器排队回执时设置独立 waiting 状态，右上角显示“等待确认”。后续确认轮询保持该状态，处理完成才显示“已同步”；确认请求真正发生网络异常时仍进入“同步待重试”，本机事件保留。

相关 56 项回归测试通过，另有真实线上完整快照重放测试通过：接受 9,918 条线路，排除 54 条，第二次同步没有再次下载同一快照。静态分析 0 错误、0 警告，4 项代码风格提示。

本机最终安装验收：

- 进程 PID：74116。首次同步后继续观察 75 秒，覆盖一分钟定时轮询。
- 成功导入记录：2 次；同步错误：0；此进程新增崩溃报告：0。
- 观察结束时待确认的本机事件：0。
- 数据库完整性：ok。总频道记录：22206。
- 原安装备份：`/Users/shou/Documents/Codex/2026-07-18/git/outputs/BobTV-sync-fix-20261024/before-confirmation-ui/BobTV.app`。数据库备份：`/Users/shou/Documents/Codex/2026-07-18/git/outputs/BobTV-sync-fix-20261024/before-confirmation-ui/clubtivi.db`。

首轮安装观察曾因原生窗口关闭请求而提前结束。日志完整记录资源清理、数据库 isolate 退出确认及应用停止，没有新增崩溃报告。最终版本另行完成以上完整观察。

同时只读核对了服务器队列：检查时队列为空，之前收到的一条本机上报已有 applied 回执，处理服务最近一次运行成功。未修改或重启服务器服务。

主要修改：`lib/data/services/website_channel_catalog_service.dart`、`lib/data/services/channel_inventory_sync_service.dart`、`lib/features/channels/shared_sync_badge.dart`，以及对应回归测试。保留此前数据库退出顺序修复和工作区既有改动。

证据目录：`/Users/shou/Documents/Codex/2026-07-18/git/outputs/BobTV-sync-fix-20261024`。

主要文件：`manifest.json`、`catalog.json.gz`、`rejected-routes.json`、`live-snapshot-test-receipt.json`、`regression-final.log`、`analyze-final.log`、`installed-sync-final-verification.json`、`server-queue-inspection.txt`、`source-hashes.json`。
