import Foundation

@MainActor
enum MeetingModelDownload {
    static func continueDiarization(
        _ dir: URL,
        download: (@MainActor (DiarizationModel) async throws -> Void)? = nil,
        resume: @escaping @MainActor (URL, DiarizationState.Request) async throws -> Void
    ) async throws {
        try await ProcessingOperations.shared.run(session: dir, kind: .diarization) {
            try await continueDiarizationWork(dir, download: download, resume: resume)
        }
    }

    private static func continueDiarizationWork(
        _ dir: URL,
        download: (@MainActor (DiarizationModel) async throws -> Void)?,
        resume: @MainActor (URL, DiarizationState.Request) async throws -> Void
    ) async throws {
        guard let state = DiarizationState.read(dir), state.retainsAudio else { throw CocoaError(.fileReadUnknown) }
        let request = state.request
        do {
            try SessionClaim.acquire(dir, stage: .transcribe)
            defer { SessionClaim.release(dir) }
            if let download { try await download(request.model) }
            else { try await DiarizationModelStore.shared(for: request.model).download() }
            try Task.checkCancellation()
            guard DiarizationState.read(dir)?.request == request else { throw CocoaError(.fileReadUnknown) }
        }
        try Task.checkCancellation()
        try await resume(dir, request)
    }
}
