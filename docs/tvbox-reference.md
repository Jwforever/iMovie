# TVBox / OK 影视实现参考

核查日期：2026-11-11。实现目标是 iPhone 本机运行，并参考开源播放器已形成的功能划分和界面组织。

## 核查的版本

- [OK 影视 okcaptain/TV](https://github.com/okcaptain/TV/tree/2362d6845f4b91b7846b5cd77f947cd5884e0894)，提交 `2362d6845f4b91b7846b5cd77f947cd5884e0894`，GPL-3.0。
- [FongMi/TV](https://github.com/FongMi/TV/tree/5b41d9da52e1573ab9b5d399d656d11eb9fe8557)，提交 `5b41d9da52e1573ab9b5d399d656d11eb9fe8557`，GPL-3.0。

直接阅读了手机端 `VodFragment`、分类页、`SiteViewModel`、`SiteApi`、Spider 接口和 JAR 加载器。iMovie 的 SwiftUI 和采集代码独立编写，没有把这些 Java / XML 文件作为应用源码或资源打包。

## 本轮落实的行为

| 开源实现的行为 | iMovie 0.3.0 中的实现 |
| --- | --- |
| `getHome` / `setHome` 保存当前来源 | 本地保存 `homeSourceKey`；首页直接显示选中来源；切源后更新内容 |
| 手机端来源标题、分类栏与内容页 | 顶栏切源、横向分类、推荐卡片和海报网格 |
| 首页、历史记录入口 | 首页最近播放横栏，支持重新取址后继续播放 |
| `homeContent` 与 `homeVideoContent` 区分分类和推荐 | JSON 接口先读首页分类 / 推荐，分类接口作为无推荐时的内容回退；保留分类栏 |
| `categoryContent` / `detailContent` / `playerContent` | 按源路由分类、详情选集和本机网页 / 系统播放 |
| 来源独立异步搜索 | 最多 4 个请求并发、完成即显示、持续补充后续站点；失败可单独重试 |

同一 B站实现下的多个分类条目搜索相同公开接口，因此合并查询并显示覆盖的分类条目数。其余不同 JSON API 不因显示名称相同就合并。

## Android 源为何仍需逐项适配

[Spider 接口](https://github.com/FongMi/TV/blob/5b41d9da52e1573ab9b5d399d656d11eb9fe8557/catvod/src/main/java/com/github/catvod/crawler/Spider.java) 明确区分首页、分类、详情、搜索、播放。主应用提供这些入口，实际站点逻辑由配置指定的 Spider 实现。

[JarLoader](https://github.com/FongMi/TV/blob/5b41d9da52e1573ab9b5d399d656d11eb9fe8557/app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java) 使用 Android 的 `DexClassLoader` 与运行时。饭太硬当前的 Guard 插件不是这些播放器主仓库里自带的通用采集规则；读取开源播放器不能自动得到配置内全部加固爬虫的 iOS 实现。

本轮补充 `csp_AueteGuard` / `csp_Auete` 的 Swift 适配。旧规则中的 `auete2so.php` 已失效，当前站点公开表单为 `auete4so.php`，海报列表、详情、选集也换了结构。适配依据站点当前公开页面，由 iPhone 读取播放页明确提供的公开 HLS；未找到时使用本机 WKWebView 播放。

站点域名和访问限制会变化。立播旧域名和发布页指向的现行域名在本轮 macOS 探测中返回 HTTP 403；厂长多个入口也返回 403，不将它们记为已验证可用。
