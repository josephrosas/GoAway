import Foundation

public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }

    public func cancel() {
        lock.lock()
        flagged = true
        lock.unlock()
    }
}
