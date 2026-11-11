# 通用来源规则

iMovie 0.4.0 对全部 Android CSP 来源开放尝试。配置更新后，新的 `csp_` 类名自动进入通用适配，无需先加入 App 的逐源名单。已实现的专用适配仍优先使用；为来源保存规则后，该来源改走通用流程。

## 不重新编译即可修改的内容

- 官网 / JSON 接口地址和请求头。
- 搜索、分类、详情、播放页地址模板。
- HTML 列表、标题、海报、简介、分类、线路和选集的 CSS 选择器。
- 读取方式：`auto`、`html` 或 `json`。

通用 HTML 默认识别奥特、MacCMS 常见 stui / myui / module / public / fed 结构。JSON 默认识别 `class`、`list`、`vod_id`、`vod_name`、`vod_play_from`、`vod_play_url` 等采集字段。网页取址读取明确的媒体元素、播放器公开配置与有限层数 iframe，然后交给 AVPlayer。

## 在 App 中修改

1. 「设置 → 来源地址 / 通用规则」选择来源；也可以从该源加载失败页进入规则。
2. 填写官网或完整 JSON API 地址，选择读取方式。
3. 常见结构可直接保存；不匹配时在高级 JSON 中补充模板和 CSS 选择器。
4. 点击「保存并使用」。首页选中源会重新加载；规则保存在本机，重启和重新导入配置后继续生效。
5. 「恢复配置默认规则」删除本机覆盖，恢复最近导入配置携带的规则或自动识别方式。

高级 JSON 解码需要 `baseURL`；保存时上方地址栏和读取方式优先。示例中的 `example.test` 仅表示规则格式，需要换成实际来源。

```json
{
  "baseURL": "https://example.test/",
  "mode": "html",
  "searchURL": "/find?wd={query}&page={page}",
  "categoryURL": "/type/{category}?page={page}",
  "listSelector": ".stui-vodlist > li",
  "titleSelector": "h4 a",
  "linkSelector": "a[href]",
  "posterSelector": "img",
  "noteSelector": ".pic-text",
  "categorySelector": "nav a[href]",
  "detailTitleSelector": "h1",
  "summarySelector": ".vod_content",
  "lineSelector": ".stui-content__playlist",
  "episodeSelector": "a[href]",
  "headers": {
    "Referer": "https://example.test/"
  }
}
```

分类默认为导航链接的完整 URL，因此常见页面无需设置 `categoryURL`。只有分类 ID 本身适合模板时才填写该字段。未配置含 `{page}` 的模板时，通用引擎会跟随页面真实的“下一页”链接，单次最多跟随 49 次；更多页数请设置模板。

JSON 采集接口的最小规则：

```json
{
  "baseURL": "https://example.test/api.php/provide/vod/",
  "mode": "json"
}
```

默认请求参数包括 `ac=detail`、`pg`、搜索词 `wd`、分类 `t` 和详情 `ids`。自定义地址模板会优先使用，也能用于 JSON 返回内容；字段格式仍需符合上述采集结构。

## 让配置直接携带规则

每个 `sites` 条目可增加 `ios` 或 `iMovie` 对象。本机覆盖规则优先于导入配置，配置规则优先于自动识别。

```json
{
  "sites": [
    {
      "key": "future-source",
      "name": "新来源",
      "type": 3,
      "api": "csp_FutureGuard",
      "searchable": 1,
      "ios": {
        "baseURL": "https://example.test/",
        "mode": "html",
        "searchURL": "/search?wd={query}&page={page}"
      }
    }
  ]
}
```

也会尝试从 `ext` 的 JSON、可读 Base64 JSON 或远程 `.json` 中读取 `baseURL` / `siteUrl` / `homeUrl` / `host`，支持嵌套的 `ios` / `iMovie` 对象。`ext` 若直接给出可读取的官网 URL，也可自动使用。只有 Android 类名或不可读加固数据时，应用无法由类名推导出真实域名，会提示补充来源地址。

| 占位符 | 内容 |
| --- | --- |
| `{query}` | 已做 URL 查询编码的搜索词 |
| `{page}` | 从 1 开始的页码 |
| `{category}` | 来源返回的分类 ID，HTML 默认通常为完整 URL |
| `{id}` | 影片 ID；在 `playerURL` 中为选集原始值 |
| `{url}` | 对选集值做 URL 查询编码，用于解析地址参数 |

`detailURL` 默认沿用列表中的详情链接；`playerURL` 默认沿用选集链接。返回媒体地址后走同一 HTTP 提取与系统播放流程。配置关闭搜索的来源仍遵循 `searchable: 0`。

## 仍需要扩展引擎的情况

TVBox / OK 影视统一了 Spider 调用接口，各插件仍负责站点规则。iMovie 提供自己的公共采集流程，不执行原 Android DEX / ELF / Guard 包，也没有完整 drpy 宿主。

新源沿用已支持的 HTML / JSON 和公开播放器结构，改地址或数据规则即可尝试；全新的加密签名、专有 JSON 字段协议、网盘登录、磁力、会员或 DRM 需要对应能力。全部 Android 条目均已开放，遇到这些情况会报错，不以逐源测试结果决定是否开放，也不承诺每条线路都能播放。
