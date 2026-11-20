# 在线同步故障与本地播放

选台与主播放器、预览和暖播放器都通过同一条线路状态服务。服务器请求失败或超时时，服务记录诊断，15 秒内避免重复前台请求，继续读取本地持久缓存。HTTP 故障不会被解释为线路已淘汰，也不会清除已知淘汰记录。

本地已淘汰线路仍不能打开；服务器成功返回的淘汰状态必须先持久化。数据库故障单独报告。

2026-11-16 维护中，root 执行目录原子发布生成了服务账号不可读的文件，造成目录与线路状态接口 HTTP 500。已恢复当前清单、快照的 bobtv 归属与公开读取权限，给原子发布补充权限与归属保持。两个节点的目录与线路状态接口已重新核验为 HTTP 200。

原生静音验收使用显式 `BOBTV_TEST_MUTE=1`，在每个主、预览和暖播放器打开前设置静音，不修改用户保存的音量偏好。独立离线诊断使用内存数据库及失败的状态同步接口，验证实际原生播放器仍能播放已有 URL。

## Action Movies master-playlist fallback

With programme/subtitle discovery unavailable, the original Rakuten master
playlist reaches the native decoder. The bundled FFmpeg experimental HLS WebVTT
reader can wait indefinitely for nonempty packets from the provider's
`empty_sub.vtt` rendition, preventing audio/video initialization. For this
reviewed Action UK source, bootstrap the master once and select its highest
bandwidth reviewed same-host/service audio/video rendition. This also avoids
initially probing every bitrate. Keep caption retrieval in the independent
subtitle session. Native HLS WebVTT is unavailable
on this compatibility path; unavailable caption services yield no captions and
must still allow video. Other sources retain their original master and native track handling.
Embedded subtitles in supported audio/video streams retain the selection policy.

## Optional subtitle-media availability

The subtitle service advertises `playbackReady` only after at least 24 seconds
of normalized audio/video exist in the session. A warming or unavailable service
leaves the provider source in use. If an accepted subtitle-media stream stalls
for ten seconds while playing, clear its subtitle timeline and open the original
provider once, without another subtitle-service attempt. The owning route guard
checks durable exclusions again before and after this asynchronous fallback.
Changing channel, pausing or disposing cancels the watchdog.
