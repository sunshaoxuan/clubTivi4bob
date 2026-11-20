# 手机抽屉界面第一阶段实现与验证

日期：2026-11-20，日本时间。

## 本轮实现

开发分支 `codex/mobile-channel-drawer-20261120`，基线 `881211c99f13b47dfd5c1e97c7d26303c7e02123`。独立工作区：`/Users/shou/Documents/Codex/2026-07-18/git/work/bobtv-mobile-channel-drawer-20261120`。

已把共享手机组件接入应用频道页。Android/iOS 小窗口使用手机形态，TV 和宽平板保持原有布局。手机竖屏抽屉自底部向上，横屏自右向左，开关有过渡动画；旋转保留筛选草稿和浏览状态，背景视频组件保持挂载。

频道最多两列，窄屏或大字体采用一列；频道网格纵向滚动。支持搜索、来源筛选、分类草稿和确认应用、收藏范围及会话内最近播放。分类加载错误保留筛选面板并允许重试。手机单击采用直接切台，首帧准备好后收起抽屉；失败保留列表。旧选择请求不能覆盖新选择的反馈，关闭后重新打开也不受旧完成事件影响。

本轮集中在已确认的 UI/UE 与播放衔接。空播放器的渠道隔离、固定网关依赖移除、自定义资源包解析、商店身份签名、PiP 与系统投屏等仍属于后续阶段。当前构建不能作为 App Store 提审成品。

## 自动化与编译

- 最终回归：110 项通过，1 项原有本地视觉测试跳过。包含新增手机行为测试以及平板、紧凑布局、全屏会话回归。
- 新增手机组件、原生探针与测试文件已进行静态分析。既有大频道页的存量问题与同配置下的原始源码对照，最终差异以证据目录的 `analysis-comparison.json` 为准。
- Intel Mac 主应用 Debug 构建通过；独立手机界面原生探针构建通过。没有替换已安装应用，没有上传、发布或变更官方版本号。
- 第一阶段曾因缺少 iOS 26.2 平台而无法运行。后续已安装官方运行时，完成完整 iOS 应用编译与 iPhone/iPad 静音测试，详见 [iOS 模拟器补充报告](ios-simulator-validation.md)。移动真机尚未验收。

## Mac 静音验证

运行独立应用 `BobTV Mobile QA`，使用生产手机 UI 组件、现有 PlayerService 与本地自制 AVI，无音轨；测试中请求音量为 0。探针不加载用户目录或生产服务器，证据保存在独立 outputs 目录。

原生测试依次完成：竖屏播放、底部抽屉、来源 B 与纪录片分类草稿、确认后显示 20 个源内频道、抽屉打开期间转横屏、右侧抽屉、实际单击切台及成功后收起、滚动到末尾、故障注入反馈。采样时解码尺寸为 160×96，播放时间从 0 前进到 57.8 秒，来源与分类操作没有改变当前频道；切台后播放时间重新前进，当前频道改变。未记录 Flutter 界面异常。

测试片时长为 90 秒，后半段在自然结束后才执行故障注入，最终 `playing=false` 与自然结束一致。故障注入只验证错误提示、列表保留和频道身份不被替换；不能据此宣称真实网络断流时原节目连续播放已通过。用户输入搜索已由组件测试验证，Mac 原生输入自动化没有形成独立通过结论。

## 截图与日志

证据目录：`/Users/shou/Documents/Codex/2026-07-18/git/outputs/mobile-channel-drawer-20261120`。

- `screenshot-overview.png`：实际渲染截图对照。
- `01_portrait_closed.png`：竖屏播放。
- `02_portrait_bottom_drawer.png`：底部频道抽屉。
- `03_portrait_filter.png`：分类及来源筛选。
- `04_portrait_filtered.png`：应用筛选后的列表。
- `05_landscape_right_drawer.png`：横屏右侧频道抽屉。
- `06_landscape_after_switch.png`：单击切台并收起抽屉。
- `07_landscape_failure.png`：注入失败反馈。
- `events.jsonl`、`native-status-final.json`：事件与最终状态，事件时间为 UTC。
- `tests.log`、`analysis.log`、`analysis-baseline.log`、`analysis-comparison.json`：自动化和静态分析证据。
- `macos-main-build.log`、`macos-probe-build.log`、`ios-simulator-build.log`：构建证据。
- `source-sha256.json`：最终源码校验值。

截图由运行中的 Flutter RepaintBoundary 捕获，包含原生视频纹理，并经本机窗口截图交叉观察。它们属于 Intel Mac 上的共享组件验证，不能替代 iOS/Android 设备截图。

## 后续工作

优先补齐 Apple 官方平台与模拟器运行时，再验证 iPhone 和 iPad。随后完成手机播放状态订阅、沉浸控制层、来源管理与空播放器启动流程，细化地区和频道类别的筛选衔接，补齐会话外最近播放与语言文案。移动系统生命周期、键盘、手势、安全区域、真实源切换失败和长时间播放需分别验收。
