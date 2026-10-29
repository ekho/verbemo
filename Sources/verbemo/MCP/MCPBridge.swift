import Foundation
import ArgumentParser
import Darwin

struct MCPBridgeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Connect a local MCP client to the running Verbemo app over stdio.")
    @Option(name: .long, help: "Private, client-owned directory for downloaded audio (default: private process temporary directory).")
    var outputDir: String?
    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let bridge = MCPBridge(home: .current, outputDirectory: outputDir.map { URL(fileURLWithPath: $0) })
        bridge.run(input: STDIN_FILENO, output: STDOUT_FILENO)
    }
}

/// Client adapter only: no library access, app startup, or processing calls.
final class MCPBridge: @unchecked Sendable {
    private let home: Home
    private let outputDirectory: URL
    private let lock = NSLock()
    private let outputLock = NSLock()
    private let work = DispatchGroup()
    private var active: [String: MCPOperation] = [:]
    private var stopping = false
    init(home: Home, outputDirectory: URL? = nil) {
        self.home = home
        let temporary = FileManager.default.temporaryDirectory.path
        let resolved = realpath(temporary, nil)
        let parent = resolved.map { String(cString: $0) } ?? temporary
        if let resolved { free(resolved) }
        self.outputDirectory = outputDirectory ?? URL(fileURLWithPath: parent).appendingPathComponent("verbemo-mcp-\(UUID().uuidString)")
    }
    func run(input: Int32, output: Int32) {
        let outputFlags = fcntl(output, F_GETFL)
        guard outputFlags >= 0, fcntl(output, F_SETFL, outputFlags | O_NONBLOCK) == 0 else { return }
        var pending = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        defer { stopIO(); work.wait(); _ = fcntl(output, F_SETFL, outputFlags) }
        while !lock.withLock({ stopping }) {
            var readable = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&readable, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 { continue }
            guard ready > 0 else { return }
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard line.count <= MCPContract.hardResponseBytes else { return }
                guard let value = try? MCPJSON.parse(line) else {
                    guard write(MCPServer.error(code: -32700, message: "Parse error"), to: output, input: input) else { return }
                    continue
                }
                if value["method"] == .string("notifications/cancelled"), let id = value["params"]?["requestId"], let key = try? id.encoded().base64EncodedString() {
                    lock.withLock { active[key] }?.cancel(); continue
                }
                let key = value["id"].flatMap { try? $0.encoded().base64EncodedString() } ?? UUID().uuidString
                let scope = MCPOperation()
                let accepted = lock.withLock { () -> Bool in
                    guard !stopping, active.count < 8, active[key] == nil else { return false }
                    active[key] = scope; return true
                }
                guard accepted else {
                    if let id = value["id"], !write(MCPServer.error(id: id, code: -32603, message: "Bridge busy"), to: output, input: input) { return }
                    continue
                }
                work.enter()
                let task = Task.detached { [self] in
                    defer { work.leave() }
                    let data = await exchange(line, scope: scope)
                    if !scope.isCancelled, !data.isEmpty, !write(data, to: output, input: input, scope: scope) { stopIO() }
                    _ = lock.withLock { active.removeValue(forKey: key) }
                    scope.cancel()
                }
                scope.onCancel { task.cancel() }
            }
            if pending.count > MCPContract.hardResponseBytes { return }
        }
    }
    private func stopIO() {
        let scopes = lock.withLock { stopping = true; return Array(active.values) }
        scopes.forEach { $0.cancel() }
    }
    private func write(_ data: Data, to fd: Int32, input: Int32, scope: MCPOperation? = nil) -> Bool {
        outputLock.withLock {
            let line = data + Data([10])
            let deadline = Date().addingTimeInterval(30)
            return line.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    guard scope?.isCancelled != true, !lock.withLock({ stopping }), Date() < deadline else { return false }
                    var descriptors = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0), pollfd(fd: input, events: 0, revents: 0)]
                    let ready = Darwin.poll(&descriptors, 2, 100)
                    if ready < 0 && errno == EINTR { continue }
                    guard ready >= 0, descriptors[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL) == 0,
                          descriptors[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) == 0 else { return false }
                    if descriptors[0].revents & Int16(POLLOUT) == 0 { continue }
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    guard count > 0 else { return false }; offset += count
                }
                return true
            }
        }
    }
    func exchange(_ body: Data, scope: MCPOperation = MCPOperation()) async -> Data {
        let original = try? MCPJSON.parse(body)
        let id = original?["id"]
        guard body.count <= MCPContract.hardResponseBytes, original?.object != nil else { return MCPServer.error(code: -32600, message: "Invalid request") }
        if let id {
            switch id {
            case .int: break
            case .string(let text) where text.utf8.count <= 1024: break
            default: return MCPServer.error(code: -32600, message: "Invalid request id")
            }
        }
        do {
            let config = try MCPConfiguration.read(home: home)
            guard config.enabled, let token = try MCPCredentials(home: home).read() else { throw MCPFailure(.serverStopping) }
            let endpoint = URL(string: "http://127.0.0.1:\(config.port)/mcp")!
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await Transfer.request(request, scope: scope)
            guard (200...299).contains(response.statusCode) else { throw MCPFailure(.dataUnreadable) }
            if response.statusCode == 202 { return Data() }
            var data = try Self.decodeReply(bytes, contentType: response.mimeType ?? "")
            guard var envelope = try MCPJSON.parse(data).object, envelope["id"] == id else { throw MCPFailure(.dataUnreadable) }
            if original?["method"] == .string("tools/call"), original?["params"]?["name"] == .string("get_meeting_audio"),
               envelope["error"] == nil, envelope["result"]?["isError"] != .bool(true),
               var content = envelope["result"]?["structuredContent"]?.object {
                guard let items = content["items"]?.array else { throw MCPFailure(.dataUnreadable) }
                let directory = try openOutputDirectory()
                defer { close(directory) }
                var created: [String] = [], finished = false
                defer { if !finished { for name in created { unlinkat(directory, name, 0) } } }
                var downloaded: [MCPJSON] = []
                for item in items {
                    guard !scope.isCancelled, var metadata = item.object,
                          let uri = item["download_uri"]?.string,
                          let url = URL(string: uri), Self.permitted(url, port: config.port),
                          case .int(let size) = item["size_bytes"], size >= 0 else { throw MCPFailure(.dataUnreadable) }
                    let ext = (item["filename"]?.string as NSString?)?.pathExtension.lowercased() ?? ""
                    guard ["caf", "wav", "m4a", "mp3", "flac", "ogg", "opus"].contains(ext) else { throw MCPFailure(.dataUnreadable) }
                    let name = UUID().uuidString + "." + ext
                    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw MCPFailure(.dataUnreadable) }
                    created.append(name)
                    do {
                        var download = URLRequest(url: url)
                        download.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                        _ = try await Transfer.request(download, scope: scope, file: fd, expected: Int64(size))
                        guard !scope.isCancelled, fsync(fd) == 0 else { throw MCPFailure(.dataUnreadable) }
                        close(fd)
                    } catch { close(fd); throw error }
                    metadata["local_path"] = .string(outputDirectory.appendingPathComponent(name).path)
                    downloaded.append(.object(metadata))
                }
                content["items"] = .array(downloaded); content.removeValue(forKey: "resources")
                envelope["result"] = try MCPContract.resultEnvelope(.object(content))
                data = try MCPJSON.object(envelope).encoded()
                guard data.count <= MCPContract.hardResponseBytes, !scope.isCancelled else { throw MCPFailure(.responseTooLarge) }
                finished = true
            }
            return data
        } catch {
            guard let id else { return Data() }
            return MCPServer.error(id: id, code: -32603, message: "Verbemo bridge unavailable or transfer failed; check the running app and local MCP settings")
        }
    }
    static func permitted(_ url: URL, port: Int) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "http",
              components.host == "127.0.0.1", components.port == port, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        let parts = components.percentEncodedPath.split(separator: "/")
        return parts.count == 3 && parts[0] == "audio" && parts[1].hasPrefix("m_") && parts[2].hasPrefix("a_")
            && parts.dropFirst().allSatisfy { $0.dropFirst(2).count == 64 && $0.dropFirst(2).allSatisfy({ $0.isHexDigit && $0.isASCII }) }
    }
    static func decodeReply(_ bytes: Data, contentType: String) throws -> Data {
        guard bytes.count <= MCPContract.hardResponseBytes else { throw MCPFailure(.responseTooLarge) }
        if contentType == "application/json" { return bytes }
        guard contentType == "text/event-stream", let text = String(data: bytes, encoding: .utf8) else { throw MCPFailure(.dataUnreadable) }
        var events: [Data] = [], lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty {
                if !lines.isEmpty { events.append(Data(lines.joined(separator: "\n").utf8)); lines.removeAll() }
            } else if line.hasPrefix("data:") { let value = line.dropFirst(5); lines.append(String(value.first == " " ? value.dropFirst() : value)) }
        }
        guard lines.isEmpty, events.count == 1 else { throw MCPFailure(.dataUnreadable) }
        return events[0]
    }
    private func openOutputDirectory() throws -> Int32 {
        guard outputDirectory.path.hasPrefix("/") else { throw MCPFailure(.invalidParams) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let parts = outputDirectory.path.split(separator: "/")
        for (index, part) in parts.enumerated() {
            let name = String(part)
            if index == parts.count - 1, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { close(fd); throw MCPFailure(.dataUnreadable) }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd); fd = next
            guard fd >= 0 else { throw MCPFailure(.dataUnreadable) }
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw MCPFailure(.dataUnreadable) }
        return fd
    }
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private var data = Data()
        private var response: HTTPURLResponse?
        private var received: Int64 = 0
        private let file: Int32?
        private let expected: Int64?
        private let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        init(file: Int32?, expected: Int64?, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            self.file = file; self.expected = expected; self.continuation = continuation
        }
        static func request(_ request: URLRequest, scope: MCPOperation, file: Int32? = nil, expected: Int64? = nil) async throws -> (Data, HTTPURLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = Transfer(file: file, expected: expected, continuation: continuation)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.connectionProxyDictionary = [:]
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = file == nil ? 30 : 24 * 60 * 60
                configuration.httpMaximumConnectionsPerHost = 1
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: request)
                scope.onCancel { task.cancel(); session.invalidateAndCancel() }
                task.resume()
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                  expected == nil || (response.statusCode == 200 && response.expectedContentLength == expected),
                  file != nil || response.expectedContentLength <= MCPContract.hardResponseBytes else { completionHandler(.cancel); return }
            self.response = response; completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
            received += Int64(bytes.count)
            guard received <= (expected ?? Int64(MCPContract.hardResponseBytes)) else { dataTask.cancel(); return }
            if let file {
                let success = bytes.withUnsafeBytes { buffer -> Bool in
                    var offset = 0
                    while offset < buffer.count {
                        let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { return false }; offset += count
                    }
                    return true
                }
                if !success { dataTask.cancel() }
            } else { data.append(bytes) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let response, expected == nil || received == expected else { continuation.resume(throwing: MCPFailure(.dataUnreadable)); return }
            continuation.resume(returning: (data, response))
        }
    }
}
