import SwiftUI
import AVKit

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published var error: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var hasVideoFrame = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var media: MediaLink?
    @Published private(set) var resolving = false
    let sessionID = UUID().uuidString
    var onProgress: ((MediaLink, Double) -> Void)?
    private var observation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var resume = 0.0
    private var progressObserver: Any?
    private var resolutionTask: Task<Void, Never>?
    private var generation = UUID()
    private var shouldPlay = false
    private var lastRecordedAt = Date.distantPast
    private var liveCertificateDelegate: LiveCertificateDelegate?

    init() {
        progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? max(0, time.seconds) : 0
                if let media = self.media, Date().timeIntervalSince(self.lastRecordedAt) >= 5 {
                    self.lastRecordedAt = Date()
                    self.onProgress?(media, self.position)
                }
            }
        }
    }

    func select(site: SourceSite, episode: Episode, flag: String, title: String, poster: String = "", resume: @escaping (MediaLink) -> Double) {
        beginResolution {
            var media = try await TVAPIClient().resolve(site: site, episode: episode, flag: flag, title: title)
            media.poster = poster
            return (media, resume(media))
        }
    }

    func prepare(_ source: MediaLink, resume: Double, force: Bool = false) {
        guard force || media?.id != source.id || player.currentItem == nil else { return }
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
        clearItem()
        error = nil
        self.resume = resume
        self.media = media
        shouldPlay = true
        do {
            let url = try HTTPAddress.parse(media.url)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let asset = AVURLAsset(url: url, options: media.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": media.headers])
            if media.allowsInvalidCertificate == true {
                let delegate = LiveCertificateDelegate()
                liveCertificateDelegate = delegate
                asset.resourceLoader.setDelegate(delegate, queue: .global(qos: .userInitiated))
            }
            let item = AVPlayerItem(asset: asset)
            observation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.player.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay:
                        let duration = item.duration.seconds
                        if self.resume > 3, duration.isFinite, self.resume < duration - 3 {
                            self.player.seek(to: CMTime(seconds: self.resume, preferredTimescale: 600))
                        }
                        self.resume = 0
                        self.player.play()
                    case .failed:
                        self.error = item.error?.localizedDescription ?? "媒体无法播放。请检查地址、网络和编码格式。"
                    default: break
                    }
                }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放中断，请重试或切换来源。"
                Task { @MainActor [weak self] in self?.error = message }
            }
            player.replaceCurrentItem(with: item)
            player.allowsExternalPlayback = true
            onProgress?(media, resume)
            lastRecordedAt = Date()
            timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPlaying = self.player.timeControlStatus == .playing
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func rendered(_ ready: Bool) { hasVideoFrame = ready }

    func resumeAfterTransition(wasPlaying: Bool) {
        guard wasPlaying, shouldPlay, player.currentItem?.status == .readyToPlay else { return }
        player.play()
    }

    var position: Double {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite else { return 0 }
        let current = player.currentTime().seconds
        return current.isFinite && current < duration - 3 ? current : 0
    }

    func stop() {
        generation = UUID()
        resolutionTask?.cancel()
        resolutionTask = nil
        resolving = false
        shouldPlay = false
        if let media { onProgress?(media, position) }
        clearItem()
        media = nil
    }

    private func clearItem() {
        observation = nil
        timeControlObservation = nil
        isPlaying = false
        hasVideoFrame = false
        elapsed = 0
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        liveCertificateDelegate = nil
    }

    deinit {
        resolutionTask?.cancel()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let progressObserver { player.removeTimeObserver(progressObserver) }
        player.pause()
    }
}

private final class LiveCertificateDelegate: NSObject, AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge) -> Bool {
        guard authenticationChallenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = authenticationChallenge.protectionSpace.serverTrust else { return false }
        authenticationChallenge.sender?.use(URLCredential(trust: trust), for: authenticationChallenge)
        return true
    }
}

@MainActor struct NativeVideoPlayer: UIViewControllerRepresentable {
    @ObservedObject var playback: PlaybackController

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIViewController(context: Context) -> PlayerContainerViewController {
        let container = PlayerContainerViewController()
        container.playback = playback
        let controller = container.videoController
        controller.player = playback.player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.showsPlaybackControls = true
        controller.speeds = []
        controller.delegate = context.coordinator
        context.coordinator.observation = controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak playback] controller, _ in
            let ready = controller.isReadyForDisplay
            Task { @MainActor in playback?.rendered(ready) }
        }
        return container
    }

    func updateUIViewController(_ container: PlayerContainerViewController, context: Context) {
        let controller = container.videoController
        if controller.player !== playback.player { controller.player = playback.player }
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        weak var playback: PlaybackController?
        var observation: NSKeyValueObservation?
        init(playback: PlaybackController) { self.playback = playback }

        func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            let playing = playback?.isPlaying == true
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor in self?.playback?.resumeAfterTransition(wasPlaying: playing) }
            }
        }
    }
}

/// AVPlayerViewController is embedded as a child; Apple does not support subclassing it.
@MainActor final class PlayerContainerViewController: UIViewController {
    weak var playback: PlaybackController?
    let videoController = AVPlayerViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(videoController)
        videoController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoController.view)
        NSLayoutConstraint.activate([
            videoController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoController.view.topAnchor.constraint(equalTo: view.topAnchor),
            videoController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        videoController.didMove(toParent: self)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        let playing = playback?.isPlaying == true
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.view.setNeedsLayout()
            Task { @MainActor in self?.playback?.resumeAfterTransition(wasPlaying: playing) }
        }
    }
}

@MainActor struct PlaybackSurface: View {
    @ObservedObject var controller: PlaybackController
    var fills = false

    var body: some View {
        NativeVideoPlayer(playback: controller)
            .modifier(PlaybackSurfaceStyle(fills: fills))
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
            Text("点开播放器控件可全屏；横过来画面会自动铺满。")
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
