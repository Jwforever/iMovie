import SwiftUI

@MainActor struct LiveView: View {
    @EnvironmentObject private var store: AppStore
    @State private var customURL = ""

    var body: some View {
        List {
            Section {
                TextField("M3U / TXT 直播列表地址", text: $customURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let url = HTTPAddress.optional(customURL) {
                    NavigationLink {
                        ChannelListView(source: LiveSource(name: "自定义列表", url: url.absoluteString, headers: [:]))
                    } label: { Label("打开列表", systemImage: "arrow.right.circle") }
                }
            } header: { Text("添加直播列表") } footer: {
                Text("支持 HTTP/HTTPS 的 M3U、TXT 和 HLS。播放效果取决于源的连通性与编码。")
            }
            if let sources = store.config?.lives, !sources.isEmpty {
                Section("配置中的直播") {
                    ForEach(sources) { source in
                        if source.needsAndroidProxy {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(source.name)
                                Text("依赖 Android 本地代理，暂不可用").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        } else {
                            NavigationLink { ChannelListView(source: source) } label: {
                                Label(source.name, systemImage: "tv")
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("导入配置后，直播来源会出现在这里。").foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.backdrop)
        .navigationTitle("直播")
    }
}

@MainActor struct ChannelListView: View {
    let source: LiveSource
    @State private var channels: [MediaLink] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    private var filtered: [MediaLink] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? channels : channels.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.group.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if loading { ProgressView("正在加载频道…") }
            if let error {
                Text(error).foregroundStyle(.orange)
                Button("重试") { Task { await load() } }
            }
            if !channels.isEmpty { Text("\(filtered.count) 个频道").font(.caption).foregroundStyle(.secondary) }
            ForEach(filtered) { channel in MediaRow(media: channel) }
        }
        .scrollContentBackground(.hidden).background(Theme.backdrop)
        .searchable(text: $search, prompt: "搜索频道或分组")
        .navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
        .task { if channels.isEmpty { await load() } }
        .refreshable { await load() }
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await HTTPClient().playlist(source)
            guard !Task.isCancelled else { return }
            channels = result
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
