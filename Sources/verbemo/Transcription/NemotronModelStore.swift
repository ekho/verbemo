import FluidAudio
import Foundation
import os

/// One on-disk Nemotron resource for live and final transcription. Recognition
/// sessions own their decoder state; only the download and files are shared.
struct NemotronModelStore: Sendable {
    static let title = "NVIDIA Nemotron 3.5 ASR Streaming Multilingual 0.6B"
    static let chunkMilliseconds = 1120
    static let didChange = Notification.Name("NemotronModelStore.didChange")
    enum State: Equatable, Sendable {
        case idle, downloading(Double), ready, failed(String)
    }
    enum StoreError: Error, LocalizedError {
        case incomplete
        var errorDescription: String? {
            localised("Nemotron download is incomplete. Try again.", "Nemotron скачан не полностью. Повторите загрузку.")
        }
    }
    typealias Downloader = @Sendable (String, URL, @escaping @Sendable (Double) -> Void) async throws -> URL
    private static let downloads = SharedDownloads<Double>()
    private static let states = OSAllocatedUnfairLock(initialState: [String: (UUID, State)]())
    let root: URL
    private let downloader: Downloader

    init(root: URL? = nil, downloader: @escaping Downloader = { language, root, progress in
        try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: language, chunkMs: chunkMilliseconds, to: root
        ) { progress($0.fractionCompleted) }
    }) {
        self.root = (root ?? Home.current.modelsDirectory.appendingPathComponent("FluidAudio", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        self.downloader = downloader
    }

    var modelDirectory: URL {
        root.appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
    }
    var lockURL: URL { root.appendingPathComponent(".nemotron-model.lock") }
    func variantDirectory(language: String) -> URL {
        modelDirectory.appendingPathComponent(
            StreamingNemotronMultilingualAsrManager.languageDirectory(for: language), isDirectory: true)
            .appendingPathComponent("\(Self.chunkMilliseconds)ms", isDirectory: true)
    }
    private func marker(_ variant: URL) -> URL { variant.appendingPathComponent(".verbemo-incomplete") }

    func isReady(language: String) -> Bool {
        let variant = variantDirectory(language: language)
        return !FileManager.default.fileExists(atPath: marker(variant).path) && Self.completeFiles(at: variant)
    }

    private static func completeFiles(at dir: URL) -> Bool {
        func file(_ name: String) -> Bool {
            ((try? dir.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
        func model(_ name: String) -> Bool {
            // Empty model directories can survive an interrupted download.
            let compiled = "\(name).mlmodelc/"
            let package = "\(name).mlpackage/"
            return (file(compiled + "coremldata.bin") && file(compiled + "model.mil")
                && file(compiled + "weights/weight.bin"))
                || (file(package + "Manifest.json") && file(package + "Data/com.apple.CoreML/model.mlmodel")
                    && file(package + "Data/com.apple.CoreML/weights/weight.bin"))
        }
        guard file("metadata.json"), file("tokenizer.json"), model("encoder") else { return false }
        return ["decoder_joint_argmax", "decoder_joint_noencproj", "decoder_joint"].contains(where: model)
            || (model("decoder") && model("joint"))
    }

    func state(language: String) -> State {
        if isReady(language: language) { return .ready }
        let cached = Self.states.withLock { $0[variantDirectory(language: language).path]?.1 } ?? .idle
        return cached == .ready ? .idle : cached
    }
    var isDownloading: Bool {
        Self.states.withLock { values in
            values.contains { key, value in
                key.hasPrefix(modelDirectory.path + "/") && { if case .downloading = value.1 { return true }; return false }()
            }
        }
    }

    @discardableResult
    func download(language: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        let variant = variantDirectory(language: language)
        if isReady(language: language) { progress?(1); return variant }
        return try await Self.downloads.wait(for: variant.path, progress: { progress?($0) }) { [self] report in
            let operation = UUID()
            Self.states.withLock { $0[variant.path] = (operation, .downloading(0)) }
            NotificationCenter.default.post(name: Self.didChange, object: root)
            @Sendable func update(_ state: State) {
                let changed = Self.states.withLock { states in
                    guard states[variant.path]?.0 == operation else { return false }
                    let changed = states[variant.path]?.1 != state
                    states[variant.path] = (operation, state)
                    return changed
                }
                if changed { NotificationCenter.default.post(name: Self.didChange, object: root) }
            }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let lock = try await FileLock.acquire(lockURL)
                defer { lock.release() }
                try Task.checkCancellation()
                if isReady(language: language) { update(.ready); report(1); return variant }
                try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)
                try Data().write(to: marker(variant), options: .atomic)
                // FluidAudio's marker alone can bypass repair of missing assets.
                try? FileManager.default.removeItem(at: variant.appendingPathComponent("metadata.json"))
                _ = try await downloader(language, root) { fraction in
                    let fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
                    update(.downloading((fraction * 100).rounded(.down) / 100))
                    report(fraction)
                }
                try Task.checkCancellation()
                guard Self.completeFiles(at: variant) else { throw StoreError.incomplete }
                try FileManager.default.removeItem(at: marker(variant))
                update(.ready)
                report(1)
                return variant
            } catch is CancellationError {
                update(.idle)
                throw CancellationError()
            } catch {
                update(.failed(error.localizedDescription))
                throw error
            }
        }
    }

    func delete() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try await FileLock.acquire(lockURL)
        defer { lock.release() }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
        Self.states.withLock { states in
            states = states.filter { !$0.key.hasPrefix(modelDirectory.path + "/") }
        }
        NotificationCenter.default.post(name: Self.didChange, object: root)
    }
}
