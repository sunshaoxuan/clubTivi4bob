# BobTV 应用端 API 契约

核对日期：2026-09-27。服务基址：`https://bobtv.briconbric.com`。请求正文使用 UTF-8。应用端只访问本站，不需要访问 GitHub。

本文依据当前服务端实现编写。现有发布包尚未接入这些新 API。服务端没有公开的报告网页、候选源查询接口、贡献者汇总接口或供应用端使用的 API 密钥。公网 API 可以被其他程序调用，服务端不能证明请求一定来自 BobTV。

## 0. 预分类频道快照

公共线路使用规范化 URL 作为全局唯一标识，与客户端、来源仓库、台名和分类无关。统一协议及域名大小写、默认端口和空路径；保留实际路径、查询参数、HTTP/HTTPS 差异和非默认端口。重复来源分别记录，线路只入库一次。淘汰覆盖等价地址的所有副本，重新发现不能清除淘汰记录。重复淘汰不再递增版本。发布快照会拒绝地址等价的重复线路，客户端导入时也进行防御性去重。详见 `ROUTE_IDENTITY.md`。

`GET /api/v1/channel-catalog/manifest` 返回 `schemaVersion`、`version`、`generatedAt`、`channelCount`、`routeCount`、`snapshotUrl`、`compressedBytes` 和 `sha256`。当前尚未发布频道快照时返回 `{"schemaVersion":1,"version":null,"channelCount":0,"routeCount":0}`，客户端应继续使用本地目录。响应支持 `ETag` 和 `If-None-Match`。

有内容时，客户端从同一本站域名请求 `snapshotUrl`，路径格式为 `/api/v1/channel-catalog/snapshots/{sha256}.json.gz`。先核对压缩字节长度和 SHA-256，再解压、验证 `schemaVersion`、`version`、分类树及唯一的频道和线路 ID。快照的 `categories` 带有 `id`、`parentId`、`name`、`sortOrder`；`channels` 带有 `id`、`name`、`categoryId`、`countryCode`、`regionCode`、`sortOrder`、`epgId`、`logoUrl`、`routes`。每条 `routes` 包含 `id`、`url`、`source`、`lastPlayableAt`、`healthScore`。

快照由管理者使用 `publish_channel_catalog.py` 从已整理的 JSON 文件发布。脚本在完整校验后写入不可变压缩文件，最后原子替换 manifest。空目录、无效分类、重复 ID、未通过公开地址检查的线路都不能覆盖上一版。网站目前尚无可发布的已分类频道数据；这套接口不把未经审核的 GitHub 探索结果称为有效线路。客户端继续保留用户订阅、收藏、淘汰记录与本机后备目录。

所有 BobTV 安装读取同一份已发布快照。简洁模式在取得网站快照后只展示该共享清单和用户自己的收藏；进阶模式仍可查看本机订阅。客户端每 15 分钟检查一次版本，下载成功后应用新增或撤回的线路。用户在本机淘汰的 URL 仍会被本机屏蔽，网站发布新版不会让该 URL 自动复活。发布操作由管理者执行，本机播放反馈不会自动修改所有用户的共享清单。

## 1. 已审核视频源目录

`GET /api/v1/sources`，无需请求正文和认证。

成功时返回 HTTP `200`、`Content-Type: application/json` 和 `Cache-Control: no-store`：

```json
{
  "sources": [
    {
      "id": "example-channel",
      "name": "示例频道",
      "url": "https://media.example.org/live.m3u8",
      "feedback": {
        "recentPlayable": 2,
        "recentFailed": 1,
        "windowSeconds": 1800
      }
    }
  ]
}
```

示例地址与数据仅用于说明格式。正式目录目前返回 `{"sources":[]}`，空目录属于正常成功状态。`id` 是后续报告使用的源标识，匹配 `^[a-z0-9][a-z0-9-]{0,39}$`。`feedback` 统计最近 30 分钟内每个指纹的最新反馈，属于未经独立验证的客户端观察，不代表源可用或拥有分发授权。目录里的地址由服务端人工审核；客户端仍应限制媒体解析与跳转目标，并与用户自己的订阅分开保存，不自动覆盖本地源。

网络失败时可保留最近一次成功取得的目录供界面显示，并清楚区分缓存与当前结果。不要把目录中的 URL、用户自己的 URL 或访问令牌放进反馈请求。

## 2. 播放结果报告

`POST /api/v1/source-reports`，请求头 `Content-Type: application/json`，正文最多 **512 字节**，只允许以下三个字段：

```json
{
  "sourceId": "example-channel",
  "fingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "playable": true
}
```

| 字段 | 规则 |
| --- | --- |
| `sourceId` | 必需，目录中现有的 `id`，格式 `^[a-z0-9][a-z0-9-]{0,39}$`。 |
| `fingerprint` | 必需，客户端生成并持续使用的 **64 个小写十六进制字符**，格式 `^[a-f0-9]{64}$`。 |
| `playable` | 必需，JSON 布尔值 `true` 或 `false`，不能是字符串或数字。 |

成功返回 HTTP `202`：

```json
{"accepted":true}
```

仅对目录中的源，在实际媒体开始解码播放或明确失败后报告。单次 HTTP 200、未开始播放的候选源或尚未确定的网络状态不能作为成功播放。客户端每个源每 5 分钟最多上报一次。服务端按源、指纹及 5 分钟时间桶覆盖重复反馈，记录保存约 30 分钟；每个源的展示计数按指纹取最新结果。服务端只保存传入指纹的 SHA-256 摘要，不接收原始 MAC、硬件序列号、账号、播放 URL、请求头或令牌。

指纹的生成与本地持久化由客户端开发进程设计。它应有足够熵，在同一安装的 IP 和网络环境改变后保持稳定；不要直接上传 MAC 地址，也不要仅用可枚举的 MAC 值计算无盐摘要并假定它具备匿名性。应用内的健康反馈说明与开关建议默认关闭，用户启用后才自动上报。这是客户端要求，服务端无法代替客户端检查用户是否启用开关。

## 3. 候选源提交

`POST /api/v1/source-candidates`，请求头 `Content-Type: application/json`，正文最多 **4096 字节**，恰好包含以下五个字段：

```json
{
  "name": "示例频道",
  "url": "https://media.example.org/live.m3u8",
  "device": "Windows",
  "fingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "consent": true
}
```

| 字段 | 规则 |
| --- | --- |
| `name` | 必需，1 至 64 个字符，不含控制字符。 |
| `url` | 必需，不超过 2048 字符的公开 HTTPS 地址，包含非空路径；不含用户名、密码、查询参数、片段或自定义端口。拒绝 IP 字面量、单标签主机及 `.local`、`.internal`、`.localhost` 域名。 |
| `device` | 必需，只能是 `Windows`、`Android`、`iOS`、`macOS`、`Linux`、`Other` 之一。 |
| `fingerprint` | 必需，与播放报告相同的 64 字符小写十六进制指纹。 |
| `consent` | 必需，只接受 JSON 布尔值 `true`。 |

成功返回 HTTP `202`：

```json
{"id":"ca0e7bd553f2","pendingReview":true}
```

`id` 是地址摘要的前 12 个字符，仅用于回执。`202` 只表示进入私有待审核库，**不表示发布**。客户端应提供与健康反馈分开的主动提交动作，并在发送前让用户确认有权公开分享该源，明确告知将记录完整地址、本次请求 IP、粗粒度设备类别、可信 Cloudflare 边缘可得的国家或地区代码和指纹摘要。未同意时不要发请求，也不要自动上传用户本地订阅、带认证参数的 URL、播放历史或设备型号。待审核内容没有公共读取接口，也不会自动进入目录。

URL 校验限制的是语法与主机名形式，服务端不会对候选地址执行 DNS 解析或播放探测。客户端及审核流程不能把通过校验理解为来源安全、可访问或已有授权。

待审记录保留 14 天；同一 URL、指纹及自然日内的重复提交会更新已有记录。同一客户端更换 IP 后可继续以相同指纹关联待审记录。服务端对传入指纹再次计算 SHA-256 后存储；IP 和国家代码只留在私有待审库，不向公共目录返回。

## 4. 诊断日志上传

`POST /api/v1/logs`，请求头 `Content-Type: application/x-ndjson`，UTF-8 JSON Lines，每行一个 JSON 对象。正文最多 **1 MiB**，最多 **5000 行**，每行最多 **4096 个字符**。

```jsonl
{"time":"2026-09-27T00:00:00Z","event":"startup","platform":"windows"}
{"time":"2026-09-27T00:01:00Z","event":"heartbeat","uptimeSeconds":60,"rssBytes":12345678}
```

每行必须有 `time` 与 `event`。允许的字段全集是 `time`、`event`、`source`、`fatal`、`uptimeSeconds`、`rssBytes`、`maxRssBytes`、`platform`，任何额外字段会导致整次请求被拒绝。值只能是字符串、数字或布尔值，字符串最长 256 字符。客户端应将 `time`、`event`、`source`、`platform` 编码为字符串，`fatal` 为布尔值，数值指标为数字；服务端当前只强制值属于上述三种基本类型，客户端不要依赖这种宽松性。

首次保存返回 HTTP `201`：

```json
{"id":"<上传正文的64位小写SHA-256>","duplicate":false}
```

完全相同的请求字节再次上传返回 HTTP `200`，`duplicate` 为 `true`。日志仅在服务端私有存储，保留 14 天且无公共读取接口，总存储上限 512 MiB。客户端应从既有日志投影出白名单字段，发送最近的有限快照；不要发送原始日志、路径、异常正文、堆栈、播放地址、令牌、账号、崩溃转储或设备唯一标识。自动上传应由用户主动启用，默认关闭，关闭后停止请求。网络故障不得阻塞播放和本地日志。

## 5. 桌面版自动更新

Windows x64、macOS Intel 和 macOS Apple Silicon 分别检查
`GET /updates/windows-x64/latest.json`、`GET /updates/macos-x64/latest.json`、
`GET /updates/macos-arm64/latest.json`。尚未发布对应平台的合格更新包时返回
`404`，客户端继续使用当前版本。成功响应沿用 `schema: 1`、`version`、
`archive`、`sha256`、`bytes`、`publishedAt` 字段。macOS 清单还包含
`signature`，其值是对 ZIP 原始字节作 P-256 SHA-256 签名后得到的 Base64。
`archive` 位于本站
`/updates/files/`，仅已列入平台清单的 ZIP 可下载。客户端核对版本、字节长度、
SHA-256 和包内结构；Windows 在退出后备份并替换可写的便携安装目录，
macOS 还用应用内置公钥验证 ZIP 签名，并检查应用代码签名完整性、标识和架构。

发布工作流为 Windows 生成带 `BobTV/` 根目录的 ZIP 和
`BobTV-update-metadata.json`。镜像任务完整校验发布文件后再原子更新平台清单。
Mac 测试 DMG 不会进入自动更新清单。正式更新包必须用 BobTV 发布私钥签名，
经对应架构的安装测试后再发布。Apple Developer ID 签名与公证可另行加入，
不属于本站更新包签名的依赖项。

## 6. 状态码与重试

| 状态 | 含义 | 客户端处理 |
| --- | --- | --- |
| `200` | 目录成功，或日志正文已保存过。 | 成功完成。 |
| `201` | 新日志已保存。 | 成功完成。 |
| `202` | 播放报告已接受，或候选源进入待审库。 | 成功完成，不把候选视为发布。 |
| `404` | 报告引用了不在目录中的源，或路径不存在。 | 不重试相同请求，更新目录后再决定。 |
| `413` | 正文超过接口限制。 | 缩小或修正内容，不原样重试。 |
| `415` | `Content-Type` 不正确。 | 修正客户端，不原样重试。 |
| `422` | JSON、字段集合或字段值不合规。 | 修正客户端，不原样重试。 |
| `429` | 达到限流。 | 遵守响应头 `Retry-After`，使用有上限的退避。 |
| `503` | 存储达到上限等服务端暂时不可用。 | 遵守 `Retry-After`，稍后有限重试。 |
| 其他 `5xx` 或超时 | 服务端或网络暂时异常。 | 有上限的指数退避，不影响播放。 |

服务端限流分别为：播放报告每源站可见 IP 每小时最多 3600 次；候选提交每可识别来源 IP 每小时最多 30 次；日志上传每源站可见 IP 每小时最多 300 次。Cloudflare 代理可能导致部分限流按边缘节点地址聚合，因此客户端不要依赖这些上限作为发送频率目标。POST 错误通常返回 `{"detail":"..."}`。不要按英文 `detail` 文案分支，按 HTTP 状态和稳定字段处理。

## 6. 本站安装包接口

如果客户端需要读取本站发行包，可使用 `GET /releases.json` 获取 `releases` 数组，条目包含 `version`、`date`、`filename`、显示用的 `size` 和 64 字符 SHA-256 `sha256`。再请求 `GET /downloads/{filename}`；只有清单中的文件名可下载，支持 `HEAD` 和 HTTP Range。实际文件字节应以 `sha256` 校验，不能用显示用 `size` 校验。本站提供 Windows x64 ZIP 与 macOS Intel、Apple Silicon DMG，下载不会重定向用户到 GitHub。自动更新分别查询 `/updates/windows-x64/latest.json`、`/updates/macos-x64/latest.json`、`/updates/macos-arm64/latest.json`，校验更新包字节数与 SHA-256；macOS 更新还校验内置公钥对应的发布者签章。

## 7. 客户端验收要点

覆盖空目录、缓存与断网、用户本地源隔离、指纹格式与跨 IP 稳定性、真实播放后的报告、关闭开关无上报、候选提交前明确同意、非法地址拒绝、日志字段投影和大小限制、`200/201/202` 成功、`404/413/415/422` 不原样重试、`429/503` 遵守 `Retry-After`、超时不影响播放，以及应用退出后不保留后台上传任务。上线前用两个独立客户端和真实新发行包核对 HTTPS 调用；现有发布包不会自动具备这些功能。

## 8. 共享频道初始化闭环

Windows 与 macOS 的共享频道接口与旧版 `/api/v1/sources` 独立。

- `GET /api/v1/channel-catalog/manifest` 返回已分类清单版本、频道数、线路数、快照地址、压缩字节数和 SHA-256。
- `GET /api/v1/channel-catalog/snapshots/{sha256}.json.gz` 下载不可变快照。
- `POST /api/v1/channel-catalog/inventory` 分批上报公开频道、分类、线路和淘汰记录。正文包含 `schemaVersion: 1`、64 位十六进制 `fingerprint`、最多 200 项的 `routes`，最多 512 KiB。线路字段为 `name`、`url`、`group`、`source`、`blocked`，可选 `epgId`、`logoUrl`、Unix 秒数 `playableAt`。响应 `202` 包含 `accepted`、`skipped`、`storedRoutes`、`blockedRoutes`、`verifiedRoutes`。
- `GET /api/v1/channel-catalog/blocked` 返回 `schemaVersion: 1` 与已淘汰地址数组 `urls`。后续上报不能解除淘汰状态。

- `POST /api/v1/channel-catalog/events` 持久化同步新增、分类、线路权重、删除和淘汰事件。正文包含 `schemaVersion: 1`、`fingerprint` 和最多 200 个 `events`，上限 512 KiB。每个事件含唯一 `id`、公开 `url`、`kind`。`upsert` 含 `metadata` 与 `baseRevision`；`classify` 含 `group` 与 `baseRevision`；`health` 含 0 至 10 的正向 `success` 和负向 `failure` 次数；`delete`、`retire` 无额外字段。
- 响应 `202` 含 `schemaVersion: 1` 和 `receipts`，每项包含事件 `id`、`revision`、`status`。状态为 `applied`、`conflict`、`rejected` 或 `retry`。服务器按客户端与事件 ID 去重，分类采用版本比较保护。`retry` 保留在客户端持久队列，其他状态仅确认对应事件 ID。旧版清单上报不会覆盖手工分类。
- 客户端每 15 秒分批上报变更，每分钟检查共享清单版本。修改、权重和删除在后台发布，不等待慢线路验证；新增线路仍需服务器验证。快照线路可包含 `revision`，共享 `healthScore` 参与线路排序。空清单和失去最后线路的分类都能同步移除。界面显示同步过程，网络失败不阻塞本地修改。

服务器定时验证候选媒体并原子发布清单。客户端采用内置小型启动清单，后台下载网站清单及验证记录，按分类直接展示，通过本地检查继续更新可用性。线路上报采用分页与成功检查点，失败自动重试。全局淘汰记录应用到所有来源。频道清单不会夹带收藏、观看历史或私人源认证数据。详细快照结构与验收流程见 `docs/channel-catalog-sync.md`。
