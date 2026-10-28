# 国家首字母导航验收

源版本为 `1.1.16+111`，基线 `6e7e143`，本次候选文件摘要见 [candidate.json](candidate.json)。本地 Chromium 浏览器宿主复制生产 `CompactCategoryRow`、`CountryNameIndex`、`CountryNames`，复制后逐文件 SHA256 一致。宿主使用完整国家名称表和本地选择/置顶回调，无生产频道或服务器写入。截图为实际 Flutter Web 渲染，DPR 1。

## 功能与响应式

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| M 分组、美国选择、Y 分组、英国选择 | PASS | desktop-m.png；浏览器实际选择后宿主当前国家更新 |
| United States 搜索、清除、无结果、重开复位 | PASS | desktop-search.png、desktop-empty.png；组件回归 |
| 筛选后右键置顶与 Esc 关闭 | PASS | 浏览器回调显示“置顶：美国”；Esc 退回宿主；长按由组件回归验证 |
| 1280×800、390×844、320×700 | PASS | desktop-all.png、mobile-all.png、narrow-all.png |
| 320×360、1.8倍字体、长名称与末尾字母 | PASS | short-large-all.png、short-large-long.png、short-large-last.png；横向滚动后 Z 可筛选，长名称可换行点击 |
| 软键盘与最短窗口组合 | 组件回归 | country_navigation_test.dart 的 viewInsets.bottom=180/300 场景；桌面浏览器未模拟真实手机输入法 |
| 控制台与网络 | PASS | 控制台 error/warn 为0；最终61个网络事件无失败与 HTTP >=400，browser-network.json |
| 布局切换中的输入焦点 | PASS | browser-focus.json：320×420→320×240→320×420，焦点/光标持续，输入“美国”后能直接改为“英国” |

## 几何和视觉

先检查实际整体图，再检查原尺寸裁图 `desktop-menu.png`、`mobile-menu.png`、`long-name-detail.png`。四边和四角完整；标题与关闭按钮位置稳定；搜索、字母、计数和结果形成连续栅格。选中字母和当前国家颜色明确；长名称换行后仍可点击。

最终239项完整可见控件/文本测量见 [pixel-measurements.json](pixel-measurements.json)。字形取自截图前景像素，背景可用内框与热区单独记录。完整按钮热区至少44px，相邻按钮间距最小6px，同排字形中心差最大0.5px；逐控件字形余量与中心误差通过预设预算。输入框采用实际绘制背景，因为 Flutter HTML 编辑覆盖层的 DOM 框包含额外空间。滚动区边界处的部分可见按钮不用于完整控件几何判定，完整尺寸另由组件测试断言，已实际滚动验证可达。

首轮桌面主题把 minimumSize:44 缩为36px，首轮几何判为 FAIL。修正标准密度后重建，并重新采集此目录全部最终图片；验收阈值没有调整。后续测量排除了浏览器语义树裁切后的局部按钮框，避免把滚动裁切框当成整个背景。

Gemini 3.1 Pro High 两次最小图片请求返回 upstream_error。随后 Gemini 3.8 Flash High 最小图片验证成功，独立截图复核原文见 [gemini-review.txt](gemini-review.txt)：桌面和手机常规状态判合格，对短窗口提出疑点。主 Agent 逐项复核如下：

| 外部疑点 | 主 Agent 核验 |
| --- | --- |
| “全部”下灰色残条 | 为横向滚动条；实际向右滚动可见 T/W/X/Y/Z，见 short-large-last.png。该控件在短窗口明确承担导航功能。 |
| 搜索框和提示缺失 | short-large-long.png 已向下滚动；同候选初始状态 short-large-all.png 显示完整搜索与提示。整体滚动是短窗口的预设行为。 |
| 全部却只有1项 | 当前字母筛选为全部，名称搜索限定为“圣文森特和格林纳丁斯”，两条件同时成立；移动搜索前后状态及实际点击结果已核验。 |
| 关闭图标较小 | 图标保持标准20px，独立44×44点击区域；字体放大只改变文字，测量和实际关闭操作通过。 |

几何 PASS 与主 Agent 视觉 PASS 分开成立。外部疑点未被直接作为通过依据。

## 交付边界

本批新增有限国家字首元数据、国家专用索引菜单及其回归测试。无新运行库、数据库 migration、后台数据或发布配置变更。生产 ChannelsScreen 的国家行接线已代码审查，实际 UI 运行证据来自同源码组件宿主。未重新构建或安装 macOS/Windows/Android 桌面包，未执行七平台正式发布门禁，当前结果仅用于本地源码交付。

收尾限制：自动审批策略阻止了删除任务内临时宿主和Flutter缓存，返回 `blocked by policy`；临时服务已关闭，文件保留且排除在提交之外，清理项未完成。

完整 Flutter 测试与分析的命令、退出码见 [checks.json](checks.json)，候选检查前后摘要见 [candidate.json](candidate.json)。

正式候选统一检查完成：871通过、23跳过；完整分析退出0、0 error、22 warning、181 info。本次菜单、索引及新测试无finding。此前两轮全量分别通过870与871项，后续焦点反例使相关验收失效，前两轮身份保存在 before-focus-fix 和 before-web-focus-fix 记录。最终候选采用固定编辑器祖先及固定 ClampingScrollPhysics，并在正式全量前通过浏览器连续输入复测；每次额外全量均绑定到相关失败及修改后的输入，未重复执行相同候选。

Gemini视觉建议来自最终焦点修复前的同款布局；后续修复仅稳定父级和语义角色，没有改变控件尺寸、文案、颜色或栅格。因此不重复调用外部视觉模型。最终候选的全部截图与239项像素测量已重新采集并由主 Agent 检查。

复现组件宿主：用当前 Flutter SDK 创建临时 web 项目，将 `preview-main.dart.txt` 内容保存为该项目的 `lib/main.dart`，按 `preview-source-hashes.json` 所列相对路径复制本仓库三个生产文件，执行 `flutter build web --no-web-resources-cdn --no-wasm-dry-run` 并在本地服务目录打开。`?scale=1.8` 为本地字体缩放夹具。`measure_pixels.py` 从仓库根目录运行，使用 Pillow 读取已经保存的截图与浏览器控件边界；不会操纵浏览器。
