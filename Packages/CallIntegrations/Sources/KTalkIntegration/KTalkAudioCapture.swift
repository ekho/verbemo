import Foundation
import CallIntegrations

actor KTalkAudioCapture: CallAudioCapture {
    nonisolated let events: AsyncThrowingStream<CallAudioEvent, Error>
    private let continuation: AsyncThrowingStream<CallAudioEvent, Error>.Continuation
    private let space: URL
    private let port: Int
    private let callID: String
    private let runID = UUID().uuidString
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var decoder: KTalkAudioDecoder?
    private var pulse = ContinuousClock.now
    private(set) var clockOrigin: Date?
    private var failure: (any Error)?
    private var began = false
    private var stopping = false
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var binding: String { "__verbemoAudio_" + runID }
    private var control: String { "__verbemoCapture_" + runID }

    init(space: URL, port: Int, callID: String) throws {
        guard KTalkModel.validSpace(space), (1024...65535).contains(port),
              !callID.isEmpty, callID.utf8.count <= 1024 else {
            throw CallAudioFailure.invalidConfiguration
        }
        self.space = space; self.port = port; self.callID = callID
        let pair = AsyncThrowingStream<CallAudioEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = pair.stream; continuation = pair.continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: KTalkNoRedirects(), delegateQueue: nil)
    }

    func start() async throws {
        guard !began, !stopped, !stopping else { throw CallAudioFailure.stopped }
        began = true
        do {
            let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/json/list")!)
            guard !stopping, !stopped, (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 1_048_576 else { throw CallAudioFailure.unavailable }
            let all = try JSONDecoder().decode([KTalkCDP.Target].self, from: data)
            let targets = all.filter { $0.type == "page" && $0.url.scheme == "https"
                && $0.url.host == space.host && $0.url.port == nil && $0.url.user == nil && $0.url.password == nil }
            let candidates = targets.filter { callID.hasPrefix($0.id + ":") }
            guard targets.count <= 8, candidates.count == 1, let target = candidates.first,
                  let url = target.webSocketDebuggerUrl, KTalkModel.validDebugger(url, port: port)
            else { throw CallAudioFailure.unavailable }
            let connection = session.webSocketTask(with: url)
            connection.maximumMessageSize = 1_048_576
            socket = connection; decoder = KTalkAudioDecoder(runID: runID)
            connection.resume()
            receiver = Task { [weak self] in await self?.receive(connection) }
            let verification = try await command("Runtime.evaluate", ["expression": KTalkCDP.expression, "returnByValue": true])
            let envelope = try JSONSerialization.jsonObject(with: verification) as? [String: Any]
            guard let result = envelope?["result"] as? [String: Any], let remote = result["result"] as? [String: Any],
                  let value = remote["value"], JSONSerialization.isValidJSONObject(value) else { throw CallAudioFailure.invalidData }
            let reading = try KTalkModel.reading(JSONSerialization.data(withJSONObject: value), targetID: target.id, space: space)
            guard reading.participation == .inCall, reading.call?.id == callID else { throw CallAudioFailure.unavailable }
            _ = try await command("Runtime.addBinding", ["name": binding])
            guard !stopping, !stopped, let resource = Bundle.module.url(forResource: "capture", withExtension: "js")
            else { throw CallAudioFailure.stopped }
            let source = try String(contentsOf: resource, encoding: .utf8)
            let config = try Self.json(["run": runID, "binding": binding, "control": control,
                                       "conference": String(callID.dropFirst(target.id.count + 1))])
            _ = try await command("Runtime.evaluate", ["expression": "(\(source))(\(config))",
                "returnByValue": true, "awaitPromise": true, "userGesture": true])
            if let failure { throw failure }
            guard !stopping, !stopped else { throw CallAudioFailure.stopped }
            pulse = .now
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1))
                        guard let self else { return }
                        try await self.renew()
                    } catch {
                        if !Task.isCancelled { await self?.fail(error) }
                        return
                    }
                }
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        if stopped { return }
        if stopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        stopping = true; heartbeat?.cancel(); heartbeat = nil
        if socket != nil {
            let key = try? Self.json(control)
            if let key {
                _ = try? await command("Runtime.evaluate", ["expression": "window[\(key)]?.cleanup()", "awaitPromise": true])
            }
            _ = try? await command("Runtime.removeBinding", ["name": binding])
        }
        stopped = true
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session.invalidateAndCancel()
        for id in Array(pending.keys) { resolve(id, .failure(CallAudioFailure.stopped)) }
        continuation.finish()
        for waiter in stopWaiters { waiter.resume() }
        stopWaiters.removeAll()
    }

    private func renew() async throws {
        guard !stopping, !stopped, failure == nil else { return }
        guard pulse.duration(to: .now) < .seconds(3) else { throw CallAudioFailure.timedOut }
        let key = try Self.json(control)
        let data = try await command("Runtime.evaluate", ["expression": "window[\(key)]?.renew() === true", "returnByValue": true])
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = envelope?["result"] as? [String: Any]
        let remote = result?["result"] as? [String: Any]
        guard remote?["value"] as? Bool == true else { throw CallAudioFailure.unavailable }
    }

    private func receive(_ connection: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await connection.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: throw CallAudioFailure.invalidData
                }
                guard data.count <= 1_048_576,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { throw CallAudioFailure.invalidData }
                if let id = object["id"] as? Int { resolve(id, .success(data)); continue }
                guard !stopping, failure == nil, object["method"] as? String == "Runtime.bindingCalled",
                      let params = object["params"] as? [String: Any], params["name"] as? String == binding,
                      let payload = params["payload"] as? String else { continue }
                do {
                    guard let event = try decoder?.receive(payload) else { continue }
                    if case .heartbeat(let frame, let rate) = event {
                        pulse = .now
                        if clockOrigin == nil { clockOrigin = Date(timeIntervalSinceNow: -Double(frame) / Double(rate)) }
                    }
                    switch continuation.yield(event) {
                    case .enqueued: break
                    case .dropped: throw CallAudioFailure.overloaded
                    case .terminated: return
                    @unknown default: throw CallAudioFailure.overloaded
                    }
                    if case .ended = event { continuation.finish(); heartbeat?.cancel() }
                } catch { fail(error) }
            }
        } catch {
            if !stopping, !stopped { fail(error) }
            for id in Array(pending.keys) { resolve(id, .failure(error)) }
        }
    }

    private func fail(_ error: any Error) {
        guard failure == nil, !stopping, !stopped else { return }
        failure = error; heartbeat?.cancel()
        continuation.finish(throwing: error)
    }

    private func command(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let socket, !stopped else { throw CallAudioFailure.stopped }
        nextID += 1
        let id = nextID
        let request = try Self.json(["id": id, "method": method, "params": params])
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    await self?.resolve(id, .failure(CallAudioFailure.timedOut))
                }
                Task { [weak self] in
                    do { try await socket.send(.string(request)) }
                    catch { await self?.resolve(id, .failure(error)) }
                }
            }
        } onCancel: { Task { await self.resolve(id, .failure(CancellationError())) } }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil,
              let result = object["result"] as? [String: Any], result["exceptionDetails"] == nil
        else { throw CallAudioFailure.unsupportedSchema }
        return data
    }

    private func resolve(_ id: Int, _ result: Result<Data, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
}
