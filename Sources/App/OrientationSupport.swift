import UIKit
import CoreMotion

/// iOS 在“方向锁定”开启时不会自动旋转，App 必须自己感知物理方向再请求几何更新，
/// 否则用户只能先去关掉系统锁定才能横屏。播放器用这里的策略临时接管方向。
enum OrientationPolicy {
    /// 交给系统的允许方向。非播放场景保持竖屏，播放时放宽到全向。
    static var mask: UIInterfaceOrientationMask = .portrait
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationPolicy.mask
    }
}

@MainActor
final class PlaybackOrientation: ObservableObject {
    @Published private(set) var isLandscape = false
    private let motion = CMMotionManager()
    private var lastVote: Bool?
    private var votes = 0
    private var active = false

    func start() {
        OrientationPolicy.mask = .allButUpsideDown
        guard !active else { return }
        active = true
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let acceleration = data?.acceleration else { return }
            let landscape = abs(acceleration.x) > 0.6 && abs(acceleration.x) > abs(acceleration.y)
            Task { @MainActor in self.vote(landscape) }
        }
    }

    func stop() {
        active = false
        motion.stopAccelerometerUpdates()
        OrientationPolicy.mask = .portrait
        apply(.portrait)
    }

    /// 手动切换，给不想转动手机的场合兜底。
    func toggle() {
        apply(isLandscape ? .portrait : .landscapeRight)
    }

    /// 详情页播放器：点全屏按钮进横屏。
    func enterFullscreen() {
        OrientationPolicy.mask = .allButUpsideDown
        apply(.landscapeRight)
    }

    /// 返回竖屏并收回方向权限。
    func exitFullscreen() {
        OrientationPolicy.mask = .portrait
        apply(.portrait)
    }

    func toggleFullscreen() {
        if isLandscape { exitFullscreen() } else { enterFullscreen() }
    }

    /// 连续几次同向才切换，避免手抖来回横竖。
    private func vote(_ landscape: Bool) {
        if lastVote == landscape { votes += 1 } else { lastVote = landscape; votes = 0 }
        guard votes >= 2 else { return }
        apply(landscape ? .landscapeRight : .portrait)
    }

    private func apply(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        isLandscape = mask == .landscapeRight || mask == .landscapeLeft || mask == .allButUpsideDown
    }
}
