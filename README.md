# iMovie 0.5.0 · iOS 私人播放器

原生 SwiftUI iPhone / iPad 应用，iOS 16 及以上。**0.5.0 起不再有任何站点域名硬编码**：应用打开配置时，从配置的 `spider` 字段下载插件包，在设备内静态解开 `jar → *.guard → 明文 classes.dex`，再从插件里读出每个采集器的域名、搜索模板与 CSS 选择器，交给统一采集引擎请求网页并由 AVPlayer 播放。站点换域名只需重新导入配置，不需要重编 IPA。

使用时不需要 Android 手机、盒子或自建解析服务器；不执行 Dalvik 字节码、不加载 `.so`、不跑安卓模拟器。

## 这版删掉了什么

| 删除项 | 原问题 |
| --- | --- |
| `AueteAdapter` / `HTMLSourceAdapter` / `TuxiaobeiAdapter` / `BilibiliAdapter` / `FirstAidAdapter` | 每个都写死了站点域名（`www.aeete.com`、`dm84.tv`、`www.libvio.pw`、`www.tuxiaobei.com`…），站点迁移即失效 |
| `NativeSourceAdapter` 枚举与 `SourceSite.type` | 靠 `type` + 类名白名单分发，新源必须发版 |
| 硬编码兜底域名 / 搜索路径（`cz4k.com`、`xb6v.com`、`/auete4so.php?searchword=`、`/vodsearch/…`） | 猜出来的地址必然过期 |
| 上述适配器对应的 3 个测试文件 | 随实现一起删除 |

保留并接通的是一套：**配置 → 插件包 → DEX 字符串 → 站点规则 → 通用网页采集**。

## 新的解析链

```text
配置 spider 字段            https://…/xxx.jpg;md5;9d5f341a…
        │
        ▼  下载 + 校验后解容器
GuardContainer              ZIP 中央目录 / local header → {1,2,5,6} XOR 0x07 → raw inflate
        │                   产出内层 classes.dex（2.72 MB）
        ▼
DexFile + DexInstruction    DEX 索引表、class_data、code_item、Dalvik 指令长度表
        │
        ▼
GuardStringDecoder          fill-array-data 常量表 + D(short[],start,len,key) 调用折叠
        │                   含无参 getter 转发、parseInt 常量折叠
        ▼
GuardRuleBuilder            按方法归属推断 baseURL / listSelector / searchURL / 选集选择器
        │
        ▼
GenericSourceAdapter        SwiftSoup 采集列表、详情、选集 → MediaResolver 提取媒体
```

`Sources/Core/Guard/` 是这条链的全部实现，纯字节运算 + `Compression` 框架，无第三方密码库。相同算法在 `tools/dexrules/` 有一套 Python 参考实现，并有 `Tests/CoreTests/Fixtures/spider.jar`（与线上 md5 一致的插件包）作为回归夹具。

## 实测覆盖

用饭太硬当前配置（48 个点播条目，全部 `type=3`；6 个直播列表）跑一遍静态解析：45 个采集器里 **28 个能直接解出站点域名并生成规则**。

| 站点 | 解出的主域 | 解出的规则 |
| --- | --- | --- |
| 奥特 / Auete | `www.au1080.top` | `ul.threadlist li` / `h2 a` / `auete4so.php?searchword={wd}&page={pg}` / `ul.episode-list li > a` |
| 厂长 / NewCz | `www.4kcz.com` 等 7 个 | 列表、搜索、详情、选集 |
| 立播 / Libvio | `www.libvio.io` | 同上 |
| 比特 / Bttwoo | `www.bttwo.life` | 同上 |
| 荐影 / YGP | `www.6huo.com` | 同上 |
| 盘她 / YpanSo | `www.melost.cn` | 同上 |
| 巴士 / Dm84 | `dmbus.cc` | 同上 |

剩余 7 个影视条目（豆豆、光影/奶酪、热播、视界、剧圈、新6V）的域名**根本不在插件字符串里**：插件把它们放在路由层由 `ext` 或服务端下发，安卓端运行时才产生。这些来源会在界面上直接说明原因，并可手动填一个可访问的网址后按通用网页规则采集，不会凭空捏造域名。

## 安装与第一次使用

1. 用你自己的签名工具重签 `dist/iMovie-0.5.0-unsigned.ipa`，装到 iPhone / iPad。
2. 「设置」已默认填入 `http://www.饭太硬.cc/tv`，点「导入 / 更新配置」。导入后会在后台预热插件解析。
3. 「首页」左上角选择点播源；首次打开某个源时才按需解规则，之后走本机缓存。
4. 详情页选集后上方直接播放，不加载原播放网页。
5. 某个源报错时，界面会区分「插件里没有域名」和「网站要求验证」；前者去「设置 → 来源地址 / 通用规则」补地址即可。

## 构建

需要 macOS、完整 Xcode 15+ 与 XcodeGen（已验证 Xcode 16.4 / iOS SDK 18.5）。

```bash
brew install xcodegen
bash scripts/build-unsigned.sh
```

脚本先跑 `swift test`（含插件包回归测试），再生成工程、编译 arm64 Release、检查 Mach-O 与平台后打包：

```text
dist/iMovie-0.5.0-unsigned.ipa
dist/iMovie-0.5.0-unsigned.ipa.sha256
```

Windows 无法编译 iOS 应用；本仓库通过 `.github/workflows/ios.yml` 在 macOS runner 上构建，Actions 产物 `iMovie-unsigned-ipa` 即签名前 IPA。

## 验证

```bash
swift test                                            # 含真实插件包解码回归
python3 -m unittest discover -s Tests/Python -v
npm install && npx playwright install chromium && npm run test:browser
```

`GuardPluginTests` 用真实 jar 断言：容器解出的 DEX 为 2,728,036 字节、常量表 > 100 张、Auete 解出 `www.au1080.top` 且能生成完整规则、SixV 无域名时不生成规则。

## 结构

```text
Sources/App/        SwiftUI、AVPlayer、WebKit、本地存储
Sources/Core/       配置解码、JSON 接口、通用网页采集、媒体提取
Sources/Core/Guard/ 插件解包 + DEX 字符串解码 + 规则生成
Resources/          图标、Info.plist、隐私清单、组件许可
Tests/CoreTests/    核心测试（含真实插件包夹具）
Tests/UITests/      iOS 界面与播放流程测试
tools/dexrules/     Python 参考实现与取证脚本
docs/               调查、验证与交接记录
scripts/            构建、模拟器、打包脚本
```

HTML 解析使用 MIT 许可的 SwiftSoup 2.9.6，许可见「设置 → 开源组件许可」与 `Resources/ThirdPartyNotices.txt`。项目不包含任何影视内容，配置与媒体由使用者自行提供。
