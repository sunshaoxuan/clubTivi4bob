# iOS 原生媒体适配

本轮为本地开发，未发布、未提交 App Store。iPhone 与 iPad 共用原生桥接，保留现有手机抽屉和平板方向布局。

## 实现

* AirPlay：触控投屏入口打开 `AVPlayerViewController`，使用系统路由选择与外部播放。包含任意 HTTP 请求头的线路使用现有资源转发入口，未使用私有 AVURLAsset 请求头选项。
* 画中画：按 `AVPictureInPictureController.isPictureInPictureSupported()` 检查设备能力。支持时进入系统播放器，再由用户操作系统画中画按钮。支持后台播放和恢复系统播放界面；不支持的设备显示提示。
* 播放交接：先记住本地静音状态，暂停并静音 media_kit。原生期间抑制主播放器自动重开和意外恢复播放，结束后还原静音状态。原生会话关闭或失败后恢复原频道；直播重新打开当前线路，点播恢复时间位置。正常切台、预览提升和停止操作撤销旧会话所有权，关闭系统播放器。原生播放期间暂停自动换线；在后台结束会话时等应用回到前台再恢复原播放器。
* 设备端识别：仅用户点击字幕菜单中的入口后申请 Speech 权限。`SFSpeechAudioBufferRecognitionRequest.requiresOnDeviceRecognition` 固定为 `true`，并检查授权、语言和 `supportsOnDeviceRecognition`。输入来自节目解码的 16 kHz 单声道 Int16 PCM，不使用麦克风。
* 识别语言优先使用音轨元数据。音轨未标注时使用系统语言，不宣称具备自动语言识别。能力和语言支持探测放在后台队列；未授权时不创建语音识别器，普通播放不等待模型探测。单次输入最多 40 秒，40 秒截止，取消和切台后的结果不再回写。iOS 与 Android 使用相同的移动端 PCM 保留、缓冲预算和 HLS 清晰度余量策略。
* 时间轴：把原有本地流复制算法移入 C++ 线程，使用随机路径的回环 HTTP 输出和中断回调。保留已有 discontinuity、流变化和包修复事件，不在 iOS 启动子进程。
* 依赖：构建时从 FFmpeg 官方下载固定 SHA-256 的 6.0 源码，编译同 ABI 的 Avfilter 与 Avformat，补充 `bobtv_pcm`、音量规范化和 MPEG-TS 输出。仅替换应用构建目录中的框架，不修改 CocoaPods 或依赖缓存。保留其余解码库，随应用放入 LGPL 声明、源代码归档和构建脚本。
* 运行时代码与功能均随应用编译打包，没有动态下载执行代码或隐藏功能。

系统播放器使用媒体自身提供的字幕。Flutter 字幕绘制层和服务端候选版本目前没有注入系统画中画或 AirPlay，不能宣称这些字幕已经完成原生同步。

当前音频时间轴辅助链路已经覆盖 MPEG-TS 分片的 HLS。MP4/部分 fMP4 转 TS 还依赖现有 iOS 解码库未包含的 bitstream filter，失败时退回原始播放源，不能把这类流的离线字幕对齐算作完成。Apple 系统播放器直接播放 MP4 不经过这条辅助链路。

`supportsOnDeviceRecognition` 表示 API 支持，不能单独证明语言模型已经可用。模型缺失或识别失败保留已有字幕和视频播放，不改用在线识别。

## 静音与验证边界

Debug 包以 `BOBTV_QA_SILENT=true` 构建。Swift Debug 编译条件同时启用，原生播放器将 `isMuted=true`、`volume=0`，Flutter 播放器使用已有静音开关。模拟器音频设备无法初始化时，专用 QA 入口可以将 mpv 输出改为 `null`，仍解码音轨用于采样。这个设置不属于普通应用入口。

测试视频由本机 AVAssetWriter 生成，包含自制颜色动画及合成音频。测试语音使用已有自制 PCM 样本。官方 XCTest 用于系统权限弹窗和原生控件，Flutter 官方驱动用于播放状态与应用操作，simctl 用于安装和截图。

证据目录：`/Users/shou/Documents/Codex/2026-07-18/git/outputs/mobile-native-features-20261120`。

最终验证结果及仍待真机检查的项目记录在该目录的 `acceptance.md`。同一台 Intel Mac 上，iPhone 模拟器返回画中画能力为 false，iPad 模拟器返回 true。iPad 已实际启动画中画并留存状态与截图。没有连接 AirPlay 接收设备，不把系统界面或按钮出现视为电视投屏成功。

## Apple 官方接口依据

* https://developer.apple.com/documentation/avkit/avplayerviewcontroller
* https://developer.apple.com/documentation/AVKit/AVPictureInPictureController
* https://developer.apple.com/documentation/Speech/SFSpeechRecognizer/supportsOnDeviceRecognition
* https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
* https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition
