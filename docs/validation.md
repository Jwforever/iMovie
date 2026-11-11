# 当前验证状态

## 0.3.0 回归

检查日期：2026-11-11，亚洲 / 上海。新增首页选源、分类导航、推荐卡片、最近播放，修复图片触摸范围；新增奥特网站适配、手动网站验证入口和搜索站点合并 / 并发调度。

- 25 项 Swift 核心测试通过，包括来源识别、重复分类搜索合并、奥特当前 HTML 列表 / 详情与安全的公开 HLS 提取。
- 8 项 Python 工具测试与 1 项浏览器媒体识别测试通过。
- iPhoneOS arm64 Release 编译及未签名 IPA 打包通过。
- 模拟器最终结果与构建提交在交付时写入 `dist/build-info.json`。
- 奥特当前首页 → 「折月亮」详情选集 → 本机读取公开 HLS → AVPlayer 进入 `playing`，已在 iPhone 16 / iOS 18.5 模拟器完成；搜索验证页面及应用内验证入口也已实际打开。测试没有代填验证码，验证后搜索是否受站点进一步限制仍取决于实际网络与网站状态。
- 奥特搜索在 macOS HTTP 探测中返回网站自己的验证码页。应用提供用户在 WebKit 中完成验证并将相关站点 Cookie 共享给本机请求的入口；自动化测试不代填或绕过验证码。
- 动漫巴士在本轮云端回归中连续两次搜索报「无法连接服务器」。应用对连接中断、无法连接主机、DNS 与超时增加一次有限重试；模拟器测试仅在明确出现连接故障时记录为跳过，并保存截图，解析或播放断言失败仍判为失败。旧版完整播放的证据保留在下方，不能据此宣称本轮该来源已通过。
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

本地 `dist/screenshots/` 保存从 Xcode xcresult 导出的截图。其中 `11-dm84-system-playing.png` 可见真实来源的解码画面，`07-user-config-imported.png` 显示配置与来源数量。测试使用的演示片库和生成视频仅在测试环境运行，不打包进 IPA。

Windows 的 Edge 手机模式另验证同一动漫巴士页面约 19 秒连续播放、readyState 4，作为浏览器侧补充证据；iOS 结论以模拟器测试为依据。
