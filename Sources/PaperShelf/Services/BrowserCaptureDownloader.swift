import Foundation
import PDFKit
import PaperCore

/// Downloads public PDFs without browser cookies, ambient credentials, proxies, or an HTTP listener.
/// DNS is checked and pinned to the actual curl connection on every redirect.
enum BrowserCaptureDownloader {
    static func download(_ url: URL, to destination: URL) async throws {
        let worker = Task.detached(priority: .userInitiated) { try downloadSynchronously(url, to: destination) }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func downloadSynchronously(_ input: URL, to destination: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("PaperShelfCapture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let body = work.appendingPathComponent("response.pdf")
        let headers = work.appendingPathComponent("headers.txt")
        let errors = work.appendingPathComponent("errors.txt")
        var current = input
        for redirect in 0...5 {
            try Task.checkCancellation()
            current = try BrowserCaptureNetworkPolicy.publicURL(current.absoluteString)
            let addresses = try BrowserCaptureNetworkPolicy.publicAddresses(for: current)
            try Task.checkCancellation()
            let host = current.host!.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let port = current.port ?? (current.scheme == "https" ? 443 : 80)
            let resolved = addresses.map { $0.contains(":") ? "[\($0)]" : $0 }.joined(separator: ",")
            fm.createFile(atPath: errors.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            let errorHandle = try FileHandle(forWritingTo: errors)
            defer { try? errorHandle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            var arguments = ["--disable", "--silent", "--show-error", "--connect-timeout", "15", "--max-time", "120",
                                 "--max-filesize", String(BrowserCapturePayload.maximumPDFBytes), "--proto", "=http,https",
                                 "--noproxy", "*",
                                 "--user-agent", "PaperShelf/0.2 BrowserCapture", "--header", "Accept: application/pdf",
                                 "--dump-header", headers.path, "--output", body.path, "--url", current.absoluteString]
            if !BrowserCaptureNetworkPolicy.isPublicIPAddress(host) { arguments += ["--resolve", "\(host):\(port):\(resolved)"] }
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle
            try process.run()
            var interruption: Error?
            while process.isRunning {
                if Task.isCancelled { interruption = CancellationError() }
                let bytes = (try? body.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if bytes > BrowserCapturePayload.maximumPDFBytes { interruption = BrowserCaptureError.oversized }
                if interruption != nil { process.terminate(); break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit()
            if let interruption { throw interruption }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                // Do not include raw curl stderr: it can contain private signed-URL query parameters.
                throw BrowserCaptureError.network("HTTP 传输未完成（curl \(process.terminationStatus)）")
            }
            let data = try Data(contentsOf: headers)
            guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else { throw BrowserCaptureError.network("响应头无效") }
            let blocks = text.components(separatedBy: "\r\n\r\n").filter { $0.hasPrefix("HTTP/") }
            guard let block = blocks.last, let statusText = block.components(separatedBy: "\r\n").first,
                  let status = Int(statusText.split(separator: " ").dropFirst().first ?? "") else {
                throw BrowserCaptureError.network("HTTP 状态无效")
            }
            if [301, 302, 303, 307, 308].contains(status) {
                guard redirect < 5,
                      let line = block.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("location:") }),
                      let next = URL(string: String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces), relativeTo: current)?.absoluteURL,
                      !(current.scheme == "https" && next.scheme == "http") else { throw BrowserCaptureError.network("重定向无效或过多") }
                current = try BrowserCaptureNetworkPolicy.publicURL(next.absoluteString)
                continue
            }
            guard status == 200 else { throw BrowserCaptureError.network("服务器返回 HTTP \(status)") }
            let bytes = try body.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 5, bytes <= BrowserCapturePayload.maximumPDFBytes else { throw BrowserCaptureError.oversized }
            let handle = try FileHandle(forReadingFrom: body)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 1024) ?? Data()
            guard prefix.range(of: Data("%PDF-".utf8)) != nil,
                  let document = PDFDocument(url: body), !document.isLocked, document.pageCount > 0 else {
                throw BrowserCaptureError.invalidPDF
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // copyItem refuses replacement. No source or existing attachment is ever overwritten.
            try fm.copyItem(at: body, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return
        }
        throw BrowserCaptureError.network("重定向过多")
    }
}
