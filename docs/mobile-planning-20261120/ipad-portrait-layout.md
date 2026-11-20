# iPad 竖屏布局更正

日期：2026-11-20，日本时间。

按用户补充要求，iPad 竖屏使用上方播放器、下方频道的结构；横屏宽窗口保留左侧播放器、右侧频道。Android Pad 使用相同规则。手机继续使用已有频道抽屉。桌面竖向窗口的既有双栏规则保留。

## 实现

通过平板触控平台与完整窗口方向共同判断布局，避免顶部工具栏扣除高度后把竖屏误判为横屏。竖屏播放器铺满内容宽度，按视频比例和频道说明预留高度，并限制在可用高度的约一半；下方频道网格独立滚动。

共享内容区改为稳定的 Flex 树，切换轴向时保留播放器和频道组件的状态。新增 iOS 与 Android 平板旋转组件测试，验证上下和左右位置，同时检查播放器 State 没有重建。桌面竖向窗口仍验证左右布局。原有紧凑频道测试同步更新平板竖屏的几何断言。

## 验证

- 本机 Intel Mac，Xcode 26.3、官方 iOS 26.2 模拟器，iPad Pro 11-inch M4。
- 完整 Debug 应用编译运行成功。最终热重载显示 0 个库变化，运行包已包含本轮最终逻辑。
- 实际截图确认播放器在上、分类和频道在下。真实 CCTV-1 播放，原生解码尺寸 1280×720，`playing=true`、`muted=true`，播放时间继续前进。另通过界面静音按钮将音量设为 0。
- `tablet_orientation_layout_test`、`tablet_presentation_test`、`compact_channel_layout_test`、`mobile_channel_home_test` 共 109 项通过，1 项原有本地视觉测试跳过。
- 本轮修改的布局、策略及新测试静态分析无问题。
- 横屏布局和旋转时播放器 State 保持由组件测试验证；本轮未新增 iPad 物理横屏旋转或 Android 原生设备结论。

证据目录：`/Users/shou/Documents/Codex/2026-07-18/git/outputs/ipad-portrait-layout-20261120`。

最终截图 `ipad-portrait-stacked.png` 为 CoreSimulator 原始系统截图。`playback-verification.json` 记录两次原生播放采样；测试、分析和 iOS 运行日志保存在同目录。此次为本地开发验证，未发布。
