# iOS 模拟器与真实台标验证

日期：2026-11-20，日本时间。此文补充第一阶段报告中的 iOS 环境缺失状态。

后续布局更正：iPad 竖屏已改为上方播放器、下方频道，最新截图与验证见 [iPad 竖屏布局更正](ipad-portrait-layout.md)。本文旧 iPad 分栏截图保留作为历史证据。

## 环境

Intel Mac，Xcode 26.3，iOS 26.2 SDK 23C57。通过 Xcode 官方 `xcodebuild -downloadPlatform iOS -buildVersion 26.2 -architectureVariant universal` 安装 iOS 26.2 universal Simulator Runtime 23C54，支持本机 x86_64。已完成 dyld 共享缓存生成。

使用 CoreSimulator 官方命令创建 iPhone 17 Pro 与 iPad Pro 11-inch M4 设备。SDK 默认映射指向未安装的 23C57 运行时，因此使用官方 `simctl runtime match set iphoneos26.2 23C54 --sdkBuild 23C57` 指定已安装运行时。映射前后记录位于证据目录。恢复默认命令：`xcrun simctl runtime match set iphoneos26.2 --default --sdkBuild 23C57`。

模拟器窗口自动控制接口返回 `cgWindowNotFound`。设备后台可正常启动、运行应用与导出系统截图。应用操作采用 Flutter SDK 自带的 Driver，入口独立保存在 `tools/diagnostics/mobile_app_driver.dart`，常规入口不启用测试驱动。截图通过 `simctl io screenshot` 保存。

## UI 变更

手机频道卡片复用 Windows 版 `channelCardDecoration`，使用 20 点圆角、色彩渐变、轻边框与选中描边。频道最多两列，保留真实台标比例，卡片背景使用低透明度模糊台标。深浅台标通过像素亮度检测选择承托底色，透明白色台标不会淹没在浅色底板中。台标失败时保留频道名称与文字缩写。

真实应用由现有目录同步导入频道与台标。另存一份仅含名称与台标元数据的目录样本，以及 CCTV、NHK、France 2、Arirang 等真实图片，供可重复的外观检查。部分远端台标返回 502，已记录，不能将所有频道的台标加载视为成功。

修复完整 iPhone 应用首次同步期间顶部工具栏横向溢出。手机启动工具栏保留品牌、可截断状态和语言入口。

## 静音方式

仅当 Debug 构建显式传入 `BOBTV_QA_SILENT=true` 时，原生主播放器和候选播放器强制开启 mute。读取原生播放属性验证静音，避免仅凭界面音量图标作判断。普通构建与 Release 构建保持原有音量行为。

## 证据

目录：`/Users/shou/Documents/Codex/2026-07-18/git/outputs/ios-simulator-logo-20261120`。

以下列出设备实测与最终截图。

## 实测结果

完整 iOS Debug 应用编译与运行成功。实际应用接入现有网站目录，本机 iPhone 数据库已导入超过一万条频道线路记录；这包含同一频道的多条线路，不代表独立频道总数。

- iPhone：实际验证竖屏底部抽屉、横屏右侧抽屉、两列频道、真实台标、来源与分类筛选。停止播放后重新选择当前频道，准备完成后抽屉收起。修复同一频道停止或失败后被提前收起、无法重试的问题。
- iPhone：原生采样均为 1280×720、`playing=true`、`muted=true`。播放进度依次为 897、37057、79897 毫秒；切换“北京”分类后仍保持 CCTV-1 播放，随后恢复“央视”并旋转横屏，频道身份保持一致。
- iPad：真实 CCTV-1 画面正常，保持左播放器与右频道分栏；原生采样为 1280×720，进度从 2947 增至 55867 毫秒，两次均 `playing=true`、`muted=true`。本轮 iPad 截图为竖屏，调用方向偏好没有形成物理横屏旋转证据，不能据此宣称 iPad 横屏已验收。
- 11 项手机组件与台标对比度测试通过，包含新增的“停止的当前频道可以重试”测试。此前平板与全屏等回归为 110 项通过，1 项原有本地视觉测试跳过。新增组件、主入口和测试驱动共 5 个分析目标无问题；大频道页仍有 41 项既有诊断，未宣称整个仓库分析无问题。

完整应用实测暴露了首次播放状态与视频纹理挂载的时序问题。冷启动只以当前线路身份确定已接入，再等待原生首帧确认就绪；增加播放状态订阅，播放按钮随原生状态更新。未准备好的选择保持抽屉，首帧等待上限 30 秒。

## 最终证据清单

- `simulator-review.png`：实际截图缩放排版总览。
- `iphone-final-portrait-channels.png`：真实台标与底部频道抽屉，暂停和静音图标与播放状态对应。
- `iphone-final-portrait-filter.png`：分类“北京”的筛选草稿。
- `iphone-final-landscape-channels.png`：右侧两列频道抽屉。
- `iphone-final-landscape-filter.png`：右侧筛选。
- `iphone-final-portrait-playback.png`：停止后重新选台、抽屉收起后的播放。
- `ipad-portrait-playback.png`：iPad 分栏与真实节目播放。
- `playback-verification.json`：上述五次原生状态采样及播放进度。
- `final-mobile-tests.log`、`final-focused-analysis.log`：最终测试和分析。
- `source-sha256.json`：工作区变更文件校验。

横屏 iPhone 的系统截图保存为设备原始朝向，另存仅旋转 270 度的阅读副本；原始 `*-raw.png` 同时保留。iPad 使用原始系统截图。总览仅缩放和排列，没有替换应用内画面。

## 范围与已知限制

所有构建和安装均限本机官方模拟器，没有发布、上传商店或替换桌面版。QA 驱动属于独立开发入口，常规主入口不启用。Debug 原生播放器正在播放时，Flutter Hot Restart 曾触发原生 Dart 回调崩溃，记录保存在迭代日志；随后采用完整进程退出与重新启动完成复测，普通 Hot Reload 正常。该开发工具重启场景仍需单独处理，不能声称模拟器所有生命周期场景均通过。

本轮没有移动真机、长时间播放、后台恢复、iPad 物理旋转与分屏模式的完整验收。部分台标远端错误仍会触发缩写回退，最终央视截图中的台标已实际加载。
