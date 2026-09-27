# BobTV 公共源目录客户端对接 Prompt

请在本仓库的 BobTV 客户端接入已审核公共源目录。客户端代码在 `lib/`，站点及 API 在 `website/`。以 `website/API.md` 为服务端契约。不要把本地用户订阅、播放地址、访问令牌、请求头、账号、播放记录或原始设备标识上传。

启动后与运行期间读取 `GET https://bobtv.briconbric.com/api/v1/sources`。响应为 `{ "sources": [{ "id": "...", "name": "...", "url": "https://...", "feedback": { "recentPlayable": 0, "recentFailed": 0, "windowSeconds": 1800 } }] }`。当前目录允许为空。仅把明确来自该目录的地址与本地源分开标识，按用户选择或产品既有规则播放，不自动覆盖本地订阅。目录 URL 由服务端审核；客户端仍应对不可信网络目标、重定向及媒体解析设边界。近期反馈是匿名客户端观察，不能视为独立验证或播放保证。

对目录中的源，在真实播放开始或明确失败后发送 `POST https://bobtv.briconbric.com/api/v1/source-reports`，`Content-Type: application/json`，UTF-8，正文只能包含 `sourceId`、`fingerprint`、`playable`。客户端负责生成稳定、高熵的 64 字符小写十六进制指纹；生成和持久化方案由客户端开发进程确定，目标是在 IP 与网络环境变化后保持同一客户端标识。不要上传原始 MAC、硬件序列号、账号或指纹生成材料。示例：`{"sourceId":"example","fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","playable":true}`。在设置页说明该标识会被服务端再次哈希并保留于短期反馈记录，健康共享开关默认关闭，用户开启后自动上报。成功是 `202`；未知源 `404`、输入错误 `413/415/422` 不重试；`429` 遵循 `Retry-After`，`5xx` 使用有上限的退避。每个源每 5 分钟至多报告一次，网络失败不能影响播放。不要为未播放的候选源上报“成功”，也不要因为一次探测 HTTP 200 就认为媒体实际可观看。报告只由客户端调用 API，站点没有报告网页。

验收：测试空目录、目录缓存与网络失败、源与本地订阅隔离、关闭共享无上报、只在实际播放后上报、跨 IP 使用同一指纹、正文白名单、节流、错误重试与关闭播放器无后台任务。运行 `flutter test`、`flutter analyze`，发布新 Windows 包后从两台独立客户端实测目录与上报。现有发布包不会自动具备这项功能。

如需让客户端贡献新的公开源，增加独立、默认关闭的主动提交动作。提交前明确展示：将发送源名称和完整公开 HTTPS 地址；服务端会记录本次提交的 IP、设备类别、Cloudflare 可得的国家或地区及指纹摘要，私有保留 14 天用于审核及防滥用，不公开候选与贡献者信息。只在用户确认有权公开分享并主动勾选同意后发送 `POST https://bobtv.briconbric.com/api/v1/source-candidates`，正文只能为 `{"name":"名称","url":"https://public.example/live.m3u8","device":"Windows","fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","consent":true}`。使用与健康报告相同的客户端指纹，服务端只保存 SHA-256 摘要。设备仅从 `Windows`、`Android`、`iOS`、`macOS`、`Linux`、`Other` 中选择，不发送硬件 ID 或型号。禁止自动上传本地订阅、带账号或令牌的地址、请求头和播放历史。返回 `202` 只代表进入待审核队列，不能当作发布成功。错误与限流策略同健康报告。增加未同意不发送、URL 白名单、隐私字段和待审核状态的测试。候选只通过客户端 API 提交，无公开报告页面。
