# iMovie 0.3.0 · iOS 私人播放器

0.3.0 参考 TVBox / OK 影视的首页组织，增加记忆选源、顶部分类、推荐卡片、海报网格及最近播放；全局搜索按站点合并重复分类条目、持续并发查询和单源重试。新增奥特影视当前网站的 Swift 适配及用户手动完成网站验证的入口。实现参考见 [源码核查记录](docs/tvbox-reference.md)，最终测试结果见 [验证记录](docs/validation.md)。

原生 SwiftUI iPhone / iPad 应用，支持 iOS 16 及以上。已用 Xcode 16.4 编译 arm64 真机版本并生成未签名 IPA，可用自己的证书重新签名安装。

应用在 iPhone 内通过 Swift 和 WebKit 访问来源、识别媒体和播放，**使用时不需要 Android 手机、盒子或自建解析服务器**。编译使用 macOS GitHub Actions；构建服务不参与日常解析或播放。

已在 iPhone 16 / iOS 18.5 模拟器完成用户真实配置的“导入 → 动漫巴士搜索 → 详情选集 → WebKit 媒体识别 → AVPlayer 播放”。这不是全部来源兼容，也没有在实体 iPhone 上测试。

## 安装和第一次使用

1. 使用自己的签名工具重新签名 `dist/iMovie-0.3.0-unsigned.ipa`，再安装到 iPhone。
2. 打开「设置」，默认已填入 `http://www.饭太硬.cc/tv`，点击「导入 / 更新配置」。
3. 回到「首页」，点击左上角选择点播源；选择结果会保留。默认首页展示推荐内容，上方可切换分类。
4. 播放页出现「已找到媒体地址」后，点击「系统播放」。也可以使用网页本身的播放器。
5. 「搜索」可同时查询已适配且允许搜索的来源；「我的」保存收藏和播放记录。

更多操作见 [快速上手](docs/quick-start.md)。签名证书、描述文件和安装期限由所用签名方式决定。项目不需要保存你的 Apple ID 密码。

## 饭太硬当前配置的支持范围

2026-11-10 读取到 48 个点播条目、6 个直播列表。原始配置含 45 个 Android Guard 条目和 3 个 drpy 条目；本项目为部分条目独立编写 iOS 实现，不执行原 Android 二进制。

| 来源 / 能力 | 实现与验证 |
| --- | --- |
| 动漫巴士 / Dm84 | 原生分类、搜索、详情和选集；本机 WebKit 取址；真实配置到系统播放的 iOS 模拟器流程通过 |
| B站公开内容 | 1 套本机适配对应配置中 7 个 Bili 条目；分类关键词、搜索、分 P、公开视频单文件 MP4；电脑端公开 API 和媒体 Range 请求通过，尚未完成 iOS 端该源的播放验证 |
| 儿童 / 启蒙（兔小贝） | 独立 Swift 适配；分类、搜索、详情和公开 MP4 网络链路通过，尚未完成 iOS 端该源的播放验证 |
| 立播 / Libvio | 实验性 HTML 适配；当前站点访问受限，未验证完整浏览与播放 |
| 奥特 / Auete | 0.3.0 新增当前网站分类、海报、详情选集和公开 HLS 识别；搜索要求网站验证码时可在应用内手动验证；最终回归见验证记录 |
| 其余 35 个 Android 条目 | 显示「待移植」，当前不能搜索或播放 |
| 虎牙 / 斗鱼 drpy 条目 | 显示「脚本待适配」，没有完整 drpy 宿主 |
| JSON 类型 1 / 4 | 可接入返回公开媒体地址的接口；分类、搜索、分页、详情、选集；本地测试配置完整流程通过。用户原配置没有这类源 |
| 直播 | M3U / TXT / HLS 列表；6 个配置列表中 1 个依赖 Android localhost 代理，明确标为不可用；其余频道未逐一验证 |

设置中「本机移植（实验）11」表示 5 套适配识别到的 11 个配置条目，**不表示 11 个独立站点都已实测可用**。全局搜索会合并重复的 B站分类条目；配置中关闭搜索的兔小贝不参与全局搜索，仍可从首页选择后浏览。来源和媒体可用性会随网络、地区、网站结构及接口限制变化。

Android 归档包含 `classes.dex`、Android ELF `.so` 和 Guard 资源，不能直接装入 iOS。详见 [独立使用调查](docs/ios-standalone-research.md) 和 [原始接口检查](docs/interface-report.json)。

## 已实现的功能

- 中文深色 SwiftUI 界面，片库、搜索、直播、收藏 / 记录、设置。
- TVBox JSON / JSONC、Base64、图片 `**` Base64 配置导入，处理注释、尾逗号、CRLF 换行和中文域名。
- 已知来源的本机适配、分类、搜索、分页、详情和选集。
- 跨来源搜索，来源独立报告错误。
- WKWebView 网页播放及 HTTP(S) 媒体识别，支持 iframe、DOM、fetch / XHR 和资源记录。
- 直接粘贴视频地址；也可开启「使用内置网页播放器」打开播放网页。
- AVPlayer 系统控件、倍速、系统全屏、AirPlay 和画中画入口。
- 本地收藏和播放记录；系统播放器的播放进度保存与恢复；保存来源和选集，重播时刷新有时效的媒体地址。
- 从网页切换系统播放时，通知子页面暂停，避免两个播放器同时出声。

AVPlayer 只能播放系统支持的编码。DRM、会员 / 网盘登录、磁力、P2P、UDP / RTSP、下载、弹幕、DLNA 和完整 drpy / Android 插件兼容尚未实现。网页媒体识别也不保证能处理所有 blob / MSE、Cookie 或特殊认证站点。

## 构建

需要 macOS、完整 Xcode 15 或更新版本及 XcodeGen。已验证环境为 Xcode 16.4 / iOS SDK 18.5。

```bash
brew install xcodegen
bash scripts/build-unsigned.sh
```

脚本运行 Swift 核心测试，生成 Xcode 工程，编译 iPhoneOS arm64 Release 应用，检查 Mach-O 和真机平台后打包：

```text
dist/iMovie-0.3.0-unsigned.ipa
dist/iMovie-0.3.0-unsigned.ipa.sha256
```

GitHub 私有仓库内已运行 `.github/workflows/ios.yml`。在 Actions 中选择「Build unsigned iOS app → Run workflow」可以重新编译；`iMovie-unsigned-ipa` 为签名前产物，`iMovie-simulator-evidence` 为测试截图与 xcresult。云端产物保留 7 天，本地 `dist/` 文件不会因此过期。

直接用 Xcode 调试：运行 `xcodegen generate`，打开 `iMovie.xcodeproj`，配置自己的 Team、Bundle ID 与签名后运行。

## 验证

- 21 项 Swift 核心测试通过。
- 8 项 Python 工具测试通过。
- 1 项浏览器测试通过，覆盖 DOM / fetch / iframe 媒体识别、去重、URL scheme 过滤、跨 iframe 暂停。
- 3 项 iOS 模拟器界面测试通过，覆盖本地配置及播放、收藏重播和记录、网页切换系统播放、真实配置与动漫巴士播放。
- 真机 arm64 Release 构建及 IPA 打包通过；未在实体 iPhone 安装或验证 AirPlay / 画中画。

完整证据和限制见 [验证记录](docs/validation.md)。运行方法：

```bash
swift test
python3 -m unittest discover -s Tests/Python -v
npm install
npx playwright install chromium
npm run test:browser
# macOS：xcodegen generate 后执行
bash scripts/test-simulator.sh
```

Windows 已安装 Edge 时，可设置 `IMOVIE_BROWSER_CHANNEL=msedge` 运行浏览器测试，无需额外下载 Chromium。测试用本地视频由 AVFoundation 生成，不随 IPA 分发。

## 结构

```text
Sources/App/       SwiftUI、AVPlayer、WebKit、本地存储
Sources/Core/      配置、直播列表、JSON API、HTML 与公开来源适配
Resources/         图标、Info.plist、隐私清单、媒体观察脚本、组件许可
Tests/CoreTests/   核心 Swift 行为测试
Tests/UITests/     iOS 界面与播放流程测试
Tests/Fixtures/    本地测试站点与生成视频
Tests/Browser/     网页媒体观察脚本测试
Tests/Python/      配置检查与 IPA 打包工具测试
scripts/           诊断、构建、模拟器和打包脚本
docs/              使用说明、调查与验证记录
```

应用独立实现，没有复制 OK 影视的 Android 源码。HTML 解析使用 MIT 许可的 SwiftSoup 2.9.6，许可附在应用的「设置 → 开源组件许可」和 `Resources/ThirdPartyNotices.txt`。
