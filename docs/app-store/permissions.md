# 权限与网络例外说明

- Face ID：用户登录后自行开启账号生物验证时调用，用于本机账号解锁。Touch ID 使用同一系统验证路径。不上传模板。
- Speech Recognition：用户主动开启设备字幕对齐时使用节目解码音频，不申请麦克风录音；当前文案说明设备处理，须验证原生请求确实要求设备识别并处理模型缺失。
- Background audio：现有 Info.plist 声明 audio，用于用户媒体播放。不能拿静音模拟器构建当作正常后台声音测试通过。
- Local Network：现有 Debug 包的提示与 Bonjour 服务来自 Flutter 调试，正式 Release 中须重新检查，不能把 Debug 产物直接上传。若正式投屏发现确实使用局域网，需另行提供准确用途说明及必要 Bonjour 配置。
- ATS：当前源 Info.plist 全局 `NSAllowsArbitraryLoads=true`。用户媒体来源可能使用 HTTP，但应按最终网络用途核实并准备范围准确的说明，不能宣称本版本只允许 HTTPS。账号服务使用 HTTPS。
- 本次未改动 Info.plist 或签名能力。最终权限制表、隐私报告、二进制和审核说明必须一致。
