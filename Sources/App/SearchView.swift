import SwiftUI

struct SiteSearchResult: Identifiable {
    let site: SourceSite
    let videos: [Video]
    let error: String?
    var id: String { site.id }
}

@MainActor struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var results: [SiteSearchResult] = []
    @State private var searching = false
    @State private var submitted = ""
    @State private var work: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        List {
            HStack {
                TextField("搜索影片、剧集或视频", text: $query).submitLabel(.search).onSubmit { search() }
                Button(action: search) { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索")
            }
            if searching { ProgressView("正在搜索 \(store.config?.nativeSites.filter(\.searchable).count ?? 0) 个可用来源…") }
            if store.config == nil { Text("先到设置中导入接口配置。").foregroundStyle(.secondary) }
            if !searching && !submitted.isEmpty && results.allSatisfy({ $0.videos.isEmpty }) {
                Text("没有找到“\(submitted)”的结果。可以更换关键词，或查看下方来源状态。").foregroundStyle(.secondary)
            }
            ForEach(results) { result in
                Section(result.site.name) {
                    if let error = result.error { Text(error).font(.caption).foregroundStyle(.secondary) }
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
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.backdrop)
        .navigationTitle("搜索")
        .onDisappear { work?.cancel(); searching = false }
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
        let sites = store.config?.nativeSites.filter(\.searchable) ?? []
        work = Task {
            // 三个来源一组；来源之间独立失败，不阻塞已返回的结果。
            for start in stride(from: 0, to: sites.count, by: 3) {
                guard !Task.isCancelled else { return }
                let batch = Array(sites[start..<min(start + 3, sites.count)])
                await withTaskGroup(of: SiteSearchResult.self) { group in
                    for site in batch {
                        group.addTask {
                            do {
                                let page = try await TVAPIClient().page(site: site, search: term)
                                return SiteSearchResult(site: site, videos: page.videos, error: nil)
                            } catch { return SiteSearchResult(site: site, videos: [], error: error.localizedDescription) }
                        }
                    }
                    for await result in group {
                        guard requestID == token, !Task.isCancelled else { group.cancelAll(); return }
                        results.append(result)
                    }
                }
            }
            if requestID == token { searching = false }
        }
    }
}
