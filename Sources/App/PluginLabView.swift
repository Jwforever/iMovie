import SwiftUI

/// 实验台：用 Dalvik 解释器直接执行插件里的采集器，看它自己吐出来的 JSON。
///
/// 这不是"按规则采集"，而是把插件的字节码跑一遍——和 OK影视 在安卓上做的事一样。
/// 放在设置里，是为了在不影响正式采集链路的前提下验证解释器。
@MainActor
struct PluginLabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedKey = ""
    @State private var keyword = "八仙"
    @State private var running = false
    @State private var result: DalvikRunResult?
    @State private var failure: String?
    @State private var showRaw = false
    @State private var work: Task<Void, Never>?

    private var sites: [SourceSite] { store.config?.nativeSites ?? [] }
    private var site: SourceSite? {
        sites.first { $0.key == selectedKey } ?? sites.first
    }

    var body: some View {
        List {
            Section("采集器") {
                if sites.isEmpty {
                    Text("先在设置里导入配置。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("来源", selection: Binding(
                        get: { site?.key ?? "" },
                        set: { selectedKey = $0 }
                    )) {
                        ForEach(sites) { item in
                            Text("\(item.name) · \(item.api)").tag(item.key)
                        }
                    }
                    TextField("搜索关键词", text: $keyword)
                }
            }

            Section("执行") {
                Button("首页（homeContent）") { run(.home) }
                    .disabled(running || site == nil)
                Button("搜索（searchContent）") { run(.search(keyword: keyword)) }
                    .disabled(running || site == nil)
                if running {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("解释器正在跑插件字节码…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let failure {
                Section("没有跑通") {
                    Text(failure).font(.callout).foregroundStyle(.orange)
                    Text("把这段文字发我，我按它补指令或垫片。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let result {
                Section("结果") {
                    Text(result.summary).font(.caption.monospaced())
                    ForEach(Array(result.requests.enumerated()), id: \.offset) { _, item in
                        Text("\(item.code)  \(item.url)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(item.code == 200 ? Color.secondary : Color.orange)
                    }
                }
                Section("插件返回") {
                    Text(result.json.isEmpty ? "（空）" : String(result.json.prefix(showRaw ? 20000 : 1200)))
                        .font(.caption.monospaced())
                    Button(showRaw ? "收起" : "展开全部") { showRaw.toggle() }
                }
            }
        }
        .navigationTitle("插件解释器")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if selectedKey.isEmpty { selectedKey = store.homeSource?.key ?? sites.first?.key ?? "" }
        }
        .onDisappear { work?.cancel() }
    }

    private func run(_ action: DalvikSpiderAction) {
        guard let site else { return }
        running = true
        failure = nil
        result = nil
        let spider = store.config?.spider
        work = Task {
            defer { running = false }
            do {
                let output = try await DalvikSpider.run(spider: spider, api: site.api,
                                                        action: action,
                                                        ext: site.extensionValue)
                result = output
            } catch is CancellationError { }
            catch {
                failure = error.localizedDescription
            }
        }
    }
}
