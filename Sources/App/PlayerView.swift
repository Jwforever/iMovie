import SwiftUI
import AVKit

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published var error: String?
    @Published private(set) var isPlaying = false
    private var observation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var resume = 0.0

    func open(_ media: MediaLink, resume: Double) {
        stop()
        error = nil
        self.resume = resume
        do {
            let url = try HTTPAddress.parse(media.url)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let asset = AVURLAsset(url: url, options: media.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": media.headers])
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
            timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPlaying = self.player.timeControlStatus == .playing
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    var position: Double {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite else { return 0 }
        let current = player.currentTime().seconds
        return current.isFinite && current < duration - 3 ? current : 0
    }

    func stop() {
        observation = nil
        timeControlObservation = nil
        isPlaying = false
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    deinit {
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }
}

@MainActor struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

@MainActor struct PlayerSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = PlaybackController()
    let media: MediaLink

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    NativeVideoPlayer(player: controller.player)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit).background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                        .accessibilityIdentifier("native-player")
                        .accessibilityValue(controller.isPlaying ? "playing" : "waiting")
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(media.title).font(.title3.bold())
                            Text(media.group).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.toggleFavorite(media) } label: {
                            Image(systemName: store.isFavorite(media) ? "bookmark.fill" : "bookmark").font(.title3)
                        }.accessibilityLabel(store.isFavorite(media) ? "取消收藏" : "收藏")
                    }
                    if let error = controller.error {
                        Text(error).font(.subheadline).foregroundStyle(.orange)
                        Button("重新连接") { controller.open(media, resume: 0) }.buttonStyle(.bordered)
                    }
                    HStack(spacing: 12) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button("\(rate.formatted())×") { controller.player.rate = Float(rate) }
                                .font(.caption).buttonStyle(.bordered)
                        }
                    }
                    Text("全屏、投屏和画中画可通过播放器控件开启。").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Theme.backdrop)
            .navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } } }
        }
        .onAppear {
            let position = store.position(for: media)
            controller.open(media, resume: position)
            store.record(media, position: position)
        }
        .onDisappear { store.record(media, position: controller.position); controller.stop() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { store.record(media, position: controller.position) }
        }
    }
}
