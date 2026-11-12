import SwiftUI
import AVFAudio

@MainActor
final class PlaybackController: ObservableObject {
    @Published var error: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var hasVideoFrame = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var media: MediaLink?
    @Published private(set) var resolving = false
    @Published private(set) var speed = 1.0
    let sessionID = UUID().uuidString
    var onProgress: ((MediaLink, Double) -> Void)?
    private var resolutionTask: Task<Void, Never>?
    private var generation = UUID()
    private var resume = 0.0
    private var lastRecordedAt = Date.distantPast
    private var coreIdle = true
    private var paused = true
    /// 由播放视图（MPVMetalViewController）挂上来；视图未就绪前先记 pending。
    weak var surface: MPVMetalViewController?

    func select(site: SourceSite, episode: Episode, flag: String, title: String, poster: String = "", resume: @escaping (MediaLink) -> Double) {
        beginResolution {
            var media = try await TVAPIClient().resolve(site: site, episode: episode, flag: flag, title: title)
            media.poster = poster
            return (media, resume(media))
        }
    }

    func prepare(_ source: MediaLink, resume: Double, force: Bool = false) {
        guard force || media?.id != source.id || surface?.mpv == nil else { return }
        beginResolution { (try await MediaResolver().resolve(source), resume) }
    }

    private func beginResolution(_ operation: @escaping @MainActor () async throws -> (MediaLink, Double)) {
        stop()
        error = nil
        resolving = true
        let token = generation
        resolutionTask = Task {
            do {
                let (media, resume) = try await operation()
                guard generation == token, !Task.isCancelled else { return }
                resolving = false
                open(media, resume: resume)
            } catch is CancellationError { }
            catch {
                guard generation == token, !Task.isCancelled else { return }
                resolving = false
                self.error = error.localizedDescription
            }
        }
    }

    func open(_ media: MediaLink, resume: Double) {
        clearPlaybackState()
        error = nil
        self.resume = resume
        self.media = media
        do {
            let url = try HTTPAddress.parse(media.url)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let start = self.resume
            self.resume = 0
            let (target, headers) = Self.route(url: url, headers: media.headers)
            surface?.load(url: target, headers: headers, start: start)
            onProgress?(media, position)
            lastRecordedAt = Date()
        } catch { self.error = error.localizedDescription }
    }

    /// 统一走已验证的本地回环代理（证书/头信息/m3u8 重写都在代理层消化）；
    /// 代理未就绪时退回原始地址 + mpv 自带头（tls-verify 已关）。
    private static func route(url: URL, headers: [String: String]) -> (target: String, headers: [String: String]) {
        if let proxied = LocalStreamProxy.shared.mediaURL(for: url, headers: headers) {
            return (proxied.absoluteString, [:])
        }
        var effective = headers
        if !effective.keys.contains(where: { $0.lowercased() == "user-agent" }) {
            effective["User-Agent"] = BrowserProfile.userAgent
        }
        return (url.absoluteString, effective)
    }

    /// 播放视图就绪后回填：把挂起的内容交给 mpv。
    func attach(_ surface: MPVMetalViewController) {
        self.surface = surface
        guard let media else { return }
        let start = resume
        resume = 0
        guard let url = try? HTTPAddress.parse(media.url) else {
            surface.load(url: media.url, headers: media.headers, start: start)
            return
        }
        let (target, headers) = Self.route(url: url, headers: media.headers)
        surface.load(url: target, headers: headers, start: start)
    }

    // MARK: - mpv 事件（主线程）

    func updateElapsed(_ value: Double) {
        elapsed = value.isFinite ? max(0, value) : 0
        if let media, Date().timeIntervalSince(lastRecordedAt) >= 5 {
            lastRecordedAt = Date()
            onProgress?(media, position)
        }
    }

    func updateDuration(_ value: Double) {
        duration = value.isFinite ? max(0, value) : 0
    }

    func updatePaused(_ value: Bool) {
        paused = value
        isPlaying = !paused && !coreIdle
    }

    func updateCoreIdle(_ value: Bool) {
        coreIdle = value
        isPlaying = !paused && !coreIdle
    }

    func ended(_ message: String?) {
        if let message {
            error = "播放中断：\(message)。可重试或更换线路。"
        } else if let media {
            onProgress?(media, 0)
        }
    }

    func rendered(_ ready: Bool) { hasVideoFrame = ready }

    // MARK: - 控制

    func playPause() { surface?.playPause() }
    func seek(to seconds: Double) { surface?.seek(to: seconds) }

    func setSpeed(_ value: Double) {
        speed = value
        surface?.setSpeed(value)
    }

    var position: Double {
        if duration > 0 {
            return elapsed.isFinite && elapsed < duration - 3 ? elapsed : 0
        }
        return elapsed.isFinite ? elapsed : 0
    }

    func stop() {
        generation = UUID()
        resolutionTask?.cancel()
        resolutionTask = nil
        resolving = false
        if let media { onProgress?(media, position) }
        surface?.stopPlayback()
        clearPlaybackState()
        media = nil
    }

    private func clearPlaybackState() {
        isPlaying = false
        hasVideoFrame = false
        elapsed = 0
        duration = 0
        coreIdle = true
        paused = true
    }

    deinit {
        resolutionTask?.cancel()
    }
}

/// mpv Metal 渲染视图接入 SwiftUI。
@MainActor struct NativeVideoPlayer: UIViewControllerRepresentable {
    @ObservedObject var playback: PlaybackController

    func makeUIViewController(context: Context) -> MPVMetalViewController {
        let controller = MPVMetalViewController()
        controller.playback = playback
        playback.attach(controller)
        return controller
    }

    func updateUIViewController(_ controller: MPVMetalViewController, context: Context) {
        controller.playback = playback
    }
}

@MainActor struct PlaybackSurface: View {
    @ObservedObject var controller: PlaybackController
    var fills = false
    /// 传入后在控制条里显示全屏按钮（详情页播放器用）。
    var onFullscreen: (() -> Void)? = nil
    var isFullscreen = false
    @State private var showControls = true
    @State private var seeking = false
    @State private var seekValue: Double = 0
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        NativeVideoPlayer(playback: controller)
            .modifier(PlaybackSurfaceStyle(fills: fills))
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }
            .overlay { controls }
            .accessibilityIdentifier("native-player")
            .accessibilityValue(controller.isPlaying ? "playing" : "waiting")
            .overlay(alignment: .bottomLeading) {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement().accessibilityLabel("播放会话")
                    .accessibilityValue("\(controller.sessionID)|\(Int(controller.elapsed))|\(controller.hasVideoFrame ? "frame" : "waiting")")
                    .accessibilityIdentifier("playback-session")
                    .allowsHitTesting(false)
            }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if showControls {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Button { controller.playPause(); scheduleHide() } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    Button {
                        controller.seek(to: max(0, controller.elapsed - 10))
                        scheduleHide()
                    } label: {
                        Image(systemName: "gobackward.10").font(.title3)
                    }
                    if controller.duration > 0 {
                        Text(Self.timeString(seeking ? seekValue : controller.elapsed))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { seeking ? seekValue : min(controller.elapsed, max(controller.duration, 0.1)) },
                            set: { seekValue = $0 }), in: 0...max(controller.duration, 0.1)) { editing in
                            seeking = editing
                            if !editing {
                                controller.seek(to: seekValue)
                                scheduleHide()
                            }
                        }
                        Text(Self.timeString(controller.duration))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text(controller.hasVideoFrame ? "直播流" : "正在缓冲…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                            Button(String(format: "%.2fx", value)) { controller.setSpeed(value) }
                        }
                    } label: {
                        Text(String(format: "%.2fx", controller.speed)).font(.caption.monospacedDigit())
                    }
                    if let onFullscreen {
                        Button(action: onFullscreen) {
                            Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.title3)
                        }
                    }
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(12)
            }
            .onChange(of: controller.isPlaying) { playing in
                if playing { scheduleHide() }
            }
        }
    }

    private static func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct PlaybackSurfaceStyle: ViewModifier {
    var fills: Bool

    func body(content: Content) -> some View {
        if fills {
            content.background(.black)
        } else {
            content.aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 15))
        }
    }
}

@MainActor struct PlayerSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = PlaybackController()
    @StateObject private var orientation = PlaybackOrientation()
    let media: MediaLink

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape {
                    PlaybackSurface(controller: controller, fills: true)
                        .ignoresSafeArea()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if controller.resolving { ProgressView("正在提取视频链接…").tint(.white).foregroundStyle(.white) }
                            PlaybackSurface(controller: controller)
                            details
                        }.padding(20)
                    }
                }
            }
            .overlay(alignment: .topTrailing) { closeButton }
        }
        .statusBarHidden()
        .onAppear { orientation.start() }
        .onDisappear { orientation.stop() }
        .task {
            let position = store.position(for: media)
            controller.onProgress = { [weak store] in store?.record($0, position: $1) }
            controller.prepare(media, resume: position)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { store.record(media, position: controller.position) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(media.title).font(.title3.bold()).foregroundStyle(.white)
                    Text(media.group).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button { store.toggleFavorite(media) } label: {
                    Image(systemName: store.isFavorite(media) ? "bookmark.fill" : "bookmark")
                        .font(.title3).foregroundStyle(.white)
                }.accessibilityLabel(store.isFavorite(media) ? "取消收藏" : "收藏")
            }
            if let error = controller.error {
                Text(error).font(.subheadline).foregroundStyle(.orange)
                Button("重新连接") { controller.prepare(media, resume: controller.position, force: true) }
                    .buttonStyle(.bordered)
            }
            Text("点画面显示播放控制；横过来画面会自动铺满。")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var closeButton: some View {
        Button {
            controller.stop()
            dismiss()
        } label: {
            Text("完成")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.white.opacity(0.16), in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(.trailing, 16)
        .padding(.top, 10)
        .accessibilityIdentifier("player-close")
    }
}
