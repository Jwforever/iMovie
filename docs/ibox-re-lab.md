# iBox 2.5.0 逆向报告（iOS 影视壳）

产物目录：`C:/Users/junti/AppData/Local/Temp/imovie_re/ibox_unzip/`

## 1. 基本信息

| 项 | 值 |
|---|---|
| IPA | `iBox_2.5.0_2_id自签.ipa`，95,454,166 B |
| App 目录 | `Payload/Player.app` |
| CFBundleIdentifier | `com.super.tvbox` |
| 显示名 / 可执行文件 | iBox / `Player` |
| 版本 | 2.5.0 (build 1)，MinimumOSVersion 12.0 |
| 架构 / 加密 | arm64，`LC_ENCRYPTION_INFO_64 cryptid = 0` → **已解密**，可直接静态分析 |
| 主二进制 | 68,382,096 B，Swift（`_TtC6Player…` 符号完好） |

## 2. 结论先行

1. **iBox 与 TVBox 没有任何代码级关系**。全二进制搜不到 `tvbox` / `csp_` / `catvod` / `.jar` / `DexClassLoader` / `Init$Loader` 任一特征。
   → 它**不能**导入饭太硬 `http://www.饭太硬.cc/tv`，也不能跑 `csp_*Guard` 那类加密 DEX 插件。
2. 它解决"域名不写死"的方式是**另一条路**：**App 里一个站点域名都没有**，所有站点都是**运行时下载的脚本**（Lua / JavaScript），域名写在脚本里。
3. 它是目前最贴近 iMovie 需求的**已上架/可自签 iOS 样板**：内置 **Lua 5.4** 解释器 + 系统 **JavaScriptCore**，同一套宿主 API 供两种脚本使用。

## 3. 站点是怎么来的（关键机制）

### 3.1 源列表：远程加密 JSON

二进制里三个镜像地址（同一份文件，互为备份）：

```
https://ghfast.top/https://raw.githubusercontent.com/ibox707/ibox/main/api_250.json
https://gh-proxy.com/https://github.com/ibox707/ibox/blob/main/api_250.json
https://gitee.com/zzuli/study/raw/master/api_250.json
```

GitHub 仓库 `ibox707/ibox` 是公开的，`main` 分支下共 42 个文件：`api.json`、`api_215` … `api_251`、`api_666`、`api_demo.json`、`wn_100.json`、`wn_config.json`。

**这些文件全部是密文**：整体 Base64，解码后 40,887 B（≠16 对齐，不是裸 AES-CBC）。已排除：zlib/gzip、30 组 16 字符密钥的 XOR/RC4、二进制内 99,196 条候选字符串的 AES-128/192/256 ECB/CBC（含偏移 0–19 对齐探测）。密钥要么是运行期派生，要么走 `sessionAesKey` 通道（二进制里有 `x-encrypted=1 but aesKey nil`、`[Network] [config] response empty or decrypt failed`）。

→ 说明 iBox 的**站点清单本身也是加密的**，App 内解密后得到一个站点数组。

### 3.2 站点对象模型

Swift 里可见结构体字段（mangled 名 `SS7siteKey_SS9runtimeIdSS9sourceURLt`）：

```
Site { siteKey: String, runtimeId: String, sourceURL: String }
```

`sourceURL` 指向该站点对应的 **Lua / JS 脚本**。`siteKey` 用于隔离每个站点的存储、Keychain、Cookie 命名空间（`siteKeyStore` / `siteKeychain` / `memStore`）。

### 3.3 脚本入口分类

二进制里有 **158 个** `*Spider` 类，两类并存：

- **原生 Swift 写死的站点**（约 40+）：`TuXiaoBeiSpider`、`XiaFanSpider`、`YiSpider`、`MuqiSpider`、`JwwSpider`、`BiliLiveSpider`、`DouYinSpider`、`HaoKanSpider`、`WebCmsSpider`、`WebBdysSpider`、`DmbusSpider`、`DubokuSpider` …
- **脚本驱动**：`LuaVideoSpider`、`JsVideoSpider`、`CliCliSpider`、`JiongSpider`、`UutuSpider`、`VodAESSpider`、`CaijiSpider`

即：**原生兜底 + 脚本扩展**。新站点不用发版。

## 4. 脚本运行时（可直接抄的部分）

### 4.1 引擎

- **Lua 5.4**（静态编入主二进制，含 `luaL_openlibs`、`/usr/local/share/lua/5.4/?.lua` 搜索路径、`lua_debug>` 交互串）
- **JavaScriptCore**（系统框架 `JSContext` / `JSValue`，Promise 化封装）
- 两套共用同一份宿主 API 语义（源码注释里写"对齐 js-host-api.md"，`hostApiVersion = 1`）

### 4.2 随包 Lua 胶水（明文，可直接读）

| 文件 | 作用 |
|---|---|
| `LuaScriptBootstrap.lua` | 最小宿主：`httpGet` / `httpPost` / `utils.*`（md5、base64、aes128cbc、hmac） |
| `LuaScriptHostGlobals.lua` | 完整宿主 API（见下） |
| `JiongLuaParse.lua` | 囧次元系脚本底（`vmplugin.invoke_method`） |
| `CliCliLuaParse.lua` | CliCliSpider 增量：`server_sign`、`socket.http.request`、`ltn12.sink.table` |
| `dkjson.lua` | JSON |

### 4.3 宿主 API 覆盖面（`LuaScriptHostGlobals.lua`）

- 网络：`fetch`（Promise/Response 风格：`text/json/bytes/base64/arrayBuffer/header`）、`fetchHtml`（返回 DOM 句柄）、`httpGet/httpPost`、`sleep`（协程 yield）
- 二进制与编码：`bytesToBase64` / `base64ToBytes` / `utf8ToBytes` / `bytesToUtf8` / `hexToBytes` / `bytesToHex`
- 密码学（90+ 函数）：md5/sha1/sha256/sha384/sha512、hmac 全家、AES（CBC/ECB/CTR/CFB/OFB/GCM）、DES/3DES、RC4、RSA（含 OAEP / 私钥加密 / 签名）、**SM2/SM3**、zlib/gzip inflate-deflate、`xxh64Hex16`
- HTML：`htmlParse` / `htmlQuery` / `htmlQueryAll` / `htmlText` / `htmlOwnText` / `htmlHtml` / `htmlOuter` / `htmlAttr` / `htmlParent` / `htmlChildren` / `htmlClass` / `htmlHasClass`（底层 SwiftSoup）
- 存储：`memStore`（内存）、`siteKeyStore` / `appKeyStore`（MMKV）、`siteKeychain` / `appKeychain`（Keychain）
- 网盘：`panAuth`（夸克/百度/阿里/123/139 登录态）、`panProxy`（本地反代，`GCDWebServer`）、`m3u8Proxy`（本地 m3u8 改写，`httpLua$siteKey$runtimeId$url` / `httpJs$…`）
- 其它：`protobufCompile/Encode/Decode`（SwiftProtobuf）、`device`、`isVPNOn`、`isUsedProxy`、`rotateCaptchaBestAngle`（滑块验证码角度）、`setTimeout/setInterval`、`console`
- 注意：**脚本接口不是 TVBox 那套** `homeContent/detailContent/playerContent`，而是自家的 `homeTabs` / `homeList` / `homeMore` / `search` / `detail` / `danmu`

### 4.4 连带的库（说明这套壳的完整度）

`SwiftSoup`（CSS 选择器）、`SwiftProtobuf`、`SwiftyRSA`、`MMKV`、`GCDWebServer`、`CryptoSwift` 类实现、`MobileVLCKit` + `Mpv` + `AliyunPlayer` + 火山 `TTSDK`（多播放器内核）、`Alamofire`、`HandyJSON`、`Kingfisher`、广告 SDK（穿山甲/百度/GDT/KS/Sigmob）。

## 5. 对 iMovie 的可借鉴点

1. **零域名常量的正确姿势 = 站点即脚本**。App 只保留"脚本运行时 + 宿主 API + 站点清单地址"，域名、选择器、鉴权全在远端脚本里；换域名只改脚本，连清单都不用更新。
2. **iOS 上完全可行**：Lua 5.4 静态编入 + 系统 JavaScriptCore，不需要下载可执行代码，不碰 JIT。iBox 就是活证据（`com.super.tvbox`，2.5.0，自签可跑）。
3. **JS 优于 Lua 落地的理由**：JavaScriptCore 是系统框架，零体积、零签名负担、Swift 桥接最顺；Lua 要自带 C 源码但换来 CliCli/Myuko 生态的现成脚本。
4. **别忘了 `fetchHtml` + CSS 选择器这一层**：脚本作者最需要的是"给我选择器，不要让我写正则"。iMovie 已有 SwiftSoup，可直接对齐。
5. **站点清单可以加密**（iBox 就是把清单 Base64+AES 后再公开托管），防的是脚本被随手抄走，不是防逆向。

## 6. 与饭太硬路线的对比

| | 饭太硬 / TVBox `type=3` | iBox |
|---|---|---|
| 解析单元 | `.jar`（内含加密 DEX + OLLVM `.so`） | `.lua` / `.js` 脚本 |
| iOS 能否执行 | **不能**（需 Dalvik + ARM native） | **能**（解释执行） |
| 域名来源 | Guard 运行时生成，静态不可见 | 明文写在脚本里，随脚本更新 |
| 谁维护站点 | 插件作者，改域名要重新发 jar | 任何人都能改脚本 |

→ 想在 iOS 上"运行时解析、不写死域名、不发版换域名"，**必须放弃饭太硬的 DEX 插件形态**，转成脚本形态；iBox 已经把这条路走通了。

## 7. 复现命令

```bash
# 解包
python -c "import zipfile;zipfile.ZipFile('ibox.ipa').extractall('ibox_unzip')"
# 检查加密标志（cryptid 应为 0）
python - <<'EOF'
import struct
b=open('Payload/Player.app/Player','rb').read(); off=32
magic,ct,cs,ft,ncmds,sz,fl,rs=struct.unpack_from('<IiiIIIII',b,0)
for _ in range(ncmds):
    cmd,s=struct.unpack_from('<II',b,off)
    if cmd==0x2C: print('cryptid',struct.unpack_from('<III',b,off+8)[2])
    off+=s
EOF
# 取源列表（密文）
curl -sL https://ghfast.top/https://raw.githubusercontent.com/ibox707/ibox/main/api_250.json
```
