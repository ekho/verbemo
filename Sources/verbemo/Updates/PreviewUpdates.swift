import Foundation

@MainActor
final class PreviewUpdates {
    enum State: Equatable {
        case idle, checking, available(PreviewRelease), upToDate, failed
    }

    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastAttemptKey = "previewUpdates.lastAutomaticAttempt"
    private let defaults: UserDefaults
    private let now: () -> Date
    private let lookup: @MainActor () async throws -> PreviewRelease?
    private var timer: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var requestedManually = false
    var onChange: ((State) -> Void)?
    private(set) var state: State = .idle { didSet { onChange?(state) } }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() },
         lookup: @escaping @MainActor () async throws -> PreviewRelease?) {
        self.defaults = defaults
        self.now = now
        self.lookup = lookup
    }

    deinit {
        timer?.cancel()
        request?.cancel()
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        timer?.cancel()
        let time = now()
        let last = defaults.object(forKey: Self.lastAttemptKey) as? Date
        let elapsed = last.map { time.timeIntervalSince($0) } ?? Self.interval
        let due = elapsed < 0 || elapsed >= Self.interval
        let delay = due ? Self.interval : Self.interval - elapsed
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.start()
        }

        guard due else { return nil }
        defaults.set(time, forKey: Self.lastAttemptKey)
        return check()
    }

    @discardableResult
    func checkManually() -> Task<Void, Never> {
        requestedManually = true
        let task = check()
        state = .checking
        return task
    }

    private func check() -> Task<Void, Never> {
        if let request { return request }
        let task = Task { [weak self, lookup] in
            let result: Result<PreviewRelease?, Error>
            do { result = .success(try await lookup()) } catch { result = .failure(error) }
            self?.finish(result)
        }
        request = task
        return task
    }

    private func finish(_ result: Result<PreviewRelease?, Error>) {
        let manual = requestedManually
        requestedManually = false
        request = nil
        switch result {
        case .success(.some(let release)): state = .available(release)
        case .success(nil): state = manual ? .upToDate : .idle
        case .failure: if manual { state = .failed }
        }
    }
}
