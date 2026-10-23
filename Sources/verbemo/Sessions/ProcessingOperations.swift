import Foundation

/// Process-local ownership, independent of the queues and cross-process SessionClaim.
/// A cancelled running entry stays visible until its task has unwound and cleaned up.
final class ProcessingOperations: @unchecked Sendable {
    static let shared = ProcessingOperations()

    enum Kind: Sendable { case transcription, diarization, postProcessing, summary, sweep, importMedia, archive }
    enum State: Sendable { case waiting, running, cancelling }
    enum Completion: Sendable, Equatable { case completed, cancelled, failed(String) }

    /// Retained by snapshots rather than an unbounded registry of past runs.
    fileprivate final class ResultHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Completion?
        private var waiters: [CheckedContinuation<Completion, Never>] = []

        func wait() async -> Completion {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if let result { continuation.resume(returning: result) }
                    else { waiters.append(continuation) }
                }
            }
        }

        func finish(_ result: Completion) {
            let waiting = lock.withLock {
                self.result = result
                let waiting = waiters
                waiters.removeAll()
                return waiting
            }
            for waiter in waiting { waiter.resume(returning: result) }
        }
    }

    fileprivate final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var token = UUID()
        var current: UUID { lock.withLock { token } }
        func advance() { lock.withLock { token = UUID() } }
    }
    private final class WeakGeneration {
        weak var value: Generation?
        init(_ value: Generation) { self.value = value }
    }

    struct Snapshot: Sendable {
        let id: UUID
        let session: URL?
        let kind: Kind
        let state: State
        fileprivate let result: ResultHandle
        fileprivate let generation: Generation?
        fileprivate let generationToken: UUID?
        var isCurrentGeneration: Bool { generation?.current == generationToken }

        fileprivate func capturingGeneration() -> Self {
            Self(id: id, session: session, kind: kind, state: state, result: result,
                 generation: generation, generationToken: generation?.current)
        }

        fileprivate func updating(kind: Kind? = nil, state: State? = nil) -> Self {
            Self(id: id, session: session, kind: kind ?? self.kind, state: state ?? self.state, result: result,
                 generation: generation, generationToken: generationToken)
        }
    }
    struct Ticket: Sendable {
        let id: UUID
        fileprivate let owner: ProcessingOperations

        func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
            if Task.isCancelled { owner.cancel(id) }
            let task = try owner.start(id, operation: operation)
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { owner.cancel(id) }
        }
    }

    private struct Context: Sendable {
        let owner: ProcessingOperations
        let id: UUID
        let session: URL?
    }
    @TaskLocal private static var context: Context?
    private struct Entry {
        var snapshot: Snapshot
        var cancel: (@Sendable () -> Void)?
        var failure: String?
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var generations: [URL: WeakGeneration] = [:]
    private var accepting = true

    private static func canonical(_ session: URL?) -> URL? {
        session?.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Reserve before scheduling so waiting work can be cancelled without ever starting.
    func register(session: URL?, kind: Kind) throws -> Ticket {
        try lock.withLock {
            guard accepting else { throw CancellationError() }
            let id = UUID(), session = Self.canonical(session)
            pruneGenerations()
            let generation = session.map { session in
                let value = generations[session]?.value ?? Generation()
                value.advance()
                generations[session] = WeakGeneration(value)
                return value
            }
            entries[id] = Entry(snapshot: Snapshot(id: id, session: session,
                kind: kind, state: .waiting, result: ResultHandle(),
                generation: generation, generationToken: generation?.current))
            return Ticket(id: id, owner: self)
        }
    }

    func run<T: Sendable>(session: URL? = nil, kind: Kind,
                         operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if let context = Self.context, context.owner === self,
           context.session == Self.canonical(session),
           let state = lock.withLock({ entries[context.id]?.snapshot.state }) {
            if state == .cancelling { throw CancellationError() }
            try Task.checkCancellation()
            let previous = lock.withLock { entries[context.id]?.snapshot.kind }
            stage(kind)
            defer { if let previous { stage(previous) } }
            return try await operation()
        }
        return try await register(session: session, kind: kind).run(operation)
    }

    func stage(_ kind: Kind, state: State = .running) {
        guard let context = Self.context, context.owner === self else { return }
        lock.withLock {
            guard var entry = entries[context.id] else { return }
            entry.snapshot = entry.snapshot.updating(kind: kind,
                state: entry.snapshot.state == .cancelling ? .cancelling : state)
            entries[context.id] = entry
        }
    }

    /// For owners that persist an error instead of throwing it out of the run.
    func reportFailure(_ message: String) {
        guard let context = Self.context, context.owner === self else { return }
        lock.withLock { entries[context.id]?.failure = message }
    }

    private func pruneGenerations() {
        generations = generations.filter { $0.value.value != nil }
    }

    func snapshot() -> [Snapshot] {
        lock.withLock {
            pruneGenerations()
            return entries.values.map { $0.snapshot.capturingGeneration() }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    func closeAdmission() { lock.withLock { accepting = false } }
    var isAccepting: Bool { lock.withLock { accepting } }

    func cancelAndWait(_ id: UUID) async {
        let result = lock.withLock { entries[id]?.snapshot.result }
        cancel(id)
        _ = await result?.wait()
    }

    func cancelAndWait(_ snapshot: Snapshot) async -> Completion {
        cancel(snapshot.id)
        return await snapshot.result.wait()
    }

    func cancelAndWait(session: URL) async {
        let runs = snapshot().filter { $0.session == Self.canonical(session) }
        for run in runs { cancel(run.id) }
        for run in runs { _ = await run.result.wait() }
    }

    /// Call from an external owner (future shutdown), never from an owned operation.
    func cancelAllAndWait() async {
        closeAdmission()
        let runs = snapshot()
        for run in runs { cancel(run.id) }
        for run in runs { _ = await run.result.wait() }
    }

    private func start<T: Sendable>(_ id: UUID,
                                   operation: @escaping @Sendable () async throws -> T) throws -> Task<T, Error> {
        try lock.withLock {
            guard var entry = entries[id], entry.cancel == nil else { throw CancellationError() }
            entry.snapshot = entry.snapshot.updating(state: .running)
            let context = Context(owner: self, id: id, session: entry.snapshot.session)
            let task = Task {
                do {
                    let value = try await Self.$context.withValue(context) {
                        try Task.checkCancellation()
                        return try await operation()
                    }
                    self.finish(id, result: .completed)
                    return value
                } catch {
                    self.finish(id, result: error is CancellationError ? .cancelled : .failed(error.localizedDescription))
                    throw error
                }
            }
            entry.cancel = { task.cancel() }
            entries[id] = entry
            return task
        }
    }

    func cancel(_ id: UUID) {
        var waiting: ResultHandle?
        let action: (@Sendable () -> Void)? = lock.withLock {
            guard var entry = entries[id] else { return nil }
            if let cancel = entry.cancel {
                entry.snapshot = entry.snapshot.updating(state: .cancelling)
                entries[id] = entry
                return cancel
            }
            // No task or resources exist for a reservation that never started.
            entries.removeValue(forKey: id)
            waiting = entry.snapshot.result
            return nil
        }
        waiting?.finish(.cancelled)
        action?()
        lock.withLock { pruneGenerations() }
    }

    private func finish(_ id: UUID, result: Completion) {
        guard let entry = lock.withLock({ entries.removeValue(forKey: id) }) else { return }
        let outcome: Completion
        if result == .completed, let failure = entry.failure { outcome = .failed(failure) }
        else { outcome = result }
        entry.snapshot.result.finish(outcome)
        lock.withLock { pruneGenerations() }
    }
}
