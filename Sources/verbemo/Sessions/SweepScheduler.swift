import Foundation

/// When the running app sweeps the recordings folder: after the queue has
/// drained, and never twice at once.
///
/// Four things ask for a sweep — the launch, the network coming back, the
/// recordings folder changing and a broken config reading again — and two of
/// them arrive in the same turn whenever a fixed config also names a new
/// folder. Each used to start a sweep of its own straight after asking the
/// queue to resume, so two sweeps and a drain walked the same folders at once,
/// each finding the others' claims and saying so in the session logs.
///
/// A request made while a sweep waits for the drain is the same sweep. One
/// made while a sweep is already walking the folder is owed one more pass,
/// since the thing that prompted it — a new folder, a model back — may have
/// come too late for the pass under way.
@MainActor
final class SweepScheduler {
    private enum State {
        case idle
        case waiting
        case sweeping(again: Bool)
    }

    var onActivityChange: (() -> Void)?

    private var state = State.idle { didSet { onActivityChange?() } }
    private let waitForQueue: () async -> Void
    private let sweep: () async -> Void
    private let operations: ProcessingOperations

    init(waitForQueue: @escaping () async -> Void, sweep: @escaping () async -> Void,
         operations: ProcessingOperations = .shared) {
        self.waitForQueue = waitForQueue
        self.sweep = sweep
        self.operations = operations
    }

    /// Whether a sweep is waiting or running.
    var isBusy: Bool {
        if case .idle = state { return false }
        return true
    }

    func request() {
        switch state {
        case .waiting, .sweeping(again: true):
            return
        case .sweeping(again: false):
            state = .sweeping(again: true)
            return
        case .idle:
            guard let ticket = try? operations.register(session: nil, kind: .sweep) else { return }
            state = .waiting
            Task {
                do { try await ticket.run { await self.run() } }
                catch { self.state = .idle }
            }
        }
    }

    private func run() async {
        defer { state = .idle }
        while !Task.isCancelled {
            operations.stage(.sweep, state: .waiting)
            await waitForQueue()
            guard !Task.isCancelled else { break }
            state = .sweeping(again: false)
            operations.stage(.sweep)
            await sweep()
            guard !Task.isCancelled, case .sweeping(again: true) = state else { break }
            state = .waiting
        }
    }
}
