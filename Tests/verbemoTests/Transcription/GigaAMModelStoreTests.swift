import Foundation
import os
import Testing
@testable import verbemo

struct GigaAMModelStoreTests {
    private let payload = Data("gigaam model bytes".utf8)
    private let sha256 = "442de2a02580f805d19af697c86dd54b591ee1c72681980c379df7fb80445979"

    @Test("A verified GigaAM model is installed atomically with byte progress")
    func verifiedDownload() async throws {
        let directory = temporaryDirectory()
        let manifest = fixtureManifest(sha256: sha256)
        let updates = OSAllocatedUnfairLock(initialState: [GigaAMModelStore.Progress]())
        let payload = payload
        let store = GigaAMModelStore(directory: directory, manifest: manifest) {
            _, partial, progress in
            try payload.write(to: partial)
            progress(.init(receivedBytes: Int64(payload.count), totalBytes: Int64(payload.count)))
        }

        let installed = try await store.download { update in
            updates.withLock { $0.append(update) }
        }

        #expect(try Data(contentsOf: installed) == payload)
        #expect(!FileManager.default.fileExists(atPath: installed.path + ".partial"))
        #expect(updates.withLock { $0.last?.fraction } == 1)
    }

    @Test("A corrupt GigaAM download is removed")
    func corruptDownload() async throws {
        let directory = temporaryDirectory()
        let manifest = fixtureManifest(sha256: String(repeating: "0", count: 64))
        let payload = payload
        let store = GigaAMModelStore(directory: directory, manifest: manifest) {
            _, partial, _ in try payload.write(to: partial)
        }

        await #expect(throws: GigaAMModelStore.Error.invalidSHA256) {
            try await store.download()
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(manifest.fileName).path))
    }

    private func fixtureManifest(sha256: String) -> GigaAMModelStore.Manifest {
        .init(
            id: "fixture",
            fileName: "fixture.gguf",
            revision: "075dff81f843cf23d22b4ce943ffdc4dd8650cd7",
            downloadURL: URL(string: "https://example.test/fixture.gguf")!,
            expectedBytes: Int64(payload.count),
            sha256: sha256)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("verbemo-gigaam-store-\(UUID().uuidString)")
    }
}
