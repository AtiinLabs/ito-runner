import Foundation

/// How long a plugin call may wait on host work before the runner gives up on it. These are
/// watchdogs against hung host work, not network timeouts: the app's own timeouts (request,
/// resource, Cloudflare challenge) should always fire first.
public struct HostCallTimeouts: Sendable, Equatable {
    /// A network request, including any challenge the host solves on the plugin's behalf.
    public var net: TimeInterval
    /// Loading a page or running a script in the host's web view.
    public var webview: TimeInterval

    public init(net: TimeInterval = 120, webview: TimeInterval = 60) {
        self.net = net
        self.webview = webview
    }
}

/// Cancellation of one runner job. The caller's task cancels it; host work the job is waiting on
/// registers what to do when that happens.
final class CallToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelAction: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            defer { cancelAction = nil }
            return cancelAction
        }
        action?()
    }

    /// Runs `action` when the job is cancelled, or right away if it already is. Replaces any
    /// earlier action; nil removes it.
    func setCancelAction(_ action: (@Sendable () -> Void)?) {
        let runNow: Bool = lock.withLock {
            guard !cancelled else { return true }
            cancelAction = action
            return false
        }
        if runNow { action?() }
    }
}

/// How waiting on host work ended.
enum HostCallOutcome<Value> {
    case completed(Value)
    case failed(any Error)
    case cancelled
    case timedOut
}

/// Where the host work's outcome is published once. The first outcome wins and wakes the
/// waiting thread; later ones (a result arriving after a timeout) are dropped.
final class HostCallCell<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: HostCallOutcome<Value>?

    func finish(_ outcome: HostCallOutcome<Value>) {
        let published: Bool = lock.withLock {
            guard self.outcome == nil else { return false }
            self.outcome = outcome
            return true
        }
        if published { semaphore.signal() }
    }

    /// Blocks until an outcome is published or `deadline` passes.
    func wait(until deadline: DispatchTime) -> HostCallOutcome<Value> {
        if semaphore.wait(timeout: deadline) == .timedOut {
            finish(.timedOut)
        }
        return lock.withLock { outcome ?? .timedOut }
    }
}

extension WasmBridge {
    /// Runs async host work for the current plugin call and blocks the runner's queue until the
    /// work finishes, the call is cancelled, or `timeout` passes. On cancellation or timeout the
    /// work is cancelled and its late result is dropped.
    func waitForHostWork<Value: Sendable>(
        timeout: TimeInterval,
        _ work: @escaping @Sendable () async throws -> Value
    ) -> HostCallOutcome<Value> {
        let token = activeCallToken
        if token?.isCancelled == true { return .cancelled }

        let cell = HostCallCell<Value>()
        let task = Task {
            do {
                cell.finish(.completed(try await work()))
            } catch {
                cell.finish(.failed(error))
            }
        }
        token?.setCancelAction {
            cell.finish(.cancelled)
            task.cancel()
        }
        let outcome = cell.wait(until: .now() + timeout)
        token?.setCancelAction(nil)
        if case .completed = outcome {} else { task.cancel() }
        return outcome
    }
}
