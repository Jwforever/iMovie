# 当前验证状态

检查日期：2026-11-10，亚洲 / 上海。

| 检查 | 结果 |
| --- | --- |
| 用户提供的配置地址 | HTTP 200，成功解码图片封装的 Base64 JSONC |
| 来源数量 | 48 个点播源，45 个 Android 爬虫、3 个 JavaScript 爬虫；6 个直播列表 |
| 爬虫包校验 | MD5 与配置一致；归档内确有 classes.dex 与 Android ARM32 / ARM64 ELF 库 |
| Python 工具行为测试 | 8 项通过：封装解码、注释与转义、Base64、域名规范化、JSONP、公开页面解析、拒绝伪应用、拒绝模拟器应用 |
| Swift 源码语法 | 15 个 Swift 文件经 tree-sitter-swift 检查，无语法错误；这不能替代 Swift 编译器类型检查 |
| 构建脚本 | bash -n 语法检查通过 |
| 项目配置 / workflow | YAML 可解析；所引用资源路径存在 |
| Info.plist / 隐私清单 | plist 可解析 |
| Swift 单元测试 | 已编写 14 项，当前环境无 Swift 工具链，尚未执行 |
| Xcode 真机构建 | 未运行；需要 macOS、完整 Xcode 与 Apple SDK |
| IPA | 尚未生成，没有用源码或模拟器程序冒充 IPA |
| 真机播放、AirPlay、画中画、断点恢复 | 未实测 |
| 饭太硬 Android 点播 | 45 个 Guard 插件尚未移植；开发方向为 iPhone 本机适配，不要求用户准备 Android 设备 |
| drpy 来源 | 完整兼容宿主尚未实现；其中兔小贝已另写独立 Swift 适配样例，不执行原 drpy |
| 本机来源可行性实测 | 无 Android / 自建解析服务器，直接读取分类 30 项、搜索 2 项、公开播放地址，MP4 样本返回 206 / ftyp；仅证明 HTTP 链路 |
| 名称 | 目录、界面、Bundle Display Name、Swift package、构建 target 和 IPA 文件名已改为 iMovie |

源码中的播放器、收藏、记录、直播和 JSON 点播适配需要在 Xcode 构建后进行真机验证。接口成功解码与影片成功播放是两个不同的验证阶段。
