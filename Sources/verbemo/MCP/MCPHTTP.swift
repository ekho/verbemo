import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

struct MCPByteRange: Equatable, Sendable {
    let start: Int64
    let count: Int64
    let partial: Bool
    static func parse(_ header: String?, size: Int64) throws -> Self {
        guard let header else { return .init(start: 0, count: size, partial: false) }
        guard header.hasPrefix("bytes="), !header.contains(","), size > 0 else { throw MCPFailure(.invalidParams) }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { throw MCPFailure(.invalidParams) }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw MCPFailure(.invalidParams) }
            let count = min(suffix, size)
            return .init(start: size - count, count: count, partial: true)
        }
        guard let start = Int64(parts[0]), start < size,
              let end = parts[1].isEmpty ? size - 1 : Int64(parts[1]), end >= start else { throw MCPFailure(.invalidParams) }
        return .init(start: start, count: min(end, size - 1) - start + 1, partial: true)
    }
}

/// One listener, bounded connections, and a private SDK server per POST. No request logging.
final class MCPHTTP: @unchecked Sendable {
    typealias Gate = @Sendable (MCPOperation) async throws -> MCPRequestContext
    let port: Int
    private let token: String
    private let gate: Gate
    private let query: MCPServer.Query
    private let lock = NSLock()
    private var accepting = true
    private var listener: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var connections: [UUID: (Channel, MCPOperation)] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var jsonCount = 0
    private var audioCount = 0
    init(port: Int, token: String, gate: @escaping Gate, query: @escaping MCPServer.Query = MCPServer.query) {
        self.port = port; self.token = token; self.gate = gate; self.query = query
    }
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        lock.withLock { self.group = group }
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(HeaderLimit()).flatMap {
                        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: false)
                    }.flatMap {
                        channel.pipeline.addHandler(Handler(host: self))
                    }
                }.bind(host: "127.0.0.1", port: port).get()
            let keep = lock.withLock { () -> Bool in
                guard accepting else { return false }; listener = channel; return true
            }
            if !keep { try? await channel.close().get(); throw MCPFailure(.serverStopping) }
        } catch { stopAdmission(); await stop(); throw MCPFailure(.dataUnreadable) }
    }
    func stopAdmission() {
        let state = lock.withLock { () -> (Channel?, [(Channel, MCPOperation)]) in
            accepting = false
            let state = (listener, Array(connections.values))
            listener = nil; connections.removeAll()
            return state
        }
        state.0?.close(promise: nil)
        for (channel, scope) in state.1 { scope.cancel(); channel.close(promise: nil) }
    }
    func stop() async {
        stopAdmission()
        let group = lock.withLock { let result = self.group; self.group = nil; return result }
        guard let group else { return }
        let work = lock.withLock { Array(tasks.values) }
        for task in work { await task.value }
        // NIO cleanup is independent of any tool task; the app's quit barrier is separately bounded.
        await withCheckedContinuation { continuation in group.shutdownGracefully { _ in continuation.resume() } }
    }
    var activeConnections: Int { lock.withLock { connections.count } }
    private func attach(_ channel: Channel, scope: MCPOperation, id: UUID) -> Bool {
        lock.withLock {
            guard accepting, connections.count < 16 else { return false }
            connections[id] = (channel, scope); return true
        }
    }
    private func detach(_ id: UUID) { _ = lock.withLock { connections.removeValue(forKey: id) } }
    private func startWork(id: UUID, head: HTTPRequestHead, body: Data, channel: Channel, scope: MCPOperation) {
        lock.withLock {
            guard accepting, connections[id] != nil else { scope.cancel(); return }
            let task = Task.detached { [self] in
                await serve(head, body: body, channel: channel, scope: scope)
                _ = lock.withLock { tasks.removeValue(forKey: id) }
            }
            tasks[id] = task
            scope.onCancel { task.cancel() }
        }
    }
    private func acquire(audio: Bool) -> Bool {
        lock.withLock {
            guard accepting, audio ? audioCount < 2 : jsonCount < 8 else { return false }
            if audio { audioCount += 1 } else { jsonCount += 1 }; return true
        }
    }
    private func release(audio: Bool) { lock.withLock { if audio { audioCount -= 1 } else { jsonCount -= 1 } } }
    private func authorize(_ head: HTTPRequestHead) -> Int? {
        let authority = "127.0.0.1:\(port)"
        guard head.headers["host"] == [authority] else { return 403 }
        let origins = head.headers["origin"]
        guard origins.isEmpty || origins == ["http://" + authority] else { return 403 }
        let auth = head.headers["authorization"]
        guard auth.count == 1, auth[0].hasPrefix("Bearer "), MCPCredentials.matches(String(auth[0].dropFirst(7)), token) else { return 401 }
        return nil
    }
    private func respond(_ channel: Channel, status: Int, body: Data = Data(), headers: [(String, String)] = []) async throws {
        var fields = HTTPHeaders(headers)
        fields.add(name: "Content-Length", value: String(body.count))
        fields.add(name: "Content-Type", value: "application/json")
        fields.add(name: "Connection", value: "close")
        fields.add(name: "Cache-Control", value: "no-store")
        try await channel.writeAndFlush(HTTPServerResponsePart.head(.init(version: .http1_1, status: .init(statusCode: status), headers: fields))).get()
        if !body.isEmpty { try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: body)))).get() }
        try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
    }
    private func sendAudio(_ part: HTTPServerResponsePart, channel: Channel, scope: MCPOperation) async throws {
        guard !scope.isCancelled else { throw MCPFailure(.serverStopping) }
        try await channel.writeAndFlush(part).get()
    }
    private func serve(_ head: HTTPRequestHead, body: Data, channel: Channel, scope: MCPOperation) async {
        defer { scope.cancel(); if channel.isActive { channel.close(promise: nil) } }
        do {
            if let status = authorize(head) { try await respond(channel, status: status, body: MCPServer.error(code: -32600, message: "Access denied")); return }
            let context: MCPRequestContext
            do { context = try await gate(scope) }
            catch { stopAdmission(); return }
            guard !scope.isCancelled else { return }
            let isAudio = head.uri.hasPrefix("/audio/")
            guard acquire(audio: isAudio) else { try await respond(channel, status: 503); return }
            defer { release(audio: isAudio) }
            if isAudio {
                guard head.method == .GET || head.method == .HEAD else { try await respond(channel, status: 405); return }
                let components = head.uri.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count == 4, components[0].isEmpty, components[1] == "audio",
                      components[2].hasPrefix("m_"), components[3].hasPrefix("a_"), head.headers["range"].count <= 1 else { try await respond(channel, status: 400); return }
                let file: MCPFiles.AudioHandle
                do { file = try MCPLibrary.openAudio(meetingID: String(components[2]), audioID: String(components[3]), runtime: context.runtime) }
                catch { try await respond(channel, status: 404); return }
                let range: MCPByteRange
                do { range = try MCPByteRange.parse(head.headers.first(name: "range"), size: file.size) }
                catch { try await respond(channel, status: 416, headers: [("Content-Range", "bytes */\(file.size)")]); return }
                var headers = HTTPHeaders([("Content-Length", String(range.count)), ("Accept-Ranges", "bytes"), ("Content-Type", "application/octet-stream"), ("Cache-Control", "no-store"), ("Connection", "close")])
                if range.partial { headers.add(name: "Content-Range", value: "bytes \(range.start)-\(range.start + range.count - 1)/\(file.size)") }
                try await sendAudio(.head(.init(version: .http1_1, status: range.partial ? .partialContent : .ok, headers: headers)), channel: channel, scope: scope)
                if head.method == .GET {
                    var offset = range.start
                    while offset < range.start + range.count {
                        guard !scope.isCancelled else { return }
                        // Every chunk rechecks config/root/token and the pinned file revision.
                        _ = try await gate(scope)
                        try context.runtime.check()
                        let bytes = try file.read(offset: offset, count: Int(min(65536, range.start + range.count - offset)))
                        guard !bytes.isEmpty else { return }
                        try await sendAudio(.body(.byteBuffer(channel.allocator.buffer(bytes: bytes))), channel: channel, scope: scope)
                        offset += Int64(bytes.count)
                    }
                }
                try await sendAudio(.end(nil), channel: channel, scope: scope)
            } else if head.uri == "/mcp" {
                guard head.method == .POST else { try await respond(channel, status: 405); return }
                var headers: [String: String] = [:]
                for (name, value) in head.headers { headers[name.lowercased()] = value }
                let result = await MCPServer.handle(body: body, headers: headers, context: context, scope: scope, query: query)
                guard !scope.isCancelled else { return }
                _ = try await gate(scope)
                try await respond(channel, status: result.0, body: result.1)
            } else { try await respond(channel, status: 404) }
        } catch { /* Closing the connection is the safe terminal response after a partial transfer. */ }
    }

    private final class Handler: ChannelDuplexHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundIn = HTTPServerResponsePart
        let host: MCPHTTP
        let id = UUID()
        let scope = MCPOperation()
        var head: HTTPRequestHead?
        var body = Data()
        var started = false
        var idle: Scheduled<Void>?
        var deadline: Scheduled<Void>?
        init(host: MCPHTTP) { self.host = host }
        func channelActive(context: ChannelHandlerContext) {
            guard host.attach(context.channel, scope: scope, id: id) else { context.close(promise: nil); return }
        }
        func resetIdle(_ channel: Channel, seconds: Int64) {
            idle?.cancel()
            idle = channel.eventLoop.scheduleTask(in: .seconds(seconds)) { [scope] in scope.cancel(); channel.close(promise: nil) }
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !started else { scope.cancel(); context.close(promise: nil); return }
            resetIdle(context.channel, seconds: 10)
            switch unwrapInboundIn(data) {
            case .head(let incoming):
                guard head == nil, incoming.uri.utf8.count + incoming.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 }) <= 16384,
                      incoming.headers["content-length"].count <= 1,
                      incoming.headers["content-type"].count <= 1,
                      incoming.headers["mcp-protocol-version"].count <= 1 else { context.close(promise: nil); return }
                head = incoming
                if let length = incoming.headers.first(name: "content-length"), let count = Int64(length), count > 1024 * 1024 { context.close(promise: nil) }
            case .body(var buffer):
                guard body.count + buffer.readableBytes <= 1024 * 1024 else { context.close(promise: nil); return }
                body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            case .end(let trailers):
                guard let head, trailers == nil else { context.close(promise: nil); return }
                started = true; idle?.cancel()
                let channel = context.channel
                // Audio is bounded by idle progress, JSON by total wall-clock time.
                if !head.uri.hasPrefix("/audio/") {
                    deadline = channel.eventLoop.scheduleTask(in: .seconds(30)) { [scope] in scope.cancel(); channel.close(promise: nil) }
                } else { resetIdle(channel, seconds: 30) }
                let body = self.body
                host.startWork(id: id, head: head, body: body, channel: channel, scope: scope)
            }
        }
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            if head?.uri.hasPrefix("/audio/") == true { resetIdle(context.channel, seconds: 30) }
            context.write(data, promise: promise)
        }
        func channelInactive(context: ChannelHandlerContext) {
            idle?.cancel(); deadline?.cancel(); scope.cancel(); host.detach(id)
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { scope.cancel(); context.close(promise: nil) }
    }
    /// Reject an oversized header before NIO's decoder can retain its larger built-in maximum.
    private final class HeaderLimit: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer
        private var count = 0
        private var tail: UInt32 = 0
        private var complete = false
        private var idle: Scheduled<Void>?
        func channelActive(context: ChannelHandlerContext) {
            resetIdle(context.channel); context.fireChannelActive()
        }
        private func resetIdle(_ channel: Channel) {
            idle?.cancel()
            idle = channel.eventLoop.scheduleTask(in: .seconds(10)) { channel.close(promise: nil) }
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if !complete {
                resetIdle(context.channel)
                for byte in unwrapInboundIn(data).readableBytesView {
                    count += 1; tail = (tail << 8) | UInt32(byte)
                    guard count <= 16384 else { context.close(promise: nil); return }
                    if tail == 0x0d0a0d0a { complete = true; idle?.cancel(); break }
                }
            }
            context.fireChannelRead(data)
        }
        func channelInactive(context: ChannelHandlerContext) { idle?.cancel(); context.fireChannelInactive() }
    }
}
