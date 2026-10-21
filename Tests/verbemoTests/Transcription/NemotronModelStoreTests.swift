import Darwin
import Foundation
import Testing
import os
@testable import verbemo

enum NemotronFixtures {
    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nemotron-test-\(UUID())")
    }
    static func install(at variant: URL) throws {
        for name in ["metadata.json", "tokenizer.json", "encoder.mlmodelc/coremldata.bin",
                     "encoder.mlmodelc/model.mil", "encoder.mlmodelc/weights/weight.bin",
                     "decoder_joint.mlmodelc/coremldata.bin", "decoder_joint.mlmodelc/model.mil",
                     "decoder_joint.mlmodelc/weights/weight.bin"] {
            let file = variant.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { try Data("{}".utf8).write(to: file) }
        }
    }
}

struct NemotronModelStoreTests {
    @Test("Live/final/restarted stores reuse the same ready 1120 ms files without a downloader")
    func readyReuse() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = NemotronModelStore(root: root) { _, _, _ in calls.withLock { $0 += 1 }; throw URLError(.notConnectedToInternet) }
        let dir = store.variantDirectory(language: "auto")
        try NemotronFixtures.install(at: dir)
        let before = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("encoder.mlmodelc/weights/weight.bin").path)
        #expect(try await store.download(language: "ru-RU") == dir)
        let restarted = NemotronModelStore(root: root) { _, _, _ in calls.withLock { $0 += 1 }; throw URLError(.notConnectedToInternet) }
        #expect(try await restarted.download(language: "auto") == dir)
        #expect(restarted.isReady(language: "ru"))
        #expect(calls.withLock { $0 } == 0)
        let after = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("encoder.mlmodelc/weights/weight.bin").path)
        #expect(before[.systemFileNumber] as? UInt64 == after[.systemFileNumber] as? UInt64)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(dir.path.hasSuffix("nemotron-multilingual/multilingual/1120ms"))
    }

    @Test("Language aliases and separate live/final stores join one download and share progress")
    func concurrentAliases() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate(), started = Gate()
        let count = OSAllocatedUnfairLock(initialState: 0)
        let heard = OSAllocatedUnfairLock(initialState: Set<String>())
        let downloader: NemotronModelStore.Downloader = { language, root, progress in
            count.withLock { $0 += 1 }; started.open(); await gate.pass()
            progress(0.5)
            let dir = NemotronModelStore(root: root).variantDirectory(language: language)
            try NemotronFixtures.install(at: dir)
            return dir
        }
        let live = NemotronModelStore(root: root, downloader: downloader)
        let final = NemotronModelStore(root: root, downloader: downloader)
        let first = Task { try await live.download(language: "en-US") { _ in heard.withLock { _ = $0.insert("live") } } }
        let second = Task { try await final.download(language: "de-DE") { _ in heard.withLock { _ = $0.insert("final") } } }
        await started.pass()
        try await Task.sleep(for: .milliseconds(50))
        #expect(live.state(language: "en-US") == final.state(language: "de-DE"))
        #expect(!live.isReady(language: "en-US"))
        gate.open()
        let urls = try await [first.value, second.value]
        #expect(urls[0] == urls[1])
        #expect(count.withLock { $0 } == 1)
        #expect(heard.withLock { $0 } == ["live", "final"])
        #expect(live.state(language: "en-US") == .ready)
        #expect(final.state(language: "de-DE") == .ready)
    }

    @Test("Cancelling live does not cancel the shared download still wanted by final")
    func cancelOne() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate(), started = Gate()
        let store = NemotronModelStore(root: root) { language, root, _ in
            started.open(); await gate.pass(); try Task.checkCancellation()
            let dir = NemotronModelStore(root: root).variantDirectory(language: language)
            try NemotronFixtures.install(at: dir); return dir
        }
        let live = Task { try await store.download(language: "auto") }
        let final = Task { try await store.download(language: "ru-RU") }
        await started.pass(); try await Task.sleep(for: .milliseconds(50))
        live.cancel()
        await #expect(throws: CancellationError.self) { try await live.value }
        #expect(store.isDownloading)
        gate.open()
        #expect(try await final.value == store.variantDirectory(language: "auto"))
        #expect(store.isReady(language: "ru-RU"))
    }

    @Test("Failed and interrupted transfers never publish readiness; repair keeps intact files", arguments: [false, true])
    func interruptedRepair(cancel: Bool) async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate(), started = Gate(), finished = Gate()
        let broken = NemotronModelStore(root: root) { language, root, _ in
            defer { finished.open() }
            let dir = NemotronModelStore(root: root).variantDirectory(language: language)
            try NemotronFixtures.install(at: dir); started.open(); await gate.pass()
            try Task.checkCancellation()
            throw URLError(.networkConnectionLost)
        }
        let task = Task { try await broken.download(language: "auto") }
        await started.pass()
        #expect(!broken.isReady(language: "auto"), "Even all assets present are incomplete until the transfer commits")
        let weight = broken.variantDirectory(language: "auto").appendingPathComponent("encoder.mlmodelc/weights/weight.bin")
        let inode = try FileManager.default.attributesOfItem(atPath: weight.path)[.systemFileNumber] as? UInt64
        if cancel { task.cancel() }
        gate.open()
        do { _ = try await task.value; Issue.record("Expected transfer failure") } catch {}
        await finished.pass()
        #expect(!broken.isReady(language: "auto"))
        let repaired = NemotronModelStore(root: root) { language, root, _ in
            let dir = NemotronModelStore(root: root).variantDirectory(language: language)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("metadata.json").path))
            try NemotronFixtures.install(at: dir); return dir
        }
        _ = try await repaired.download(language: "ru-RU")
        #expect(repaired.isReady(language: "auto"))
        #expect(inode == (try FileManager.default.attributesOfItem(atPath: weight.path)[.systemFileNumber] as? UInt64))
    }

    @Test("Missing weights and an incomplete downloader cannot report a ready model")
    func incomplete() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NemotronModelStore(root: root) { language, root, _ in
            let dir = NemotronModelStore(root: root).variantDirectory(language: language)
            try NemotronFixtures.install(at: dir)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("encoder.mlmodelc/weights/weight.bin"))
            return dir
        }
        await #expect(throws: NemotronModelStore.StoreError.self) { try await store.download(language: "auto") }
        #expect(!store.isReady(language: "auto"))
        guard case .failed = store.state(language: "auto") else { Issue.record("Missing shared failure"); return }
    }

    @Test("Readiness follows deleted files, even after a successful shared transfer")
    func staleReadiness() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NemotronModelStore(root: root) { language, root, _ in
            let dir = NemotronModelStore(root: root).variantDirectory(language: language)
            try NemotronFixtures.install(at: dir); return dir
        }
        let dir = try await store.download(language: "ru-RU")
        #expect(store.state(language: "auto") == .ready)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("tokenizer.json"))
        #expect(store.state(language: "auto") == .idle)
    }

    @Test("A live recording joins an existing final download and can stop independently")
    func liveWaitsForFinal() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Gate(), finish = Gate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = NemotronModelStore(root: root) { language, root, _ in
            calls.withLock { $0 += 1 }; started.open(); await finish.pass()
            try Task.checkCancellation()
            let dir = NemotronModelStore(root: root).variantDirectory(language: language)
            try NemotronFixtures.install(at: dir); return dir
        }
        let final = Task { try await store.download(language: "auto") }
        await started.pass()
        let live = LiveTranscriptionCoordinator(modelStore: store)
        await live.beginRecording(enabled: true, language: "ru-RU", update: { _ in }, attach: { _ in })
        #expect(await live.snapshot.status == .loading)
        try await Task.sleep(for: .milliseconds(50))
        await live.finishRecording()
        finish.open()
        _ = try await final.value
        #expect(calls.withLock { $0 } == 1)
        #expect(store.isReady(language: "ru-RU"))
    }

    @Test("Another process completes the model under the same lock without a second download")
    func processLock() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NemotronModelStore(root: root) { _, _, _ in Issue.record("Duplicate downloader"); throw URLError(.unknown) }
        let lock = try await FileLock.acquire(store.lockURL)
        let waiting = Task { try await store.download(language: "auto") }
        try await Task.sleep(for: .milliseconds(50))
        try NemotronFixtures.install(at: store.variantDirectory(language: "ru-RU"))
        lock.release()
        _ = try await waiting.value
        #expect(store.isReady(language: "auto"))
    }
}
