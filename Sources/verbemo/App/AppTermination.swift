import Foundation

/// One exit barrier, entered synchronously after the user accepts quitting.
@MainActor
final class AppTermination {
    private let operations: ProcessingOperations
    private var task: Task<Void, Never>?
    var isStopping: Bool { task != nil }

    init(operations: ProcessingOperations) { self.operations = operations }

    func begin(stop: () -> Void,
               finishRecording: @escaping @MainActor () async -> Void,
               finishServices: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        if let task { return task }
        operations.closeAdmission()
        stop()
        let task = Task {
            await finishRecording()
            await operations.cancelAllAndWait()
            await finishServices()
        }
        self.task = task
        return task
    }
}
