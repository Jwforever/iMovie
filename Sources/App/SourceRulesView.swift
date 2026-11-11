import SwiftUI

@MainActor struct SourceRulesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    var body: some View {
        List {
            Text("可为来源补充官网或 JSON 接口，使用统一采集 / 播放流程。规则保存本机，更新原配置后继续保留；也支持配置条目携带 ios 规则，无需重编译 App。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach((store.config?.sites ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { site in
                NavigationLink { SourceRuleEditor(site: site) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(site.name).font(.subheadline)
                        Text(site.genericRule?.baseURL ?? (site.usesGenericAdapter ? "自动识别 · 通用尝试" : "使用专用适配"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("rule-source-\(site.key)")
            }
        }.navigationTitle("来源规则").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "查找来源")
    }
}

@MainActor struct SourceRuleEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let site: SourceSite
    @State private var address = ""
    @State private var mode = "auto"
    @State private var advanced = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section(site.name) {
                TextField("官网 / JSON API 完整地址", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("source-rule-address")
                Picker("读取方式", selection: $mode) {
                    Text("自动识别").tag("auto")
                    Text("网页 / 奥特 / MacCMS").tag("html")
                    Text("JSON 采集接口").tag("json")
                }
                Text("保存后该来源使用通用适配。新源只要沿用已支持的 HTML / JSON 结构，更新地址或规则即可尝试，无需重新开发。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("高级规则（可选 JSON）") {
                TextEditor(text: $advanced).font(.caption.monospaced()).frame(minHeight: 210)
                    .accessibilityIdentifier("source-rule-json")
                Text("可配置 searchURL、categoryURL、detailURL、playerURL、listSelector、titleSelector、linkSelector、posterSelector、lineSelector 和 episodeSelector。地址模板支持 {query}、{page}、{category}、{id}、{url}。留空使用通用规则。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.orange).font(.caption) } }
            Section {
                Button("保存并使用") { save() }.accessibilityIdentifier("source-rule-save")
                Button("恢复配置默认规则", role: .destructive) { store.saveRule(nil, for: site); dismiss() }
            }
        }.navigationTitle("来源规则").navigationBarTitleDisplayMode(.inline)
            .task {
                guard !loaded else { return }; loaded = true
                let detected = site.genericRule == nil ? try? await GenericSourceAdapter(site: site).rule() : nil
                if let rule = site.genericRule ?? detected {
                    address = rule.baseURL
                    mode = rule.mode ?? "auto"
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    if let data = try? encoder.encode(rule) { advanced = String(decoding: data, as: UTF8.self) }
                }
            }
    }

    private func save() {
        do {
            _ = try HTTPAddress.parse(address)
            var rule = GenericSourceRule(baseURL: address)
            if !advanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rule = try JSONDecoder().decode(GenericSourceRule.self, from: Data(advanced.utf8))
            }
            rule.baseURL = address.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.mode = mode
            store.saveRule(rule, for: site)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
