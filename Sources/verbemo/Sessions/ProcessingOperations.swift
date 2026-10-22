import Foundation

/// Process-local ownership, independent of the queues and cross-process SessionClaim.
/// A cancelled running entry stays visible until its task has unwound and cleaned up.
final class ProcessingOperations: @unchecked Sendable {
    static let shared = ProcessingOperations()

    enum Kind: Sendable { case transcription, diarization, postProcessing, summary, sweep, importMedia, archive }
    enum State: Sendable { case waiting, running, cancelling }
    struct Snapshot: Sendable {
        let id: UUID
        let session: URL?
        var kind: Kind
        var state: State
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
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var accepting = true

    private static func canonical(_ session: URL?) -> URL? {
        session?.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Reserve before scheduling so waiting work can be cancelled without ever starting.
    func register(session: URL?, kind: Kind) throws -> Ticket {
        try lock.withLock {
            guard accepting else { throw CancellationError() }
            let id = UUID()
            entries[id] = Entry(snapshot: Snapshot(id: id, session: Self.canonical(session),
                                                   kind: kind, state: .waiting))
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
            entry.snapshot.kind = kind
            if entry.snapshot.state != .cancelling { entry.snapshot.state = state }
            entries[context.id] = entry
        }
    }

    func snapshot() -> [Snapshot] {
        lock.withLock { entries.values.map(\.snapshot).sorted { $0.id.uuidString < $1.id.uuidString } }
    }

    func closeAdmission() { lock.withLock { accepting = false } }
    var isAccepting: Bool { lock.withLock { accepting } }

    func cancelAndWait(_ id: UUID) async {
        cancel(id)
        await wait(id)
    }

    func cancelAndWait(session: URL) async {
        let ids = snapshot().filter { $0.session == Self.canonical(session) }.map(\.id)
        for id in ids { cancel(id) }
        for id in ids { await wait(id) }
    }

    /// Call from an external owner (future shutdown), never from an owned operation.
    func cancelAllAndWait() async {
        closeAdmission()
        let ids = snapshot().map(\.id)
        for id in ids { cancel(id) }
        for id in ids { await wait(id) }
    }

    private func start<T: Sendable>(_ id: UUID,
                                   operation: @escaping @Sendable () async throws -> T) throws -> Task<T, Error> {
        try lock.withLock {
            guard var entry = entries[id], entry.cancel == nil else { throw CancellationError() }
            entry.snapshot.state = .running
            let context = Context(owner: self, id: id, session: entry.snapshot.session)
            let task = Task {
                defer { self.finish(id) }
                return try await Self.$context.withValue(context) {
                    try Task.checkCancellation()
                    return try await operation()
                }
            }
            entry.cancel = { task.cancel() }
            entries[id] = entry
            return task
        }
    }

    func cancel(_ id: UUID) {
        let action: (@Sendable () -> Void)? = lock.withLock {
            guard var entry = entries[id] else { return nil }
            if let cancel = entry.cancel {
                entry.snapshot.state = .cancelling
                entries[id] = entry
                return cancel
            }
            // No task or resources exist for a reservation that never started.
            entries.removeValue(forKey: id)
            for waiter in entry.waiters { waiter.resume() }
            return nil
        }
        action?()
    }

    private func wait(_ id: UUID) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                guard entries[id] != nil else { continuation.resume(); return }
                entries[id]?.waiters.append(continuation)
            }
        }
    }

    private func finish(_ id: UUID) {
        let waiters = lock.withLock { entries.removeValue(forKey: id)?.waiters ?? [] }
        for waiter in waiters { waiter.resume() }
    }
}
