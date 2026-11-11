import SwiftUI

@MainActor struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var choosingSource = false
    @State private var openingLink = false
    @State private var queuedMedia: MediaLink?

    var body: some View {
        Group {
            if let site = store.homeSource {
                SiteView(site: site, embedded: true).id(site)
            } else {
                VStack(spacing: 22) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 64, weight: .light)).foregroundStyle(Theme.accent)
                    Text("把喜欢的故事，放上首页").font(.title2.bold())
                    Text("导入你的接口，选择点播来源。\n分类、推荐和最近播放会出现在这里。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    NavigationLink { SettingsView() } label: {
                        Label("导入接口配置", systemImage: "plus.circle.fill").padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent)
                    Button("打开播放地址") { openingLink = true }.foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            }
        }
        .background(Theme.backdrop)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { choosingSource = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.accent)
                        Text(store.homeSource.map { Theme.sourceName($0.name) } ?? "iMovie")
                            .font(.headline).foregroundStyle(.primary)
                        Image(systemName: "chevron.down").font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                }.accessibilityLabel("切换点播源").accessibilityIdentifier("home-source-picker")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { openingLink = true } label: { Image(systemName: "link") }
                    .accessibilityLabel("打开播放地址").accessibilityIdentifier("home-open-link")
            }
        }
        .sheet(isPresented: $choosingSource) { SourcePickerView().environmentObject(store) }
        .sheet(isPresented: $openingLink, onDismiss: {
            if let media = queuedMedia { queuedMedia = nil; store.play(media) }
        }) {
            DirectLinkView { media in queuedMedia = media; openingLink = false }
                .environmentObject(store)
        }
    }
}

@MainActor struct SourcePickerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var probing = false

    private var sites: [SourceSite] {
        let filtered = (store.config?.sites ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        // 排序：默认源固定第一；其余按最近一次真实拉取结果，出过片的在前，
        // 没测过的居中，失败的沉底；同分保持配置顺序。
        return filtered.enumerated().sorted { lhs, rhs in
            let leftDefault = lhs.element.key == store.homeSource?.key
            let rightDefault = rhs.element.key == store.homeSource?.key
            if leftDefault != rightDefault { return leftDefault }
            let left = store.rank(of: lhs.element), right = store.rank(of: rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("插件来源 · 本机解析") {
                    ForEach(sites.filter { $0.isPlugin }) { sourceRow($0) }
                }
                if sites.contains(where: { $0.runtime == .jsonAPI }) {
                    Section("JSON 接口") { ForEach(sites.filter { $0.runtime == .jsonAPI }) { sourceRow($0) } }
                }
                if sites.contains(where: { !$0.isNative }) {
                    Section("其他来源") { ForEach(sites.filter { !$0.isNative }) { sourceRow($0) } }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.backdrop)
            .searchable(text: $filter, prompt: "查找点播来源")
            .navigationTitle("选择点播源").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await probeUntested() }
        }
    }

    /// 首次打开时把还没试过的来源各拉一次首屏，结果写进 health，
    /// 列表随即按"能用的在前"自己重排。
    private func probeUntested() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }
        let targets = (store.config?.sites ?? []).filter { $0.isNative && store.health[$0.key] == nil }
        var index = 0
        while index < targets.count {
            if Task.isCancelled { break }
            let slice = Array(targets[index..<min(index + 4, targets.count)])
            await withTaskGroup(of: Void.self) { group in
                for site in slice { group.addTask { await store.probe(site) } }
            }
            index += 4
        }
    }

    private func sourceRow(_ site: SourceSite) -> some View {
        Button {
            store.selectHomeSource(site)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(site.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(site.isNative ? (site.searchable ? "分类 · 搜索 · 选集" : "分类 · 选集") : site.runtime.title)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let health = store.health[site.key] {
                    Image(systemName: health.ok && health.items > 0 ? "checkmark.seal.fill"
                          : (health.ok ? "circle.dashed" : "exclamationmark.triangle.fill"))
                        .font(.caption)
                        .foregroundStyle(health.ok && health.items > 0 ? Theme.accent
                                         : (health.ok ? Color.secondary : Color.orange))
                        .accessibilityLabel(health.ok && health.items > 0 ? "上次有内容" : "上次没有内容")
                }
                if store.homeSource?.id == site.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                else if !site.isNative { Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary) }
            }.padding(.vertical, 5)
        }.accessibilityIdentifier("source-\(site.key)")
    }
}

@MainActor struct DirectLinkView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var directURL = ""
    @State private var openAsWebPage = false
    var onPlay: (MediaLink) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("视频或网页地址") {
                    TextField("https://… / 视频或 HLS 地址", text: $directURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("library-direct-url")
                        .onSubmit { playDirect() }
                    Toggle("从网页地址提取视频链接", isOn: $openAsWebPage)
                        .font(.subheadline).accessibilityIdentifier("library-web-mode")
                    Button(action: playDirect) {
                        Label("开始播放", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("library-open")
                        .disabled(directURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.scrollContentBackground(.hidden).background(Theme.backdrop)
                .navigationTitle("打开播放地址").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func playDirect() {
        do {
            let url = try HTTPAddress.parse(directURL)
            let media = MediaLink(title: url.lastPathComponent.isEmpty ? "地址播放" : url.lastPathComponent, url: url.absoluteString, group: openAsWebPage ? "网页" : "直链", kind: openAsWebPage ? .web : .direct)
            onPlay(media)
        } catch { store.error = error.localizedDescription }
    }
}

@MainActor struct SiteView: View {
    @EnvironmentObject private var store: AppStore
    let site: SourceSite
    var embedded = false
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
    @State private var verifyingSource = false
    @State private var verifyURL: URL?
    private let client = TVAPIClient()
    private var isHome: Bool { category.isEmpty && activeSearch.isEmpty }

    var body: some View {
        Group {
            if !site.isNative {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        EmptyPanel(icon: "puzzlepiece.extension", title: site.runtime.title, message: site.runtime.explanation)
                        Text("来源标识").font(.headline)
                        Text(site.api).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                        Text("这个来源没有可用的解析方式。插件源会现场解开配置指定的 spider 包；脚本源暂时没有运行时。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(20)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22, pinnedViews: [.sectionHeaders]) {
                      Section {
                        if isHome { recentSection }
                        HStack {
                            Text(activeSearch.isEmpty ? (isHome ? "热播推荐" : (categories.first { $0.id == category }?.name ?? "全部内容")) : "搜索结果")
                                .font(.title3.bold())
                            Spacer()
                            Text(isHome ? "来源首页" : "\(videos.count) 部").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("home-content-heading")
                        if let error {
                            EmptyPanel(icon: "wifi.exclamationmark", title: "加载失败", message: error)
                            if site.isPlugin {
                                NavigationLink("来源地址 / 规则") { SourceRuleEditor(site: site) }.buttonStyle(.borderedProminent)
                                Button("在网页中验证后重试") { openVerification() }
                                    .buttonStyle(.borderedProminent).accessibilityIdentifier("source-verify")
                            }
                            Button("重试") { Task { await load(reset: true) } }.buttonStyle(.bordered)
                        }
                        if !loading && error == nil && videos.isEmpty {
                            EmptyPanel(icon: "magnifyingglass", title: "暂无内容", message: "试试切换分类或更换关键词。")
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 20) {
                            ForEach(videos) { video in
                                NavigationLink { VideoDetailView(site: site, video: video) } label: {
                                    VideoPosterCard(video: video).contentShape(Rectangle())
                                }
                                    .buttonStyle(.plain).accessibilityIdentifier("video-card-\(video.id)")
                            }
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(25) }
                        if !loading && page < pageCount {
                            Button("加载更多") { Task { await load(reset: false) } }
                                .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                      } header: {
                       VStack(spacing: 14) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("在\(Theme.sourceName(site.name))搜索", text: $search).submitLabel(.search)
                                .onSubmit { submitSearch() }
                                .accessibilityIdentifier("site-search-query")
                            if !search.isEmpty { Button { search = ""; submitSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
                            Button("搜索", action: submitSearch).font(.subheadline.weight(.medium))
                                .accessibilityLabel("搜索")
                                .accessibilityIdentifier("site-search-submit")
                        }.padding(.horizontal, 14).padding(.vertical, 12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 22) {
                                    categoryButton("推荐", id: "")
                                    ForEach(categories) { item in categoryButton(item.name, id: item.id) }
                                }
                            }
                       }.padding(.top, 10).padding(.bottom, 8).background(Theme.backdrop)
                      }
                    }.padding(.horizontal, 18).padding(.bottom, 24)
                }
                .refreshable { await load(reset: true) }
            }
        }
        .background(Theme.backdrop)
        .navigationTitle(embedded ? "" : Theme.sourceName(site.name)).navigationBarTitleDisplayMode(.inline)
        .task { if site.isNative && videos.isEmpty { await load(reset: true) } }
        .sheet(isPresented: $verifyingSource, onDismiss: { Task { await load(reset: true) } }) {
            if let verifyURL { SourceVerificationView(url: verifyURL) }
        }
    }

    private func openVerification() {
        Task {
            if let rule = try? await GenericSourceAdapter(site: site).rule(),
               let url = HTTPAddress.optional(rule.baseURL) {
                verifyURL = url
                verifyingSource = true
            } else {
                store.error = "还没有解出这个来源的网站地址，可以先在“来源规则”里填写。"
            }
        }
    }

    private func categoryButton(_ title: String, id: String) -> some View {
        Button {
            category = id
            activeSearch = ""
            search = ""
            Task { await load(reset: true) }
        } label: {
            VStack(spacing: 8) {
                Text(title).font(.system(size: 16, weight: category == id ? .bold : .medium))
                    .foregroundStyle(category == id ? Color.primary : Color.secondary)
                Capsule().fill(category == id ? Theme.accent : Color.clear).frame(height: 3)
            }.fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(.plain).accessibilityIdentifier("category-\(id.isEmpty ? "home" : id)")
    }

    @ViewBuilder private var recentSection: some View {
        if !store.history.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("最近播放").font(.title3.bold())
                    Spacer()
                    NavigationLink { CollectionView() } label: { Text("全部记录").font(.caption).foregroundStyle(.secondary) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(store.history.prefix(10))) { record in
                            Button { store.play(record.media) } label: {
                                HStack(spacing: 11) {
                                    CachedPosterImage(url: HTTPAddress.optional(record.media.poster ?? ""))
                                        .frame(width: 48, height: 48).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(record.media.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                                        Text(record.position > 0 ? "看到 \(Int(record.position) / 60):\(String(format: "%02d", Int(record.position) % 60)) · 继续播放" : "继续播放")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(width: 230, alignment: .leading).padding(15)
                                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain).accessibilityIdentifier("recent-\(record.id)")
                        }
                    }
                }
            }.accessibilityIdentifier("home-recent")
        }
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
        if reset { videos = []; pageCount = 1 }
        let requestedPage = reset ? 1 : page + 1
        defer { if requestToken == token { loading = false } }
        do {
            let result: VideoPage
            if !activeSearch.isEmpty {
                let matches = try await client.search(site: site, query: activeSearch)
                result = VideoPage(categories: [], videos: matches, page: 1, pageCount: 1)
            } else {
                result = try await client.page(site: site, category: category, page: requestedPage)
            }
            guard requestToken == token, !Task.isCancelled else { return }
            if reset { videos = result.videos }
            else {
                let ids = Set(videos.map(\.id))
                videos += result.videos.filter { !ids.contains($0.id) }
            }
            if !result.categories.isEmpty { categories = result.categories }
            page = requestedPage
            pageCount = result.pageCount
            store.recordHealth(site.key, ok: true, items: videos.count)
        } catch is CancellationError { }
        catch {
            if requestToken == token {
                self.error = error.localizedDescription
                store.recordHealth(site.key, ok: false, items: 0)
            }
        }
    }
}

@MainActor struct VideoPosterCard: View {
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PosterView(url: video.poster)
                .overlay(alignment: .bottomTrailing) {
                    if !video.note.isEmpty {
                        Text(video.note).font(.system(size: 10, weight: .medium)).lineLimit(1).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5)).padding(6)
                    }
                }
            Text(video.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                .frame(height: 34, alignment: .topLeading)
        }
        .contentShape(Rectangle())
    }
}

@MainActor struct PosterView: View {
    let url: String
    var body: some View {
        Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    CachedPosterImage(url: HTTPAddress.optional(url))
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
    }
}

@MainActor struct VideoDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = PlaybackController()
    let site: SourceSite
    let video: Video
    @State private var detail: Video?
    @State private var loading = false
    @State private var selection: Episode?
    @State private var selectedLine: String?
    @State private var error: String?
    @State private var verifyingDetail = false
    @State private var verifyURL: URL?
    private let client = TVAPIClient()

    var body: some View {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Group {
                    if let selection {
                        VStack(alignment: .leading, spacing: 12) {
                            PlaybackSurface(controller: playback)
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(video.title) · \(selection.title)").font(.headline)
                                    Text(selectedLine ?? site.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let media = playback.media {
                                    Button { store.toggleFavorite(media) } label: {
                                        Image(systemName: store.isFavorite(media) ? "bookmark.fill" : "bookmark")
                                    }.accessibilityLabel(store.isFavorite(media) ? "取消收藏" : "收藏")
                                }
                            }
                            if playback.resolving { ProgressView("正在提取视频链接…") }
                            if let error = playback.error {
                                Text(error).font(.subheadline).foregroundStyle(.orange)
                                Button("重新获取播放链接") { play(selection, line: selectedLine ?? "") }.buttonStyle(.bordered)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .top, spacing: 18) {
                                PosterView(url: (detail ?? video).poster).frame(width: 120)
                                VStack(alignment: .leading, spacing: 12) {
                                    Text((detail ?? video).title).font(.title2.bold())
                                    Text((detail ?? video).note).font(.subheadline).foregroundStyle(Theme.accent)
                                    Text(site.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !(detail ?? video).summary.isEmpty {
                                Text((detail ?? video).summary).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text("选择下方剧集开始播放").font(.caption).foregroundStyle(.secondary)
                        }.accessibilityIdentifier("detail-introduction")
                    }
                }.id("detail-top")
                if loading { ProgressView("正在加载选集…") }
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(.orange)
                    if site.isPlugin {
                        Button("打开网站验证") { openDetailVerification() }.buttonStyle(.bordered)
                            .accessibilityIdentifier("detail-verify")
                    }
                    Button("重新加载") { Task { await fetchDetail() } }.buttonStyle(.bordered)
                }
                if let detail {
                    ForEach(detail.lines) { line in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(line.name).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 10) {
                                ForEach(line.episodes) { episode in
                                    Button(episode.title) {
                                        play(episode, line: line.name)
                                        withAnimation { proxy.scrollTo("detail-top", anchor: .top) }
                                    }
                                        .font(.caption).frame(maxWidth: .infinity, minHeight: 35)
                                        .buttonStyle(.bordered)
                                        .tint(selection?.id == episode.id && selectedLine == line.name ? Theme.accent : .secondary)
                                        .accessibilityIdentifier("episode-\(episode.title)")
                                }
                            }
                        }
                    }
                    if detail.lines.isEmpty { Text("该接口没有返回选集。\n可尝试其他来源。").foregroundStyle(.secondary) }
                }
            }.padding(20)
          }
        }
        .background(Theme.backdrop).navigationTitle("影片详情").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { playback.stop(); dismiss() } label: { Label("返回", systemImage: "chevron.left") }
                    .accessibilityIdentifier("detail-back")
            }
        }
        .toolbar(selection == nil ? .visible : .hidden, for: .tabBar)
        .task { await fetchDetail() }
        .sheet(isPresented: $verifyingDetail, onDismiss: { Task { await fetchDetail() } }) {
            if let verifyURL { SourceVerificationView(url: verifyURL) }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active, let media = playback.media { store.record(media, position: playback.position) }
        }
    }

    @MainActor private func fetchDetail() async {
        guard detail == nil else { return }
        loading = true
        error = nil
        defer { loading = false }
        do { detail = try await client.detail(site: site, id: video.id) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func openDetailVerification() {
        Task {
            let base = (try? await GenericSourceAdapter(site: site).rule())?.baseURL ?? ""
            if let url = HTTPAddress.optional(video.id, relativeTo: HTTPAddress.optional(base)) {
                verifyURL = url
                verifyingDetail = true
            } else {
                store.error = "还没有解出这个来源的网站地址。"
            }
        }
    }

    @MainActor private func play(_ episode: Episode, line: String) {
        selection = episode
        selectedLine = line
        playback.onProgress = { [weak store] in store?.record($0, position: $1) }
        playback.select(site: site, episode: episode, flag: line, title: "\(video.title) · \(episode.title)", poster: (detail ?? video).poster, resume: { [weak store] in store?.position(for: $0) ?? 0 })
    }
}
