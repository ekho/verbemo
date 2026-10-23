import Foundation
import Testing
@testable import verbemo

struct LiveRetirementTests {
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
