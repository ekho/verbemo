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
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.storage)
        defer { form.stop(); withExtendedLifetime(application) {} }
        let controls = form.modelFilesControl(for: model)
        let download = controls.button
        #expect(!download.isHidden)
        #expect(download.isEnabled)
    }
    @Test(.freshHome) func storageOffersFileOperationsWithoutAnotherModelSelector() throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.storage)
        defer { form.stop(); withExtendedLifetime(application) {} }
        let model = try #require(ModelStorage().all().first { $0.kind == .whisper })
        let controls = form.modelFilesControl(for: model)
        #expect(controls.status === form.modelFilesControl(for: model).status)
        #expect(controls.button === form.modelFilesControl(for: model).button)
        #expect(!controls.status.allDescendants.contains { $0 is NSPopUpButton || $0 is NSSwitch || $0 is ChoiceCard })
        #expect(controls.button.title == localised("Download", "Скачать"))
        #expect(!FileManager.default.fileExists(atPath: model.directory.path))
    }
    @Test(.freshHome, .speaking(.russian), .enabled(if: Platform.supportsLocalModels))
    func modelTypesAndActionsStayAlignedAtBothWindowWidths() throws {
        let store = WhisperModelStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: store.modelURL)
        let application = ApplicationWindow()
        defer { application.settings.setup.stop(); application.hide() }
        application.navigate(.storage)
        let content = application.settings.content(for: .storage)
        let labels = content.allDescendants.compactMap { $0 as? NSTextField }
        let heading = try #require(labels.first { $0.stringValue == "Расшифровка" })
        let group = try #require(heading.superview as? NSStackView)
        #expect(group.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } == ["Расшифровка", "Диаризация"])

        for width in [1340.0, 760.0] {
            application.panel.setContentSize(NSSize(width: width, height: 820))
            application.panel.contentView?.layoutSubtreeIfNeeded()
            for model in ModelStorage().all() {
                let name = try #require(labels.first { $0.stringValue == model.name })
                let line = try #require(name.superview as? NSStackView)
                let action = try #require(line.arrangedSubviews.compactMap { $0 as? NSButton }.first)
                #expect(action.title == (model.kind == .whisper ? "Удалить" : "Скачать"))
                #expect(!action.isHidden)
                #expect(NSFontManager.shared.traits(of: try #require(name.font)).contains(.boldFontMask))
                #expect(abs(action.convert(action.bounds, to: group).maxX - group.bounds.maxX) < 1)
                #expect(name.frame.maxX <= action.frame.minX)
                #expect(name.frame.width > 100)
            }
        }
    }
    @Test(.freshHome) func selectedAndProcessingModelsCannotBeDeleted() throws {
        let application = ApplicationWindow()
        let settings = application.settings
        application.navigate(.storage)
        defer { withExtendedLifetime(application) {} }
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
