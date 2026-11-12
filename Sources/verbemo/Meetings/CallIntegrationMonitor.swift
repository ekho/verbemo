import Foundation
import CallIntegrations
import KTalkIntegration

/// Composition root: all other consumers depend only on CallIntegrations.
@MainActor
final class CallIntegrationMonitor {
    private(set) var observations: [CallObservation] = []
    var onChange: (([CallObservation]) -> Void)?
    private var tasks: [Task<Void, Never>] = []
    private var providers: [any CallIntegration] = []
    private var accepting = false

    static func configuredProviders() -> [any CallIntegration] {
        let settings = Config.ktalkIntegration()
        guard settings.enabled else { return [] }
        let text = settings.space
        let url = text.isEmpty ? nil : URL(string: text)
        let provider = (text.isEmpty || url != nil ? try? KTalkIntegration(spaceURL: url,
                accessibilityEnabled: settings.accessibility) : nil)
            ?? (try! KTalkIntegration(accessibilityEnabled: settings.accessibility))
        return [provider]
    }

    func start(providers: [any CallIntegration]) {
        guard tasks.isEmpty else { return }
        self.providers = providers
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

    var statusText: String {
        if providers.isEmpty { return localised("KTalk integration is off", "Интеграция с KTalk выключена") }
        if directCallReady { return localised("Call detected — direct audio will be checked when recording starts", "Звонок обнаружен — прямой звук будет проверен при начале записи") }
        if observations.contains(where: { $0.participation == .inCall }) {
            return localised("Call detected; recording will use microphone and system audio", "Звонок обнаружен; запись будет использовать микрофон и системный звук")
        }
        return localised("Waiting for a confirmed KTalk call", "Ожидание подтверждённого звонка KTalk")
    }

    var directCallReady: Bool { Self.directCandidate(in: observations) != nil }

    static func directCandidate(in observations: [CallObservation], now: Date = Date()) -> CallObservation? {
        let joined = observations.filter { $0.participation == .inCall }
        guard joined.count == 1, let call = joined.first, call.source == .application,
              call.call != nil, (0...5).contains(now.timeIntervalSince(call.observedAt)) else { return nil }
        return call
    }

    func audioFactory(for observation: CallObservation?) -> RecordingSession.CallAudioFactory? {
        guard accepting, let observation,
              let provider = providers.first(where: { $0.id == observation.integrationID }) as? any CallAudioIntegration else { return nil }
        let candidate = Self.directCandidate(in: observations)
        let id = candidate?.integrationID == observation.integrationID && candidate?.call?.id == observation.call?.id
            ? candidate?.call?.id : nil
        return {
            guard let id else { throw CallAudioFailure.unavailable }
            return try await provider.makeAudioCapture(for: id)
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
        providers.removeAll()
    }
}
