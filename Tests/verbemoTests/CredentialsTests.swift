import AppKit
import Foundation
import Testing

@testable import verbemo

/// Where keys go, and what a key check is allowed to conclude.
@Suite(.serialized)
struct CredentialsTests {
    // MARK: - what a check concludes

    @Test("A status is works, refused, or neither — and no answer is not a refusal")
    func verdictFromStatus() {
        #expect(Credentials.verdict(status: 200) == .works)
        #expect(Credentials.verdict(status: 401) == .refused)
        #expect(Credentials.verdict(status: 403) == .refused)
        #expect(Credentials.verdict(status: 500) == .unexpected(status: 500))
        #expect(Credentials.verdict(status: 429) == .unexpected(status: 429))
        #expect(Credentials.verdict(status: nil) == .unreachable)
        // ElevenLabs' working key is the one that gets a validation error.
        #expect(Credentials.verdict(status: 422, accepted: [422]) == .works)
        #expect(Credentials.verdict(status: 200, accepted: [422]) == .unexpected(status: 200))
    }

    /// The defect: offline, every key check came back "that key was refused",
    /// and a person with a perfectly good key was told to go and get another.
    @Test("A Mac with no network is told it could not ask, not that the key was refused")
    func offlineIsUnreachable() async {
        let session = StubbedService.session { _ in .failure(URLError(.notConnectedToInternet)) }
        #expect(await Credentials.assemblyAI("key", session: session) == .unreachable)
        #expect(await Credentials.elevenLabs("key", session: session) == .unreachable)
        #expect(await SummaryKeyProbe.check(
            provider: .anthropic, key: "key", session: session) == .unreachable)

        let refused = StubbedService.session { _ in .success(401) }
        #expect(await Credentials.assemblyAI("key", session: refused) == .refused)
        let elevenLabsWorks = StubbedService.session { _ in .success(422) }
        #expect(await Credentials.elevenLabs("key", session: elevenLabsWorks) == .works)
    }

    @Test("Only a refusal says refused")
    func verdictSentences() {
        let verdicts: [Credentials.Verdict] = [.works, .unreachable, .unexpected(status: 503)]
        for verdict in verdicts {
            #expect(!verdict.sentence(keepingSaved: true).isEmpty)
            #expect(!verdict.sentence(keepingSaved: true).contains("refused"))
        }
        #expect(Credentials.Verdict.refused.sentence(keepingSaved: true).contains("refused"))
    }

    // MARK: - where a key goes

    @Test("The summary key for OpenAI itself shares the transcription key's file")
    func officialOpenAISharesTheSlot() throws {
        try withFreshHome { _ in
            let slot = Credentials.summarySlot(for: "openai-api", in: [:])
            #expect(slot.path == Config.openAIKeyPath)
            #expect(slot.isVerbemos)
            #expect(Credentials.transcriptionSlot(for: "openai", in: [:]).path
                == Config.openAIKeyPath)
        }
    }

    @Test("An OpenAI-compatible endpoint's key has a file of its own")
    func compatibleEndpointHasItsOwnSlot() throws {
        let config: [String: Any] = [
            "summary": ["openai_base_url": "https://openrouter.ai/api/v1"],
        ]
        try withFreshHome(config: config) { _ in
            let slot = Credentials.summarySlot(for: "openai-api", in: config)
            #expect(slot.path == Credentials.openAICompatibleKeyPath)
            #expect(slot.path != Config.openAIKeyPath)
            #expect(slot.isVerbemos)
        }
    }

    @Test("A key file named in the config is where the key is read, and written only if it is verbemo's")
    func namedKeyPathIsRespected() throws {
        try withFreshHome { home in
            let inside: [String: Any] = [
                "summary": ["openai_api_key_path": "~/.config/verbemo/keys/router"],
            ]
            let slot = Credentials.summarySlot(for: "openai-api", in: inside)
            #expect(slot.isNamedInConfig)
            #expect(slot.path.path == home.url.appendingPathComponent(".config/verbemo/keys/router").path)
            #expect(slot.isVerbemos)

            let shared: [String: Any] = [
                "summary": ["api_key_path": "~/.config/anthropic/token"],
            ]
            let sharedSlot = Credentials.summarySlot(for: "anthropic-api", in: shared)
            #expect(sharedSlot.isNamedInConfig)
            #expect(!sharedSlot.isVerbemos, "a file other tools share is not verbemo's to write")

            let assembly: [String: Any] = [
                "transcription": ["assemblyai": ["api_key_path": "~/elsewhere/key"]],
            ]
            #expect(!Credentials.transcriptionSlot(for: "assemblyai", in: assembly).isVerbemos)
        }
    }

    @Test("The summary reads a compatible endpoint's key, and transcription goes on reading OpenAI's")
    func readersAgreeWithTheSlots() throws {
        let config: [String: Any] = [
            "summary": ["backend": "openai-api", "openai_base_url": "https://api.groq.com/openai/v1"],
        ]
        try withFreshHome(config: config) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            #expect(Credentials.summaryOpenAIKey() == nil,
                    "a third-party endpoint is never handed the OpenAI key")

            try Credentials.writeSecret("groq-key", to: Credentials.openAICompatibleKeyPath)
            #expect(Credentials.summaryOpenAIKey() == "groq-key")
            #expect(Config.openAIKey() == "openai-key")
        }
    }

    /// `summary.openai_api_key_path` named one file for both passes, and the
    /// summary sent it to whatever its Base URL said: an OpenAI key went to
    /// OpenRouter the moment the URL changed.
    @Test("An OpenAI key named for the summary is not sent to a third-party Base URL")
    func openAIKeyStaysWithOpenAI() throws {
        let config: [String: Any] = [
            "summary": [
                "backend": "openai-api", "openai_base_url": "https://openrouter.ai/api/v1",
                "openai_api_key_path": "~/secrets/openai",
            ],
        ]
        try withFreshHome(config: config) { home in
            let named = home.url.appendingPathComponent("secrets/openai")
            try Credentials.writeSecret("openai-key", to: named)

            #expect(Credentials.summaryOpenAIKey() == nil,
                    "the OpenAI key was handed to openrouter.ai")
            #expect(Credentials.summarySlot(for: "openai-api", in: config).path
                == Credentials.openAICompatibleKeyPath)

            var withRouterKey = config
            var summary = config["summary"] as! [String: Any]
            summary["openai_compatible_api_key_path"] = "~/secrets/router"
            withRouterKey["summary"] = summary
            try home.writeConfig(withRouterKey)
            try Credentials.writeSecret(
                "router-key", to: home.url.appendingPathComponent("secrets/router"))
            #expect(Credentials.summaryOpenAIKey() == "router-key")
            #expect(Credentials.summarySlot(for: "openai-api", in: withRouterKey).isNamedInConfig)
        }
    }

    /// And the other way: an OpenRouter key named there was read by the
    /// OpenAI transcription engine and sent to api.openai.com.
    @Test("A compatible server's key is not sent to OpenAI by transcription")
    func routerKeyStaysWithTheRouter() throws {
        let config: [String: Any] = [
            "summary": [
                "backend": "openai-api", "openai_base_url": "https://openrouter.ai/api/v1",
                "openai_api_key_path": "~/secrets/router",
            ],
        ]
        try withFreshHome(config: config) { home in
            try Credentials.writeSecret(
                "router-key", to: home.url.appendingPathComponent("secrets/router"))
            #expect(Config.openAIKey() == nil, "transcription read the OpenRouter key")
            #expect(Credentials.transcriptionSlot(for: "openai", in: config).path
                == Config.openAIKeyPath)

            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            #expect(Config.openAIKey() == "openai-key")
        }
    }

    @Test("Transcription's own key file is read, and an older config's summary setting still is for OpenAI")
    func transcriptionKeyFile() throws {
        try withFreshHome { home in
            let legacy: [String: Any] = ["summary": ["openai_api_key_path": "~/secrets/openai"]]
            try home.writeConfig(legacy)
            try Credentials.writeSecret(
                "legacy-key", to: home.url.appendingPathComponent("secrets/openai"))
            #expect(Config.openAIKey() == "legacy-key",
                    "a config written before the setting split lost its transcription key")
            #expect(Credentials.summaryOpenAIKey() == "legacy-key")

            let own: [String: Any] = [
                "transcription": ["openai": ["api_key_path": "~/secrets/transcribe"]],
                "summary": ["openai_base_url": "https://api.groq.com/openai/v1"],
            ]
            try home.writeConfig(own)
            try Credentials.writeSecret(
                "transcribe-key", to: home.url.appendingPathComponent("secrets/transcribe"))
            #expect(Config.openAIKey() == "transcribe-key")
            #expect(Credentials.transcriptionSlot(for: "openai", in: own).isNamedInConfig)
            #expect(Credentials.summaryOpenAIKey() == nil)
        }
    }

    @Test("A server on this Mac may still be offered the OpenAI key when nothing else was pasted")
    func loopbackEndpointFallsBackToTheOpenAIKey() throws {
        let config: [String: Any] = [
            "summary": ["backend": "openai-api", "openai_base_url": "http://127.0.0.1:1234/v1"],
        ]
        try withFreshHome(config: config) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            #expect(Credentials.summaryOpenAIKey() == "openai-key")
        }
    }

    // MARK: - the form, end to end

    @Test("Each cloud provider keeps its key editor inside its own card")
    @MainActor
    func cloudProviderCardsOwnTheirKeyFields() throws {
        try withFreshHome(config: ["transcription": ["engine": "assemblyai"]]) { _ in
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.transcription)
            defer { form.stop(); withExtendedLifetime(application) {} }
            let root = try #require(application.panel.contentView)
            let cards = root.allDescendants.compactMap { $0 as? ChoiceCard }
            for service in CloudService.allCases {
                let id = service.rawValue
                let card = try #require(cards.first { $0.id == id })
                let field = try #require(card.allDescendants.first {
                    $0.identifier?.rawValue == "transcription.key.\(id)"
                } as? NSSecureTextField)
                #expect(!field.isHiddenOrHasHiddenAncestor)
                let title = try #require(card.accessibilityLabel())
                #expect(field.accessibilityLabel()?.contains(title) == true)
                field.stringValue = "draft-\(id)"
                #expect(card.accessibilityPerformPress())
            }
            form.refresh()
            for service in CloudService.allCases {
                let field = try Self.field("transcription.key.\(service.rawValue)", in: form)
                #expect(field.stringValue == "draft-\(service.rawValue)")
                #expect(service.key() == nil, "selecting a card must not save another provider's draft")
            }
        }
    }

    @Test("Cloud provider selection restores its endpoint and saved key")
    @MainActor
    func cloudProvidersKeepIndependentKeys() async throws {
        try await withFreshHome(config: ["transcription": ["engine": "assemblyai"]]) { home in
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.transcription)
            defer { form.stop(); withExtendedLifetime(application) {} }
            let page = try #require(form.settingsPages[.transcription])
            let cards = page.allDescendants.compactMap { $0 as? ChoiceCard }
            var asked: [Credentials.Check] = []
            form.checkKey = { asked.append($0); return .works }
            let providers: [(CloudService, Credentials.Check.Service, String)] = [
                (.assemblyAI, .assemblyAI, "api.assemblyai.com"),
                (.openAI, .openAI(baseURL: "https://api.openai.com/v1"), "api.openai.com"),
                (.elevenLabs, .elevenLabs, "api.elevenlabs.io"),
            ]
            for (service, check, _) in providers {
                let id = service.rawValue
                #expect(try #require(cards.first { $0.id == id }).accessibilityPerformPress())
                let field = try Self.field("transcription.key.\(id)", in: form)
                field.stringValue = "saved-\(id)-key"
                await form.saveCloudKey(for: id)
                #expect(asked.last == Credentials.Check(service: check, key: "saved-\(id)-key"))
                #expect(field.stringValue.isEmpty, "saved secrets must not be redisplayed")
                #expect(Config.transcriptionCloudProvider() == id)
            }
            for (service, _, host) in providers.reversed() {
                let id = service.rawValue
                #expect(try #require(cards.first { $0.id == id }).accessibilityPerformPress())
                let selected = CloudService(provider: EngineResolver.cloudProvider(configured: Config.transcriptionEngine()))
                #expect(selected == service)
                #expect(selected.probeURL.host == host)
                #expect(selected.key() == "saved-\(id)-key")
                #expect(!home.configText!.contains("saved-\(id)-key"))
                let path = Credentials.transcriptionSlot(for: id, in: Config.raw()).path
                #expect(Config.secret(at: path) == "saved-\(id)-key")
                let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
                #expect(permissions?.intValue == 0o600)
            }
            #expect(asked.count == 3, "switching a configured provider must not require the key again")
        }
    }

    @Test("A late key check saves only its own provider without undoing a later selection", arguments: [false, true])
    @MainActor
    func cloudKeyCheckPreservesLaterChoice(turnCloudOff: Bool) async throws {
        try await withFreshHome(config: ["transcription": ["engine": "assemblyai"]]) { _ in
            try Credentials.writeSecret("assembly-key", to: Config.assemblyAIKeyPath)
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.transcription)
            defer { form.stop(); withExtendedLifetime(application) {} }
            let page = try #require(form.settingsPages[.transcription])
            let cards = page.allDescendants.compactMap { $0 as? ChoiceCard }
            #expect(try #require(cards.first { $0.id == "elevenlabs" }).accessibilityPerformPress())
            let started = Gate(), release = Gate()
            form.checkKey = { _ in started.open(); await release.pass(); return .works }
            try Self.field("transcription.key.elevenlabs", in: form).stringValue = "elevenlabs-key"
            let check = Task { await form.saveCloudKey(for: "elevenlabs") }
            await started.pass()
            #expect(try #require(cards.first { $0.id == "openai" }).accessibilityPerformPress())
            if turnCloudOff {
                let toggle = try #require(page.allDescendants.first {
                    $0.identifier?.rawValue == "transcription.cloud"
                } as? NSSwitch)
                toggle.state = .off
                _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
            }
            release.open()
            await check.value
            #expect(Config.elevenLabsKey() == "elevenlabs-key")
            #expect(Config.assemblyAIKey() == "assembly-key")
            #expect(Config.openAIKey() == "openai-key")
            #expect(Config.transcriptionCloudProvider() == "openai")
            #expect(Config.transcriptionEnabled() == !turnCloudOff)
        }
    }

    @Test("An older key check cannot replace a newer key or a new draft", arguments: [false, true])
    @MainActor
    func cloudKeyChecksKeepLatestEdit(saveLatest: Bool) async throws {
        try await withFreshHome(config: ["transcription": ["engine": "assemblyai"]]) { _ in
            try Credentials.writeSecret("saved-key", to: Config.assemblyAIKeyPath)
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.transcription)
            defer { form.stop(); withExtendedLifetime(application) {} }
            let field = try Self.field("transcription.key.assemblyai", in: form)
            let started = Gate(), release = Gate()
            form.checkKey = { check in
                if check.key == "older-key" { started.open(); await release.pass() }
                return .works
            }
            field.stringValue = "older-key"
            let oldCheck = Task { await form.saveCloudKey(for: "assemblyai") }
            await started.pass()
            field.stringValue = "newer-key"
            if saveLatest { await form.saveCloudKey(for: "assemblyai") }
            release.open()
            await oldCheck.value
            #expect(Config.assemblyAIKey() == (saveLatest ? "newer-key" : "saved-key"))
            #expect(field.stringValue == (saveLatest ? "" : "newer-key"))
        }
    }

    @Test("Switching between OpenAI and a compatible service keeps endpoints and keys separate")
    @MainActor
    func summaryProviderSwitchKeepsEndpointsAndKeys() async throws {
        let config: [String: Any] = [
            "summary": ["backend": "openai-api", "openai_base_url": "https://router.example/api/v1"],
        ]
        try await withFreshHome(config: config) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            try Credentials.writeSecret("router-key", to: Credentials.openAICompatibleKeyPath)
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.summary)
            defer { form.stop(); withExtendedLifetime(application) {} }
            let selector = try #require(application.panel.contentView?.allDescendants.compactMap { $0 as? NSSegmentedControl }
                .first { $0.label(forSegment: 0) == "OpenAI" })
            try #require(selector.segmentCount == 3)
            #expect(selector.selectedSegment == 2, "a legacy custom endpoint must select compatible")

            selector.selectedSegment = 0
            selector.sendAction(selector.action, to: selector.target)
            form.refresh()
            #expect(selector.selectedSegment == 0)
            #expect(Config.summary().openAIBaseURL == "https://api.openai.com/v1")
            #expect(Credentials.summaryOpenAIKey() == "openai-key")
            #expect(try Self.field("summary.key", in: form).placeholderString == "API key")

            selector.selectedSegment = 2
            selector.sendAction(selector.action, to: selector.target)
            form.refresh()
            #expect(selector.selectedSegment == 2)
            #expect(Config.summary().openAIBaseURL == "https://router.example/api/v1")
            #expect(Credentials.summaryOpenAIKey() == "router-key")
            #expect(try Self.field("summary.key", in: form).placeholderString == "API key")

            var asked: [Credentials.Check] = []
            form.checkKey = { asked.append($0); return .works }
            try Self.field("summary.key", in: form).stringValue = "replacement-router-key"
            await form.saveSummaryKey()
            #expect(asked == [Credentials.Check(
                service: .openAI(baseURL: "https://router.example/api/v1"), key: "replacement-router-key")])
            #expect(Config.openAIKey() == "openai-key")
        }
    }

    @Test("Choosing a compatible service before entering its URL does not use the OpenAI key")
    @MainActor
    func compatibleProviderNeedsItsOwnEndpoint() throws {
        try withFreshHome(config: ["summary": ["backend": "openai-api"]]) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.summary)
            defer { form.stop(); withExtendedLifetime(application) {} }
            let selector = try #require(application.panel.contentView?.allDescendants.compactMap { $0 as? NSSegmentedControl }
                .first { $0.label(forSegment: 0) == "OpenAI" })
            try #require(selector.segmentCount == 3)
            selector.selectedSegment = 2
            selector.sendAction(selector.action, to: selector.target)
            form.refresh()
            #expect(selector.selectedSegment == 2)
            #expect(Config.summary().openAIBaseURL.isEmpty)
            #expect(Credentials.summaryOpenAIKey() == nil)
            #expect(Credentials.summarySlot(for: "openai-api", in: Config.raw()).path
                == Credentials.openAICompatibleKeyPath)
        }
    }

    /// The defect itself: a key pasted for OpenRouter was checked against
    /// OpenRouter and then written over the OpenAI key, which the OpenAI
    /// transcription engine reads. Every meeting after it came back 401.
    @Test("Saving a summary key for a compatible endpoint leaves the OpenAI key alone")
    @MainActor
    func summaryKeyForAnEndpointKeepsTheOpenAIKey() async throws {
        let config: [String: Any] = [
            "summary": ["backend": "openai-api", "openai_base_url": "https://openrouter.ai/api/v1"],
        ]
        try await withFreshHome(config: config) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.summary)
            defer { form.stop(); withExtendedLifetime(application) {} }
            var asked: [Credentials.Check] = []
            form.checkKey = { asked.append($0); return .works }

            try Self.field("summary.key", in: form).stringValue = "router-key"
            await form.saveSummaryKey()

            #expect(asked == [Credentials.Check(
                service: .openAI(baseURL: "https://openrouter.ai/api/v1"), key: "router-key")])
            #expect(Config.secret(at: Config.openAIKeyPath) == "openai-key")
            #expect(Config.secret(at: Credentials.openAICompatibleKeyPath) == "router-key")
            #expect(Credentials.summaryOpenAIKey() == "router-key")
            #expect(try Self.field("summary.key.status", in: form).stringValue == "key works")
        }
    }

    @Test("A key file the config names outside verbemo's drawer is not written, and the form says where")
    @MainActor
    func summaryKeyIntoANamedSharedFileIsRefused() async throws {
        let config: [String: Any] = [
            "summary": ["backend": "anthropic-api", "api_key_path": "~/.config/anthropic/token"],
        ]
        try await withFreshHome(config: config) { home in
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.summary)
            defer { form.stop(); withExtendedLifetime(application) {} }
            var asked = 0
            form.checkKey = { _ in asked += 1; return .works }

            try Self.field("summary.key", in: form).stringValue = "sk-ant-new"
            await form.saveSummaryKey()

            #expect(asked == 0, "a key that cannot be saved is not worth checking")
            #expect(Config.secret(at: Config.anthropicKeyPath) == nil)
            #expect(!FileManager.default.fileExists(
                atPath: home.url.appendingPathComponent(".config/anthropic/token").path))
            let status = try Self.field("summary.key.status", in: form).stringValue
            #expect(status.contains("~/.config/anthropic/token"))
        }
    }

    @Test("An unsuccessful cloud key check preserves the saved key", arguments: [
        Credentials.Verdict.unreachable, .refused, .unexpected(status: 503),
    ])
    @MainActor
    func cloudKeyFailure(verdict: Credentials.Verdict) async throws {
        try await withFreshHome { _ in
            try Credentials.writeSecret("good-key", to: Config.assemblyAIKeyPath)
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.transcription)
            defer { form.stop(); withExtendedLifetime(application) {} }
            form.checkKey = { _ in verdict }

            try Self.field("transcription.key.assemblyai", in: form).stringValue = "new-key"
            await form.saveCloudKey(for: "assemblyai")

            #expect(Config.secret(at: Config.assemblyAIKeyPath) == "good-key")
            let status = try Self.field("transcription.key.assemblyai.status", in: form).stringValue
            #expect(status == verdict.sentence(keepingSaved: true))
        }
    }

    @Test("Changing the key file during verification does not write to the previous slot")
    @MainActor
    func cloudKeySlotChangeDuringCheck() async throws {
        try await withFreshHome { _ in
            try Credentials.writeSecret("saved-key", to: Config.assemblyAIKeyPath)
            let application = ApplicationWindow()
            let form = application.settings.setup
            application.navigate(.transcription)
            defer { form.stop(); withExtendedLifetime(application) {} }
            form.checkKey = { _ in
                Config.update(path: ["transcription", "assemblyai", "api_key_path"], value: "~/external/key")
                return .works
            }
            try Self.field("transcription.key.assemblyai", in: form).stringValue = "new-key"
            await form.saveCloudKey(for: "assemblyai")
            #expect(Config.secret(at: Config.assemblyAIKeyPath) == "saved-key")
            #expect(try Self.field("transcription.key.assemblyai.status", in: form).stringValue
                == "Key settings changed — enter the key again.")
        }
    }

    @MainActor
    private static func field(_ id: String, in form: SetupForm) throws -> NSTextField {
        var pending = Array(form.settingsPages.values) as [NSView]
        while let view = pending.popLast() {
            if let field = view as? NSTextField, field.identifier?.rawValue == id { return field }
            pending.append(contentsOf: view.subviews)
        }
        throw FieldMissing(id: id)
    }

    private struct FieldMissing: Error { let id: String }
}

/// A URL loading system that answers every request itself — with a status,
/// or with the error a Mac with no network gets.
final class StubbedService: URLProtocol, @unchecked Sendable {
    typealias Answer = @Sendable (URLRequest) -> Result<Int, URLError>

    /// One answer per session, found by the header this adds to every request
    /// it makes, so suites running at once cannot answer for each other.
    private static let answers = Answers()

    static func session(_ answer: @escaping Answer) -> URLSession {
        let id = UUID().uuidString
        answers.set(id, answer)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedService.self]
        configuration.httpAdditionalHeaders = ["x-stub": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "x-stub") ?? ""
        guard let answer = Self.answers.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch answer(request) {
        case .success(let status):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: StubbedService.Answer] = [:]

    func set(_ id: String, _ answer: @escaping StubbedService.Answer) {
        lock.withLock { byID[id] = answer }
    }

    func get(_ id: String) -> StubbedService.Answer? {
        lock.withLock { byID[id] }
    }
}
