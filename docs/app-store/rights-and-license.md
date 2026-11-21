# 素材与软件许可附件

本附件记录许可来源及当前构建证据，不充当与未知频道运营方签署的合同。

## 演示视频

Big Buck Bunny 与 Sintel 预告片来自既有范例的可核查输入，许可基础为 Blender 项目的 CC BY 3.0 声明。随包 NOTICE 记录作品、来源、署名、许可链接及轮播、缩放、转码等改动。连续轮播的 HLS 属于直播式分发，画面为录制动画，不称为现场摄像直播。生成的测试信号、几何台标采用原创 CC0 示例。

公开播放不等于自动允许再分发。此附件仅用于明确记录的演示素材，不覆盖个人服务器上的其他频道、台标、EPG、字幕或节目资料。若最终版本实际提供其他目录，逐项添加相应授权材料。

## 原生媒体与开源依赖

当前模拟器 Mpv 字符串含 `-Dgpl=false`；Avformat、Avfilter 的构建证据含 LGPL 许可说明，Avcodec 默认构建还出现版本 3 配置。不能据 package 的 MIT LICENSE 概括底层全部依赖，也不能只凭这些字符串认定完整分发义务已经完成。

`technical/native-libraries.json` 保存观察到的参数与 SHA-256。正式 iOS arm64 Archive 须重新检查同一信息、动态链接、对应源码与修改、许可展示、重链接等适用义务。自有 FFmpeg 修改与源码归档须能对应实际出货二进制。

`THIRD-PARTY-NOTICES.txt` 来自现有 Flutter 包；`BOBTV-SOURCE-LICENSE.txt` 保留项目 Apache-2.0 许可。应用版权字段不能消除原始贡献者及依赖的版权说明。没有为申请商店编造独占权或第三方授权证书。

## 开发包内目录资源

早期开发包曾包含 `channel_catalog_starter.json.gz` 和 `github_ai_snapshot.json.gz`。当前 `pubspec.yaml` 已用显式清单仅声明演示数据包及 Unicode 许可，不再声明这两份旧目录资产。源代码中的历史文件保留供开发回归使用。必须从最终安装包和 iOS Archive 检查实际资产，不能只以首页未显示频道作为依据。
