# iMovie：iPhone 独立使用的可行性调查

日期：2026-11-10。需求：用户只有 iPhone，自己签名安装，不依赖 Android 手机、盒子或用户维护的解析服务器。

## 结论

**iOS 可以独立完成搜索、选集、网页取址和播放。Android 不是这类播放器的必要条件。**

需要区分两个目标：

1. 做出类似 OK 影视、在 iPhone 上独立使用的播放器：有可行的本机实现路线。
2. 不修改任何采集逻辑，直接运行饭太硬当前配置内全部 Android 爬虫：没有找到经过核实的 iOS 原生兼容方案，当前二进制明确依赖 Android。

本项目采用第一个目标，保留配置导入，并对支持的网站使用 iOS 本机适配或脚本。不能把同名网站的移植当作原 Android 插件已兼容。

## 饭太硬当前配置的实物证据

检查地址：`http://www.饭太硬.cc/tv`。

- 48 个点播条目：45 个 `csp_*Guard`、3 个 drpy JavaScript。
- 配置中的爬虫文件是 ZIP/JAR 容器，MD5 与配置声明一致。
- 包内有 `classes.dex`、`assets/ftyguard_v7.so`、`assets/ftyguard_v8.so`、`assets/ftyshinidie.guard`。
- `.so` 是 ELF 格式，分别为 ARM32 和 AArch64；iOS 使用 Mach-O，CPU 同为 ARM64 不代表二进制兼容。
- DEX 字符串表实际包含 `Landroid/content/Context;`、`Landroid/content/SharedPreferences;`、`Landroid/app/Application;`、`Ldalvik/system/DexClassLoader;` 等 Android 类型。
- 当前 3 个脚本源是虎牙、斗鱼、儿童启蒙。**仅支持这 3 个也不等于已经覆盖电影电视剧。**

这些证据表明问题同时涉及字节码、Android API、加载器和原生库。单纯“在 IPA 内加一个 Java 引擎”不足以直接运行该包。iPhone 自签也不会自动提供这些组件。

本次未解密 `.guard`，未运行原 Android 插件。更复杂的解释器或模拟环境在理论上可以研究，但不作为本项目普通自签安装的可靠交付路线。

## iPhone 本机可用的技术路线

| 路线 | 手机独立使用 | 能否直接执行当前 Guard 包 | 适用范围 |
| --- | --- | --- | --- |
| URLSession + Swift 采集适配 | 可以 | 不能 | 公开 JSON、HTML、分类、搜索、播放地址 |
| JavaScriptCore + 网络 / DOM / 加密桥接 | 可以 | 不能 | JS 规则；drpy 需要补齐完整宿主依赖 |
| WKWebView + JavaScript 消息桥接 | 可以 | 不能 | 需要页面执行脚本的播放页；并非任意资源或 DRM 都可取址 |
| 编译进 App 的 QuickJS | 可以作为备选研究 | 不能 | 解释执行 JS；需移植并验证 C 库、模块及宿主接口 |
| 直接加载现有 DEX + Android ELF | 现有 iOS 项目未提供可用路径 | 需要完整兼容环境 | 不作为普通自签 iPhone 的交付方案 |
| 远程网关 / Android worker | 依赖外部设备或服务 | worker 中可能可执行 | 不符合本次独立使用要求 |

JavaScriptCore 是 JavaScript 引擎，本身不带浏览器 DOM、drpy 的 `req/pdfh/pdfa`、模块加载和本地代理。WKWebView 提供网页执行环境，但其 `WKNavigationDelegate` 不能被描述为任意 HTTP 子请求拦截器；跨域 iframe、MSE/blob、Cookie、请求头、验证码及 DRM 都需要具体分析。

检查饭太硬的 `drpy2.min.js`，实际导入了 `assets://js/lib/cheerio.min.js`、`crypto-js.js`、`node-rsa.js`、`pako.min.js`、`模板.js`、`gbk.js`、`json5.js` 和 `jinja.js`。因此下一阶段除了 JS 求值，还要处理模块入口、网络桥接、DOM 选择器、字符编码、存储和加密依赖；不能只把该文件交给 `JSContext.evaluateScript` 就宣称支持 drpy。

在本机执行解析，仍然需要联网访问用户添加的网站或网站自身的 API。这里的“独立”指不要求用户另准备解析设备或自建服务器。

## 已核实的技术资料与同类项目

### 1. Apple JavaScriptCore / WebKit

Apple 文档直接说明 JavaScriptCore 可在 Swift / Objective-C 应用内执行 JavaScript，并暴露自定义原生对象；`WKUserContentController` 支持注入脚本和与 App 通信。

- [JavaScriptCore](https://developer.apple.com/documentation/javascriptcore)
- [JSContext](https://developer.apple.com/documentation/javascriptcore/jscontext)
- [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)
- [WKUserContentController](https://developer.apple.com/documentation/webkit/wkusercontentcontroller)

**可得结论：iOS 有实现本机采集 / 规则执行所需的基础能力。不能据此声称 drpy 已完整兼容。**

### 2. Kazumi

核查版本：`7265274fac136a0cfe6ee32ea37f32f06ea57672`。

README 标示可侧载 iOS 版；源码中的 Apple 实现使用 headless WebView、注入脚本与 JavaScript handler，规则采集由独立的 XPath/API 规则系统完成。

- [项目说明](https://github.com/Predidit/Kazumi/blob/7265274fac136a0cfe6ee32ea37f32f06ea57672/README.md)
- [Apple WebView 实现](https://github.com/Predidit/Kazumi/blob/7265274fac136a0cfe6ee32ea37f32f06ea57672/lib/webview/video/impl/video_webview_apple_impl.dart)
- [网页视频源服务](https://github.com/Predidit/Kazumi/blob/7265274fac136a0cfe6ee32ea37f32f06ea57672/lib/services/video_source/webview_video_source_service.dart)

这是本机规则与网页解析的实现参考。**它的规则不是饭太硬 Android JAR，不能当作饭太硬兼容性证据。**本次未安装其 IPA，也未复制其代码。

### 3. tvbox-Swift

核查版本：`fdde6c51ce3cd94cbac4fb4dcdfcf4bbfe7c34ba`。

[README](https://github.com/Jstrom2022/tvbox-Swift/blob/fdde6c51ce3cd94cbac4fb4dcdfcf4bbfe7c34ba/README.md) 明确支持类型 0/1/4，暂不支持 type 3 JAR/Spider。这说明“支持 TVBox 配置”需要逐项看执行能力。

### 4. 带 CatVod 网关的 Swift 分支

核查版本：`dcfbdd598596bfab9cef44a9d48fde8ce5a6b5a6`。

- [网关设计](https://github.com/shareu007/tvbox-Swift-macOS/blob/dcfbdd598596bfab9cef44a9d48fde8ce5a6b5a6/docs/spider-gateway-design.md) 写明：`csp_*` JAR 由可选 Android worker 执行；Node bundle 由 macOS 子进程执行。
- [EmbeddedSpiderGateway.swift](https://github.com/shareu007/tvbox-Swift-macOS/blob/dcfbdd598596bfab9cef44a9d48fde8ce5a6b5a6/tvbox/Services/EmbeddedSpiderGateway.swift) 文件由 `#if os(macOS)` 包裹。

**macOS 自带网关不代表 iPhone 自带网关，更不能说明 iPhone 原生运行了 Android 爬虫。**

### 5. JS 引擎与 Java 转换工具

- [flutter_js](https://github.com/abner/flutter_js)：说明在 iOS 使用系统 JavaScriptCore，并桥接网络请求；可参考实现思路，不代表自动提供 TVBox 宿主。
- [QuickJS 官方文档](https://bellard.org/quickjs/quickjs.html)：可嵌入的 JavaScript 解释器。
- [QuickJS-iOS](https://github.com/siuying/QuickJS-iOS)：实验性 iOS 静态库构建示例，维护较旧，仅作可行性佐证。
- [Google J2ObjC](https://github.com/google/j2objc)：明确要求 Java 源码，明确不能转换 Android 二进制应用。它不能把现成的加固 DEX / `.so` 自动转成 iOS 插件。

## 本次实际做通的可重复实验

从用户原配置中选择 `dr_兔小贝`（儿童 / 启蒙），根据公开网站接口另写适配，不运行原脚本。

实测链路：

1. 读取用户原配置，确认包含该源。
2. 直接请求网站分类接口，返回 30 个条目，外层为 JSONP。
3. 直接请求“小星星”搜索页，解析出 2 个不重复结果。
4. 请求一个公开播放页，从 `mip-search-video` 的 `video-src` 属性读取媒体地址。
5. 对媒体地址执行 `Range: bytes=0-1023`；返回 HTTP 206、`video/mp4`，字节 4–7 为 `ftyp`。

全过程未使用 Android、自建解析服务器、云端自建函数或原 drpy 引擎。详细实测在 `native-source-probe.json`。

这证明该源可以使用普通 HTTP / HTML 逻辑实现本机适配。**实验运行在当前 Windows 的 Python 环境，并使用 iPhone User-Agent；尚未验证 Swift 代码、iOS 网络环境、完整视频、解码或播放控制。**

配套 Swift 适配已写入 `Sources/Core/TuxiaobeiAdapter.swift`，导入原配置后按已知规则地址识别为“本机适配·实验”。如果网站结构变化，会报告失败；不会静默把未知源认作已适配。

这只是一个公开来源的可行性样例，不能当作用户所需电影电视剧已完成。本次尝试原配置中立播网站主页时，当前电脑遇到证书链验证失败；未绕过证书检查，未验证该源的完整采集和播放。

## 本项目后续开发方向

采用 iPhone 本机架构：Swift 网络层、来源适配接口、JavaScriptCore 规则执行、WKWebView 页面处理、系统播放器。没有证据说明需要要求用户购买 Android 设备。

下一步先完成一个实际需要的影视站点的“搜索 → 详情 → 选集 → 媒体播放”闭环，再扩展 JS 宿主和更多站点。每个源需要独立验证，不承诺原 Guard 包全部无改动兼容。

iOS 本机运行和 IPA 编译是两个问题：App 运行不需要 Mac；生成 IPA 仍需 macOS 上的 Xcode / Apple SDK，可使用云构建。当前尚未触发云构建、生成 IPA 或进行真机验证。
