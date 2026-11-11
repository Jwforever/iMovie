# dexrules —— 从 CatVod/DEX 插件静态导出站点规则

把饭太硬那类 `csp_*Guard` 插件里的采集规则与站点域名，从 jar 静态提取出来。
**不执行 Dalvik、不执行 ARM、不需要模拟器、不联安卓。**

整条链只有三件事：解容器 → 解字符串 → 按方法归类。

> **2026-11 更新**：线上 jar 换成了标准 ZIP（带中央目录，local header 里 flag=0x808
> 写 0 长度），旧版只扫 local header 的写法会读到 `csize=0` 而失败。现在
> `unpack_guard.py` 先走中央目录、再退回 local header 扫描，内层 `.guard` 仍按
> local header 处理。Swift 端 `Sources/Core/Guard/GuardContainer.swift` 同一套逻辑。

## 一、jar 的结构（三层，已全部打通）

| 层 | 内容 | 状态 |
|---|---|---|
| 外层 `classes.dex`（16 KB） | 46 个 `XxxGuard extends BaseSpiderGuard` 空壳 | 只登记，不采 |
| `assets/ftyshinidie.guard`（1.26 MB） | 被扰动过的 ZIP，内含内层 DEX | **已可静态解开** |
| 内层 `classes.dex`（2.72 MB） | 真正的采集器 `Xxx`（`Auete`/`Dm84`/`Libvio`…），字符串表编码 | **已可静态解码** |

命名规律：`AiDjGuard` → `AiDj`，去掉 `Guard` 后缀（40/45 命中）。

### 1.1 guard 容器：ZIP 头完整、数据被扰动

`ftyshinidie.guard` 是**抹掉中央目录**的 ZIP。local file header 仍然完整，所以
文件名 / 压缩长度 / 原始长度都读得到：

```
classes.dex            method=8(deflate)  csize=1287881  usize=2728036
META-INF/MANIFEST.MF   method=8(deflate)  csize=71       usize=73
```

数据段看起来像正常 deflate（`2c d7 ...` 是合法的 dynamic block 头），但直接解压会报
`invalid code lengths set`。原因是做了**字节值替换**：

```python
# deflate 流中，凡值 ∈ {1,2,5,6} 的字节，写入前 XOR 0x07
# 即 1↔6、2↔5（低 3 位取补码）。该变换自逆。
table = bytes(b ^ 7 if b in (1, 2, 5, 6) else b for b in range(256))
plain_deflate = cipher.translate(table)
dex = zlib.decompressobj(-15).decompress(plain_deflate)
```

只有 `{1,2,5,6}` 参与，`{0,3,4,7}` 不动——这一点是判定关键：若按「所有 ≤7 的字节取反」
处理，`0`/`7` 会被误改，反而解不开。

**双重校验**：

1. 解出的内层 DEX = 2,728,036 字节，与安卓内存 dump 的 MD5 完全一致（`80555d0e…`）。
2. `MANIFEST.MF` 解出正好 73 字节（= zip 记录的 usize），内容是
   `Dex-Location: classes.dex`；不还原时解出 74 字节且把 `Location` 写成 `Locasion`。

换新 jar 时这一层不用改代码，规则是固定的字节值映射。

## 二、字符串加密

内层 DEX 的**方法体是明文的**（`dexdump -d` 可直接反汇编），但字符串被两种方式藏起来：

1. **明文 `const-string`**：一部分站点（Auete、Dm84、Fy、YueTing 等）的域名直接可读。
2. **`short[]` 常量表 + XOR 解码**：其余站点的域名、搜索路径、CSS 选择器都在这里。

解码器在 DEX 里被克隆了 40+ 份，每份字节码完全一样：

```java
static String D(short[] t, int start, int len, int key) {
    char[] c = new char[len];
    for (int i = 0; i < len; i++) c[i] = (char) (t[start + i] ^ key);
    return new String(c);
}
```

- `short[] t` 由各类的 `<clinit>` 用 `fill-array-data` 填充（644~2000 个 short）。
- 调用点形如 `D(table, 0, 39, 2196)`，三个参数都是常量 → **可完全静态还原**。

### 2.1 取表的三种写法都要认

| 写法 | 例子 | 处理 |
|---|---|---|
| `sget-object vX, 类.short:[S` | 多数类 | 直接映射到 `fill-array-data` 的表 |
| `invoke-static {}, 类.xxx:()[S` + `move-result-object` | `DouDou.ﺏﺎﺵف()` | 先建「getter → 表」映射，再按 `move-result-object` 落位 |
| 本类唯一表 | 单表类 | 兜底直接用 |

漏掉 getter 这一种，`豆豆/瓜子/糯米/看球` 这几个类的字符串会一条都解不出来。

### 2.2 OLLVM 带来的两个坑

- 控制流被压成 `goto` 环 + 一串 `if-eq` 分派。**常量常在前面的块里设好、后面的块才用**，
  所以不能按基本块清空寄存器，只能做「最后一次写入」追踪，再用字符合法性过滤取错的组合。
- 参数字面量会用 `const/16 X` + `xor-int/lit16 Y` 混淆（如 `1616 ^ 1633 = 49`），
  必须做 XOR 常量折叠。
- `ۣ۟۠ۡۢۤۥۦۧۨ`（U+06DF–U+06E8，即 0-9）只是状态机 `if-eq` 的比较值，
  不是第三层加密；但作为 `parseInt` 的入参时要还原成 ASCII 数字再折叠。

> 踩过的坑：Dalvik 指令长度表里 `const/4` 是 **1** 个 code unit、`const/16` 是 **2** 个。
> 写错会把后续指令全部错位，看起来就像「方法体被加密」——这个误判卡了很久。

## 三、工具

| 文件 | 作用 |
|---|---|
| `unpack_guard.py` | **入口**：jar/guard → 内层 DEX（反扰 + inflate） |
| `decode_strings.py` | **核心**：解出 `short[] ^ key` 表编码的字符串（含 getter / XOR 折叠） |
| `site_hosts.py` | **出口**：DEX + 站点列表 → 站点域名对照表 |
| `dexstr.py` | 解析 DEX 基本结构（字符串/类型/方法/字段/类定义） |
| `resolve_sites.py` | 递归展开无参 getter，聚合每个站点能拿到的字符串 |
| `gen_rules.py` | 按 Guard 名单生成 `GenericSourceRule` JSON |
| `verify_rule.py` | 用规则实抓页面验证 |

```bash
# 1. jar -> 内层 DEX
python unpack_guard.py http.cache.jar -o inner.dex

# 2. DEX -> 全部表编码字符串
python decode_strings.py inner.dex decoded_strings.json

# 3. DEX + 配置站点列表 -> 域名表
python site_hosts.py inner.dex sites-ext-dump.json -o site_hosts.json
```

## 四、结果

- guard 容器：**完全解开**，产出与内存 dump 逐字节一致。
- 字符串：解出 **6338** 条，覆盖 **64** 个类（改进 getter 支持前是 3442/54）。
- 域名：45 个 Guard 里 **28 个**拿到域名；影视/点播类 38 个里 28 个。

典型样本：

| 站点 | 类 | 域名 |
|---|---|---|
| 立播 | `Libvio` | `www.libvio.io` |
| 比特 | `Bttwoo` | `www.bttwo.life` |
| 厂长 | `NewCz` | `czzy.xn--t75a.eu.org`、`t02.cz01.org` |
| 荐影 | `YGP` | `www.6huo.com` |
| 奥特 | `Auete` | `www.au1080.top` |
| 巴士 | `Dm84` | `dmbus.cc` |
| 多多 | `Doubao` | `www.doubaozhibo.com` |
| 海绵 | `Hmys` | `u.yyxdmn.com`、`u.gslock.com` |
| 瓜子 | `Appgz` | `api.nstpsw.com` |
| 糯米 | `Nmyswv` | `vip.wwgz.cn:5200` |
| 看球 | `Kanqiu` | `www.88kanqiu.pw` |
| 盘她/盘他 | `YpanSo` / `BpanSo` | `www.melost.cn` |

**剩下的 7 个影视站拿不到域名**：豆豆(`DouDou`)、光影/奶酪(`T4`)、热播(`AppTT`)、
视界(`App99`)、剧圈(`AppSx`)、新6V(`SixV`)。原因不是解码失败——这些类的字符串已经解出
80~295 条（搜索模板、API 路径、请求头、RSA 公钥等齐全），而是**它们本来就没有把域名
写进 DEX**：

- `T4` 的字符串里有 `'siteUrl'` 字段名，说明 baseURL 由配置的 `ext` 下发；
  但光影的 ext 解密后只有 `{"bd":[...], "...":[...]}`，不含任何 URL。
- `AppSx` 里有 `'domain'` 字段，`AppTT`/`App99` 是纯 API 站点（签名 + 时间戳 + 公钥握手），
  域名由服务端下发。

这类站点要么走「另一个 32 字符密文解码路径」，要么必须运行时取域名——属于**设计上的
更高一级防封**，不是解析器能力问题。

## 五、产物形态

```json
{
  "key": "Auete",
  "baseURL": "https://www.au1080.top",
  "mode": "html",
  "listSelector": "ul.threadlist li",
  "titleSelector": "h2 a@title",
  "posterSelector": "a.pic img@src",
  "noteSelector": "span.hdtag",
  "linkSelector": "h2 a@href",
  "searchURL": "auete4so.php?searchword={wd}&page={pg}",
  "detailTitleSelector": "h1.detail-title",
  "summarySelector": "div.message p.detail-des",
  "episodeSelector": "ul.episode-list li > a",
  "lineSelector": "div.card-header span b"
}
```

选择器语法 `css` / `css@attr` 与 `GenericSourceRule` 一致，可直接塞进 iMovie。

## 六、已验证

- **容器层**：`guard.bin → recovered.dex`，MD5 与安卓内存 dump 相同；
  `MANIFEST.MF` 独立交叉验证通过。
- **字符串层**：从 `recovered.dex` 解码的结果与从内存 dump 解码的结果逐条相同。
- **规则层**：`Auete` 抓 `https://www.au1080.top/Movie/index.html` 出 20 条，
  标题/备注/链接/海报全对，`maiketaisen_maikeguilai` 与 frida 实调插件结果一致。
- **域名可用性**：`www.melost.cn` 现返回 200，`www.au1080.top` 返回 302。

## 七、剩余工作

1. 7 个「域名由配置/服务端下发」的站点：需先解开 ext 的流密码（`DexNative.decrypt`，
   算法在 `ftyguard_v7/v8.so` 内自实现，无 AES/ChaCha 常量），或走运行时抓一次。
2. 规则只能表达**标准 HTML 采集站**。网盘类（`Pan`/`Cloud_*`）、B 站、纯 API 类
   （`AppSx`/`AppTT`/`App99`）需要专门实现。
3. 移植到 Swift：容器层与字符串层都是纯字节运算，无第三方依赖（zlib + 查表）。
4. 域名失效时需「入口页自发现」兜底：请求 baseURL → 跟随跳转 → 从页面绝对链接投票定主域。
