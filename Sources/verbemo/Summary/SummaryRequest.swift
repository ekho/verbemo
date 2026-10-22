import Foundation

/// Immutable parameters and backend closures for one user-approved summary attempt.
/// Keys stay inside closures in memory; nothing here is written to configuration.
struct SummaryRequest: Sendable {
    let settings: Config.SummarySettings
    let backends: [LLMBackend]
    let fingerprint: String?

    static func capture(backend: String? = nil) throws -> SummaryRequest {
        if let reason = Config.unreadableReason { throw PostProcessor.Refusal.configUnreadable(reason) }
        let config = Config.raw()
        var settings = Config.summary(in: config)
        if let backend {
            guard LLMBackend.names.contains(backend) else { throw unavailable() }
            settings.backend = backend
            settings.enabled = true
        }
        guard settings.enabled, settings.backend != "none" else { throw unavailable() }
        let backends = LLMBackend.available(preference: settings.backend,
            anthropicModel: settings.configuredModel, config: config, freezeConfiguration: true)
        guard !backends.isEmpty else { throw unavailable() }
        return SummaryRequest(settings: settings, backends: backends,
            fingerprint: MeetingEgress.fingerprint(for: .summary,
                route: .init(preference: settings.backend, anthropicModel: settings.configuredModel),
                summary: settings, backends: backends, config: config))
    }

    func checkAccess() async throws {
        var failure: (any Error)?
        for backend in backends {
            try Task.checkCancellation()
            do { try await backend.checkAccess(); return }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let advice = LLMError.signInAdvice(error, backend: backend.name, hasNextBackend: false) {
                    let command = backend.name == "claude-cli" ? "claude /login" : "codex login"
                    failure = PostProcessor.SummaryRegenerationError.unavailable(localised(advice,
                        "Нет входа в \(backend.name). Выполните \(command) и повторите попытку."))
                } else if error is PostProcessor.SummaryRegenerationError {
                    failure = error
                } else {
                    failure = PostProcessor.SummaryRegenerationError.unavailable(localised(
                        "Could not verify access to \(backend.name). Check its connection and Summary settings, then retry.",
                        "Не удалось проверить доступ к \(backend.name). Проверьте подключение и настройки сводки, затем повторите попытку."))
                }
            }
        }
        throw failure ?? Self.unavailable()
    }

    static func unavailable() -> PostProcessor.SummaryRegenerationError {
        .unavailable(localised("This provider is unavailable. Check Summary settings.",
                               "Способ недоступен. Проверьте настройки сводки."))
    }

    var disclosure: String {
        let destinations = backends.map { backend in
            switch backend.name {
            case "codex-cli": return localised("Codex (service configured in Codex)", "Codex (сервис из настроек Codex)")
            case "claude-cli": return "Claude Code / Anthropic"
            case "anthropic-api": return "Anthropic API"
            case "openai-api": return "API · " + Self.host(settings.openAIBaseURL)
            case "ollama": return "Ollama · " + Self.host(settings.ollamaBaseURL)
                + localised(" (cloud models may forward text)", " (облачная модель может отправить текст дальше)")
            default: return backend.name
            }
        }.joined(separator: " → ")
        return localised("Transcript destination: ", "Куда отправится текст: ") + destinations
            + localised(". Only for this summary; global settings stay unchanged.",
                        ". Только для этой сводки; общие настройки не меняются.")
    }

    private static func host(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return localised("invalid address", "неверный адрес") }
        return host + (url.port.map { ":\($0)" } ?? "")
    }
}
