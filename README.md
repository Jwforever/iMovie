# iMovie · iOS 私人播放器

为 iPhone / iPad 编写的原生 SwiftUI 项目，目标为 iOS 16 及以上。可在 Mac 构建未签名 IPA，再使用自己的签名工具安装。

**当前交付是源码和构建脚本，还没有经过 Xcode 编译，也没有可安装的 IPA。当前 Windows 环境没有 Apple iOS SDK。**

本项目按 **iPhone 独立使用** 开发，不要求准备 Android 手机、盒子或自建解析服务器。iOS 能使用本机网络层、JavaScriptCore 和 WebKit 实现采集；现有 Android 爬虫二进制则需要独立移植，不能直接加载。调查、依据和实测范围见 [iOS 独立使用调查](docs/ios-standalone-research.md)。

## 你提供的饭太硬接口

默认配置地址为 `http://www.饭太硬.cc/tv`。首次启动后进入「设置 → 导入 / 更新配置」，才会访问该地址。

2026-11-10 对该地址的实测结果：

| 项目 | 结果 | 当前支持情况 |
| --- | --- | --- |
| 配置封装 | 图片 + 标识 + `**` + Base64(JSONC) | 已实现解码；JSON 中的注释、尾逗号可处理 |
| 点播来源 | 48 个 | 可读取名称和兼容状态 |
| Android 来源 | 45 个 `csp_*Guard` | 现成二进制不能直接运行，需要逐站本机移植 |
| 脚本来源 | 3 个 drpy JavaScript 来源 | 其中 1 个已写入本机移植样例；完整 drpy 宿主尚未实现 |
| 本机 JSON 点播接口 | 0 个 | 配置中没有类型 1 / 4 的 JSON 源 |
| 本机移植样例 | 儿童 / 启蒙（兔小贝） | 已编写 Swift 适配；网站 HTTP 链路实测通过，尚待 iOS 编译和播放验证 |
| 直播列表 | 6 个，其中 1 个依赖 Android 本地代理 | 其余可以尝试读取；未验证每个频道的播放 |

抓取的爬虫归档包含 `classes.dex`、ARM32/ARM64 的 Android ELF `.so` 库以及 `.guard` 资源，MD5 与配置声明一致。它不只是普通的 JSON 或可直接运行的 JavaScript。给 IPA 重新签名不会增加 Android 运行环境。

详细检查结果保存在 `docs/interface-report.json`。该报告不包含影片库或原始爬虫二进制，接口内容随时可能变化。

为满足只有 iPhone 的使用需求，后续沿本机路线开发：

1. 使用 Swift 实现网站分类、搜索、详情和公开媒体取址，已为配置内一个公开来源编写首个样例。
2. 增加 JavaScriptCore 规则执行和 drpy 所需的网络、模块、DOM、加密桥接，支持可移植的 JS 来源。
3. 对需要页面执行的来源接入 WKWebView；逐个核实 Cookie、请求头、跨域页面和媒体编码。

当前还没有完整 JS 宿主、通用网页解析或电影电视剧站点的真机闭环。样例没有执行原 Android Guard 包，不能据此承诺全部 45 个插件兼容。

## 已写入的功能

- 深色中文界面，iPhone / iPad 自适应布局。
- 导入 TVBox JSON / JSONC、Base64、图片 `**` Base64 配置；显示兼容状态。
- 原生 JSON 类型 1 / 4 接口适配代码：分类、搜索、分页、详情、选集；类型 4 支持明确返回无需网页解析的播放地址。这些需要实际接口继续联调。
- 独立编写的兔小贝适配：分类、搜索、公开媒体取址，接入原配置识别，标记为“本机适配·实验”。
- M3U、TXT 直播列表解析，携带常见 User-Agent、Referer、Origin 请求头。
- HTTP/HTTPS 直链播放，使用 AVPlayer 系统控件；支持系统提供的全屏、AirPlay、画中画和倍速能力。
- 本地收藏、最近播放记录、点播进度恢复。
- 清楚报告 Android 本地代理和不支持的采集类型。

AVPlayer 只支持其能解码的媒体；网页解析、DRM、网盘登录、磁力、P2P、UDP/RTSP、下载、弹幕和 DLNA 暂未实现。第三方源需要的任意请求头在系统播放器上的行为仍需真机验证。

## 在 Mac 生成 IPA

需要完整 Xcode 15 或更新版本，并安装 Xcode 命令行工具及 XcodeGen。

```bash
brew install xcodegen
cd iMovie
bash scripts/build-unsigned.sh
```

脚本依次运行核心 Swift 单元测试、生成 Xcode 工程、编译 arm64 iOS 真机应用，再将真正的 Mach-O `.app` 打包为：

```text
dist/iMovie-0.1.0-unsigned.ipa
dist/iMovie-0.1.0-unsigned.ipa.sha256
```

未签名 IPA 需要使用自己的证书和描述文件重新签名。可使用自己已有的签名工具；安装有效期取决于所用签名方式。不要提供 Apple ID 密码给本项目。

如需在 Xcode 直接调试：运行 `xcodegen generate`，打开 `iMovie.xcodeproj`，在项目签名设置中启用代码签名，填写自己的 Team 和唯一 Bundle ID。

## 没有 Mac 时

项目包含手动触发的 `.github/workflows/ios.yml`：将 **iMovie 文件夹本身作为独立仓库根目录**，在 GitHub Actions 中选择「Build unsigned iOS app → Run workflow」，成功后下载 `iMovie-unsigned-ipa` 构建产物。

这个流程需要你的 GitHub 仓库和 macOS runner 额度；当前没有创建远程仓库、上传源码或运行云构建。workflow 尚未经过远程运行验证。

## 验证接口

配置检查工具只读取配置、归档目录和 ELF 文件头，不运行爬虫。

```bash
python3 scripts/inspect_config.py --spider --output docs/interface-report.json
python3 scripts/probe_native_source.py --output docs/native-source-probe.json
python3 -m unittest discover -s Tests/Python -v
swift test
```

## 项目结构

```text
Sources/App/             SwiftUI 界面、播放器、本地存储
Sources/Core/            配置、直播列表和 JSON 接口适配
Resources/               Info.plist、隐私清单、图标
Tests/CoreTests/         Swift 核心行为测试
Tests/Python/            配置检查工具测试
scripts/                 接口诊断、Mac 构建和 IPA 打包
docs/interface-report.json  本次实际检查结果
docs/ios-standalone-research.md  本机架构调查、出处与限制
docs/native-source-probe.json  无 Android 的公开来源 HTTP 实测
```

这是一份独立实现，没有拷贝 OK 影视的 Android 源码。
