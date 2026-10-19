import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One token per conversion, inherited by structured work via TaskLocal.
final class ConversionCancellation: @unchecked Sendable {
    @TaskLocal static var current: ConversionCancellation?
    private let lock = NSLock()
    private var cancelled = false
    private var callbacks: [UUID: @Sendable () -> Void] = [:]

    @discardableResult
    func register(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let invoke = cancelled
        if !invoke { callbacks[id] = callback }
        lock.unlock()
        if invoke { callback() }
        return id
    }
    func unregister(_ id: UUID) {
        lock.lock(); callbacks.removeValue(forKey: id); lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func check() throws {
        if isCancelled || Task<Never, Never>.isCancelled { throw CancellationError() }
    }
    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let pending = Array(callbacks.values)
        callbacks.removeAll()
        lock.unlock()
        // Reentrant callbacks must never execute under the registry lock.
        for callback in pending { callback() }
    }
    static func checkCurrent() throws {
        try Task<Never, Never>.checkCancellation()
        try current?.check()
    }
}

/// Owns only the launched child. Never sends signals to external Office/iWork apps.
/// Callback returns immediately, including when called by the main actor.
final class ConversionChild: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var stopped = false
    init(_ process: Process) { self.process = process }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [self] in
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
