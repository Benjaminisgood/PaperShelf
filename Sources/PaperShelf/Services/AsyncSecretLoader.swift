import Foundation

/// A system credential read cannot always be interrupted. Stop awaiting it on
/// cancellation or timeout and discard a late result without launching work.
enum AsyncSecretLoader {
    struct Timeout: LocalizedError {
        var errorDescription: String? { "读取凭据超时；请在系统中检查钥匙串授权后重试。" }
    }

    static func load(timeout: TimeInterval = 30,
                     _ read: @escaping @Sendable () throws -> [String: String]) async throws -> [String: String] {
        try Task.checkCancellation()
        let pending = Pending()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.install(continuation) else { return }
                let deadline = DispatchWorkItem { pending.finish(.failure(Timeout())) }
                pending.installDeadline(deadline)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
                DispatchQueue.global(qos: .userInitiated).async {
                    guard pending.isPending else { return }
                    pending.finish(Result { try read() })
                }
            }
        } onCancel: {
            pending.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return result
    }

    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String: String], Error>?
        private var completed: Result<[String: String], Error>?
        private var deadline: DispatchWorkItem?

        var isPending: Bool {
            lock.lock(); defer { lock.unlock() }
            return completed == nil
        }

        func install(_ value: CheckedContinuation<[String: String], Error>) -> Bool {
            lock.lock()
            if let completed {
                lock.unlock()
                value.resume(with: completed)
                return false
            }
            continuation = value
            lock.unlock()
            return true
        }

        func installDeadline(_ value: DispatchWorkItem) {
            lock.lock()
            let finished = completed != nil
            if !finished { deadline = value }
            lock.unlock()
            if finished { value.cancel() }
        }

        func finish(_ result: Result<[String: String], Error>) {
            lock.lock()
            guard completed == nil else { lock.unlock(); return }
            completed = result
            let waiting = continuation
            continuation = nil
            let timer = deadline
            deadline = nil
            lock.unlock()
            timer?.cancel()
            waiting?.resume(with: result)
        }
    }
}
