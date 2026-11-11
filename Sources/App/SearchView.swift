import SwiftUI

struct SiteSearchResult: Identifiable {
    let target: SourceSearchTarget
    let videos: [Video]
    let error: String?
    var site: SourceSite { target.site }
    var id: String { target.id }
}

private struct SearchHit: Identifiable {
    let site: SourceSite
    let video: Video
    let relevance: Int
    var id: String { site.id + "|" + video.id }
}

@MainActor struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var results: [SiteSearchResult] = []
    @State private var searching = false
    @State private var submitted = ""
    @State private var work: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var selectedSource: String?
    @State private var verifyingSource = false
    @State private var verificationTarget: SourceSearchTarget?
    @State private var showingSources = false

    private var targets: [SourceSearchTarget] { store.config?.searchTargets ?? [] }
    private var visibleResults: [SiteSearchResult] { results.filter { selectedSource == nil || $0.id == selectedSource } }
    private var hits: [SearchHit] {
        visibleResults.flatMap { result in
            result.videos.map { SearchHit(site: result.site, video: $0, relevance: SearchRanking.score(title: $0.title, query: submitted)) }
        }.sorted {
            if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
            if $0.video.title != $1.video.title { return $0.video.title.localizedStandardCompare($1.video.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索影片、剧集或视频", text: $query).submitLabel(.search).onSubmit { search() }
                    .accessibilityIdentifier("global-search-query")
                Button("搜索", action: search).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("global-search-submit")
            }.padding(13).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 16).padding(.bottom, 12)
            HStack(alignment: .top, spacing: 0) {
                sourceSidebar.frame(width: 92)
                Divider()
                resultsPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.backdrop)
        .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingSources = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("搜索来源说明")
            }
        }
        .sheet(isPresented: $showingSources) { sourceInformation }
        .sheet(isPresented: $verifyingSource, onDismiss: {
            if let target = verificationTarget { retry(target) }
        }) {
            if let url = try? AueteAdapter.pageURL(category: nil, search: submitted, page: 1) { SourceVerificationView(url: url) }
        }
    }

    private var sourceSidebar: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                sourceFilter("全部源", key: nil, count: results.reduce(0) { $0 + $1.videos.count })
                ForEach(targets) { target in
                    sourceFilter(Theme.sourceName(target.site.name), key: target.id,
                                 count: results.first { $0.id == target.id }?.videos.count)
                }
            }.padding(.vertical, 8).padding(.horizontal, 5)
        }.background(Theme.panel.opacity(0.45))
    }

    private func sourceFilter(_ title: String, key: String?, count: Int?) -> some View {
        Button { selectedSource = key } label: {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: selectedSource == key ? .bold : .medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 29)
                if !submitted.isEmpty {
                    let result = results.first { $0.id == key }
                    Text(result?.error != nil ? "未返回" : count.map { "\($0) 部" } ?? (searching ? "搜索中" : "待查询"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 11).padding(.horizontal, 3)
                .foregroundStyle(selectedSource == key ? Theme.accent : Color.secondary)
                .background(selectedSource == key ? Theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("search-filter-\(key ?? "all")")
    }

    private var resultsPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if store.config == nil {
                    Text("先到设置中导入接口配置。").font(.subheadline).foregroundStyle(.secondary)
                } else if submitted.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("找一部想看的影片").font(.headline)
                        Text("支持 \(targets.count) 个站点。输入片名后按匹配度排序，也可点左侧来源筛选。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 20)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(hits.count) 个结果 · 匹配度优先").font(.caption.weight(.medium))
                            Text("\(results.filter { !$0.videos.isEmpty }.count) 个有结果 · \(results.filter { $0.error != nil }.count) 个未返回")
                                .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("search-summary")
                        }
                        Spacer(minLength: 0)
                        if searching { ProgressView().controlSize(.small) }
                    }
                    if hits.isEmpty && !searching && visibleResults.allSatisfy({ $0.error == nil }) {
                        Text("没有找到匹配内容，可以换个关键词或切换来源。").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(visibleResults.filter { $0.error != nil }) { result in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(Theme.sourceName(result.site.name)).font(.caption.weight(.semibold))
                            Text(result.error ?? "").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("重试") { retry(result.target) }
                                if result.site.nativeAdapter == .auete {
                                    Button("网页验证") { verificationTarget = result.target; verifyingSource = true }
                                }
                            }.font(.caption)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(hits) { hit in
                        NavigationLink { VideoDetailView(site: hit.site, video: hit.video) } label: {
                            HStack(alignment: .top, spacing: 11) {
                                PosterView(url: hit.video.poster).frame(width: 64, height: 96)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(hit.video.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(3)
                                    Text(Theme.sourceName(hit.site.name)).font(.caption).foregroundStyle(Theme.accent)
                                    if !hit.video.note.isEmpty { Text(hit.video.note).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("search-hit-\(hit.id)")
                    }
                }
            }.padding(13)
        }
    }

    private var sourceInformation: some View {
        NavigationStack {
            List {
                Text("同一站点的多个分类条目合并搜索。未完成适配或配置关闭搜索的来源不会参与。结果按片名完整匹配、前缀、包含关系与字符相关度排序。")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(store.config?.sites.filter { !$0.isNative || !$0.searchable } ?? []) { site in
                    LabeledContent(site.name, value: site.isNative ? "配置关闭搜索" : "待适配").font(.caption)
                }
            }.navigationTitle("搜索来源").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingSources = false } } }
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
        let targets = targets
        work = Task {
            await withTaskGroup(of: SiteSearchResult.self) { group in
                var next = 0
                for target in targets.prefix(4) { group.addTask { await Self.fetch(target, term: term) }; next += 1 }
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
