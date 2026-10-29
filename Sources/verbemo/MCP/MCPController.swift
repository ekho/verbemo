import Foundation

@MainActor final class MCPController {
    struct Snapshot {
        let root: URL
        var boundaryPending = false
        var recording: [String: String] = [:]
        var operations: [ProcessingOperations.Snapshot] = []
        var pendingDeletion: Set<String> = []
    }
    private let home: Home
    private let snapshot: () -> Snapshot
    private var host: MCPHTTP?
    private var transition: Task<Void, Never>?
    private var epoch = UUID()
    private var currentConfig: MCPConfiguration?
    private var currentRoot: URL?
    private var currentToken: String?
    private var stopping = false
    private var retainedOperations: [UUID: ProcessingOperations.Snapshot] = [:]
    private let applied: [String: MCPJSON]
    private(set) var status = "Off"
    private(set) var listeningAddress: String?
    var onChange: (() -> Void)?
    var selectedPort: Int? { (try? MCPConfiguration.read(home: home))?.port }

    init(home: Home = .current, snapshot: @escaping () -> Snapshot) {
        self.home = home; self.snapshot = snapshot
        let initial = try? MCPConfiguration.read(home: home)
        let effective = initial.map { Self.effective($0, root: snapshot().root) } ?? [:]
        let startup = Set(SettingsSchema.everyEntry.filter(\.needsRestart).map { $0.path.joined(separator: ".") })
        applied = effective.filter { startup.contains($0.key) }
    }
    func refresh() {
        guard !stopping else { return }
        do {
            let config = try MCPConfiguration.read(home: home)
            let state = snapshot()
            guard config.enabled else { revoke(); status = "Off"; onChange?(); return }
            guard !state.boundaryPending else { revoke(); status = "Waiting for library change"; onChange?(); return }
            guard let token = try MCPCredentials(home: home).read() else { revoke(); status = "Local token missing — enable or rotate locally"; onChange?(); return }
            if currentConfig == config, currentRoot == state.root, currentToken == token, host != nil { return }
            revoke()
            currentConfig = config; currentRoot = state.root; currentToken = token
            let generation = epoch
            let next = MCPHTTP(port: config.port, token: token, gate: { [weak self] scope in
                guard let self else { throw MCPFailure(.serverStopping) }
                return try await self.context(scope: scope, epoch: generation, config: config, token: token)
            })
            host = next; status = "Starting"; onChange?()
            let previous = transition
            transition = Task { [weak self] in
                await previous?.value
                guard let self, epoch == generation, !stopping else { await next.stop(); return }
                do {
                    try await next.start()
                    guard epoch == generation, !stopping else { next.stopAdmission(); await next.stop(); return }
                    status = "Listening"; listeningAddress = "http://127.0.0.1:\(config.port)/mcp"
                } catch {
                    guard epoch == generation else { return }
                    host = nil; status = "Cannot listen on selected port"; listeningAddress = nil
                }
                onChange?()
            }
        } catch { revoke(); status = "MCP closed — settings or local token unreadable"; onChange?() }
    }
    private func revoke() {
        epoch = UUID(); host?.stopAdmission()
        let previous = transition, old = host
        transition = Task { await previous?.value; await old?.stop() }
        host = nil; listeningAddress = nil; currentConfig = nil; currentRoot = nil; currentToken = nil
    }
    func setEnabled(_ enabled: Bool) {
        revoke()
        do {
            _ = try MCPConfiguration.read(home: home)
            if enabled, try MCPCredentials(home: home).read() == nil { _ = try MCPCredentials(home: home).rotate() }
            guard Home.$scoped.withValue(home, operation: { Config.update(path: ["mcp", "enabled"], value: enabled) }) else { throw MCPFailure(.dataUnreadable) }
            refresh()
        } catch { status = "MCP closed — could not save local credentials/settings"; onChange?() }
    }
    func rotateToken() {
        revoke()
        do { _ = try MCPCredentials(home: home).rotate(); refresh() }
        catch { status = "MCP closed — could not save token"; onChange?() }
    }
    func tokenForLocalClipboard() throws -> String {
        _ = try MCPConfiguration.read(home: home)
        guard let token = try MCPCredentials(home: home).read() else { throw MCPFailure(.dataUnreadable) }
        return token
    }
    func stopAdmission() { stopping = true; revoke(); status = "Stopped"; onChange?() }
    func stop() async {
        stopAdmission()
        let pending = transition
        let barrier = StopBarrier()
        await withCheckedContinuation { continuation in
            barrier.install(continuation)
            Task { await pending?.value; barrier.finish() }
            Task { try? await Task.sleep(for: .seconds(2)); barrier.finish() }
        }
    }
    private func context(scope: MCPOperation, epoch generation: UUID, config: MCPConfiguration, token: String) throws -> MCPRequestContext {
        guard !stopping, epoch == generation, !scope.isCancelled else { throw MCPFailure(.serverStopping) }
        let state = snapshot()
        guard scope.admitsDeletionSnapshot(state.pendingDeletion) else { scope.cancel(); throw MCPFailure(.serverStopping) }
        do {
            let read = try MCPConfiguration.read(home: home)
            guard read == config, state.root == currentRoot, !state.boundaryPending,
                  try MCPCredentials(home: home).read() == token else { throw MCPFailure(.serverStopping) }
            for operation in state.operations { retainedOperations[operation.id] = operation }
            // Retain completion evidence only while its meeting generation is current; bound history.
            retainedOperations = retainedOperations.filter { $0.value.isCurrentGeneration }
            if retainedOperations.count > 256 {
                retainedOperations = Dictionary(uniqueKeysWithValues: retainedOperations.sorted { $0.key.uuidString < $1.key.uuidString }.prefix(256).map { ($0.key, $0.value) })
            }
            var processing: [String: [String: String]] = [:]
            for operation in retainedOperations.values {
                guard let session = operation.session, session.deletingLastPathComponent().standardizedFileURL == state.root.standardizedFileURL else { continue }
                let stage: String
                switch operation.kind {
                case .transcription: stage = "transcription"
                case .diarization: stage = "diarization"
                case .summary: stage = "summary"
                case .postProcessing: stage = "speaker_naming"
                case .archive: stage = "audio"
                case .sweep, .importMedia: continue
                }
                let value: String
                switch operation.completion {
                case .cancelled? where operation.state == .cancelling: value = "cancelled"
                // A job may change stages after our snapshot; its final error does not prove this stage failed.
                case .cancelled?, .failed?, .completed?: continue
                case nil: value = operation.state == .waiting ? "pending" : "running"
                }
                processing[session.lastPathComponent, default: [:]][stage] = value
            }
            let pending = state.pendingDeletion
            let runtime = MCPLibrary.Runtime(root: state.root, port: config.port, recording: state.recording, processing: processing,
                pendingDeletion: { pending.contains($0) }, cancelled: { scope.isCancelled || Task.isCancelled }, deadline: .distantFuture)
            let settings = MCPSettings(raw: config.raw, effective: Self.effective(config, root: state.root), applied: applied, secretConfigured: ["mcp.token": true])
            return MCPRequestContext(runtime: runtime, settings: settings)
        } catch { revoke(); status = "MCP closed — configuration changed"; onChange?(); throw MCPFailure(.serverStopping) }
    }
    private static func effective(_ config: MCPConfiguration, root: URL) -> [String: MCPJSON] {
        guard let bytes = try? MCPJSON.object(config.raw).encoded(), let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        var values: [String: MCPJSON] = [:]
        for entry in SettingsSchema.everyEntry {
            let path = entry.path.joined(separator: ".")
            guard let key = Config.Key(rawValue: path) else { continue }
            switch entry.kind {
            case .toggle: values[path] = .bool(Config.flag(key, in: json))
            case .number: values[path] = .number(Config.number(key, in: json))
            case .choice, .text, .multilineText:
                values[path] = entry.hasValueDefault ? .string(Config.string(key, in: json)) : .optional(Config.text(key, in: json))
            case .list: values[path] = Config.list(key, in: json).map { .array($0.map(MCPJSON.string)) } ?? .null
            }
        }
        values["recordings_dir"] = .string(root.path)
        values["mcp.enabled"] = .bool(config.enabled); values["mcp.port"] = .int(config.port)
        values["live_transcription.enabled"] = .bool(Config.liveTranscriptionEnabled(in: json))
        values["transcription.local_diarization"] = .bool(Config.localDiarizationEnabled(in: json))
        values["transcription.diarization_model"] = .string(Config.diarizationModel(in: json).rawValue)
        values["transcription.diarization_threshold"] = .number(Config.diarizationThreshold(in: json))
        values["mic_voice_processing"] = .bool(Config.micVoiceProcessing(in: json))
        let emails = Config.value(.userEmail, in: json)
        values["user_email"] = .array(EmailAddresses.normalize(emails as? [String] ?? (emails as? String).map { [$0] } ?? []).map(MCPJSON.string))
        let apps = Config.flag(.autoRecordAnyApp, in: json) ? [] : Config.list(.autoRecordApps, in: json) ?? MicActivityMonitor.defaultCallApps
        values["auto_record.apps"] = .array(apps.map(MCPJSON.string))
        values["auto_record.ignore_apps"] = .array((Config.list(.autoRecordIgnoreApps, in: json) ?? []).map(MCPJSON.string))
        let summary = Config.summary(in: json)
        values["summary.openai_compatible"] = .bool(summary.openAICompatible)
        values["summary.openai_base_url"] = .string(summary.openAIBaseURL)
        return values
    }
    private final class StopBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        func install(_ continuation: CheckedContinuation<Void, Never>) { lock.withLock { self.continuation = continuation } }
        func finish() {
            let result = lock.withLock { let value = continuation; continuation = nil; return value }
            result?.resume()
        }
    }
}
