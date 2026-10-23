import Foundation
import Testing
import os
@testable import verbemo

struct LiveRetirementTests {
    @Test("Disabling live text cancels its download without ending the recording")
    func disableCancelsDownload() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Flag(), cancelled = Flag()
        let store = NemotronModelStore(root: root) { _, _, progress in
            started.raise()
            progress(0.25)
            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(30))
            } onCancel: { cancelled.raise() }
            throw CancellationError()
        }
        let live = LiveTranscriptionCoordinator(modelStore: store)
        await live.beginRecording(enabled: false, language: "auto", update: { _ in }, attach: { _ in })
        await live.setEnabled(true, language: "auto")
        for _ in 0..<100 where !started.isRaised { try await Task.sleep(for: .milliseconds(10)) }
        #expect(started.isRaised)
        for _ in 0..<100 where await live.snapshot.status != .downloading(0.25) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await live.snapshot.status == .downloading(0.25))
        await live.setEnabled(false, language: "auto")
        for _ in 0..<100 where !cancelled.isRaised { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled.isRaised)
        #expect(await live.snapshot.isRecording)
        #expect(await live.snapshot.status == .paused)
        await live.finishRecording()
    }

    @Test("Explicitly enabling live text downloads its missing model and proceeds to preload")
    func enableDownloadsMissingModel() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = OSAllocatedUnfairLock(initialState: 0)
        let preloaded = Flag()
        let store = NemotronModelStore(root: root) { language, root, progress in
            downloads.withLock { $0 += 1 }
            progress(0.5)
            let dir = NemotronModelStore(root: root).variantDirectory(language: language)
            try NemotronFixtures.install(at: dir)
            return dir
        }
        let live = LiveTranscriptionCoordinator(modelStore: store, preload: { dir in
            #expect(dir == store.variantDirectory(language: "auto"))
            preloaded.raise()
            throw URLError(.cannotDecodeContentData)
        })
        await live.beginRecording(enabled: true, language: "auto", update: { _ in }, attach: { _ in })
        #expect(await live.snapshot.status == .modelMissing)
        #expect(downloads.withLock { $0 } == 0, "Starting capture alone must not start a network transfer")
        await live.setEnabled(true, language: "auto")
        for _ in 0..<100 where !preloaded.isRaised { try await Task.sleep(for: .milliseconds(10)) }
        #expect(downloads.withLock { $0 } == 1)
        #expect(preloaded.isRaised)
        await live.finishRecording()
    }

    @Test("Recording finish awaits a preload retired by an earlier live toggle")
    func awaitsOldPreload() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NemotronModelStore(root: root)
        try NemotronFixtures.install(at: store.variantDirectory(language: "auto"))
        let entered = Gate(), cancelled = Gate(), cleanup = Gate(), returned = Flag()
        let live = LiveTranscriptionCoordinator(modelStore: store, preload: { _ in
            await withTaskCancellationHandler {
                entered.open(); await cleanup.pass()
            } onCancel: { cancelled.open() }
            throw CancellationError()
        })
        await live.beginRecording(enabled: true, language: "auto", update: { _ in }, attach: { _ in })
        await entered.pass()
        await live.setEnabled(false, language: "auto")
        await cancelled.pass()
        let finish = Task { await live.finishRecording(); returned.raise() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!returned.isRaised)
        cleanup.open()
        await finish.value
        #expect(returned.isRaised)
        #expect(await live.snapshot.status == .idle)
    }
}
