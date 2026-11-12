import Foundation
import UIKit
import Libmpv

/// MoltenVK 会把 drawableSize 设成 1x1 强制结束呈现，导致闪烁；
/// 参考 mpv#13651，小于 1x1 的设置直接忽略。
class MetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}

/// libmpv 引擎：渲染进 Metal 层，直接播 https（tls-verify=no，证书失效不再拦截），
/// 自定义请求头走 per-file option，HLS/分片由 mpv 内部统一带头发请求。
///
/// 事件模型：observe 属性（time-pos/duration/pause/core-idle…）+ END_FILE，
/// 全部经 onPropertyChange / onEnded 回调给 PlaybackController。
final class MPVMetalViewController: UIViewController {
    private var metalLayer = MetalLayer()
    private(set) var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "imovie.mpv.events", qos: .userInitiated)
    private var backgroundPaused = false

    /// 视图加载前就指定要播的内容（PlaybackController 先 open、后挂视图的场景）。
    var pendingLoad: (url: String, headers: [String: String], start: Double)?
    var onPropertyChange: ((String, Any?) -> Void)?
    var onEnded: ((_ error: String?) -> Void)?
    weak var playback: PlaybackController?
    /// 最近几条 mpv 警告/错误日志，播放失败时带进界面错误里，便于定位。
    private var recentLogs: [String] = []
    private let logsLock = NSLock()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        setupMpv()
        if let pending = pendingLoad {
            load(url: pending.url, headers: pending.headers, start: pending.start)
            pendingLoad = nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalLayer.frame = view.bounds
    }

    deinit {
        if let mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
        }
    }

    // MARK: - 初始化

    private func setupMpv() {
        mpv = mpv_create()
        guard mpv != nil else {
            DispatchQueue.main.async { [weak self] in self?.playback?.ended("mpv 引擎创建失败") }
            return
        }
        checkError(mpv_request_log_messages(mpv, "warn"))
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer))
        checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
        checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(mpv, "gpu-context", "moltenvk"))
        checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))
        checkError(mpv_set_option_string(mpv, "video-rotate", "no"))
        // 采集源大量自签/过期证书，直接关掉校验；网络与缓冲按点播流调优。
        checkError(mpv_set_option_string(mpv, "tls-verify", "no"))
        checkError(mpv_set_option_string(mpv, "network-timeout", "30"))
        checkError(mpv_set_option_string(mpv, "cache", "yes"))
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "64MiB"))
        checkError(mpv_set_option_string(mpv, "force-window", "no"))
        let status = mpv_initialize(mpv)
        if status < 0 {
            let message = String(cString: mpv_error_string(status))
            DispatchQueue.main.async { [weak self] in
                self?.playback?.ended("mpv 初始化失败：\(message)（\(self.logTail())）")
            }
            return
        }

        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "core-idle", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)

        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let controller = Unmanaged<MPVMetalViewController>.fromOpaque(ctx).takeUnretainedValue()
            controller.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    // MARK: - 播放控制

    func load(url: String, headers: [String: String], start: Double) {
        guard mpv != nil else {
            pendingLoad = (url, headers, start)
            return
        }
        logsLock.lock()
        recentLogs.removeAll()
        logsLock.unlock()
        // 头信息用属性设置（列表属性按逗号切分），比 loadfile 选项串更稳；换集时先清空。
        let fields = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        checkError(mpv_set_property_string(mpv, "http-header-fields", headers.isEmpty ? "" : fields))
        var args = [url, "replace"]
        if start > 3 {
            args.append("start=\(Int(start))")
        }
        command("loadfile", args: args)
        setFlag("pause", false)
    }

    func setSpeed(_ speed: Double) {
        guard mpv != nil else { return }
        checkError(mpv_set_property_string(mpv, "speed", String(format: "%.2f", speed)))
    }

    func playPause() {
        setFlag("pause", !getFlag("pause"))
    }

    func seek(to seconds: Double) {
        command("seek", args: [String(max(0, seconds)), "absolute", "keyframes"])
    }

    func stopPlayback() {
        guard mpv != nil else { return }
        command("stop")
    }

    // MARK: - 事件

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            while self.mpv != nil {
                let event = mpv_wait_event(self.mpv, 0)
                guard let event else { break }
                switch event.pointee.event_id {
                case MPV_EVENT_NONE:
                    return
                case MPV_EVENT_PROPERTY_CHANGE:
                    let pointer = OpaquePointer(event.pointee.data)
                    if let property = UnsafePointer<mpv_event_property>(pointer)?.pointee {
                        self.dispatchProperty(name: String(cString: property.name), format: property.format, data: property.data)
                    }
                case MPV_EVENT_VIDEO_RECONFIG:
                    DispatchQueue.main.async { [weak self] in self?.playback?.rendered(true) }
                case MPV_EVENT_END_FILE:
                    let pointer = UnsafeMutablePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data))
                    let reason = pointer?.pointee.reason ?? MPV_END_FILE_REASON_EOF
                    if reason == MPV_END_FILE_REASON_ERROR {
                        let code = pointer.map { String(cString: mpv_error_string($0.pointee.error)) } ?? "播放失败"
                        let tail = self.logTail()
                        DispatchQueue.main.async { [weak self] in
                            self?.playback?.ended(tail.isEmpty ? code : "\(code)（\(tail)）")
                        }
                    } else if reason == MPV_END_FILE_REASON_EOF {
                        DispatchQueue.main.async { [weak self] in self?.playback?.ended(nil) }
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    let message = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data))
                    if let message {
                        let level = String(cString: message.pointee.level)
                        let text = String(cString: message.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
                        NSLog("mpv[\(level)] %@", text)
                        if level == "warn" || level == "error" || level == "fatal" {
                            self.appendLog("[\(level)] \(text)")
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default:
                    break
                }
            }
        }
    }

    private func dispatchProperty(name: String, format: mpv_format, data: UnsafeMutableRawPointer?) {
        var value: Any?
        switch format {
        case MPV_FORMAT_DOUBLE:
            value = data.map { UnsafePointer<Double>(OpaquePointer($0))?.pointee ?? 0 }
        case MPV_FORMAT_FLAG:
            value = data.map { (UnsafePointer<Int64>(OpaquePointer($0))?.pointee ?? 0) > 0 }
        case MPV_FORMAT_STRING:
            value = data.flatMap { raw in
                // MPV_FORMAT_STRING 的 data 是 char **（指向字符串指针的指针）。
                guard let inner = UnsafePointer<UnsafePointer<CChar>?>(OpaquePointer(raw))?.pointee else { return nil }
                return String(cString: inner)
            }
        default:
            value = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch name {
            case "time-pos":
                self.playback?.updateElapsed(value as? Double ?? 0)
            case "duration":
                self.playback?.updateDuration(value as? Double ?? 0)
            case "pause":
                self.playback?.updatePaused(value as? Bool ?? true)
            case "core-idle":
                self.playback?.updateCoreIdle(value as? Bool ?? true)
            default:
                self.onPropertyChange?(name, value)
            }
        }
    }

    // MARK: - 后台切换

    @objc private func enterBackground() {
        backgroundPaused = !getFlag("pause")
        setFlag("pause", true)
        checkError(mpv_set_option_string(mpv, "vid", "no"))
    }

    @objc private func enterForeground() {
        checkError(mpv_set_option_string(mpv, "vid", "auto"))
        if backgroundPaused == false {
            setFlag("pause", false)
        }
    }

    // MARK: - mpv 工具

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func command(_ command: String, args: [String] = []) {
        guard mpv != nil else { return }
        var arguments = [command] + args
        var pointers = arguments.map { UnsafePointer<CChar>(strdup($0)) }
        defer { for pointer in pointers { free(UnsafeMutablePointer(mutating: pointer)) } }
        pointers.append(nil)
        checkError(mpv_command(mpv, &pointers))
    }

    private func appendLog(_ text: String) {
        logsLock.lock()
        recentLogs.append(text)
        if recentLogs.count > 4 { recentLogs.removeFirst() }
        logsLock.unlock()
    }

    private func logTail() -> String {
        logsLock.lock()
        defer { logsLock.unlock() }
        return recentLogs.joined(separator: " | ")
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            appendLog("mpv error: " + String(cString: mpv_error_string(status)))
        }
    }
}
