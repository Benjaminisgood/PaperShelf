import Foundation
import PaperCore
import Darwin

/// Captures both streams to files, avoiding pipe backpressure for long conversions.
final class PipelineProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var cancellationCleanup: DispatchGroup?
    private var cancellationFailure: String?

    /// A PID alone is not an identity: it may be reused while cancellation waits.
    private struct ProcessIdentity: Hashable {
        let pid: Int32
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64

        static func read(_ pid: Int32) -> (identity: Self, parent: Int32, running: Bool)? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return (Self(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec),
                    Int32(info.pbi_ppid), info.pbi_status != SZOMB)
        }

        var isRunning: Bool {
            guard let current = Self.read(pid) else { return false }
            return current.identity == self && current.running
        }

        func signal(_ value: Int32) {
            guard isRunning else { return }
            Darwin.kill(pid, value)
        }
    }

    func cancel() {
        let pending: (Process, DispatchGroup)? = lock.withLock {
            cancelled = true
            guard cancellationCleanup == nil, let active = process, active.isRunning else { return nil }
            let group = DispatchGroup(); group.enter()
            cancellationCleanup = group
            return (active, group)
        }
        guard let (active, group) = pending else { return }
        // Snapshot before signalling the parent: children can be reparented as
        // soon as it exits, so they must retain their original identities here.
        guard let parent = ProcessIdentity.read(active.processIdentifier)?.identity else { group.leave(); return }
        let initial = [parent] + descendants(of: parent)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            var targets = initial
            var known = Set(initial)
            for target in targets.reversed() { target.signal(SIGTERM) }
            let gracefulDeadline = Date().addingTimeInterval(1.5)
            while Date() < gracefulDeadline && targets.contains(where: { $0.isRunning }) {
                // Include children created by still-identical processes during
                // their shutdown, without following a reused PID's new tree.
                for target in targets where target.isRunning {
                    for child in descendants(of: target) where known.insert(child).inserted {
                        targets.append(child); child.signal(SIGTERM)
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            for target in targets.reversed() { target.signal(SIGKILL) }
            let forcedDeadline = Date().addingTimeInterval(2)
            while Date() < forcedDeadline && targets.contains(where: { $0.isRunning }) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let remaining = targets.filter { $0.isRunning }
            if !remaining.isEmpty {
                lock.withLock { cancellationFailure = "取消未完成，仍有本次处理的进程运行：\(remaining.map { String($0.pid) }.joined(separator: ", "))" }
            }
        }
    }

    /// The application can defer termination until its owned children stop.
    func cancelAndWait() async throws {
        cancel()
        await waitForCleanup(lock.withLock { cancellationCleanup })
        if let failure = lock.withLock({ cancellationFailure }) { throw LearningError.message(failure) }
    }

    private func waitForCleanup(_ cleanup: DispatchGroup?) async {
        guard let cleanup else { return }
        await withCheckedContinuation { continuation in
            cleanup.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }
    }

    private func descendants(of parent: ProcessIdentity) -> [ProcessIdentity] {
        guard parent.isRunning else { return [] }
        let ps = Process(); let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        ps.standardOutput = pipe; ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); ps.waitUntilExit()
        let rows = String(data: data, encoding: .utf8)?.split(separator: "\n").compactMap { line -> (Int32, Int32)? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
            return (pid, ppid)
        } ?? []
        var descendants: [ProcessIdentity] = []; var seen: Set<ProcessIdentity> = [parent]; var pending = [parent]
        while let current = pending.popLast() {
            guard current.isRunning else { continue }
            for (pid, ppid) in rows where ppid == current.pid && pid != ps.processIdentifier {
                guard let child = ProcessIdentity.read(pid), child.running, child.parent == current.pid,
                      current.isRunning, seen.insert(child.identity).inserted else { continue }
                descendants.append(child.identity); pending.append(child.identity)
            }
        }
        return descendants
    }

    func execute(python: String, backend: String, arguments: [String], environment: [String: String], work: URL) async throws -> Data {
        var env = environment
        env["PYTHONPATH"] = backend
        env["PYTHONUNBUFFERED"] = "1"
        // Bundled Python sources are immutable app resources; keep imports from
        // attempting to write bytecode into the signed application bundle.
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return try await executeCommand(executable: python, arguments: ["-m", "papershelf_pipeline"] + arguments,
                                        environment: env, directory: backend, work: work)
    }

    func executeCommand(executable: String, arguments: [String], environment: [String: String], directory: String, work: URL) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) { [self] in
                let output = work.appendingPathComponent("result.json")
                let log = work.appendingPathComponent("progress.log")
                _ = FileManager.default.createFile(atPath: output.path, contents: nil)
                _ = FileManager.default.createFile(atPath: log.path, contents: nil)
                let stdout = try FileHandle(forWritingTo: output)
                let stderr = try FileHandle(forWritingTo: log)
                defer { try? stdout.close(); try? stderr.close() }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env.merge(environment) { _, new in new }
                env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
                task.environment = env
                task.currentDirectoryURL = URL(fileURLWithPath: directory)
                task.standardOutput = stdout; task.standardError = stderr
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    try task.run(); process = task
                }
                task.waitUntilExit()
                let cleanup = lock.withLock { process = nil; return cancellationCleanup }
                await waitForCleanup(cleanup)
                let (wasCancelled, failure) = lock.withLock { (cancelled, cancellationFailure) }
                if let failure { throw LearningError.message(failure) }
                if wasCancelled { throw CancellationError() }
                let data = try Data(contentsOf: output)
                if task.terminationStatus != 0 {
                    let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let detail = result?["error"] as? String ?? String(data: (try? Data(contentsOf: log)) ?? Data(), encoding: .utf8) ?? ""
                    throw LearningError.message("处理失败（\(task.terminationStatus)）：\(detail)")
                }
                return data
            }.value
        }, onCancel: { self.cancel() })
    }
}
