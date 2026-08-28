import Foundation

extension NSLock {
    /// Runs `body` while holding the lock, releasing it even if `body` throws.
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
