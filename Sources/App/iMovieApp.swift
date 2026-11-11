import SwiftUI

@main
@MainActor
struct iMovieApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.39, green: 0.87, blue: 0.67)
    static let backdrop = Color(red: 0.035, green: 0.045, blue: 0.065)
    static let panel = Color(red: 0.075, green: 0.09, blue: 0.12)

    static func sourceName(_ name: String) -> String {
        name.components(separatedBy: "┃").first?.trimmingCharacters(in: .whitespaces) ?? name
    }
}

@MainActor struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView {
            NavigationStack { LibraryView() }
                .tabItem { Label("首页", systemImage: "house.fill") }
            NavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            NavigationStack { LiveView() }
                .tabItem { Label("直播", systemImage: "tv") }
            NavigationStack { CollectionView() }
                .tabItem { Label("我的", systemImage: "bookmark") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .sheet(item: $store.playback) { request in
            PlayerSheet(media: request.media).environmentObject(store)
        }
        .overlay {
            if store.resolvingPlayback {
                ProgressView("正在更新播放地址…")
                    .padding(22).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .alert("暂时无法完成", isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } }
        )) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

@MainActor struct EmptyPanel: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: icon).font(.system(size: 42, weight: .light)).foregroundStyle(Theme.accent)
            Text(title).font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 24))
    }
}

@MainActor struct RuntimeLabel: View {
    var runtime: SourceRuntime
    var body: some View {
        Text(runtime.title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(runtime == .jsonAPI || runtime == .nativePort ? Theme.accent : Color.secondary)
            .background((runtime == .jsonAPI || runtime == .nativePort ? Theme.accent : Color.secondary).opacity(0.12), in: Capsule())
    }
}

@MainActor struct MediaRow: View {
    @EnvironmentObject private var store: AppStore
    var media: MediaLink
    var subtitle: String = ""

    var body: some View {
        HStack(spacing: 13) {
            Button { store.play(media) } label: {
                HStack(spacing: 13) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.accent)
                        .frame(width: 43, height: 43).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(media.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        if !subtitle.isEmpty || !media.group.isEmpty {
                            Text(subtitle.isEmpty ? media.group : subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }.buttonStyle(.plain)
            Button { store.toggleFavorite(media) } label: {
                Image(systemName: store.isFavorite(media) ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(store.isFavorite(media) ? Theme.accent : Color.secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isFavorite(media) ? "取消收藏" : "收藏")
        }
        .padding(.vertical, 5)
    }
}
