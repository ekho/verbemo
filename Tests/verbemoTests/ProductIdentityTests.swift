import Foundation
import Testing

@testable import verbemo

struct ProductIdentityTests {
    @Test func separateHomeAndRecordings() throws {
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try Home.$scoped.withValue(home) {
            #expect(Config.path == home.url.appendingPathComponent(".config/verbemo/config.json"))
            #expect(home.setupFile == home.url.appendingPathComponent(".config/verbemo/setup.json"))
            #expect(Config.defaultRoot == home.url.appendingPathComponent("Verbemo Recordings", isDirectory: true))
            #expect(Config.keysDir == home.url.appendingPathComponent(".config/verbemo/keys", isDirectory: true))
            #expect(AgentCLI.path == home.url.appendingPathComponent(".local/bin/verbemo"))
            let oldRecordings = home.url.appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: oldRecordings, withIntermediateDirectories: true)
            #expect(Config.resolveRoot(cliOverride: oldRecordings.path) == oldRecordings)
        }
    }

    @Test func relocationDoesNotReplaceAmanuWhenSourceWasRenamed() throws {
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let source = home.url.appendingPathComponent("image/Amanu.app", isDirectory: true)
        let applications = home.url.appendingPathComponent("Applications", isDirectory: true)
        let old = applications.appendingPathComponent("Amanu.app", isDirectory: true)
        for directory in [source, old] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sentinel = Data("Amanu application".utf8)
        try sentinel.write(to: old.appendingPathComponent("sentinel"))
        try Data("Verbemo application".utf8).write(to: source.appendingPathComponent("sentinel"))
        let installed = try ApplicationRelocation.install(from: source, in: applications)
        #expect(installed.lastPathComponent == "Verbemo.app")
        #expect(try Data(contentsOf: old.appendingPathComponent("sentinel")) == sentinel)
        #expect(try Data(contentsOf: installed.appendingPathComponent("sentinel"))
            == Data("Verbemo application".utf8))
    }

    @Test func separateModelsAndIPC() {
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        Home.$scoped.withValue(home) {
            for model in ModelStorage().all() {
                #expect(model.directory.path.hasPrefix(home.url.path + "/"))
                #expect(model.directory.path.contains("/verbemo/"))
            }
            #expect(Config.didChange.rawValue == "name.ekho.verbemo.config.didChange")
            let path = home.url.appendingPathComponent("session").path
            #expect(Notifications.session(in: ["name.ekho.verbemo.session": path])?.path == path)
            #expect(Notifications.session(in: ["me.samat.amanu.session": path]) == nil)
        }
    }

    @Test func sharedDiarizationStoresFollowHomeAndKeepLifetime() {
        let first = Home.sandbox()
        let second = Home.sandbox()
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }
        for model in DiarizationModel.allCases {
            let firstStore = Home.$scoped.withValue(first) {
                let store = DiarizationModelStore.shared(for: model)
                #expect(store === DiarizationModelStore.shared(for: model))
                #expect(store.directory.path.hasPrefix(first.url.path + "/.cache/verbemo/"))
                return store
            }
            Home.$scoped.withValue(second) {
                #expect(firstStore !== DiarizationModelStore.shared(for: model))
            }
            Home.$scoped.withValue(first) {
                #expect(firstStore === DiarizationModelStore.shared(for: model))
            }
        }
    }

    @Test func doesNotReadOrModifyAmanu() throws {
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try Home.$scoped.withValue(home) {
            let legacy = [
                ".config/amanu/config.json": Data(#"{"user_name":"Amanu sentinel","recordings_dir":"~/Recordings"}"#.utf8),
                ".config/amanu/setup.json": Data("old setup".utf8),
                ".config/amanu/keys/openai": Data("old private key".utf8),
                ".cache/amanu/diarization/sentinel": Data([0, 1, 255]),
                "Library/Application Support/amanu/models/whisper/sentinel": Data([2, 3, 254]),
                "Library/Application Support/FluidAudio/Models/sentinel": Data([4, 5, 253]),
                "Recordings/sentinel": Data("old recording".utf8),
                ".config/openai/token": Data("shared test key".utf8),
            ]
            for (path, bytes) in legacy {
                let file = home.url.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file)
            }
            #expect(Config.userName() == nil)
            #expect(Config.recordingsDir() == nil)
            #expect(Config.openAIKey() == "shared test key")
            #expect(Config.update(path: ["user_name"], value: "Verbemo user"))
            try Credentials.writeSecret("new private key", to: Config.openAIKeyPath)
            #expect(Config.userName() == "Verbemo user")
            #expect(Config.openAIKey() == "new private key")
            let storage = ModelStorage()
            for model in storage.all() where model.kind != .diarization {
                try FileManager.default.createDirectory(at: model.directory, withIntermediateDirectories: true)
                try Data("new model".utf8).write(to: model.directory.appendingPathComponent("sentinel"))
                try storage.delete(model)
                #expect(!FileManager.default.fileExists(atPath: model.directory.path))
            }
            for (path, bytes) in legacy {
                #expect(try Data(contentsOf: home.url.appendingPathComponent(path)) == bytes)
            }
        }
    }
}
