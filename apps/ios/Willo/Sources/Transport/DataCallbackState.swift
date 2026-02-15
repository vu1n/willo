import Foundation

/// Thread-safe container for data delivery callbacks.
///
/// Supports primary (direct) and secondary (stream) callbacks with
/// automatic buffering of data that arrives before any callback is set.
/// Callbacks are always invoked outside the lock to prevent deadlocks.
final class TransportDataCallbackState<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((T) -> Void)?
    private var pendingData: [T] = []
    private var isPrimaryCallbackSet = false

    /// Set a primary callback (from setDataCallback). Takes priority over secondary.
    func setPrimaryCallback(_ cb: @escaping (T) -> Void) {
        lock.lock()
        callback = cb
        isPrimaryCallbackSet = true
        let pending = pendingData
        pendingData.removeAll()
        lock.unlock()
        for item in pending {
            cb(item)
        }
    }

    /// Set a secondary callback (from dataStream). Only works if no primary callback is set.
    func setSecondaryCallback(_ cb: @escaping (T) -> Void) {
        lock.lock()
        if isPrimaryCallbackSet {
            lock.unlock()
            return
        }
        callback = cb
        let pending = pendingData
        pendingData.removeAll()
        lock.unlock()
        for item in pending {
            cb(item)
        }
    }

    /// Clear the callback and reset primary flag.
    func clearCallback() {
        lock.lock()
        defer { lock.unlock() }
        callback = nil
        isPrimaryCallbackSet = false
    }

    /// Deliver data to the registered callback, or buffer if none is set.
    func deliverData(_ data: T) {
        lock.lock()
        let cb = callback
        if cb == nil {
            pendingData.append(data)
        }
        lock.unlock()
        cb?(data)
    }

    /// Clear everything — callback, pending data, and primary flag.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        callback = nil
        isPrimaryCallbackSet = false
        pendingData.removeAll()
    }
}
