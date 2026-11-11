import Foundation

/// 统一的浏览器标识，供采集、取流和图片下载共用。
public enum BrowserProfile {
    public static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
}

/// 由配置指定的 spider 插件地址。导入配置时写入，采集规则按需读取。
public final class SpiderSource: @unchecked Sendable {
    public static let shared = SpiderSource()
    private let lock = NSLock()
    private var value: String?

    public var url: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func update(_ spider: String?) {
        lock.lock()
        value = spider
        lock.unlock()
    }
}
