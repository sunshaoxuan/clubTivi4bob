# BobTV 可选账号服务

## 已实现的范围

全平台 Flutter 客户端共用一个账号服务。首页顶端显示注册与登录入口，手机横屏播放器采用账号图标。邮箱验证码同时完成注册与登录，不设置密码。Google 登录接受 Gmail 与 Google Workspace 的已验证邮箱，Apple 使用 Sign in with Apple。电视可以在手机上扫描一次性授权二维码完成登录。当前播放、播放源导入和频道功能均可在未登录时使用，没有充值或收费入口。

服务端在现有 FastAPI 网站中注册 `/api/v1/account/`，通过稳定的用户 ID 为后续服务提供身份。会话最长三十天，数据库只存会话令牌的 SHA-256 摘要。验证码十分钟有效，单个验证码最多五次尝试，每邮箱每分钟一次、每小时五封，每 IP 每小时十五封，总发信预算每小时一百二十封。一次性验证码在登录时原子消费。禁用、改邮箱或修改验证状态会撤销现有会话；受保护的后续接口必须调用服务端 `accounts.current(request)`，权限校验不能依赖客户端开关。

管理员页面位于主站 `/admin`，没有加入导航或站点地图。它提供验证码或已配置第三方登录、用户搜索和分页、手工创建、编辑名称与邮箱、设置验证状态及禁用。管理员邮箱固定为 `sunsx@outlook.com` 与 `sunshaoxuan@gmail.com`，只有通过邮箱身份验证的未禁用账号才有权限。首次使用时自行验证邮箱，服务端创建对应账号。管理员不能通过当前会话撤销自己的管理权限。第三方身份已绑定的账号不能由后台改邮箱，以免原身份继承另一个人的邮箱。管理操作记录审计，不记录验证码或令牌。隐藏入口对鉴权没有替代作用。

## 第三方身份流程

使用系统浏览器和服务端授权码交换，各个平台不内置 OAuth client secret。Google 采用 PKCE，服务端校验 ID token 的签名、issuer、audience、有效期及 nonce。提供方的 `sub` 为绑定身份的稳定标识。完成身份验证后，已验证的同邮箱账号可合并使用；Apple 隐藏邮箱会形成独立账号，不猜测真实邮箱。非 Gmail / Workspace 的 Google 邮箱需改用邮箱验证码证明当前邮箱所有权。

客户端以随机 proof 的 SHA-256 摘要申请一次性 ticket，实际 proof 留在客户端；授权后轮询领取会话需要原始 proof，ticket 五分钟过期且只能领取一次。网页管理登录使用 Secure、HttpOnly、SameSite=Lax Cookie，所有通过 Cookie 执行的写操作检查同源 Origin。应用使用 Bearer，禁止跟随重定向。账号和管理员接口不走公共资源镜像，凭据只发送到主站身份服务。

Apple refresh token 使用服务器独立密钥加密存储，用于用户删除账号时调用 Apple revoke API。删除需要十分钟内的新登录；撤销失败保留账号并允许重试。用户可在应用账号页面删除账号及会话，设备播放源保留。数据备份的有限保留在隐私页面披露。

## 手机生物验证

仅在登录后提供开关。使用系统 `local_auth`，iOS 根据设备选择 Face ID 或 Touch ID，Android 使用系统支持且已录入的生物验证。打开和关闭均需通过本机生物验证；未录入时提示前往系统设置。进入后台后清除内存中的会话访问状态，再访问账号需先完成本机验证，并向服务端检查会话。取消验证不会解锁，服务器已撤销的会话会清除本机状态。账号锁定不阻止播放。

凭据存入系统安全存储，生物模板不进入 BobTV。iOS 使用 Keychain，Android 使用 KeyStore 加密存储，桌面使用平台安全存储。macOS 使用加密的传统登录钥匙串，以兼容现有 Developer ID 签名流程；没有新增需要分发 provisioning profile 的 macOS Keychain Sharing 权限。开关针对本设备，恢复邮箱登录可用于未录入或无法使用生物验证的设备。此功能提供应用内账号解锁，不替代服务端身份与未来支付操作的验证。

## 服务配置

生产读取 `/etc/bobtv/accounts.json`，可用 `BOBTV_ACCOUNTS_CONFIG` 指定。root 管理，bobtv 组只读，权限 0640。该文件不进入 Git、应用安装包或公开目录。

字段：

| 字段 | 用途 |
| --- | --- |
| `secret` | 至少三十二字符的独立随机密钥，用于验证码 HMAC 与 Apple token 加密；需安全备份，不能随意轮换 |
| `origin` | `https://bobtv.briconbric.com` |
| `smtp_host`, `smtp_port` | `mail.briconbric.com`，465，隐式 TLS，验证证书，无明文降级 |
| `smtp_user`, `smtp_from` | `postmaster@bobuy.cc` |
| `smtp_password` | 邮箱 SMTP 凭据 |
| `google_client_id`, `google_client_secret` | Google Web OAuth 应用 |
| `apple_client_id` | 关联 iOS App ID 的 Apple Services ID |
| `apple_team_id`, `apple_key_id`, `apple_private_key` | Sign in with Apple 开发者配置与 P8 私钥内容 |

Google 授权回调：`https://bobtv.briconbric.com/api/v1/account/oauth/google/callback`。
Apple return URL：`https://bobtv.briconbric.com/api/v1/account/oauth/apple/callback`，接收 `form_post`。
Apple 开发者后台需正确配置 Services ID、主 App ID、域名与 return URL，并为隐藏邮箱的邮件转发注册发信地址。Google 应配置同意页面、授权域名、回调以及发布状态；测试模式只能供许可的测试账号使用。这些提供方配置不能由客户端代码代替。配置缺失时 API 明确报告不可用，客户端禁用对应按钮。

`tools/deploy_accounts.py` 使用现有 SSH 部署通道，仅更新账号模块、路由注册与账号隐私段落，保留原站点其他内容。默认从本机 `~/.config/bobtv/accounts-secrets.json` 通过 stdin 传送配置，不打印密码。部署有受限备份、导入检查、服务健康检查与失败回滚。应用构建为本地调试验证，不属于正式七平台发版。

## 存储和维护

`BOBTV_DATA_DIR/accounts.sqlite3` 包含用户、身份、会话摘要、验证码 HMAC、限流和管理审计。数据库权限 0600。每日 `bobtv-accounts-maintenance.timer` 清理过期数据并生成私有 SQLite 一致性备份，备份目录 0700、文件 0600，按三十天策略清理；管理审计按一百八十天策略清理。原有长期公共服务备份跳过此数据库，避免账号信息无限期复制。备份恢复要保留对应加密密钥，恢复后应撤销旧会话以防恢复已删除的会话。

## 验收边界

- 单元与服务测试覆盖 OTP、会话撤销、权限、CSRF、签名与 nonce、OAuth ticket、Apple 撤销失败及生物验证状态。
- 管理页面浏览器测试使用独立临时数据库，验证码由本地测试接收器截获，没有对外发信。
- iOS 模拟器使用 Xcode 的模拟器签名与模拟器 entitlement 注入，单纯 `--no-codesign` 的构建不能用来验收钥匙串；不在手工 ad-hoc 签名中伪造开发者团队。
- 未收到 SMTP 凭据之前，不能把测试接收器的成功记作真实邮件送达。Google / Apple 缺少正式应用配置时，不能把签名测试记作真实提供方登录成功。
- 生物验证取消和状态机的自动测试不能证明实体设备的 Face ID、Touch ID 或安卓传感器成功。真机录入、成功、失败、取消、重启与后台返回仍需验证。

官方依据：

- https://developers.google.com/identity/protocols/oauth2/web-server
- https://developers.google.com/identity/gsi/web/guides/verify-google-id-token
- https://developer.apple.com/documentation/signinwithapple/verifying-a-user
- https://developer.apple.com/documentation/signinwithapple/revoke-tokens
- https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps
- https://pub.dev/packages/local_auth
