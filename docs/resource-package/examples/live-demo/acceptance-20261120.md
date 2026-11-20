# 直播范例验收

2026-11-20。本地开发版本，未上架或发布生产直播服务。

## HLS 主范例

2 分类、3 频道、3 条 HLS 直播线路。两路为明确采用 CC BY 3.0 授权的 Blender 预告片轮播，一路为实时生成的原创测试信号。原始输入的 URL、体积、SHA-256 和改动说明保存于服务器生成的 `provenance.json`。许可和署名见同目录 README、NOTICE 与 licenses。

- HLS 主清单声明 H.264 Constrained Baseline / AAC、640×360、24 fps；下级媒体清单每 3 秒更新，窗口为 6 段。
- 三路均验证媒体序号前进、分片列表变化、新 TS 分片可下载，没有 ENDLIST 或 VOD 标记。
- 三路输入均解码出视频帧。字幕匹配和对齐没有计入本次成功项。
- iPhone 与 iPad 官方 iOS 26.2 模拟器均通过 `.bobtv` 地址导入，得到 3 张卡片、3 个台标、3 个演示 EPG 频道与绑定。
- iPhone 完成实时测试信号与 Big Buck Bunny HLS 轮播播放；iPad 完成 Big Buck Bunny HLS 轮播播放。检查 native mute 为 yes、画面尺寸为 640×360、播放时间持续前进，并截图存证。
- 静音 QA 使用空音频输出并清空响度滤镜，避免 Intel 模拟器音频设备初始化失败。正常音频输出、真机与字幕识别不在本轮通过范围内。

## 直播轨道兼容修复

实测发现 iOS 在部分直播清单上能识别 H.264 视频轨道，却持续保持未选中状态。沿用原有视频检查时机，在自动选择失败、只有一个有效视频轨道时显式选择该轨道。多个节目或视频轨道保持原逻辑，广播纯音频路径保持原逻辑。

修复后重新验证 HLS 出画。相关资源包、频道播放绑定、播放按钮和视频就绪策略共 32 项测试通过；本地 iOS 模拟器开发构建成功。

## 公共 DASH 参考

DASH-IF 三路公开测试源的动态 MPD、当前实时媒体分片和分片解码均已核对，官方内容仓库采用 Apache-2.0，原文随参考包保存。

当前 iOS 模拟器构建在空数据库冷启动播放时返回 `Failed to recognize file format`，没有视频轨道或画面。因此 `public-dash-reference.bobtv` 仅作格式参考，不能用作已通过的 iPhone 审核范例。之前切台时保留旧画面得到的观察已剔除，不作为公共 DASH 播放成功证据。

## 交付与边界

HLS 范例的默认地址是本机 `http://127.0.0.1:18767/demo.bobtv`。服务器包包括输入素材、推流脚本、校验脚本、数据包和许可说明；通过实际 HTTPS 域名部署后才能供外部审核员访问。目前没有声称已有公网 HLS 地址。

推流脚本在服务器运行，BobTV 只导入 JSON 数据及读取媒体资源。工作目录里的静态 `.m3u8` 快照停止更新后不能作为直播服务，运行服务器程序才会持续生成分片。

模拟器原数据库均已备份并恢复。验收证据位于：

`/Users/shou/Documents/Codex/2026-07-18/git/outputs/open-live-demo-20261120/`

其中 `hls-window-check.json` 是直播窗口校验，`movie-iphone-states.json`、`movie-ipad-states.json` 是独立 HLS 播放记录；公开 DASH 的独立失败记录为 `public-iphone-states.json`。截图分别为 `movie-hls-playing.png`、`ipad-hls-playing.png`。
