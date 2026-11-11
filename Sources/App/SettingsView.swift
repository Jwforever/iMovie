import SwiftUI

@MainActor struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var cacheBytes = 0
    @State private var catalogBytes = 0
    @State private var clearingCache = false

    var body: some View {
        Form {
            Section {
                TextField("接口配置地址", text: $store.configURL, axis: .vertical)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("config-url")
                Button { Task { await store.importConfig() } } label: {
                    HStack {
                        Label(store.importing ? "正在导入…" : "导入 / 更新配置", systemImage: "arrow.down.circle")
                        Spacer()
                        if store.importing { ProgressView() }
                    }
                }.disabled(store.importing).accessibilityIdentifier("config-import")
            } header: { Text("TVBox 接口") } footer: {
                Text("已填入你提供的饭太硬地址。点击导入后才会连接；支持图片封装、Base64 和带注释的 JSON 配置。")
            }
            if let config = store.config {
                Section("兼容情况") {
                    LabeledContent("点播来源", value: "\(config.sites.count)")
                    LabeledContent("插件解析", value: "\(config.sites.filter { $0.isPlugin }.count)")
                    LabeledContent("JSON 接口", value: "\(config.sites.filter { $0.runtime == .jsonAPI }.count)")
                    LabeledContent("脚本源（未支持）", value: "\(config.sites.filter { $0.runtime == .javascript }.count)")
                    LabeledContent("直播列表", value: "\(config.lives.count)")
                    LabeledContent("更新于", value: config.importedAt.formatted(date: .abbreviated, time: .shortened))
                    NavigationLink("来源地址 / 通用规则") { SourceRulesView() }.accessibilityIdentifier("settings-source-rules")
                    NavigationLink("插件解释器（实验）") { PluginLabView() }.accessibilityIdentifier("settings-plugin-lab")
                    Text("插件源不执行安卓代码：应用在设备内解开配置指定的 spider 包，从插件里读出站点域名与选择器，再按网页规则采集。域名变化只需重新导入配置，不用重装 App。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("播放器") {
                Label("详情页内播放 · AirPlay · 画中画", systemImage: "play.rectangle")
                    .font(.subheadline)
                Text("支持 AVPlayer 可解码的格式，通常包括 HLS、MP4。部分 TS、MKV、网页链接及特殊音视频编码需要额外适配。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("缓存") {
                LabeledContent("图片磁盘缓存", value: ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                LabeledContent("片库与推荐缓存", value: ByteCountFormatter.string(fromByteCount: Int64(catalogBytes), countStyle: .file))
                Button(clearingCache ? "正在清理…" : "清理缓存") {
                    clearingCache = true
                    Task {
                        await ImageCache.shared.clear()
                        await CatalogCache.shared.clear()
                        cacheBytes = await ImageCache.shared.diskBytes()
                        catalogBytes = await CatalogCache.shared.diskBytes()
                        clearingCache = false
                    }
                }.disabled(clearingCache).accessibilityIdentifier("clear-image-cache")
                Text("图片缓存最多 120 MB，14 天更新；片库缓存 3 分钟，豆瓣推荐缓存 6 小时，合计最多 16 MB。搜索、配置导入和播放取址实时请求。清理不会删除收藏或播放记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("iMovie") {
                Text("收藏和播放记录保存在本机。配置和媒体由你提供，应用不附带影片库。")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink { AboutView() } label: { Label("关于 iMovie", systemImage: "info.circle") }
                    .accessibilityIdentifier("settings-about")
                NavigationLink("开源组件许可") {
                    ScrollView {
                        Text(Self.notices).font(.caption.monospaced()).textSelection(.enabled).padding(20)
                    }.navigationTitle("开源组件许可")
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.backdrop)
        .navigationTitle("设置")
        .task {
            cacheBytes = await ImageCache.shared.diskBytes()
            catalogBytes = await CatalogCache.shared.diskBytes()
        }
    }

    private static var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "SwiftSoup · MIT License" }
        return text
    }
}

@MainActor struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 64)).foregroundStyle(Theme.accent)
                    Text("iMovie").font(.largeTitle.bold())
                    Text("在你的设备上，发现与播放喜欢的内容。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("by Chris Wei").font(.headline).accessibilityIdentifier("about-developer")
                }.frame(maxWidth: .infinity).padding(.vertical, 22)
            }
            Section("软件介绍") {
                Text("iMovie 是为 iPhone 和 iPad 开发的媒体播放器，支持导入 TVBox 配置、浏览分类、聚合搜索、豆瓣高分推荐、选集播放、收藏与播放记录。")
                Text("来源请求与视频链接提取在设备内完成，使用 AVPlayer 播放，无需 Android 设备或自建解析服务。不同来源的可用性取决于网站、网络及适配情况。")
                    .foregroundStyle(.secondary)
            }
            Section("项目信息") {
                LabeledContent("版本", value: version)
                LabeledContent("开发者", value: "Chris Wei")
                Link(destination: URL(string: "https://github.com/Jwforever/iMovie")!) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("GitHub 项目", systemImage: "link")
                        Text("github.com/Jwforever/iMovie").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("about-github")
            }
        }.scrollContentBackground(.hidden).background(Theme.backdrop)
            .navigationTitle("关于 iMovie").navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor struct CollectionView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection = 0
    @State private var confirmingClear = false

    var body: some View {
        List {
            Picker("查看", selection: $selection) {
                Text("收藏").tag(0)
                Text("播放记录").tag(1)
            }.pickerStyle(.segmented).listRowBackground(Color.clear)

            if selection == 0 {
                if store.favorites.isEmpty {
                    Text("播放页或频道列表中的书签按钮，可以把喜欢的内容留在这里。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(store.favorites) { media in MediaRow(media: media) }
            } else {
                if store.history.isEmpty {
                    Text("开始播放后，这里会显示最近观看内容。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(store.history) { record in
                    MediaRow(media: record.media, subtitle: record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }.onDelete(perform: store.deleteHistory)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.backdrop)
        .navigationTitle("我的")
        .toolbar {
            if selection == 1 && !store.history.isEmpty {
                Button("清空") { confirmingClear = true }
            }
        }
        .confirmationDialog("清空本机播放记录？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空记录", role: .destructive) { store.clearHistory() }
        }
    }
}
