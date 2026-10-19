import Foundation
import os
import Testing
@testable import verbemo

struct WhisperModelStoreTests {
    private let payload = Data("whisper model bytes".utf8)
    private let payloadSHA256 = "54f3082fc93cfb892a86cbbf701e2be927e9d4669c4ec5e3a22101f3c6c2a61a"

    @Test("A verified model replaces the partial file and forwards byte progress")
    func verifiedDownloadIsInstalledAtomically() async throws {
        let directory = try temporaryDirectory("valid")
        let updates = OSAllocatedUnfairLock(initialState: [WhisperModelStore.Progress]())
        let manifest = fixtureManifest(sha256: payloadSHA256)
        let payload = payload
        let store = WhisperModelStore(directory: directory, manifest: manifest) {
            _, partial, progress in
            try payload.write(to: partial)
            progress(.init(receivedBytes: 7, totalBytes: Int64(payload.count)))
            progress(.init(receivedBytes: Int64(payload.count), totalBytes: Int64(payload.count)))
        }

        let installed = try await store.download { update in
            updates.withLock { $0.append(update) }
        }

        #expect(installed == directory.appendingPathComponent(manifest.fileName))
        #expect(try Data(contentsOf: installed) == payload)
        #expect(!FileManager.default.fileExists(atPath: installed.path + ".partial"))
        #expect(updates.withLock { $0.map(\.receivedBytes) } == [7, 19])
    }

    @Test("A model with the wrong digest is rejected and leaves no partial or final file")
    func corruptDownloadIsRemoved() async throws {
        let directory = try temporaryDirectory("corrupt")
        let manifest = fixtureManifest(sha256: String(repeating: "0", count: 64))
        let payload = payload
        let store = WhisperModelStore(directory: directory, manifest: manifest) {
            _, partial, _ in try payload.write(to: partial)
        }

        await #expect(throws: WhisperModelStore.Error.invalidSHA256) {
            try await store.download()
        }

        let final = directory.appendingPathComponent(manifest.fileName)
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: final.path + ".partial"))
    }

    @Test("A verified installed model is reused without another network request")
    func verifiedModelIsReused() async throws {
        let directory = try temporaryDirectory("reuse")
        let manifest = fixtureManifest(sha256: payloadSHA256)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: directory.appendingPathComponent(manifest.fileName))
        let downloads = OSAllocatedUnfairLock(initialState: 0)
        let store = WhisperModelStore(directory: directory, manifest: manifest) {
            _, _, _ in downloads.withLock { $0 += 1 }
        }

        let result = try await store.download()

        #expect(result.lastPathComponent == manifest.fileName)
        #expect(downloads.withLock { $0 } == 0)
        #expect(store.bytesOnDisk == payload.count)
    }

    @Test("Cancelling verification never deletes an already installed model")
    func cancellationKeepsInstalledModel() async throws {
        let directory = try temporaryDirectory("cancel-existing")
        let manifest = fixtureManifest(sha256: payloadSHA256)
        try payload.write(to: directory.appendingPathComponent(manifest.fileName))
        let store = WhisperModelStore(directory: directory, manifest: manifest) { _, _, _ in
            throw CancellationError()
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.download()
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: directory.appendingPathComponent(manifest.fileName)) == payload)
    }

    private func fixtureManifest(sha256: String) -> WhisperModelStore.Manifest {
        .init(
            id: "fixture",
            fileName: "fixture.bin",
            revision: "98aa99a0a9db05ae2342309f5096248665f7cba3",
            downloadURL: URL(string: "https://example.test/fixture.bin")!,
            expectedBytes: Int64(payload.count),
            sha256: sha256)
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbemo-whisper-store-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
