import Foundation

/// Capture the selected generation before scheduling; only that selection may show its result.
@MainActor
final class MeetingProcessingCancellation {
    private let operations: ProcessingOperations
    private var session: URL?
    private var revision = UUID()
    private var observed: Set<UUID> = []
    private var pending: [URL: UUID] = [:]
    private var waiters: [UUID: Task<Void, Never>] = [:]
    private var displayedOutcome: (completion: ProcessingOperations.Completion, snapshot: ProcessingOperations.Snapshot)?
    var outcome: ProcessingOperations.Completion? {
        guard let displayedOutcome, displayedOutcome.snapshot.isCurrentGeneration else { return nil }
        return displayedOutcome.completion
    }
    var onChange: (() -> Void)?

    init(operations: ProcessingOperations = .shared) { self.operations = operations }

    private func runs(for session: URL?) -> [ProcessingOperations.Snapshot] {
        guard let session else { return [] }
        return operations.snapshot().filter { $0.session == session }
    }

    func select(_ selected: URL?) {
        let selected = selected?.standardizedFileURL.resolvingSymlinksInPath()
        let ids = Set(runs(for: selected).map(\.id))
        if selected != session || !ids.subtracting(observed).isEmpty {
            revision = UUID()
            displayedOutcome = nil
        }
        session = selected
        observed = ids
    }

    var hasPending: Bool { !pending.isEmpty }

    func stopObserving() -> [Task<Void, Never>] {
        onChange = nil
        return Array(waiters.values)
    }

    var isCancelling: Bool {
        session.map { pending[$0] != nil } == true || runs(for: session).contains { $0.state == .cancelling }
    }
    var canCancel: Bool { !isCancelling && !runs(for: session).isEmpty }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        guard let session, pending[session] == nil else { return nil }
        let targets = runs(for: session)
        guard !targets.isEmpty else { return nil }
        let request = UUID(), revision = self.revision
        pending[session] = request
        displayedOutcome = nil
        for target in targets { operations.cancel(target.id) }
        onChange?()
        let task = Task {
            defer { waiters.removeValue(forKey: request) }
            var results: [ProcessingOperations.Completion] = []
            for target in targets { results.append(await operations.cancelAndWait(target)) }
            guard pending[session] == request else { return }
            pending.removeValue(forKey: session)
            select(self.session)
            if self.session == session, self.revision == revision,
               targets.allSatisfy(\.isCurrentGeneration), runs(for: session).isEmpty {
                let completion = results.first { if case .failed = $0 { return true }; return false }
                    ?? (results.contains(.cancelled) ? .cancelled : .completed)
                displayedOutcome = (completion, targets[0])
            }
            onChange?()
        }
        waiters[request] = task
        return task
    }
}
