# 流式直播范例

2026-11-20。范例线路指向动态 HLS 或动态 DASH 播放清单，不包含 MP4 点播地址。影片素材用作直播轮播，测试信号实时生成，均不代表现场摄像头直播。

## HLS 范例

`local-hls.bobtv` 包含 2 个分类、3 个频道、3 条 HLS 直播线路、3 个原创几何台标和一份演示 XMLTV 节目表：

| 频道 | 内容与授权 |
| --- | --- |
| 开放动画直播 · Big Buck Bunny | Blender 开放影片预告片，CC BY 3.0，原素材不裁剪，连续轮播并烧录署名 |
| 开放动画直播 · Sintel | Blender 开放影片预告片，CC BY 3.0，原素材不裁剪，连续轮播并烧录署名 |
| BobTV 实时测试信号 | FFmpeg 实时生成动态测试图和测试音，范例原创输出及几何台标以 CC0 提供 |

每 3 秒生成一段 H.264/AAC MPEG-TS，窗口保留 6 段；媒体序号持续前进，旧分片滚动移除，没有 `EXT-X-ENDLIST` 和 VOD 标记。直播时间不会因新观众打开而重置。节目表明确标注为演示编排，不冒充电视机构节目单。

影片画面底部持续显示作品、作者、许可网址、来源和改动说明，服务器同时提供 `CREDITS.html`。不使用 Blender、W3C 或电视机构的商标作为台标，不宣称获得其背书。

### 本机运行

需要 Python 3.9+、带 libx264/AAC/drawtext 的 FFmpeg，以及本机已有 TrueType 字体。默认只监听回环地址，不自动修改防火墙、反向代理或生产网站。

```sh
python3 tools/live_demo/serve.py --work-dir /tmp/bobtv-live-demo --ffmpeg /path/to/ffmpeg
```

运行后，导入地址为 `http://127.0.0.1:18767/demo.bobtv`，用于本机或 iOS 模拟器。该地址没有被描述为公网服务；新安装的 BobTV 仍由用户主动导入。

服务器下载两个约 11 MB / 4.4 MB 的开放影片预告片作为转码输入，按已核对的 SHA-256 校验，持续生成直播清单。客户端连接 `.m3u8`，不读取这些输入文件。进程退出时同时关闭所属编码器。没有使用 Unified Streaming 等商业推流软件。

### 生成服务器地址的数据包

部署时将 `--public-base` 设置为实际 HTTPS 地址，例如 `https://review.example.org/bobtv-live`；`--bind` 和 `--port` 控制监听。工具在指定工作目录生成包含完整绝对地址的 `demo.bobtv`、台标、署名、节目表接口和 HLS 路径。使用反向代理将该前缀映射到本服务。域名是占位示例，需要实际配置后才可供外部审核员访问。

### 验证直播窗口

```sh
python3 tools/live_demo/verify.py http://127.0.0.1:18767/demo.bobtv
```

工具间隔 7 秒检查窗口推进，拒绝已结束或 VOD 清单，并验证新分片可访问且是 MPEG-TS。数据包本身还应通过 `tools/validate_resource_package.dart`。

## 公共 DASH 直播测试源

`public-dash-reference.bobtv` 引用 DASH-IF livesim2 官方公开服务的 `testpic_2s`、`testpic_6s`、`testpic4_8s` 三组动态直播测试信号。它们用于直播缓冲、分片和码率测试，具有动态 MPD 与随时钟变化的可用分片，不是现场摄像直播。

[官方内容仓库](https://github.com/Dash-Industry-Forum/livesim-content) 将这些测试素材列为 livesim2 在线服务的数据；仓库采用 Apache-2.0 许可，副本见 `licenses/Apache-2.0.txt`，署名和来源见 `NOTICE.txt`。仅引用原始服务，不将该服务或其标识作为 BobTV 品牌。

这些地址由第三方维护，不提供永久可用性承诺。2026-11-20 已核对三路实时分片并解码出画；当前 iOS 模拟器构建的解码库在独立冷启动测试中返回 `Failed to recognize file format`，本包仅作 DASH 协议参考，不作为已通过的 iPhone 审核示例。iPhone 验收使用上面的 HLS 包。HLS 范例和公共 DASH 范例分别记录播放验证结果，不能用 HTTP 200 代替解码或 BobTV 播放成功。

## 授权证据

- [Big Buck Bunny 官方许可声明](https://peach.blender.org/about/)：CC BY 3.0，允许按署名条件再利用和传播；完整影片播放需保留完整片尾。本例使用官方开放素材的预告片镜像，额外持续烧录署名。
- [Sintel 官方许可声明](https://durian.blender.org/sharing/)：CC BY 3.0，原电影作品和项目素材的许可与署名要求。
- [CC BY 3.0 条款](https://creativecommons.org/licenses/by/3.0/)：按条件署名、许可链接与改动说明，不附加妨碍许可权利的技术限制。
- [官方预告片页面](https://peach.blender.org/trailer-page/)和 [Sintel 官方下载页](https://durian.blender.org/download/)可核对预告片所属项目；下载镜像为 W3C `media.w3.org`。输入文件精确 URL、体积与哈希由服务写入 `provenance.json`。

素材属于开放授权作品，仍有版权和许可条件。范例不使用未授权电视线路，不将公开可访问直接视为取得授权。
