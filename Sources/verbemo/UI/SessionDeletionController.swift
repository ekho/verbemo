import AppKit

/// Keep the folder claimed until Undo expires and Finder has moved it safely.
@MainActor
final class SessionDeletionController {
    typealias Recycle = (URL, @escaping @MainActor @Sendable (Error?) -> Void) -> Void
    private struct Pending {
        let dir: URL
        let task: Task<Void, Never>
        let completion: (Result<Void, Error>) -> Void
    }
    private let delay: TimeInterval
    private let recycle: Recycle
    private var pending: [UUID: Pending] = [:]
    private var recycling: Set<URL> = []
    var hasWork: Bool { !pending.isEmpty || !recycling.isEmpty }
    func isPending(_ dir: URL) -> Bool { recycling.contains(dir) || pending.values.contains { $0.dir == dir } }

    init(delay: TimeInterval = 6.5, recycle: @escaping Recycle = { dir, completion in
        NSWorkspace.shared.recycle([dir]) { destinations, error in
            Task { @MainActor in
                if let destination = destinations[dir] { SessionClaim.release(destination) }
                completion(error)
            }
        }
    }) {
        self.delay = delay
        self.recycle = recycle
    }

    @discardableResult
    func schedule(_ dir: URL, completion: @escaping (Result<Void, Error>) -> Void) throws -> UUID {
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".recording.json").path) else {
            throw CocoaError(.fileLocking)
        }
        try SessionClaim.acquire(dir, stage: .finish)
        let id = UUID()
        let task = Task { [weak self, delay] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.commit(id)
        }
        pending[id] = Pending(dir: dir, task: task, completion: completion)
        return id
    }

    @discardableResult
    func undo(_ id: UUID) -> Bool {
        guard let item = pending.removeValue(forKey: id) else { return false }
        item.task.cancel()
        SessionClaim.release(item.dir)
        return true
    }

    func commit(_ id: UUID) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.task.cancel()
        recycling.insert(item.dir)
        recycle(item.dir) { [weak self] error in
            SessionClaim.release(item.dir)
            self?.recycling.remove(item.dir)
            item.completion(error.map { .failure($0) } ?? .success(()))
        }
    }

    func cancelAll() { for id in Array(pending.keys) { undo(id) } }
}
