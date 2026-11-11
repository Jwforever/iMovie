# iMovie 任务恢复摘要

更新：2026-11-11，Asia/Shanghai。继续时优先读取本文、当前源码和 `dist/build-info.json`，无需重新导入旧聊天或原始大图。

## 用户要求和执行偏好

- 开发 iPhone 独立运行的 iMovie，兼容用户的饭太硬 / TVBox 配置；不依赖 Android 设备或用户自建解析服务器。
- 交付未签名 IPA，用户自行签名；同时交付源码 ZIP、完整交付 ZIP 和校验值。
- 全部 Android 来源开放，按奥特思路走统一处理，允许逐源报错，不能以测试没通过为由隐藏来源。
- 新源沿用已有结构时应通过更新地址 / 数据规则工作；只有全新协议才需要继续开发引擎。不能把“所有来源可尝试”表述成“原 Guard 已完整兼容 / 所有线路保证播放”。
- 自主完成工作，不反复索取确认。当前没有授权额外子代理。不要修改其他项目或根工作区 Git。

## 当前版本与功能

0.4.0，build 4，iOS 16+，iPhoneOS arm64，SwiftUI / Swift / AVPlayer。

- 海报整张点击进入详情，初始只显示封面简介；选集才取址，播放器在详情页顶部替换简介。
- 视频通过 HTTP 媒体元素、命名播放器配置、奥特公开 Base64 数据、有限 iframe 递归与原站公开接口取址；播放不展示 / 执行 WKWebView。
- `AVPlayerViewController.speeds = []` 隐藏倍速，移除自绘倍速。播放器对象与会话在旋转 / 全屏过程中保留；UIKit 容器管理布局和恢复播放。
- 豆瓣公开榜单至少 7 分 / 100 人评价，按评分 / 评价人数选 6 部左右滑动轮播；点击查当前源同名作品；失败回退来源推荐。
- 搜索左栏 92 点，首项全部源；右侧按完整片名、前缀、包含、字符相关度递减排序。先展示影片，后展示错误；4 个来源持续并发；B站分类合并，未知 CSP 各条目独立。
- 关于页有介绍、版本、GitHub、`by Chris Wei`。仓库 `Jwforever/iMovie` 仍为私有。
- 图片内存 32 MB / 磁盘 120 MB / 14 天，跨页面和重启复用；片库 3 分钟、豆瓣 6 小时、合计磁盘 16 MB。设置可清理。配置 / 搜索 / 视频取址不走片库缓存。

## 通用源适配（最新重点）

`GenericSourceAdapter` 为全部未知 `csp_` 条目提供公共 HTML / JSON 浏览、搜索、详情、选集及 HTTP 取址。默认识别奥特和 MacCMS 常见结构；读取 ext JSON / 可读 Base64 JSON / 远程 JSON / 官网 URL。新类名无需加入逐源名单。

`GenericSourceRule` 支持 baseURL、auto/html/json、搜索 / 分类 / 详情 / 播放模板、CSS 选择器及请求头。配置支持 `ios` / `iMovie` 对象；设置可本机覆盖，重启和配置更新后保留；恢复默认回到最近导入配置的原规则。无 `{page}` 模板时跟随实际下一页链接。

样本：48 点播 / 6 直播；45 Android 条目涉及 37 实现。11 Android 条目用专用适配，剩余 34 全部开放通用尝试；兔小贝另有专用适配，共 12 专用条目。虎牙 / 斗鱼 2 个 drpy 条目没有完整脚本宿主。

奥特与 DM84 已有真实网站的 iOS HTTP 取址 / 嵌入播放证据。B站、兔小贝和急救限电脑端网络探测；立播受 403 限制。多数加固 / 网盘 / 签名协议未实现，只有类名无法推导域名，来源失败时可补充地址或规则。源开放不要求逐源验证通过。

## 构建与证据

- 最终构建：`42970895739` 成功，应用提交 `37d2660ef5f27c7a9d318e49bbc43d85eab2c4cc`；37 核心 + 9 UI 全部通过，0 失败 / 跳过。准确测试结果和证据见 `docs/validation.md`、`dist/build-info.json`。
- 前一通用框架构建 `42967802081` 已成功：36 核心 + 9 UI，0 失败 / 跳过。随后 `42969169687` 核心 37 通过、UI 8 通过 / 1 失败；奥特测试的大幅滚动把卡片移到固定栏下，没有进入详情。最终构建修复测试定位，通用规则、保存重启、奥特 / DM84 实际播放等复验通过。
- 本地 Python 工具 8 项、Edge 浏览器观察脚本 1 项通过。
- 最终产物路径：`dist/iMovie-0.4.0-unsigned.ipa`、`dist/iMovie-0.4.0-source.zip`、`dist/iMovie-0.4.0-delivery.zip`。若缺失，说明尚需完成最终证据下载与打包，不能声称已交付。
- 物理 iPhone、用户签名安装、AirPlay 和画中画没有实测。

## 代码入口

- `Sources/Core/GenericSourceAdapter.swift`：公共采集、规则、分页。
- `Sources/Core/Models.swift`、`ConfigDecoder.swift`、`TVAPIClient.swift`：能力识别、规则导入、路由。
- `Sources/App/SourceRulesView.swift`、`AppStore.swift`：规则界面和持久化。
- `Sources/App/LibraryView.swift`、`SearchView.swift`、`SettingsView.swift`：首页 / 详情 / 搜索 / 设置。
- `Sources/App/PlayerView.swift`、`Sources/Core/MediaResolver.swift`：稳定播放器会话与 HTTP 取址。
- `Sources/App/ImageCache.swift`、`Sources/Core/CatalogCache.swift`：缓存。
- `Tests/CoreTests/GenericSourceTests.swift`、`Tests/UITests/PlaybackUITests.swift`：通用框架与完整流程。
- `docs/generic-source-rules.md`：用户规则示例；`docs/source-port-status.json`：逐源开放及限制。

Windows 工作目录：`C:/Users/junti/Documents/ChatGPT/MyWorkSpace/iMovie`，无 Xcode / Swift。云端 Xcode 16.4 / iOS SDK 18.5，macOS Actions 编译。

辅助脚本在 `../artifacts/imovie-development/`：

```text
cloud_build.py upload
cloud_build.py dispatch
cloud_build.py logs RUN_ID
download_evidence.py RUN_ID
package_delivery.py RUN_ID BUILD_SHA
write_port_status.py
```

上传仅使用独立的 `cloud-checkout/`，凭证从已有 Git 凭证助手读入内存，禁止输出或落盘令牌。打包器要求成功构建、测试无失败、IPA 校验及应用源码与构建一致；构建后仅允许 README / docs 更新。

## 避免历史请求失败

旧聊天 `01a1c434-7adc-7870-8b24-b97336258274` 的历史日志含约 5.7 MB 图片输出；此前两次模型请求约 6.2 MB，在路由模型前传输超时。短请求可用，不能简单判定模型不可用。

不要重新载入整个旧聊天或原始大截图。用文字摘要继续，视觉 QA 生成约 1080 像素宽、几十 KB 的 JPEG 联系图后读取。原始截图保留在 `dist/evidence/RUN_ID` 与 `dist/screenshots/0.4.0/`。
