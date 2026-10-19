import Foundation

/// Compatibility API for existing call sites. Product analytics is disabled.
enum Analytics {
    /// Every event that exists. There is no `track(String)`.
    enum Event: String, CaseIterable, Sendable {
        case installed
        case versionSeen = "version_seen"

        case setupOpened = "setup_opened"
        case settingsOpened = "settings_opened"
        case setupCompleted = "setup_completed"
        case micGranted = "mic_granted"
        case micDenied = "mic_denied"
        case systemAudioHeard = "system_audio_heard"
        case systemAudioSilent = "system_audio_silent"

        case recordingStarted = "recording_started"
        case recordingStartFailed = "recording_start_failed"
        case recordingFinished = "recording_finished"
        case recordingDiscarded = "recording_discarded"
        case transcriptFinished = "transcript_finished"
        case transcriptFallback = "transcript_fallback"
        case summaryFinished = "summary_finished"
        case summaryBackendFailed = "summary_backend_failed"
        case speakerNamesFinished = "speaker_names_finished"
        case speakerNamesFailed = "speaker_names_failed"

        case modelDownloadStarted = "model_download_started"
        case modelDownloadFinished = "model_download_finished"
        case modelDownloadFailed = "model_download_failed"
        case artifactOpened = "artifact_opened"

        case transcriptFailed = "transcript_failed"
        case summaryFailed = "summary_failed"
        case systemTrackSilent = "system_track_silent"
        case sessionInterrupted = "session_interrupted"

        case settingChanged = "setting_changed"
    }

    /// Every property key that may accompany an event.
    enum Property: String, CaseIterable, Sendable {
        /// `manual`, `mic-activity`, `calendar` — from `RecordingSession.Trigger`.
        case trigger
        /// `app` or `cli`.
        case surface
        /// Coarse on purpose: an exact length is a fingerprint, and no
        /// question anybody asked needs one.
        case durationBucket = "duration_bucket"
        case liveUsed = "live_used"
        case systemAudio = "system_audio"
        case engine
        case backend
        case model
        case fallbackUsed = "fallback_used"
        case fromEngine = "from_engine"
        case toEngine = "to_engine"
        case component
        case outcome
        case asset
        case artifact
        /// Always from `Reason`, never an error string. Error text carries
        /// paths, host names and occasionally an API key, and there is no
        /// sanitising of it that stays true as the code changes.
        case reason
        case setupVersion = "setup_version"
        /// For `setting_changed` only, and only ever a key from
        /// `AnalyticsCatalogue.reportableSettings`.
        case key
        case value
    }

    /// Why something failed, as a closed set.
    enum Reason: String, Sendable, Equatable {
        case noNetwork = "no_network"
        case noKey = "no_key"
        case noModel = "no_model"
        case usageLimit = "usage_limit"
        case audioMissing = "audio_missing"
        case audioTooShort = "audio_too_short"
        case refused
        case timedOut = "timed_out"
        case httpError = "http_error"
        case quit
        case unknown
    }

    /// Collapse local failures before analytics sees them. The session log
    /// keeps the original error for diagnosis; the wire gets only this closed
    /// vocabulary, so URLs, paths, account details and keys cannot hitch a
    /// ride inside somebody else's error description.
    static func reason(for error: Error) -> Reason {
        if LLMError.isUsageLimit(error) { return .usageLimit }
        if error is CancellationError { return .quit }
        if let url = error as? URLError {
            if url.code == .timedOut { return .timedOut }
            if [
                URLError.notConnectedToInternet, .networkConnectionLost,
                .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
            ].contains(url.code) { return .noNetwork }
            return .unknown
        }
        if error is OpenAICompatible.EndpointError { return .refused }
        if let llm = error as? LLMError {
            switch llm {
            case .http(let code, _): return code >= 500 ? .httpError : .refused
            case .exit where llm.isTransient: return .noNetwork
            case .emptyResponse, .malformedResponse, .exit: return .unknown
            }
        }
        return .unknown
    }

    enum Value: Sendable, Equatable {
        case text(String)
        case number(Double)
        case flag(Bool)

        var json: Any {
            switch self {
            case .text(let string): return string
            case .number(let double): return double
            case .flag(let bool): return bool
            }
        }
    }

    /// Where an exact duration turns into something that describes a lot of
    /// meetings rather than one.
    static func durationBucket(seconds: Double) -> Value {
        switch seconds {
        case ..<300: return .text("under_5m")
        case ..<900: return .text("5_15m")
        case ..<1800: return .text("15_30m")
        case ..<3600: return .text("30_60m")
        case ..<7200: return .text("1_2h")
        default: return .text("over_2h")
        }
    }

    static func start(surface: Surface) {}

    enum Surface: String, Sendable {
        case app
        case cli
    }

    enum Outcome: String, Sendable {
        case deferred
        case gaveUp = "gave_up"
    }

    enum Artifact: String, Sendable {
        case recordingsWindow = "recordings_window"
        case recordingsRoot = "recordings_root"
        case sessionFolder = "session_folder"
    }

    static func track(_ event: Event, _ properties: [Property: Value] = [:]) {
        // Intentionally no collection or transport.
    }

    static func settingChanged(path: [String], value: Any?) {}

    /// The decision on its own, so that "a path can never travel" is a thing
    /// a test can assert rather than a thing a reviewer has to notice.
    ///
    /// Nil means the change is not reportable, which is the answer for every
    /// free-text setting, every number, every list, the analytics switch
    /// itself, and any value that does not match the kind the schema declares.
    static func reportableChange(path: [String], value: Any?) -> (key: String, value: Value)? {
        let key = path.joined(separator: ".")
        guard let kind = AnalyticsCatalogue.reportableSettings[key] else { return nil }
        switch (kind, value) {
        case (_, .none):
            // Cleared, which in this config file means "back to the default"
            // rather than "unset" — see `SettingsSchema.resolve`.
            return (key, .text("default"))
        case (.toggle, .some(let raw)):
            guard let flag = raw as? Bool else { return nil }
            return (key, .flag(flag))
        case (.choice(let allowed), .some(let raw)):
            guard let string = raw as? String, allowed.contains(string) else { return nil }
            return (key, .text(string))
        }
    }

    static func flushOnExit() {}

    static var isEnabled: Bool { false }
}
