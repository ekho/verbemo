import Foundation
import CallIntegrations
import KTalkIntegration

/// Composition root: all other consumers depend only on CallIntegrations.
@MainActor
final class CallIntegrationMonitor {
    private(set) var observations: [CallObservation] = []
    var onChange: (([CallObservation]) -> Void)?
    private var tasks: [Task<Void, Never>] = []
    private var accepting = false

    static func configuredProviders() -> [any CallIntegration] {
        let settings = Config.ktalkIntegration()
        guard settings.enabled else { return [] }
        let text = settings.space
        let url = text.isEmpty ? nil : URL(string: text)
        // Invalid configuration must not re-enable the raw microphone trigger.
        let provider = (text.isEmpty || url != nil ? try? KTalkIntegration(spaceURL: url,
                accessibilityEnabled: settings.accessibility) : nil)
            ?? (try! KTalkIntegration(accessibilityEnabled: settings.accessibility))
        return [provider]
    }

    func start(providers: [any CallIntegration]) {
        guard tasks.isEmpty else { return }
        accepting = true
        observations = providers.map { .init(integrationID: $0.id, application: $0.application,
            observedAt: Date(), participation: .unknown) }
        for provider in providers {
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    let value = await provider.observe()
                    guard !Task.isCancelled, let self, accepting else { break }
                    observations.removeAll { $0.integrationID == value.integrationID }
                    observations.append(value)
                    onChange?(observations)
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                }
                await provider.stop()
            })
        }
    }

    func stopAdmission() {
        accepting = false
        for task in tasks { task.cancel() }
        observations = observations.map { .init(integrationID: $0.integrationID, application: $0.application,
            observedAt: Date(), participation: .unknown) }
        onChange?(observations)
    }

    func stop() async {
        stopAdmission()
        for task in tasks { await task.value }
        tasks.removeAll()
    }
}
