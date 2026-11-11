import SwiftUI

struct SiteSearchResult: Identifiable {
    let target: SourceSearchTarget
    let videos: [Video]
    let error: String?
    var site: SourceSite { target.site }
    var id: String { target.id }
}

@MainActor struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var results: [SiteSearchResult] = []
    @State private var searching = false
    @State private var submitted = ""
    @State private var work: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var total = 0
    @State private var verifyingSource = false
    @State private var verificationTarget: SourceSearchTarget?

    var body: some View {
        List {
            HStack {
                TextField("搜索影片、剧集或视频", text: $query).submitLabel(.search).onSubmit { search() }
                Button(action: search) { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索")
            }
            if searching { ProgressView("正在搜索 · \(results.count) / \(total) 个站点已返回") }
            if let config = store.config {
                Section {
                    Text("\(config.searchTargets.count) 个站点可尝试搜索 · 对应 \(config.nativeSites.filter(\.searchable).count) 个配置条目")
                        .font(.caption).foregroundStyle(.secondary)
                    if !submitted.isEmpty {
                        Text("\(results.filter { !$0.videos.isEmpty }.count) 个有结果 · \(results.filter { $0.error != nil }.count) 个连接失败")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("search-summary")
                    }
                    DisclosureGroup("其他来源为什么没有参与搜索？") {
                        Text("同一站点的多个分类条目合并查询。未完成适配的来源和配置中关闭搜索的来源不会参与。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(config.sites.filter { !$0.isNative || !$0.searchable }) { site in
                            HStack {
                                Text(site.name).font(.caption)
                                Spacer()
                                Text(site.isNative ? "配置关闭搜索" : "待适配").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.font(.subheadline)
                }
            }
            if store.config == nil { Text("先到设置中导入接口配置。").foregroundStyle(.secondary) }
            if !searching && !submitted.isEmpty && results.allSatisfy({ $0.videos.isEmpty }) {
                Text("没有找到“\(submitted)”的结果。可以更换关键词，或查看下方来源状态。").foregroundStyle(.secondary)
            }
            ForEach(results) { result in
                Section {
                    if let error = result.error {
                        HStack(alignment: .top) {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("重试") { retry(result.target) }.font(.caption)
                        }
                        if result.site.nativeAdapter == .auete {
                            Button("在网页中验证后重试") {
                                verificationTarget = result.target
                                verifyingSource = true
                            }.font(.caption)
                        }
                    }
                    if result.videos.isEmpty && result.error == nil { Text("没有匹配内容").font(.caption).foregroundStyle(.secondary) }
                    ForEach(result.videos) { video in
                        NavigationLink { VideoDetailView(site: result.site, video: video) } label: {
                            HStack(spacing: 12) {
                                PosterView(url: video.poster).frame(width: 52)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(video.title).font(.subheadline).lineLimit(2)
                                    Text(video.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(result.site.name)
                        if !result.target.aliases.isEmpty { Text("含 \(result.target.aliases.count + 1) 个分类源").font(.caption2) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.backdrop)
        .navigationTitle("搜索")
        .onDisappear { work?.cancel(); searching = false }
        .sheet(isPresented: $verifyingSource, onDismiss: {
            if let target = verificationTarget { retry(target) }
        }) {
            if let url = try? AueteAdapter.pageURL(category: nil, search: submitted, page: 1) {
                SourceVerificationView(url: url)
            }
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        work?.cancel()
        let token = UUID()
        requestID = token
        submitted = term
        results = []
        searching = true
        let targets = store.config?.searchTargets ?? []
        total = targets.count
        work = Task {
            // Keep four requests in flight; a slow site cannot hold up the next batch.
            await withTaskGroup(of: SiteSearchResult.self) { group in
                var next = 0
                for target in targets.prefix(4) {
                    group.addTask { await Self.fetch(target, term: term) }
                    next += 1
                }
                for await result in group {
                    guard requestID == token, !Task.isCancelled else { group.cancelAll(); return }
                    results.append(result)
                    if next < targets.count {
                        let target = targets[next]
                        next += 1
                        group.addTask { await Self.fetch(target, term: term) }
                    }
                }
            }
            if requestID == token { searching = false }
        }
    }

    nonisolated private static func fetch(_ target: SourceSearchTarget, term: String) async -> SiteSearchResult {
        do {
            let page = try await TVAPIClient().page(site: target.site, search: term)
            return SiteSearchResult(target: target, videos: page.videos, error: nil)
        } catch { return SiteSearchResult(target: target, videos: [], error: error.localizedDescription) }
    }

    private func retry(_ target: SourceSearchTarget) {
        let token = requestID, term = submitted
        Task {
            let result = await Self.fetch(target, term: term)
            guard requestID == token, !Task.isCancelled else { return }
            if let index = results.firstIndex(where: { $0.id == result.id }) { results[index] = result }
        }
    }
}
