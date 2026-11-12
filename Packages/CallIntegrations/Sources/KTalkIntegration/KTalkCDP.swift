import Foundation
import CallIntegrations

/// Only loopback CDP is contacted; no credentials or KTalk server requests.
actor KTalkCDP {
    struct Target: Decodable {
        let id: String
        let type: String
        let url: URL
        let webSocketDebuggerUrl: URL?
    }
    private let space: URL?
    private let port: Int
    private let session: URLSession
    private var sockets: [String: URLSessionWebSocketTask] = [:]
    private var joinedTargets: Set<String> = []
    private var idleTargets: Set<String>?
    private var nextID = 0
    private var stopped = false

    init(space: URL?, port: Int) {
        self.space = space; self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.7
        config.timeoutIntervalForResource = 0.7
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: KTalkNoRedirects(), delegateQueue: nil)
    }

    func stop() {
        stopped = true
        for socket in sockets.values { socket.cancel(with: .normalClosure, reason: nil) }
        sockets.removeAll()
        session.invalidateAndCancel()
    }

    func read() async -> KTalkReading {
        guard !stopped, let space else { return .init(participation: .unknown) }
        do {
            let endpoint = URL(string: "http://127.0.0.1:\(port)/json/list")!
            let (data, response) = try await session.data(from: endpoint)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_048_576 else { throw KTalkModel.InvalidModel() }
            let all = try JSONDecoder().decode([Target].self, from: data)
            let targets = all.filter { $0.type == "page" && $0.url.scheme == "https"
                && $0.url.host == space.host && $0.url.port == nil && $0.url.user == nil && $0.url.password == nil }
            guard targets.count <= 8 else { throw KTalkModel.InvalidModel() }
            let ids = Set(targets.map(\.id))
            let closedCall = !joinedTargets.subtracting(ids).isEmpty
            if idleTargets != ids { idleTargets = nil }
            joinedTargets.formIntersection(ids)
            for id in Array(sockets.keys) where !ids.contains(id) {
                sockets.removeValue(forKey: id)?.cancel(with: .normalClosure, reason: nil)
            }
            var readings: [KTalkReading] = []
            for target in targets {
                guard let url = target.webSocketDebuggerUrl, KTalkModel.validDebugger(url, port: port) else { throw KTalkModel.InvalidModel() }
                let socket: URLSessionWebSocketTask
                if let existing = sockets[target.id] { socket = existing }
                else {
                    socket = session.webSocketTask(with: url)
                    socket.maximumMessageSize = 1_048_576
                    sockets[target.id] = socket
                    socket.resume()
                }
                nextID += 1
                let result = try await evaluate(socket: socket, id: nextID)
                let reading = try KTalkModel.reading(result, targetID: target.id, space: space)
                if reading.participation == .inCall { joinedTargets.insert(target.id) }
                readings.append(reading)
            }
            guard !stopped else { return .init(participation: .unknown) }
            let active = readings.filter { $0.participation == .inCall }
            if !active.isEmpty { idleTargets = nil }
            if active.count > 1 { return .init(participation: .unknown) }
            if let call = active.first { return call }
            if let preparing = readings.first(where: { $0.participation == .preparing }) { idleTargets = nil; return preparing }
            if readings.allSatisfy(\.emptyWindow), closedCall || idleTargets == ids {
                idleTargets = ids
                return .init(participation: .idle)
            }
            idleTargets = nil
            return .init(participation: .unknown)
        } catch {
            for socket in sockets.values { socket.cancel(with: .goingAway, reason: nil) }
            sockets.removeAll()
            return .init(participation: .unknown)
        }
    }

    private func evaluate(socket: URLSessionWebSocketTask, id: Int) async throws -> Data {
        let timeout = Task {
            try await Task.sleep(for: .milliseconds(700))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            let request: [String: Any] = ["id": id, "method": "Runtime.evaluate",
                "params": ["expression": Self.expression, "returnByValue": true]]
            try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: request), as: UTF8.self)))
            for _ in 0..<64 {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: throw KTalkModel.InvalidModel()
                }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw KTalkModel.InvalidModel() }
                guard object["id"] as? Int == id else { continue }
                guard object["error"] == nil, let result = object["result"] as? [String: Any],
                      result["exceptionDetails"] == nil, let remote = result["result"] as? [String: Any],
                      let value = remote["value"] as? [String: Any] else { throw KTalkModel.InvalidModel() }
                return try JSONSerialization.data(withJSONObject: value)
            }
            throw KTalkModel.InvalidModel()
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }

    // Read-only projection: no hooks, DOM changes, token or chat reads.
    static let expression = #"""
    (() => {
      const c = window.$conf;
      if (!c) return {kind:'no_conference'};
      const r = c.roomInfo, ps = c.participants;
      if (typeof c.joined !== 'boolean' || !r || typeof r.roomName !== 'string' ||
          typeof r.title !== 'string' || !Array.isArray(ps) || ps.some(p => !p ||
          typeof p.id !== 'string' || typeof p.name !== 'string' || typeof p.local !== 'boolean' ||
          typeof p.isAnonymous !== 'boolean')) return {kind:'unsupported_schema'};
      const bool = v => typeof v === 'boolean' ? v : null;
      const text = v => typeof v === 'string' ? v : null;
      return {kind:'conference', joined:c.joined,
        room:{key:r.roomName,title:r.title,conference_id:text(r.conferenceId)},
        local_participant_id:text(c.localParticipant?.id),
        microphone_muted:bool(c.isAudioMuted), camera_muted:bool(c.isCameraMuted),
        participants:ps.map(p => ({id:p.id,
          name:[p.userInfo?.firstName,p.userInfo?.lastName].filter(v=>typeof v==='string'&&v.trim()).join(' ')||p.name,
          local:p.local,guest:p.isAnonymous,microphone_muted:bool(p.audioMuted),camera_muted:bool(p.cameraMuted)}))};
    })()
    """#
}

final class KTalkNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
