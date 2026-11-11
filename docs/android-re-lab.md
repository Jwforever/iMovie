# Android 逆向实验环境（饭太硬 jar 解密取证）

> 目的：在不依赖外部 Android 设备的前提下，用本机模拟器复现「OK影视 导入饭太硬配置 →
> 下载 spider jar → 解密 `ftyshinidie.guard` → 加载内部 DEX」的完整链路，
> 为 iOS 端「每次导入自己解 jar」提供明文样本与算法取证。

## 一、环境（本机 Windows 11，已装好）

| 组件 | 版本 / 路径 |
| --- | --- |
| Android SDK | `C:/Users/junti/AppData/Local/Android/Sdk`（本机已有） |
| Emulator | 36.1.9.0 |
| 加速 | WHPX 10.0.26200，`emulator -accel-check` → usable |
| AVD | `fty_x86`，镜像 `system-images;android-30;google_apis;x86_64` |
| 关键能力 | 该镜像 `ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi`，自带 **ARM64 二进制翻译**（`ndk_translation 0.2.2`） |
| Frida | server 17.26.2 android-x86_64 + 本机 `frida`/`frida-tools`/`frida-dexdump` |
| 工作目录 | `C:/Users/junti/AppData/Local/Temp/imovie_re/` |

**重要**：不要选 `arm64-v8a` 系统镜像。官方 emulator 在 x86_64 主机上会直接
`PANIC: Avd's CPU Architecture 'arm64' is not supported by the QEMU2 emulator on x86_64 host`。
正确做法是 x86_64 镜像 + 自带 ARM64 翻译，既有 WHPX 硬件加速又能加载 AArch64 `.so`。

## 二、启动命令

```bash
SDK=/c/Users/junti/AppData/Local/Android/Sdk
export ANDROID_SDK_ROOT='C:\Users\junti\AppData\Local\Android\Sdk'
export ANDROID_HOME="$ANDROID_SDK_ROOT"
# 创建（config.ini 里 hw.ramSize 改 2048M）
echo no | "$SDK/cmdline-tools/latest/bin/avdmanager.bat" create avd \
  -n fty_x86 -k "system-images;android-30;google_apis;x86_64" --force
# 启动：partition-size 上限 2047，用 2000；-no-accel 不要加
"$SDK/emulator/emulator.exe" -avd fty_x86 -no-window -no-audio \
  -gpu swiftshader_indirect -memory 2048 -partition-size 2000 -no-snapshot -verbose
```

`git bash` 会把 `/data/...` 转成 Windows 路径，`adb push` 目标要写 `//data/...`，
或设置 `MSYS_NO_PATHCONVERT=1`。

## 三、注入配置（绕过 UI）

配置存在 Room 数据库 `/data/data/com.fongmi.android.tv/databases/tv` 的 `Config` 表：
`CREATE TABLE Config (id, type, time, url, json, name, logo, home, parse)`。

```bash
ADB=$SDK/platform-tools/adb.exe; DEV=emulator-5556
$ADB -s $DEV root
$ADB -s $DEV push ok.apk //data/local/tmp/ && $ADB -s $DEV install -r ok.apk
$ADB -s $DEV push frida-server-x86_64 //data/local/tmp/fsrv
$ADB -s $DEV shell 'chmod 755 /data/local/tmp/fsrv; nohup /data/local/tmp/fsrv -D >/dev/null 2>&1 &'
$ADB -s $DEV forward tcp:27042 tcp:27042
# 写配置（type=0 点播，home=1 当前启用）
$ADB -s $DEV shell "sqlite3 /data/data/com.fongmi.android.tv/databases/tv \
  \"insert into Config (type,time,url,json,name,home) values (0,<ms>,'http://www.饭太硬.cc/tv','','饭太硬',1);\""
$ADB -s $DEV shell 'monkey -p com.fongmi.android.tv -c android.intent.category.LAUNCHER 1'
```

验证成功的 logcat 标志：
`ndk_translation: Initialized NDK translation (aarch64)` →
`Created dir .../cache/jar` → `Create: ....jar` → **`TV-SpiderDebug: 自定义爬虫代码加载成功！`**

## 四、取证结果

1. `cache/.ftyfnw*` = 从 jar assets 提取出的 `ftyguard_v8.so`（102440 B，AArch64 ELF）。
2. `cache/jar/<md5>.jar` = 下载到的饭太硬 spider（1411181 B）。
3. 内部 DEX 是**内存加载、用完即删**，落盘找不到；用 `frida-dexdump` 从进程内存导出：
   ```bash
   frida-dexdump -H 127.0.0.1:27042 -p <pid> -o ./dexdump -d
   ```
   **`classes03.dex` = 2,728,036 B (0x29a064)**，与 guard ZIP 条目
   `classes.dex` 的 uncompressed size 完全一致 → 这就是解密后的内部 DEX（明文）。
4. 明文 DEX 含 `Auete`/`Auete$1` 类、奥特的选择器
   `auete4so.php?searchword=`、`h1.detail-title`、`ul.episode-list li > a`，
   12762 条字符串、16 个清洗后的真实主机名，见 `inner-domains.json`。
5. **奥特域名不在明文字符串池里**——由 `DexNative.decrypt()` / `getLoader()`
   在运行时产生。已 hook 到真实调用：配置里那段加密 `ext`
   （`rfOZwatJWBBQ8sd...`）被 `decrypt()` 解成 `{"bd":[...]}` 网盘分享 ID 列表。

## 五、Java 侧解密入口（外层 DEX 反编译）

```java
// DexNative.java
static { /* 从 assets 拷 ftyguard_v8.so / v7.so 到 cache 并 System.load() */ }
public static native Object  getLoader(Object obj);   // 解密 guard 的总入口
public static native Object  getSpider(Object, String);
public static native String  decrypt(String);  encrypt(String);
public static native int[]   calcResult(int[]);
public static native String  noxSign(String,String,String);
// Init.init(Context) → (DexClassLoader) DexNative.getLoader(context)
// AueteGuard extends BaseSpiderGuard → 所有方法转发给内部 DEX 的真爬虫
```

`.so` 为 stripped + OLLVM（`datadiv_decode*`）。v8 是 AArch64，
`JNI_OnLoad@0x5184`，字符串解密函数 `.datadiv_decode6689084346758261032@0x5734`
（3097 条指令，Unicorn 可完整模拟）。JNI 方法名在文件里加密，需模拟 init_array 或
hook `RegisterNatives` 才能定位 `getLoader` 地址。

## 六、下一步

用明密文对（`guard.bin` 的 `classes.dex` 条目 vs `inner-plaintext.dex`）反推变换，
或继续静态逆 `getLoader`，目标是写出纯 Swift 的解密实现：
App 每次导入配置 → 下载 jar → 自己解 guard → zlib 解出 DEX → 读常量 → 采集。
不执行 DEX、不加载 ELF，纯数据变换，iOS 沙箱允许。
