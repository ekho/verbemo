import Foundation
import Testing
import Darwin
import CryptoKit
@testable import verbemo

@Suite(.freshHome) struct MCPTransportTests {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
        func increment() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }
    private func socket(port: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { close(fd); throw MCPFailure(.dataUnreadable) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }
    private func raw(port: Int, headers: String, body: String = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) throws -> String {
        let fd = try socket(port: port)
        defer { close(fd) }
        let data = Data("POST /mcp HTTP/1.1\r\n\(headers)Content-Type: application/json\r\nAccept: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while true { let count = Darwin.read(fd, &bytes, bytes.count); if count <= 0 { break }; result.append(contentsOf: bytes.prefix(count)) }
        return String(decoding: result, as: UTF8.self)
    }
    @Test func headerSecurityBeforeLookupAndPortConflict() async throws {
        let calls = Counter(), root = try fixture(), token = String(repeating: "c", count: 64)
        let gate: MCPHTTP.Gate = { _ in _ = calls.increment(); return .init(runtime: .init(root: root), settings: nil) }
        let host = MCPHTTP(port: 55294, token: token, gate: gate)
        try await host.start()
        let another = MCPHTTP(port: 55294, token: token, gate: gate)
        await #expect(throws: MCPFailure.self) { try await another.start() }
        let valid = "Host: 127.0.0.1:55294\r\nAuthorization: Bearer \(token)\r\n"
        for headers in [
            "Authorization: Bearer \(token)\r\n",
            valid + "hOsT: 127.0.0.1:55294\r\n",
            valid + "AUTHORIZATION: Bearer \(token)\r\n",
            valid + "Origin: null\r\n",
            valid + "Origin: http://localhost:55294\r\n",
            valid + "Origin: http://127.0.0.1:55294\r\nOrigin: http://127.0.0.1:55294\r\n",
            "Host: localhost:55294\r\nAuthorization: Bearer \(token)\r\n",
        ] {
            let response = try raw(port: 55294, headers: headers)
            #expect(response.contains(" 401 ") || response.contains(" 403 "))
        }
        #expect(calls.count == 0)
        #expect(try raw(port: 55294, headers: valid + "Origin: http://127.0.0.1:55294\r\n").contains(" 200 "))
        #expect(calls.count > 0)
        #expect(try raw(port: 55294, headers: valid + "X-Large: " + String(repeating: "x", count: 17000) + "\r\n").isEmpty)
        await host.stop()
    }
    @Test func disconnectAndStopCancelActualWork() async throws {
        let started = Counter(), cancelled = Counter(), root = try fixture(), token = String(repeating: "d", count: 64)
        let host = MCPHTTP(port: 55295, token: token, gate: { scope in .init(runtime: .init(root: root, cancelled: { scope.isCancelled }), settings: nil) }, query: { _, _, runtime, _ in
            _ = started.increment()
            while !runtime.cancelled() { usleep(1000) }
            _ = cancelled.increment()
            throw MCPFailure(.serverStopping)
        })
        try await host.start()
        let fd = try socket(port: 55295)
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting","arguments":{}}}"#
        let text = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:55295\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nAccept: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = Data(text.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        for _ in 0..<200 where started.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(started.count == 1)
        close(fd)
        for _ in 0..<200 where cancelled.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(cancelled.count == 1)
        let request = Task { try await wire(port: 55295, token: token, method: "tools/call", params: .object(["name": .string("get_meeting")])) }
        for _ in 0..<200 where started.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        host.stopAdmission()
        for _ in 0..<200 where cancelled.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(cancelled.count == 2)
        _ = try? await request.value
        await host.stop()
    }
    @Test @MainActor func controllerDoesNotCreateTokenOnStartupAndFailsClosedAfterCorruption() async throws {
        let root = try fixture(), home = Home.current
        try FileManager.default.createDirectory(at: home.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"mcp":{"enabled":true,"port":55296}}"#.utf8).write(to: home.configFile)
        let controller = MCPController(home: home, snapshot: { .init(root: root) })
        controller.refresh()
        #expect(try MCPCredentials(home: home).read() == nil)
        #expect(controller.listeningAddress == nil)
        controller.setEnabled(true)
        for _ in 0..<200 where controller.listeningAddress == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.listeningAddress == "http://127.0.0.1:55296/mcp")
        let old = try #require(try MCPCredentials(home: home).read())
        controller.rotateToken()
        #expect(try MCPCredentials(home: home).read() != old)
        for _ in 0..<200 where controller.listeningAddress == nil { try await Task.sleep(for: .milliseconds(5)) }
        let token = try #require(try MCPCredentials(home: home).read())
        #expect(try await wire(port: 55296, token: token)["result"]?["tools"]?.array?.count == 8)
        try Data("broken".utf8).write(to: home.configFile)
        // No config watcher refresh: each request must notice valid → corrupt itself.
        do { _ = try await wire(port: 55296, token: token); Issue.record("Corrupt config admitted a request") } catch { }
        #expect(controller.listeningAddress == nil)
        #expect(try String(contentsOf: home.configFile, encoding: .utf8) == "broken")
        let begin = Date(); await controller.stop()
        #expect(Date().timeIntervalSince(begin) < 2.2)
    }
    private func wire(port: Int, token: String, method: String = "tools/list", params: MCPJSON? = nil, id: MCPJSON = .int(1)) async throws -> MCPJSON {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        var value: [String: MCPJSON] = ["jsonrpc": .string("2.0"), "id": id, "method": .string(method)]
        value["params"] = params
        request.httpBody = try MCPJSON.object(value).encoded()
        return try MCPJSON.parse(await URLSession.shared.data(for: request).0)
    }
    private func fixture(bytes: Int = 128) throws -> URL {
        let root = URL(fileURLWithPath: Home.current.url.path.replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored)).appendingPathComponent("library")
        let directory = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"title":"Synthetic","started":"2026-10-28T08:00:00Z","ended":"2026-10-28T08:01:00Z","files":{"source":"source.m4a"}}"#.utf8).write(to: directory.appendingPathComponent("meta.json"))
        try Data(repeating: 42, count: bytes).write(to: directory.appendingPathComponent("source.m4a"))
        return root
    }
    @Test func protocolMethodsToolsAndResponseCap() async throws {
        let root = try fixture(), token = String(repeating: "b", count: 64)
        let host = MCPHTTP(port: 55292, token: token, gate: { scope in .init(runtime: .init(root: root, cancelled: { scope.isCancelled }), settings: nil) }, query: { name, _, _, _ in
            if name == "get_meeting" { return .object(["huge": .string(String(repeating: "\"Ж\n", count: 300000))]) }
            throw MCPFailure(.invalidParams)
        })
        try await host.start()
        let initialized = try await wire(port: 55292, token: token, method: "initialize", params: .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])]))
        #expect(initialized["result"]?["protocolVersion"] == .string("2025-11-25"))
        let listed = try await wire(port: 55292, token: token)
        #expect(listed["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } == MCPContract.tools)
        for tool in listed["result"]?["tools"]?.array ?? [] {
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(true))
            #expect(tool["annotations"]?["destructiveHint"] == .bool(false))
        }
        let unknown = try await wire(port: 55292, token: token, method: "unknown")
        #expect(unknown["error"]?["code"] == .int(-32601))
        let invalid = try await wire(port: 55292, token: token, method: "tools/call", params: .object(["name": .string("list_meetings"), "arguments": .object([:])]))
        #expect(invalid["error"]?["code"] == .int(-32602))
        let huge = try await wire(port: 55292, token: token, method: "tools/call", params: .object(["name": .string("get_meeting")]))
        #expect(huge["result"]?["structuredContent"]?["code"] == .string("response_too_large"))
        #expect(try huge.encoded().count < MCPContract.hardResponseBytes)
        await host.stop()
    }
    @Test func audioRangesLargeStreamAndBridgeAcquireExactBytes() async throws {
        let root = try fixture(bytes: 38_400_044), home = Home.current
        try FileManager.default.createDirectory(at: home.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"mcp":{"enabled":true,"port":55293}}"#.utf8).write(to: home.configFile)
        let token = try MCPCredentials(home: home).rotate()
        let host = MCPHTTP(port: 55293, token: token, gate: { scope in .init(runtime: .init(root: root, port: 55293, cancelled: { scope.isCancelled }), settings: nil) })
        try await host.start()
        let meeting = MCPContract.meetingID(root: root, relative: "meeting")
        let result = try await wire(port: 55293, token: token, method: "tools/call", params: .object(["name": .string("get_meeting_audio"), "arguments": .object(["meeting_id": .string(meeting)])]))
        #expect(result["result"]?["isError"] == .bool(false), "\(result)")
        #expect(result["result"]?["content"]?.array?.last?["type"] == .string("resource_link"))
        let uri = try #require(result["result"]?["structuredContent"]?["items"]?.array?.first?["download_uri"]?.string)
        for (range, expected) in [("bytes=3-5", 3), ("bytes=-10", 10), ("bytes=38400040-", 4)] {
            var request = URLRequest(url: URL(string: uri)!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect(data == Data(repeating: 42, count: expected))
            #expect((response as? HTTPURLResponse)?.statusCode == 206)
            #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        }
        var head = URLRequest(url: URL(string: uri)!)
        head.httpMethod = "HEAD"; head.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (empty, headResponse) = try await URLSession.shared.data(for: head)
        #expect(empty.isEmpty); #expect(headResponse.expectedContentLength == 38_400_044)
        head.httpMethod = "GET"; head.setValue("bytes=99999999-", forHTTPHeaderField: "Range")
        #expect((try await URLSession.shared.data(for: head).1 as? HTTPURLResponse)?.statusCode == 416)
        let bridge = MCPBridge(home: home, outputDirectory: root.deletingLastPathComponent().appendingPathComponent("downloads"))
        let body = try MCPJSON.object(["jsonrpc": .string("2.0"), "id": .int(9), "method": .string("tools/call"), "params": .object(["name": .string("get_meeting_audio"), "arguments": .object(["meeting_id": .string(meeting)])])]).encoded()
        let copied = await bridge.exchange(body)
        #expect(!String(decoding: copied, as: UTF8.self).contains(token))
        let local = try #require(try MCPJSON.parse(copied)["result"]?["structuredContent"]?["items"]?.array?.first?["local_path"]?.string)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: local))
        #expect(bytes.count == 38_400_044)
        #expect(SHA256.hash(data: bytes) == SHA256.hash(data: Data(repeating: 42, count: 38_400_044)))
        // Replacement must not be served through its predecessor's revision-bound URL.
        try Data("replacement".utf8).write(to: root.appendingPathComponent("meeting/source.m4a"), options: .atomic)
        head.setValue(nil, forHTTPHeaderField: "Range")
        #expect((try await URLSession.shared.data(for: head).1 as? HTTPURLResponse)?.statusCode == 404)
        await host.stop()
    }
    @Test func bridgeParsesOnlyFiniteSingleReplyAndRejectsForeignAudio() throws {
        let json = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        #expect(try MCPBridge.decodeReply(Data("event: message\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8), contentType: "text/event-stream") == json)
        for bad in ["data: {}", "data: {}\n\ndata: {}\n\n", "event: done\n\n"] {
            #expect(throws: MCPFailure.self) { try MCPBridge.decodeReply(Data(bad.utf8), contentType: "text/event-stream") }
        }
        let path = "/audio/m_" + String(repeating: "a", count: 64) + "/a_" + String(repeating: "b", count: 64)
        #expect(MCPBridge.permitted(URL(string: "http://127.0.0.1:55293" + path)!, port: 55293))
        for prefix in ["http://localhost:55293", "http://127.0.0.1:55294", "https://127.0.0.1:55293", "http://u:p@127.0.0.1:55293", "http://example.test"] {
            #expect(!MCPBridge.permitted(URL(string: prefix + path)!, port: 55293))
        }
    }
    @Test func bridgeSeveralTracksAndPrivateDirectorySafety() async throws {
        let root = try fixture(), home = Home.current, directory = root.appendingPathComponent("meeting")
        try Data(#"{"files":{"mic":"mic.caf","system":"system.caf"}}"#.utf8).write(to: directory.appendingPathComponent("meta.json"))
        try Data(repeating: 1, count: 100).write(to: directory.appendingPathComponent("mic.caf"))
        try Data(repeating: 2, count: 200).write(to: directory.appendingPathComponent("system.caf"))
        try FileManager.default.createDirectory(at: home.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"mcp":{"enabled":true,"port":55297}}"#.utf8).write(to: home.configFile)
        let token = try MCPCredentials(home: home).rotate()
        let host = MCPHTTP(port: 55297, token: token, gate: { scope in .init(runtime: .init(root: root, port: 55297, cancelled: { scope.isCancelled }), settings: nil) })
        try await host.start()
        let body = try MCPJSON.object(["jsonrpc": .string("2.0"), "id": .string("audio"), "method": .string("tools/call"), "params": .object(["name": .string("get_meeting_audio"), "arguments": .object(["meeting_id": .string(MCPContract.meetingID(root: root, relative: "meeting"))])])]).encoded()
        let output = root.appendingPathComponent("private")
        let copied = try MCPJSON.parse(await MCPBridge(home: home, outputDirectory: output).exchange(body))
        let items = try #require(copied["result"]?["structuredContent"]?["items"]?.array)
        #expect(items.count == 2)
        for item in items {
            let path = try #require(item["local_path"]?.string)
            var info = stat(); #expect(lstat(path, &info) == 0); #expect(info.st_mode & 0o777 == 0o600)
            #expect(Int(info.st_size) == item["size_bytes"]?.number.map(Int.init))
        }
        #expect(chmod(output.path, 0o755) == 0)
        let unsafe = try MCPJSON.parse(await MCPBridge(home: home, outputDirectory: output).exchange(body))
        #expect(unsafe["error"] != nil)
        let link = root.appendingPathComponent("link")
        #expect(symlink(output.path, link.path) == 0)
        let linked = try MCPJSON.parse(await MCPBridge(home: home, outputDirectory: link).exchange(body))
        #expect(linked["error"] != nil)
        await host.stop()
        let absent = await MCPBridge(home: home).exchange(body)
        #expect(try MCPJSON.parse(absent)["error"] != nil)
        #expect(!String(decoding: absent, as: UTF8.self).contains(token))
    }
    @Test func bridgeRemovesPartialFilesOnTruncatedDownload() async throws {
        let root = try fixture(bytes: 1_000_000), home = Home.current, calls = Counter()
        try FileManager.default.createDirectory(at: home.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"mcp":{"enabled":true,"port":55298}}"#.utf8).write(to: home.configFile)
        let token = try MCPCredentials(home: home).rotate()
        let host = MCPHTTP(port: 55298, token: token, gate: { scope in
            if calls.increment() >= 5 { throw MCPFailure(.serverStopping) }
            return .init(runtime: .init(root: root, port: 55298, cancelled: { scope.isCancelled }), settings: nil)
        })
        try await host.start()
        let output = root.appendingPathComponent("downloads")
        let body = try MCPJSON.object(["jsonrpc": .string("2.0"), "id": .int(3), "method": .string("tools/call"), "params": .object(["name": .string("get_meeting_audio"), "arguments": .object(["meeting_id": .string(MCPContract.meetingID(root: root, relative: "meeting"))])])]).encoded()
        let result = await MCPBridge(home: home, outputDirectory: output).exchange(body)
        #expect(try MCPJSON.parse(result)["error"] != nil)
        #expect(calls.count >= 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        await host.stop()
    }
    @Test func tokenStoreSymlinkAndWriteFailureStayClosed() throws {
        let store = MCPCredentials(home: Home.current)
        _ = try store.rotate()
        let outside = Home.current.url.appendingPathComponent("outside")
        try Data(String(repeating: "a", count: 64).utf8).write(to: outside)
        try FileManager.default.removeItem(at: store.url)
        #expect(symlink(outside.path, store.url.path) == 0)
        #expect(throws: MCPFailure.self) { try store.read() }
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        #expect(throws: MCPFailure.self) { try store.rotate() }
        #expect(throws: MCPFailure.self) { try store.read() }
    }
    @Test @MainActor func lifecycleRevokesActiveAudioForRotationRootConfigAndExit() async throws {
        let root = try fixture(bytes: 38_400_044), home = Home.current
        try FileManager.default.createDirectory(at: home.configDirectory, withIntermediateDirectories: true)
        for action in ["rotate", "root", "config", "stop"] {
            try Data(#"{"mcp":{"enabled":true,"port":55299}}"#.utf8).write(to: home.configFile)
            let token = try MCPCredentials(home: home).rotate()
            var selectedRoot = root
            let controller = MCPController(home: home, snapshot: { .init(root: selectedRoot) })
            controller.refresh()
            for _ in 0..<200 where controller.listeningAddress == nil { try await Task.sleep(for: .milliseconds(5)) }
            #expect(controller.listeningAddress != nil, "\(action): \(controller.status)")
            let meeting = MCPContract.meetingID(root: root, relative: "meeting")
            let result = try await wire(port: 55299, token: token, method: "tools/call", params: .object(["name": .string("get_meeting_audio"), "arguments": .object(["meeting_id": .string(meeting)])]))
            let uri = try #require(result["result"]?["structuredContent"]?["items"]?.array?.first?["download_uri"]?.string)
            let fd = try socket(port: 55299)
            let text = "GET \(URL(string: uri)!.path) HTTP/1.1\r\nHost: 127.0.0.1:55299\r\nAuthorization: Bearer \(token)\r\n\r\n"
            _ = Data(text.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            let first = await Task.detached { () -> Int in
                var buffer = [UInt8](repeating: 0, count: 4096)
                return Darwin.read(fd, &buffer, buffer.count)
            }.value
            #expect(first > 0)
            switch action {
            case "rotate": controller.rotateToken()
            case "root": selectedRoot = root.appendingPathComponent("other"); controller.refresh()
            case "config": try Data("broken".utf8).write(to: home.configFile); controller.refresh()
            default: controller.stopAdmission()
            }
            let remaining = await Task.detached { () -> Int in
                var total = 0, buffer = [UInt8](repeating: 0, count: 65536)
                while true { let count = Darwin.read(fd, &buffer, buffer.count); if count <= 0 { break }; total += count }
                close(fd); return total
            }.value
            #expect(first + remaining < 38_400_044, "\(action) must terminate the active transfer")
            await controller.stop()
        }
    }
    @Test func connectionAndOperationLimitsHaveNoQueue() async throws {
        let root = try fixture(), started = Counter(), token = String(repeating: "e", count: 64)
        let host = MCPHTTP(port: 55300, token: token, gate: { scope in .init(runtime: .init(root: root, cancelled: { scope.isCancelled }), settings: nil) }, query: { _, _, runtime, _ in
            _ = started.increment(); while !runtime.cancelled() { usleep(1000) }; throw MCPFailure(.serverStopping)
        })
        try await host.start()
        var sockets: [Int32] = []
        for _ in 0..<16 { sockets.append(try socket(port: 55300)) }
        for _ in 0..<200 where host.activeConnections < 16 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(host.activeConnections == 16)
        let rejected = try socket(port: 55300)
        var byte: UInt8 = 0
        #expect(Darwin.read(rejected, &byte, 1) == 0); close(rejected)
        for fd in sockets { close(fd) }; sockets.removeAll()
        for _ in 0..<200 where host.activeConnections > 0 { try await Task.sleep(for: .milliseconds(5)) }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting"}}"#
        let headers = "Host: 127.0.0.1:55300\r\nAuthorization: Bearer \(token)\r\n"
        for _ in 0..<8 {
            let fd = try socket(port: 55300); sockets.append(fd)
            let text = "POST /mcp HTTP/1.1\r\n\(headers)Content-Type: application/json\r\nAccept: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            _ = Data(text.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        for _ in 0..<200 where started.count < 8 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(started.count == 8)
        #expect(try raw(port: 55300, headers: headers, body: body).contains(" 503 "))
        #expect(started.count == 8)
        for fd in sockets { close(fd) }
        await host.stop()
    }
    @Test(arguments: [false, true]) func cancelledQueriesRetainCapacityAndStopWaitsForCompletion(deadline: Bool) async throws {
        let root = try fixture(), token = String(repeating: "b", count: 64), port = deadline ? 55308 : 55307
        let started = Counter(), cancelled = Counter(), released = Counter(), finished = Counter(), stopped = Counter()
        let host = MCPHTTP(port: port, token: token, gate: { scope in
            .init(runtime: .init(root: root, cancelled: { scope.isCancelled }), settings: nil)
        }, query: { _, _, runtime, _ in
            let ticket = started.increment()
            while !runtime.cancelled() { usleep(1000) }
            _ = cancelled.increment()
            // Deliberately model a read/cleanup that cannot finish at the cancellation signal.
            while released.count < ticket { usleep(1000) }
            _ = finished.increment()
            throw MCPFailure(.serverStopping)
        })
        try await host.start()
        var sockets: [Int32] = []
        defer {
            for fd in sockets { close(fd) }
            for _ in 0..<8 { _ = released.increment() }
        }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting"}}"#
        let headers = "Host: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
        let request = Data("POST /mcp HTTP/1.1\r\n\(headers)Content-Type: application/json\r\nAccept: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        for _ in 0..<8 {
            let fd = try socket(port: port); sockets.append(fd)
            _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        for _ in 0..<200 where started.count < 8 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(started.count == 8)
        if !deadline { for fd in sockets { close(fd) }; sockets.removeAll() }
        for _ in 0..<(deadline ? 3500 : 200) where cancelled.count < 8 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled.count == 8)
        #expect(finished.count == 0)
        // Give the cancelled SDK response waiters time to unwind, while actual reads stay held.
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<3 { #expect(try raw(port: port, headers: headers).contains(" 503 ")) }
        #expect(started.count == 8)
        _ = released.increment()
        for _ in 0..<200 where finished.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(finished.count == 1)
        #expect(try raw(port: port, headers: headers).contains(" 200 "))
        let stopping = Task { await host.stop(); _ = stopped.increment() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(stopped.count == 0)
        for _ in 0..<7 { _ = released.increment() }
        await stopping.value
        #expect(finished.count == 8)
        #expect(stopped.count == 1)
    }

    @Test func jsonDeadlineCancelsHandlerAndTransportWaiter() async throws {
        let root = try fixture(), cancelled = Counter(), token = String(repeating: "f", count: 64)
        let host = MCPHTTP(port: 55301, token: token, gate: { scope in .init(runtime: .init(root: root, cancelled: { scope.isCancelled }), settings: nil) }, query: { _, _, runtime, _ in
            while !runtime.cancelled() { usleep(1000) }
            _ = cancelled.increment(); throw MCPFailure(.serverStopping)
        })
        try await host.start()
        let started = Date()
        do { _ = try await wire(port: 55301, token: token, method: "tools/call", params: .object(["name": .string("get_meeting")])); Issue.record("Deadline did not close the request") } catch { }
        #expect(Date().timeIntervalSince(started) >= 29)
        #expect(Date().timeIntervalSince(started) < 34)
        for _ in 0..<100 where cancelled.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(cancelled.count == 1)
        await host.stop()
    }
    @Test func twoAudioTransfersLimitAndHeaderBodyIdleDeadlines() async throws {
        let root = try fixture(bytes: 38_400_044), token = String(repeating: "1", count: 64)
        let host = MCPHTTP(port: 55302, token: token, gate: { scope in .init(runtime: .init(root: root, port: 55302, cancelled: { scope.isCancelled }), settings: nil) })
        try await host.start()
        let audio = try MCPQueries.call("get_meeting_audio", arguments: ["meeting_id": .string(MCPContract.meetingID(root: root, relative: "meeting"))], runtime: .init(root: root, port: 55302))
        let uri = try #require(audio["items"]?.array?.first?["download_uri"]?.string)
        var sockets: [Int32] = []
        for _ in 0..<2 {
            let fd = try socket(port: 55302); sockets.append(fd)
            let text = "GET \(URL(string: uri)!.path) HTTP/1.1\r\nHost: 127.0.0.1:55302\r\nAuthorization: Bearer \(token)\r\n\r\n"
            _ = Data(text.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            var bytes = [UInt8](repeating: 0, count: 4096)
            #expect(Darwin.read(fd, &bytes, bytes.count) > 0)
        }
        var request = URLRequest(url: URL(string: uri)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        #expect((try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode == 503)
        for fd in sockets { close(fd) }; sockets.removeAll()
        for text in ["POST /mcp HTTP/1.1\r\n", "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:55302\r\nContent-Length: 100\r\n\r\n{"] {
            let fd = try socket(port: 55302); sockets.append(fd)
            var timeout = timeval(tv_sec: 13, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = Data(text.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        let start = Date()
        for fd in sockets { var byte: UInt8 = 0; #expect(Darwin.read(fd, &byte, 1) == 0); close(fd) }
        #expect(Date().timeIntervalSince(start) >= 9)
        #expect(Date().timeIntervalSince(start) < 13)
        await host.stop()
    }
    @Test @MainActor func settingsExportUsesAppliedValuesAndRedactsSecrets() async throws {
        let root = try fixture(), home = Home.current
        try FileManager.default.createDirectory(at: home.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"mcp":{"enabled":true,"port":55303},"window":true}"#.utf8).write(to: home.configFile)
        let token = try MCPCredentials(home: home).rotate()
        let controller = MCPController(home: home, snapshot: { .init(root: root) })
        try Data(#"{"mcp":{"enabled":true,"port":55303},"window":false,"on_stop":"SECRET","summary":{"openai_base_url":"https://u:SECRET@example.test/path?secret=SECRET#SECRET"}}"#.utf8).write(to: home.configFile)
        controller.refresh()
        for _ in 0..<200 where controller.listeningAddress == nil { try await Task.sleep(for: .milliseconds(5)) }
        let result = try await wire(port: 55303, token: token, method: "tools/call", params: .object(["name": .string("get_settings"), "arguments": .object([:])]))
        let items = try #require(result["result"]?["structuredContent"]?["items"]?.array)
        let window = try #require(items.first { $0["key"] == .string("window") })
        #expect(window["saved_value"] == .bool(false)); #expect(window["applied_value"] == .bool(true)); #expect(window["pending_apply"] == .bool(true))
        #expect(items.first { $0["key"] == .string("recordings_dir") }?["value"] == .string(root.path))
        let text = String(decoding: try result.encoded(), as: UTF8.self)
        #expect(!text.contains("SECRET")); #expect(!text.contains(token))
        await controller.stop()
    }
    @Test func errorEnvelopeBoundsUnvalidatedBusyRequestIDs() throws {
        for id in [MCPJSON.string(String(repeating: "x", count: MCPContract.hardResponseBytes)), .array([.int(1)])] {
            let data = MCPServer.error(id: id, code: -32603, message: "Bridge busy")
            #expect(data.count <= MCPContract.hardResponseBytes)
            #expect(try MCPJSON.parse(data)["id"] == .null)
        }
        #expect(try MCPJSON.parse(MCPServer.error(id: .int(9007199254740993), code: -32603, message: "Bridge busy"))["id"] == .int(9007199254740993))
    }

    @Test func stdioBridgeForwardsRepliesAndCancelsHTTPOnNotificationAndEOF() async throws {
        let root = try fixture(), home = Home.current, entered = Counter(), cancelled = Counter()
        try FileManager.default.createDirectory(at: home.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"mcp":{"enabled":true,"port":55304}}"#.utf8).write(to: home.configFile)
        let token = try MCPCredentials(home: home).rotate()
        let host = MCPHTTP(port: 55304, token: token, gate: { scope in .init(runtime: .init(root: root, cancelled: { scope.isCancelled }), settings: nil) }, query: { _, _, runtime, _ in
            _ = entered.increment(); while !runtime.cancelled() { usleep(1000) }
            _ = cancelled.increment(); throw MCPFailure(.serverStopping)
        })
        try await host.start()
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        #expect(pipe(&input) == 0); #expect(pipe(&output) == 0)
        let readFD = input[0], writeFD = output[1]
        let bridge = MCPBridge(home: home)
        let running = Task.detached { bridge.run(input: readFD, output: writeFD) }
        func send(_ line: String) { _ = Data((line + "\n").utf8).withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) } }
        send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        var response = Data(), byte: UInt8 = 0
        while Darwin.read(output[0], &byte, 1) == 1, byte != 10 { response.append(byte) }
        #expect(try MCPJSON.parse(response)["result"]?["tools"]?.array?.count == 8)
        #expect(!String(decoding: response, as: UTF8.self).contains(token))
        send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_meeting"}}"#)
        for _ in 0..<200 where entered.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(entered.count == 1)
        send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#)
        for _ in 0..<200 where cancelled.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(cancelled.count == 1)
        send(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_meeting"}}"#)
        for _ in 0..<200 where entered.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(entered.count == 2)
        close(input[1]); await running.value
        for _ in 0..<200 where cancelled.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(cancelled.count == 2)
        close(input[0]); close(output[0]); close(output[1]); await host.stop()
    }
    @Test func stdioEOFWaitsUntilPartialAudioIsRemoved() async throws {
        let root = try fixture(bytes: 1_000_000), home = Home.current, calls = Counter()
        try FileManager.default.createDirectory(at: home.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"mcp":{"enabled":true,"port":55305}}"#.utf8).write(to: home.configFile)
        let token = try MCPCredentials(home: home).rotate()
        let host = MCPHTTP(port: 55305, token: token, gate: { scope in
            if calls.increment() >= 5 { while !scope.isCancelled { usleep(1000) }; throw MCPFailure(.serverStopping) }
            return .init(runtime: .init(root: root, port: 55305, cancelled: { scope.isCancelled }), settings: nil)
        })
        try await host.start()
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        #expect(pipe(&input) == 0); #expect(pipe(&output) == 0)
        let readFD = input[0], writeFD = output[1], directory = root.appendingPathComponent("copies")
        let bridge = MCPBridge(home: home, outputDirectory: directory)
        let running = Task.detached { bridge.run(input: readFD, output: writeFD) }
        let request = try MCPJSON.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"), "params": .object(["name": .string("get_meeting_audio"), "arguments": .object(["meeting_id": .string(MCPContract.meetingID(root: root, relative: "meeting"))])])]).encoded() + Data([10])
        _ = request.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
        for _ in 0..<200 where calls.count < 5 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls.count >= 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        close(input[1]); await running.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        close(input[0]); close(output[0]); close(output[1]); await host.stop()
    }
    @Test func fullStdoutCannotBlockEOFShutdown() async throws {
        let root = try fixture(), home = Home.current, calls = Counter(), returned = Counter()
        try FileManager.default.createDirectory(at: home.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"mcp":{"enabled":true,"port":55306}}"#.utf8).write(to: home.configFile)
        let token = try MCPCredentials(home: home).rotate()
        let host = MCPHTTP(port: 55306, token: token, gate: { _ in _ = calls.increment(); return .init(runtime: .init(root: root), settings: nil) })
        try await host.start()
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        #expect(pipe(&input) == 0); #expect(pipe(&output) == 0)
        let flags = fcntl(output[1], F_GETFL)
        #expect(fcntl(output[1], F_SETFL, flags | O_NONBLOCK) == 0)
        let filler = Data(repeating: 120, count: 65536)
        while filler.withUnsafeBytes({ Darwin.write(output[1], $0.baseAddress, $0.count) }) > 0 { }
        #expect(fcntl(output[1], F_SETFL, flags) == 0)
        let readFD = input[0], writeFD = output[1]
        let bridge = MCPBridge(home: home)
        let running = Task.detached { bridge.run(input: readFD, output: writeFD); _ = returned.increment() }
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n".utf8)
        _ = request.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
        for _ in 0..<200 where calls.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls.count >= 2)
        try await Task.sleep(for: .milliseconds(50))
        close(input[1])
        for _ in 0..<200 where returned.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(returned.count == 1)
        // Drain only after the assertion, so a regression cannot leave the test worker blocked.
        _ = fcntl(output[0], F_SETFL, O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 65536)
        while Darwin.read(output[0], &bytes, bytes.count) > 0 { }
        await running.value
        close(input[0]); close(output[0]); close(output[1]); await host.stop()
    }
    @Test func loopbackAuthenticatesAndPreservesConcurrentExactResults() async throws {
        let token = String(repeating: "a", count: 64)
        let home = Home.current
        let host = MCPHTTP(port: 55291, token: token, gate: { scope in
            MCPRequestContext(runtime: .init(root: home.url, cancelled: { scope.isCancelled }), settings: nil)
        }, query: { _, args, _, _ in .object(args) })
        try await host.start()
        defer { host.stopAdmission() }
        func request(_ id: MCPJSON, text: String, authorized: Bool = true) async throws -> (MCPJSON, Int) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:55291/mcp")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if authorized { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            request.httpBody = try MCPJSON.object(["jsonrpc": .string("2.0"), "id": id, "method": .string("tools/call"), "params": .object(["name": .string("get_meeting"), "arguments": .object(["literal": .string(text), "large": .int(9007199254740993)])])]).encoded()
            let (data, response) = try await URLSession.shared.data(for: request)
            return (try MCPJSON.parse(data), (response as! HTTPURLResponse).statusCode)
        }
        async let a = request(.int(1), text: "data:text/plain,first")
        async let b = request(.int(1), text: "data:text/plain,second")
        async let c = request(.string("1"), text: "resourceLink")
        let (left, right, third) = try await (a, b, c)
        #expect(left.0["result"]?["structuredContent"]?["literal"] == .string("data:text/plain,first"))
        #expect(right.0["result"]?["structuredContent"]?["literal"] == .string("data:text/plain,second"))
        #expect(left.0["result"]?["structuredContent"]?["large"] == .int(9007199254740993))
        #expect(third.0["id"] == .string("1"))
        #expect(third.0["result"]?["structuredContent"]?["literal"] == .string("resourceLink"))
        #expect(try await request(.string("1"), text: "no", authorized: false).1 == 401)
        await host.stop()
    }
    @Test func configurationIsStrictAndOffByDefault() throws {
        #expect(try MCPConfiguration.read(home: Home.current).enabled == false)
        #expect(try MCPConfiguration.read(home: Home.current).port == 52763)
        try FileManager.default.createDirectory(at: Home.current.configDirectory, withIntermediateDirectories: true)
        for value in ["true", "1.5", "1023", "65536", "\"52763\""] {
            try Data("{\"mcp\":{\"enabled\":true,\"port\":\(value)}}".utf8).write(to: Home.current.configFile)
            #expect(throws: MCPFailure.self) { try MCPConfiguration.read(home: Home.current) }
        }
        try Data(#"{"mcp":{"enabled":true,"port":55001}}"#.utf8).write(to: Home.current.configFile)
        #expect(try MCPConfiguration.read(home: Home.current).port == 55001)
        try Data("broken".utf8).write(to: Home.current.configFile)
        #expect(throws: MCPFailure.self) { try MCPConfiguration.read(home: Home.current) }
    }
    @Test func credentialsRequireExplicitCreationAndRejectUnsafeFiles() throws {
        let store = MCPCredentials(home: Home.current)
        #expect(try store.read() == nil)
        let token = try store.rotate()
        #expect(token.count == 64)
        #expect(try store.read() == token)
        #expect(MCPCredentials.matches(token, token))
        #expect(!MCPCredentials.matches(token, token + "0"))
        var info = stat()
        #expect(lstat(store.url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(try store.rotate() != token)
        #expect(chmod(store.url.path, 0o644) == 0)
        #expect(throws: MCPFailure.self) { try store.read() }
    }
    @Test func rangesAreSingleAndBounded() throws {
        #expect(try MCPByteRange.parse(nil, size: 10) == .init(start: 0, count: 10, partial: false))
        #expect(try MCPByteRange.parse("bytes=2-4", size: 10) == .init(start: 2, count: 3, partial: true))
        #expect(try MCPByteRange.parse("bytes=8-", size: 10) == .init(start: 8, count: 2, partial: true))
        #expect(try MCPByteRange.parse("bytes=-3", size: 10) == .init(start: 7, count: 3, partial: true))
        for invalid in ["bytes=10-", "bytes=3-2", "bytes=-0", "bytes=0-1,3-4", "items=1-2"] {
            #expect(throws: MCPFailure.self) { try MCPByteRange.parse(invalid, size: 10) }
        }
    }
    @Test func instructionsUseSelectedPortAndEscapedExecutable() throws {
        let executable = "/Applications/Verbemo's Test.app/Contents/MacOS/verbemo"
        for client in MCPConnectionInstructions.Client.allCases {
            let first = MCPConnectionInstructions.text(client: client, port: 55111, executable: executable)
            let next = MCPConnectionInstructions.text(client: client, port: 55112, executable: executable)
            #expect(first.contains("127.0.0.1:55111"))
            #expect(!next.contains("55111"))
            #expect(next.contains("127.0.0.1:55112"))
            #expect(!next.contains("--port"))
        }
    }
}
