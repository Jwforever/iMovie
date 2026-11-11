# 当前验证状态

## 0.4.0 回归（当前交付）

检查日期：2026-11-11，亚洲 / 上海。当前候选构建 [GitHub Actions 42974513926](https://github.com/Jwforever/iMovie/actions/runs/42974513926)，应用代码提交 `ba2bd1ff7c747908a486d150f8214b27172bcb85`，Xcode 16.4 / iOS SDK 18.5。前轮 `42970895739` 成功后，视觉检查发现豆瓣真实接口封面字段与请求 Referer 需补充，本轮修复并重新构建；最终状态在交付前更新。

| 验证 | 最终结果 |
| --- | --- |
| Swift 核心测试 | 前轮 37 项通过；本轮新增真实豆瓣封面字段回归，待最终结果 |
| iPhone 16 / iOS 18.5 UI 测试 | 前轮 9 项全部通过，本轮复验中 |
| Python 工具测试 | 8 项通过 |
| 浏览器观察脚本测试 | 1 项通过；原有脚本仍用于网站验证码页辅助，不是新版播放必经路径 |
| 真机平台构建 | iPhoneOS arm64 Release，iOS 16+，未签名 IPA 生成通过 |
| 实体 iPhone 签名安装、AirPlay / 画中画 | 未实测 |

本轮实际验证的界面 / 播放行为：

1. 整张海报的左上、右上、中央和左下位置点击均能进入详情；详情初始没有播放器。
2. 选择剧集后，封面简介区域替换为详情页内的 AVPlayer；切换剧集在同一详情页内完成。通过 `AVPlayerViewController.speeds = []` 隐藏系统倍速入口，也移除了原来的自绘倍速按钮。
3. 连续旋转为横屏左、竖屏、横屏右、竖屏，播放会话不变，播放器保持 `playing`，`isReadyForDisplay` 为真且进度继续增长。播放器使用 UIKit 容器嵌入原 AVPlayerViewController，旋转 / 全屏变化不调用关闭播放或清空 item。模拟器结论不替代用户具体 iPhone 上的测试。
4. 奥特实际首页 → 「折月亮」第 1 集 → HTTP 提取 HLS → 详情页内系统播放；动漫巴士搜索「神厨狂后」→ 第 12 集 → HTTP 读取 iframe / 原公开解析接口 → 详情页内系统播放。两条播放流程均断言不存在 WKWebView；验证码入口仍使用独立 WebKit。
5. 两栏全局搜索：左侧「全部源」与窄站点列表，右侧按相关度排序。测试故意让无关结果先从接口返回，最终完整片名优先；筛选一个来源后其他来源结果隐藏，切回「全部源」恢复。
6. 轮播可滑动，点选后查当前来源同名作品；关于页显示 by Chris Wei 与 GitHub 地址。UI 使用本地评分样例保证可重复，生产豆瓣公开榜单另有真实 HTTP 读取验证；该样例不会打包进 IPA。评分至少 7 分、100 人评价，未读取到评分则回退来源推荐。
7. 海报同页复用、首页到详情共享；应用终止后重启仍读磁盘，同一 URL 只请求一次，清理缓存后再访问才触发第二次请求。片库缓存的持久化与清理由核心测试覆盖。图片缓存 32 MB 内存 / 120 MB 磁盘，14 天更新；片库 3 分钟、豆瓣推荐 6 小时，片库 / 推荐磁盘上限 16 MB。配置、搜索和视频取址不走片库缓存。
8. 未知 `csp_FutureGuard` 从 `ext.siteUrl` 进入公共 HTML 适配 → 列表 / 详情 / 选集 → HTTP 提取 → AVPlayer；断言没有 WKWebView。缺域名来源直接进入并显示具体错误；从错误页补充地址保存后重新加载，终止 App 再启动仍能读取该源内容。该流程最终构建通过。
9. 通用核心行为覆盖未来配置携带 `ios` 规则、未知 CSP 独立搜索、奥特 / MacCMS HTML、缺域名提示和真实下一页链接识别。没有对剩余 34 源设置逐源实测通过的开放门槛。
10. 真实豆瓣接口使用 `cover_url` / `pic.large`，兼容旧 `cover.url`。已补齐封面字段；图片服务不带 Referer 时实测 418，带 `https://m.douban.com/` 和 App User-Agent 时返回 200 / JPEG。新增字段回归，最终截图复核轮播封面。

全部 45 个 Android 条目已开放，涉及 37 个不同 API 实现；11 个使用专用 Swift 实现，剩余 34 个统一进入 HTML / JSON 通用尝试，未知类名在更新配置后自动纳入。兔小贝另有专用实现，共 12 个专用配置条目。通用框架已有本地完整播放与持久化测试，剩余 34 个实际站点没有逐一验证，也没有执行原 Guard 协议。只有类名或不可读数据时需补充网址；网盘登录、直播签名、磁力等协议仍不完整，不能声称全源可播。2 个 drpy 条目没有完整宿主。逐源状态见 [source-port-status.json](source-port-status.json)，规则格式见 [通用来源规则](generic-source-rules.md)。急救教学的公开目录和 MP4 已有网络 / 核心测试，尚未做该源 iOS 完整播放验证。

奥特搜索仍可能需要用户完成网站验证码，自动化仅打开验证入口，没有代填或绕过。立播和厂长访问限制仍存在；网站域名、登录、签名或访问策略变化会影响播放。版本 0.3 的 WebKit 播放证据保留于下文，用于追踪，不代表 0.4 当前播放路径。

最终截图位于 `dist/screenshots/0.4.0/`：真实来源播放、横竖屏、两栏搜索、轮播、关于与缓存，以及 `28-generic-source-playing.png`、`29-generic-source-error.png`、`30-generic-rule-persisted.png`。`31-live-douban-home.png` 为真实源测试环境中的首页，`25-douban-carousel.png` 为可重复测试的本地榜单样例。

中间构建 `42969169687` 的 37 项核心通过、8 项 UI 通过，奥特 UI 因大幅滚动使卡片被固定分类栏遮挡而未进入详情，记录为失败。已将测试改为按卡片位置小幅拖动并断言卡片完整可见，没有把该失败改记为站点不可用或跳过，也不影响其余来源开放。前一构建 `42967802081` 的 36 核心 / 9 UI 全部通过。

## 0.3.0 回归

检查日期：2026-11-11，亚洲 / 上海。新增首页选源、分类导航、推荐卡片、最近播放，修复图片触摸范围；新增奥特网站适配、手动网站验证入口和搜索站点合并 / 并发调度。

- 25 项 Swift 核心测试通过，包括来源识别、重复分类搜索合并、奥特当前 HTML 列表 / 详情与安全的公开 HLS 提取。
- 8 项 Python 工具测试与 1 项浏览器媒体识别测试通过。
- iPhoneOS arm64 Release 编译及未签名 IPA 打包通过。
- 最终模拟器 5 项测试全部通过，0 失败、0 跳过。覆盖首页切源 / 分类 / 重启保留 / 聚合搜索、本地播放 / 收藏 / 最近播放、网页转系统播放、真实配置的动漫巴士与奥特播放。
- 最终构建：[GitHub Actions 42954727744](https://github.com/Jwforever/iMovie/actions/runs/42954727744)，应用代码提交 `bd37dca7d5bc8d7f7c1e0c4ce5442abcd80964f2`。交付包内文档补入本次结果，应用代码与该构建一致；详细版本与 SHA256 见 `dist/build-info.json`。
- 奥特当前首页 → 「折月亮」详情选集 → 本机读取公开 HLS → AVPlayer 进入 `playing`，已在 iPhone 16 / iOS 18.5 模拟器完成；搜索验证页面及应用内验证入口也已实际打开。测试没有代填验证码，验证后搜索是否受站点进一步限制仍取决于实际网络与网站状态。
- 奥特搜索在 macOS HTTP 探测中返回网站自己的验证码页。应用提供用户在 WebKit 中完成验证并将相关站点 Cookie 共享给本机请求的入口；自动化测试不代填或绕过验证码。
- 动漫巴士在最终构建中完成真实配置 → 搜索「神厨狂后」→ 第 12 集 → WebKit 识别 HLS → AVPlayer 进入 `playing`。本轮此前连续两次云端搜索报「无法连接服务器」；应用已对连接中断、无法连接主机、DNS 与超时增加一次有限重试。最终恢复不能证明站点以后一直可用，也不能单凭这次成功确定是重试还是网络恢复起效。测试仅在明确连接故障时才会记录跳过，最终构建未触发该分支。
- 立播和厂长部分当前域名返回 HTTP 403；没有将这些来源记录为已验证可用。B站和兔小贝维持原有适配及已有网络验证范围。

## 0.2.0 历史验证

检查日期：2026-11-10，亚洲 / 上海。下表与旧版构建证据保留用于追踪，不代表 0.3.0 的新增来源验证结果。

| 检查 | 结果 |
| --- | --- |
| 用户提供的配置地址 | HTTP 200，成功解码图片封装的 Base64 JSONC |
| 来源数量 | 48 个点播源，45 个 Android 爬虫、3 个 JavaScript 爬虫；6 个直播列表 |
| 爬虫包校验 | MD5 与配置一致；归档内确有 classes.dex 与 Android ARM32 / ARM64 ELF 库 |
| Python 工具行为测试 | 8 项通过：封装解码、注释与转义、Base64、域名规范化、JSONP、公开页面解析、拒绝伪应用、拒绝模拟器应用 |
| Swift 源码语法 | 通过 Xcode / Swift 编译器编译；另有 tree-sitter 语法检查 |
| 构建脚本 | bash -n 语法检查通过 |
| 项目配置 / workflow | YAML 可解析；所引用资源路径存在 |
| Info.plist / 隐私清单 | plist 可解析 |
| Swift 单元测试 | 21 项通过；包括 CRLF JSONC 注释修复和过期播放链接重播所需的来源持久化 |
| 浏览器测试 | 1 项通过：DOM / fetch / iframe 识别、去重、scheme 过滤和 iframe 暂停 |
| iOS UI 测试 | iPhone 16 / iOS 18.5 模拟器，3 项通过，见下方流程 |
| Xcode 真机构建 | Xcode 16.4、iOS SDK 18.5，iPhoneOS arm64 Release 编译通过，关闭签名 |
| IPA | 已生成 iMovie-0.2.0-unsigned.ipa；检查了 Mach-O arm64、iPhoneOS 平台和资源 |
| 实体 iPhone、签名安装、AirPlay、画中画、断点恢复实测 | 尚未验证；模拟器通过不等于实体设备验证 |
| 饭太硬 Android 点播 | 45 个原始 Guard 条目中 9 个由独立 Swift 实现识别：动漫巴士 1、B站 7、立播 1；其余 36 个尚未适配。未执行原 Guard 包 |
| drpy 来源 | 完整兼容宿主尚未实现；其中兔小贝已另写独立 Swift 适配样例，不执行原 drpy |
| 兔小贝、B站 | 公开 HTTP / API / MP4 样本链路通过；尚未完成这两类来源的 iOS 播放验证 |
| 动漫巴士 | 真实配置导入、搜索、选集、WKWebView 媒体识别、AVPlayer 实际进入 playing，模拟器测试通过 |
| 立播 | 实验性适配；配置内域名在 macOS 云端返回 HTTP 403，Windows 证书链失败，未完成站点播放验证 |
| 名称 | 目录、界面、Bundle Display Name、Swift package、构建 target 和 IPA 文件名已改为 iMovie |

## 已通过的模拟器流程

1. `testImportBrowsePlayAndBookmark`：本地图片 Base64 配置 → JSON 片库 → 详情 / 选集 → AVPlayer 进入 playing → 收藏 → 收藏重播重新取址 → 播放记录。
2. `testWebPageFindsMediaAndOpensSystemPlayer`：内置 WebKit 加载本地网页 → 识别 MP4 → 切换 AVPlayer 并进入 playing。
3. `testUserConfigAndDM84WebMedia`：真实饭太硬接口 → 48 个点播条目 / 6 个直播列表 → 动漫巴士搜索「神厨狂后」→ 第 12 集 → 本机 WebKit 识别 HLS → 系统播放器进入 playing。

真实来源测试的公开网站随时可能变化，测试只代表执行时的结果。本机播放无需 Android 或用户自建解析服务，仍需访问来源网站及其本身的播放服务。

## 构建证据

2026-11-10 最终通过的完整 macOS 构建记录：[GitHub Actions 42803822395](https://github.com/Jwforever/iMovie/actions/runs/42803822395)，对应提交 `5aefc6fe66c9572e315f2ee3fbdc2e6d4e00f685`。这是私有仓库，需使用仓库所有者账号查看。最终交付构建信息见 `dist/build-info.json`。

本地 `dist/screenshots/0.3.0/` 保存最终构建从 Xcode xcresult 导出的截图。`11-dm84-system-playing.png` 与 `18-auete-system-playing.png` 为两个真实来源的播放画面，`15-auete-home.png` 为实际网站首页内容，`12-home-with-recent.png` 为最近播放，`20-global-search-results.png` 为本地两站点聚合搜索测试；`07-user-config-imported.png` 显示配置与来源数量。测试使用的演示片库和生成视频仅在测试环境运行，不打包进 IPA。

Windows 的 Edge 手机模式另验证同一动漫巴士页面约 19 秒连续播放、readyState 4，作为浏览器侧补充证据；iOS 结论以模拟器测试为依据。
