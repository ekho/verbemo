import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct ModelSettingsTests {
    @Test(.freshHome) func partialDownloadKeepsStorageResumeAvailable() throws {
        let store = WhisperModelStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: store.partialURL)
        let model = try #require(ModelStorage().all().first { $0.kind == .whisper })
        let form = SetupForm(forSettings: true)
        let controls = form.modelFilesControl(for: model)
        let download = try #require(controls.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == model.directory.path })
        #expect(!download.isHidden)
        #expect(download.isEnabled)
    }
    @Test(.freshHome) func storageOffersFileOperationsWithoutAnotherModelSelector() throws {
        let form = SetupForm(forSettings: true)
        let model = try #require(ModelStorage().all().first { $0.kind == .whisper })
        let controls = form.modelFilesControl(for: model)
        #expect(controls === form.modelFilesControl(for: model))
        #expect(!controls.allDescendants.contains { $0 is NSPopUpButton || $0 is NSSwitch || $0 is ChoiceCard })
        #expect(controls.allDescendants.compactMap { $0 as? NSButton }.contains { $0.title == localised("Download", "Скачать") })
        #expect(!FileManager.default.fileExists(atPath: model.directory.path))
    }
    @Test(.freshHome) func selectedAndProcessingModelsCannotBeDeleted() throws {
        let settings = SettingsWindow(hostWindow: NSWindow())
        let model = try #require(ModelStorage().all().first { $0.kind == .whisper })
        Config.update(path: ["transcription", "engine"], value: "whisper")
        #expect(settings.modelDeletionReason(model) != nil)
        Config.update(path: ["transcription", "enabled"], value: false)
        #expect(settings.modelDeletionReason(model) == nil)
        settings.isProcessing = { true }
        #expect(settings.modelDeletionReason(model) != nil)
    }
    @Test(.freshHome) func downloadAndContinueKeepsTheWaitingRequest() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let request = DiarizationState.Request(engine: "whisper", threshold: 0.7, explicit: true, model: .nemotron3)
        try DiarizationState(request: request, status: .deferred).write(to: dir)
        var resumed = 0
        try await MeetingModelDownload.continueDiarization(dir, download: { model in
            #expect(model == .nemotron3)
            Config.update(path: ["transcription", "diarization_model"], value: DiarizationModel.community1.rawValue)
        }, resume: { _, captured in
            #expect(captured == request)
            #expect(!SessionClaim.isHeld(dir))
            resumed += 1
        })
        #expect(resumed == 1)
        try await #require(throws: (any Error).self) {
            try await MeetingModelDownload.continueDiarization(dir, download: { _ in
                try DiarizationState(request: .init(engine: "whisper", threshold: 0.8), status: .pending).write(to: dir)
            }, resume: { _, _ in Issue.record("A replaced request must not resume") })
        }
        #expect(!SessionClaim.isHeld(dir))
    }
    @Test func mirroredProgressUsesTheSameDownloadAndCancellationState() {
        let target = NSObject()
        let progress = ModelDownloadProgress(model: "test", identifier: "cancel", target: target, action: #selector(NSObject.description))
        let mirror = progress.mirroredView()
        progress.begin()
        progress.update(0.42)
        #expect(!mirror.isHidden)
        #expect(mirror.allDescendants.compactMap { $0 as? NSProgressIndicator }.first?.doubleValue == 0.42)
        progress.cancelling()
        #expect(mirror.allDescendants.compactMap { $0 as? NSButton }.first?.isEnabled == false)
        progress.end()
        #expect(mirror.isHidden)
    }
}
