import SwiftUI

@MainActor struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var directURL = ""
    @State private var openAsWebPage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("YOUR LITTLE CINEMA").font(.caption2.monospaced()).tracking(3).foregroundStyle(Theme.accent)
                    Text("留一点时间，\n给喜欢的故事。")
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).lineSpacing(5)
                    Text("iMovie · 私人播放器").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.top, 10)

                VStack(alignment: .leading, spacing: 13) {
                    Label("打开播放地址", systemImage: "link").font(.headline)
                    TextField("https://… / 视频或 HLS 地址", text: $directURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("library-direct-url")
                        .padding(13).background(Theme.backdrop, in: RoundedRectangle(cornerRadius: 12))
                        .onSubmit { playDirect() }
                    Toggle("使用内置网页播放器", isOn: $openAsWebPage)
                        .font(.subheadline).accessibilityIdentifier("library-web-mode")
                    Button(action: playDirect) {
                        Label("开始播放", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("library-open")
                        .disabled(directURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 22))

                if let config = store.config {
                    if config.nativeSites.isEmpty {
                        EmptyPanel(icon: "shippingbox", title: "配置已导入，点播源需要适配", message: "共 \(config.sites.count) 个点播源，目前没有可在本机执行的来源。可在下方查看各源的兼容情况，或进入直播尝试 HTTP 频道。")
                    }
                    HStack {
                        Text("我的来源").font(.title3.bold())
                        Spacer()
                        Text("\(config.sites.count) 个").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(config.sites.sorted { $0.isNative && !$1.isNative }) { site in
                            NavigationLink { SiteView(site: site) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: site.isNative ? "rectangle.stack" : "puzzlepiece.extension")
                                        .foregroundStyle(site.isNative ? Theme.accent : Color.secondary)
                                    Text(site.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                    Spacer(minLength: 3)
                                    RuntimeLabel(runtime: site.runtime)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }.padding(15).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain).accessibilityIdentifier("source-\(site.key)")
                        }
                    }
                } else {
                    EmptyPanel(icon: "rectangle.stack.badge.plus", title: "从你的配置开始", message: "在设置中导入 TVBox 配置，查看来源兼容性；也可以直接粘贴视频地址播放。")
                    NavigationLink { SettingsView() } label: {
                        Label("导入接口配置", systemImage: "plus.circle").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }
            }.padding(20)
        }
        .background(Theme.backdrop)
        .navigationTitle("iMovie").navigationBarTitleDisplayMode(.inline)
    }

    private func playDirect() {
        do {
            let url = try HTTPAddress.parse(directURL)
            store.play(MediaLink(title: url.lastPathComponent.isEmpty ? "地址播放" : url.lastPathComponent, url: url.absoluteString, group: openAsWebPage ? "网页" : "直链", kind: openAsWebPage ? .web : .direct))
        } catch { store.error = error.localizedDescription }
    }
}

@MainActor struct SiteView: View {
    @EnvironmentObject private var store: AppStore
    let site: SourceSite
    @State private var videos: [Video] = []
    @State private var categories: [VideoCategory] = []
    @State private var search = ""
    @State private var activeSearch = ""
    @State private var category = ""
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var error: String?
    @State private var requestToken = UUID()
    private let client = TVAPIClient()

    var body: some View {
        Group {
            if !site.isNative {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        EmptyPanel(icon: "puzzlepiece.extension", title: site.runtime.title, message: site.runtime.explanation)
                        Text("来源标识").font(.headline)
                        Text(site.api).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                        Text("这个来源尚未完成本机适配。已适配的来源会标记为“本机适配·实验”。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(20)
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        HStack {
                            TextField("搜索这个来源", text: $search).submitLabel(.search)
                                .onSubmit { submitSearch() }
                                .accessibilityIdentifier("site-search-query")
                            Button(action: submitSearch) { Image(systemName: "magnifyingglass") }
                                .accessibilityLabel("搜索")
                                .accessibilityIdentifier("site-search-submit")
                        }.padding(13).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                        if !categories.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    categoryButton("全部", id: "")
                                    ForEach(categories) { item in categoryButton(item.name, id: item.id) }
                                }
                            }
                        }
                        if let error {
                            EmptyPanel(icon: "wifi.exclamationmark", title: "加载失败", message: error)
                            Button("重试") { Task { await load(reset: true) } }.buttonStyle(.bordered)
                        }
                        if !loading && error == nil && videos.isEmpty {
                            EmptyPanel(icon: "magnifyingglass", title: "暂无内容", message: "试试切换分类或更换关键词。")
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 14)], spacing: 22) {
                            ForEach(videos) { video in
                                NavigationLink { VideoDetailView(site: site, video: video) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        PosterView(url: video.poster)
                                        Text(video.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                        Text(video.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        if loading { ProgressView().padding() }
                        if !loading && page < pageCount {
                            Button("加载更多") { Task { await load(reset: false) } }.buttonStyle(.bordered)
                        }
                    }.padding(20)
                }
            }
        }
        .background(Theme.backdrop)
        .navigationTitle(site.name).navigationBarTitleDisplayMode(.inline)
        .task { if site.isNative && videos.isEmpty { await load(reset: true) } }
    }

    private func categoryButton(_ title: String, id: String) -> some View {
        Button(title) {
            category = id
            activeSearch = ""
            search = ""
            Task { await load(reset: true) }
        }
        .buttonStyle(.bordered)
        .tint(category == id ? Theme.accent : .gray)
    }

    private func submitSearch() {
        activeSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        category = ""
        Task { await load(reset: true) }
    }

    @MainActor private func load(reset: Bool) async {
        let token = UUID()
        requestToken = token
        loading = true
        error = nil
        let requestedPage = reset ? 1 : page + 1
        defer { if requestToken == token { loading = false } }
        do {
            let result = try await client.page(site: site, category: category, search: activeSearch, page: requestedPage)
            guard requestToken == token, !Task.isCancelled else { return }
            if reset { videos = result.videos }
            else {
                let ids = Set(videos.map(\.id))
                videos += result.videos.filter { !ids.contains($0.id) }
            }
            if !result.categories.isEmpty { categories = result.categories }
            page = requestedPage
            pageCount = result.pageCount
        } catch is CancellationError { }
        catch { if requestToken == token { self.error = error.localizedDescription } }
    }
}

@MainActor struct PosterView: View {
    let url: String
    var body: some View {
        Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                AsyncImage(url: HTTPAddress.optional(url)) { image in image.resizable().scaledToFill() } placeholder: {
                    ZStack { Theme.panel; Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor struct VideoDetailView: View {
    @EnvironmentObject private var store: AppStore
    let site: SourceSite
    let video: Video
    @State private var detail: Video?
    @State private var loading = false
    @State private var resolving = false
    @State private var error: String?
    private let client = TVAPIClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    PosterView(url: video.poster).frame(width: 120)
                    VStack(alignment: .leading, spacing: 12) {
                        Text((detail ?? video).title).font(.title2.bold())
                        Text((detail ?? video).note).font(.subheadline).foregroundStyle(Theme.accent)
                        Text(site.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if loading || resolving { ProgressView(resolving ? "正在获取播放地址…" : "正在加载选集…") }
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(.orange)
                    Button("重新加载") { Task { await fetchDetail() } }.buttonStyle(.bordered)
                }
                if let detail {
                    if !detail.summary.isEmpty { Text(detail.summary).font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(detail.lines) { line in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(line.name).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 10) {
                                ForEach(line.episodes) { episode in
                                    Button(episode.title) { Task { await play(episode, line: line) } }
                                        .font(.caption).frame(maxWidth: .infinity, minHeight: 35)
                                        .buttonStyle(.bordered).disabled(resolving)
                                }
                            }
                        }
                    }
                    if detail.lines.isEmpty { Text("该接口没有返回选集。\n可尝试其他来源。").foregroundStyle(.secondary) }
                }
            }.padding(20)
        }
        .background(Theme.backdrop).navigationTitle("影片详情").navigationBarTitleDisplayMode(.inline)
        .task { await fetchDetail() }
    }

    @MainActor private func fetchDetail() async {
        loading = true
        error = nil
        defer { loading = false }
        do { detail = try await client.detail(site: site, id: video.id) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    @MainActor private func play(_ episode: Episode, line: EpisodeLine) async {
        resolving = true
        defer { resolving = false }
        do {
            let link = try await client.resolve(site: site, episode: episode, flag: line.name, title: "\(video.title) · \(episode.title)")
            guard !Task.isCancelled else { return }
            store.play(link, refresh: false)
        } catch is CancellationError { }
        catch { store.error = error.localizedDescription }
    }
}
