# iMovie 0.5.5 · iOS 私人播放器

0.5.5 修复插件解释执行的引用判断、字节码操作数、OkHttp 请求传递、异常处理偏移及插件缓存更新。当前正式链路为：配置指定的 spider 插件 → 本机解释执行采集器 → 失败时使用同插件提取的网页规则 → AVPlayer。详见 [本次修复与验证](docs/hotfix-0.5.5.md)。

原生 SwiftUI iPhone / iPad 应用，iOS 16 及以上。**0.5.0 起不再有任何站点域名硬编码**：应用打开配置时，从配置的 `spider` 字段下载插件包，在设备内静态解开 `jar → *.guard → 明文 classes.dex`，再从插件里读出每个采集器的域名、搜索模板与 CSS 选择器，交给统一采集引擎请求网页并由 AVPlayer 播放。站点换域名只需重新导入配置，不需要重编 IPA。

使用时不需要 Android 手机、盒子或自建解析服务器。Dalvik 字节码由 Swift 解释器执行；不使用 JIT、不加载 Android `.so`、不跑安卓系统。解释器及宿主垫片尚未覆盖全部 Android API，不能把类数量等同于可播放来源数量。

## 为什么 iOS 不能直接跑 TVBox / OK影视 的源

这是整件事的起点，也是 0.5.0 之前那些硬编码适配器存在的原因。

### 安卓那套是怎么执行的

TVBox 配置里 `type=3` 的条目，`api` 写的是 `csp_XXXGuard` 这样的**类名**，不是网址。真正的采集逻辑装在配置 `spider` 字段指向的一个 jar 里（地址形如 `https://…/xxx.jpg;md5;9d5f…`，`.jpg` 只是伪装）。Android 端的链路是：

1. 下载 jar，按 `;md5;` 校验；
2. `DexClassLoader` 把 jar 里的 `classes.dex` 载入 ART；
3. 反射调用 `com.github.catvod.spider.Init`，再由 `Proxy` 把配置里的 `csp_XXX` 映射到 `com.github.catvod.spider.XXX`；
4. 采集器开始发请求、解析 HTML、拼播放地址。

也就是说：**域名、搜索路径、选择器、请求头、签名算法，全是 Java 代码运行时才产生的东西**，配置里一个字都没有。这既是这类配置能长期存活的原因，也是 iOS 端拿不到它们的原因。

### iOS 卡在哪三条

| 安卓能力 | iOS 的实际情况 |
| --- | --- |
| ART 执行 DEX 字节码 | 没有 JVM/ART，DEX 无法执行，`DexClassLoader` 无对应物 |
| JIT 生成并执行原生代码 | 第三方 App 没有通用 JIT 权限，动态生成的机器码不能执行 |
| `dlopen` 加载 jar 内的 `.so` | 沙箱只允许加载已签名、随包分发的动态库；`ftyshinidie.guard` 里的 `ftyguard_v7/v8.so` 即便解出来也加载不了 |

iOS 没有系统 ART，但可以用 Swift 解释器逐条执行 DEX，并为 Java / Android 外部调用提供宿主垫片。0.5.4 起正式采集优先走这条链路，静态规则提取作为失败后的回退；二者都在设备内完成。

### 现有 iOS 客户端为什么不解决这个问题

iBox 走的是另一条路：自有片源加密分发 + 固定解析接口，App 内没有 TVBox 插件运行时，也不开放导入第三方订阅配置——饭太硬这类地址根本填不进去。OK影视 的 iOS 版同理，它只认自己那套链路。

所以换一个 App 并不能解决问题：问题不在播放器，而在于**没有任何东西去执行那个 jar**。

### 取舍：不执行，只读取

既然不能执行，就不要再执行。同一个 jar 有两种身份：

- 对安卓：一段要被 ART 执行的**代码**；
- 对我们：一个装着**常量**的**数据容器**。

而这类 Guard 插件恰好把所有会变的东西——域名、搜索模板、选择器、请求头、RSA 公钥——都放在常量里，方法体只剩通用模板。于是问题从「怎么在 iOS 上跑 Java」变成「怎么把容器和编码还原成明文常量」。后者是纯字节运算，手机完全做得来。

顺带说明：这不是暴力破解，也没有猜。每一层都是把格式逆出来，再用独立证据交叉验证。

### 三层是怎么解开的

先 REA 了 OK影视（v5.1.5，`com.fongmi.android.tv` 的换皮包，78 MB）和 iBox 做对照。OK影视 里没有任何针对某个配置的专用解析代码，只有标准链路；iBox 那条路走不通（加密分发 + 不接受外部订阅）。于是拿 OK影视 当样本，逐层拆：

**第一层 · 外层 `classes.dex`（37 KB）**：46 个 `XxxGuard extends BaseSpiderGuard` 的空壳，只负责把类名登记给 `Proxy`，没有采集逻辑。

**第二层 · `ftyshinidie.guard`（1.28 MB）**：一开始以为是加密，其实不是。它是一个**被删掉中央目录的 ZIP**，并且 deflate 流里凡是值为 `{1, 2, 5, 6}` 的字节都被 XOR 了 `0x07`（1↔6、2↔5，自逆）。按这条规则还原后再 inflate，得到 2,728,036 字节的明文 DEX。

两处独立验证：解出的 DEX 的 MD5 与安卓真机内存 dump 完全一致；包里 `META-INF/MANIFEST.MF` 解出来正好是 73 字节的 `Dex-Location: classes.dex`（不做还原的话会多一字节，`Location` 会解成 `Locasion`）。

**第三层 · 内层 DEX 的字符串表**：不是标准 DEX 字符串，而是一张 `short[]` 表加一次逐位异或：

```java
static String D(short[] t, int start, int len, int key) {
    char[] c = new char[len];
    for (int i = 0; i < len; i++) c[i] = (char) (t[start + i] ^ key);
    return new String(c);
}
```

表由各类 `<clinit>` 里的 `fill-array-data` 填充，也有通过无参 getter 转发的情况；这段算法在 DEX 里被克隆了 40 多份。关键在于**调用点的三个参数全是常量**（形如 `D(table, 0, 39, 2196)`），所以一行代码都不用执行，静态扫描指令就能把明文全部折叠出来。

中途踩过一个坑：一度以为方法体也被加密，实际是自己写的 Dalvik 指令长度表错了两项——`const/4` 应该是 1 个 code unit、`const/16` 是 2 个。修正后反汇编全量正常，方法体本来就是明文。

### 还原之后得到什么

把解出的字符串按方法归属归类，就能反推每个采集器的规则：主域名、列表选择器、搜索模板、详情与选集选择器。用当前配置跑一遍：45 个采集器里 **28 个能解出域名并生成完整规则**（奥特 `www.au1080.top`、厂长 `www.4kcz.com`、立播 `www.libvio.io`…）。

剩下 7 个（豆豆、光影/奶酪、热播、视界、剧圈、新6V）的域名**确实不在 DEX 里**：它们被放在 `ext` 或服务端路由中，安卓端运行时才产生。这不是没解出来，而是本来就没有可解的常量。应用会如实说明原因，允许手填一个可访问地址后按通用规则采集。

### 最终形态

解出来的算法被重写成 Swift（`Sources/Core/Guard/`），只用系统的 `Compression` 框架和字节运算，没有第三方密码库，**没有任何后台服务**：不连自建服务器、不做云端解析、不上报数据。全过程在设备本地完成——导入配置、下载插件、解容器、解字符串、生成规则、采集网页、交给 AVPlayer。

应用不含广告，不含统计 SDK，除配置地址与站点本身外不向任何第三方发包。

真正的收益在这里：站点换域名，只要配置里的 `spider` 指向新插件，App 重新解一遍就跟着变，**不需要重编 IPA**。

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

1. 用你自己的签名工具重签 `dist/iMovie-0.5.5-unsigned.ipa`，装到 iPhone / iPad。
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
dist/iMovie-0.5.5-unsigned.ipa
dist/iMovie-0.5.5-unsigned.ipa.sha256
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
