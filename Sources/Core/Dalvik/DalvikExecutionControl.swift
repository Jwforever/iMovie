import Foundation

/// 同步字节码和同步网络垫片共用取消信号，避免脱离父 Task 后继续执行。
final class DalvikExecutionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
        try Task.checkCancellation()
    }
}
