import SwiftUI

@MainActor struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

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
                    LabeledContent("本机 JSON 接口", value: "\(config.sites.filter { $0.runtime == .jsonAPI }.count)")
                    LabeledContent("本机移植（实验）", value: "\(config.sites.filter { $0.runtime == .nativePort }.count)")
                    LabeledContent("Android 爬虫", value: "\(config.sites.filter { $0.runtime == .android }.count)")
                    LabeledContent("待适配脚本", value: "\(config.sites.filter { $0.runtime == .javascript }.count)")
                    LabeledContent("直播列表", value: "\(config.lives.count)")
                    LabeledContent("更新于", value: config.importedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("iMovie 按 iPhone 独立使用开发。已移植来源通过本机适配运行，其余 Android 插件与 drpy 脚本仍需逐步适配。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("播放器") {
                Label("系统播放器 · 倍速 · AirPlay · 画中画", systemImage: "play.rectangle")
                    .font(.subheadline)
                Text("支持 AVPlayer 可解码的格式，通常包括 HLS、MP4。部分 TS、MKV、网页链接及特殊音视频编码需要额外适配。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("iMovie 0.3.0") {
                Text("收藏和播放记录保存在本机。配置和媒体由你提供，应用不附带影片库。")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink("开源组件许可") {
                    ScrollView {
                        Text(Self.notices).font(.caption.monospaced()).textSelection(.enabled).padding(20)
                    }.navigationTitle("开源组件许可")
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.backdrop)
        .navigationTitle("设置")
    }

    private static var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "SwiftSoup · MIT License" }
        return text
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
