import Foundation

/// Capture can restart while processing runs; live begin/toggle/finish must stay ordered.
@MainActor
final class LiveTranscriptionTransitions {
    private var last: Task<Void, Never>?

    @discardableResult
    func append(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = last
        let task = Task {
            await previous?.value
            await operation()
        }
        last = task
        return task
    }

    func wait() async { await last?.value }
}
