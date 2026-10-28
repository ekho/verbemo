import Foundation

/// Immutable request inputs supplied by the application. No Config reads or processing actions.
enum MCPLibrary {
    struct Runtime: Sendable {
        let root: URL
        let port: Int
        let recording: [String: String]
        let processing: [String: [String: String]]
        let pendingDeletion: @Sendable (String) -> Bool
        let cancelled: @Sendable () -> Bool
        let deadline: Date
        init(root: URL, port: Int = 52763, recording: [String: String] = [:], processing: [String: [String: String]] = [:],
             pendingDeletion: @escaping @Sendable (String) -> Bool = { _ in false },
             cancelled: @escaping @Sendable () -> Bool = { false }, deadline: Date = Date().addingTimeInterval(30)) {
            self.root = root.isFileURL ? MCPContract.normalizedRoot(root) : root; self.port = port; self.recording = recording; self.processing = processing
            self.pendingDeletion = pendingDeletion; self.cancelled = cancelled; self.deadline = deadline
        }
        func check() throws {
            guard !cancelled(), Date() < deadline else { throw MCPFailure(.serverStopping) }
        }
    }
    typealias TranscriptDocument = MCPTextArtifacts.Transcript
    struct Version {
        let id: String?
        let current: Bool
        let transcript: TranscriptDocument?
        let transcriptError: MCPFailure.Code?
        let names: MCPTextArtifacts.Names?
        let namesSource: MCPFiles.AudioHandle?
        let namesError: MCPFailure.Code?
        let summary: MCPTextArtifacts.Summary?
        let summaryError: MCPFailure.Code?
        let meta: [String: MCPJSON]
        let revision: String
        var stale: Bool { meta["summary_stale"]?.bool ?? false }
        var hasTranscript: MCPJSON { transcriptError != nil ? .null : .bool(transcript != nil) }
        var hasSummary: MCPJSON { summaryError != nil ? .null : .bool(summary != nil) }
        func savedNames(for labels: Set<String>, check: @escaping () throws -> Void) throws -> [String: SpeakerNames.Entry] {
            if let namesSource { return try MCPTextArtifacts.names(file: namesSource, labels: labels, check: check).names.speakers }
            return names?.speakers.filter { labels.contains($0.key) } ?? [:]
        }
        func assignment(participants: [CalendarParticipant]) -> (state: String, linked: Int?, unlinked: Int?, unknown: Int?) {
            guard let transcript, let allLabels = transcript.labels, transcript.segmentCount > 0, namesError == nil else { return ("unknown", nil, nil, nil) }
            let mixed = !allLabels.isDisjoint(with: ["them", "speaker"])
            guard !mixed else { return ("unknown", nil, nil, nil) }
            let ids = Set(participants.map(\.id))
            let unknown = transcript.unknownSegments
            let labels = allLabels.filter { !SpeakerNames.isUnknown($0) }
            let linked = labels.filter { label in names?.speakers[label]?.participantID.map { ids.contains($0) } == true }.count
            let unlinked = labels.count - linked
            return (unknown == 0 && unlinked == 0 ? "complete" : "incomplete", linked, unlinked, unknown)
        }
    }
    struct Audio {
        let id: String
        let roles: [String]
        let filename: String
        let offsets: [String: MCPJSON]
        let stamp: MCPFiles.Stamp
        let handle: MCPFiles.AudioHandle?
        var mime: String { filename.hasSuffix(".caf") ? "audio/x-caf" : "audio/mp4" }
    }
    struct Meeting {
        let id: String
        let relative: String
        let meta: [String: MCPJSON]
        let participantSource: MCPFiles.AudioHandle?
        let metadataRevision: String
        let versions: [Version]
        let audio: [Audio]
        let audioError: MCPFailure.Code?
        let recordingState: String?
        let processing: [String: String]
        let revision: String
        let warnings: [MCPJSON]
        var current: Version { versions.first { $0.current }! }
        var calendar: MeetingCalendarMetadata? {
            guard let value = meta["calendar"], let bytes = try? value.encoded(),
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
            return MeetingCalendarMetadata(object)
        }
        var participants: [CalendarParticipant] { calendar?.participants ?? [] }
        var started: String? {
            // Import metadata records import time, not the media's original capture time.
            guard meta["trigger"]?.string != "import", let value = meta["started"]?.string, MCPContract.date(value) != nil else { return nil }
            return value
        }
        func existingParticipants(_ ids: Set<String>, check: @escaping () throws -> Void) throws -> Set<String> {
            if let participantSource { return try MCPTextArtifacts.participantIDs(file: participantSource, requested: ids, check: check) }
            return Set(participants.map(\.id)).intersection(ids)
        }
        var assignment: (state: String, linked: Int?, unlinked: Int?, unknown: Int?) { current.assignment(participants: participants) }
        var hasAudio: MCPJSON { audioError != nil ? .null : .bool(!audio.isEmpty) }
        var card: MCPJSON {
            .object(["meeting_id": .string(id), "title": .optional(meta["title"]?.string ?? meta["calendar"]?["title"]?.string),
                     "started_at": .optional(started), "duration_seconds": meta["duration_seconds"] ?? .null,
                     "source": .optional(meta["trigger"]?.string), "recording_state": .optional(recordingState),
                     "participants": .array(participants.map(Self.person)), "has_transcript": current.hasTranscript,
                     "has_summary": current.hasSummary, "summary_stale": .bool(current.stale), "has_audio": hasAudio,
                     "participant_assignment": .string(assignment.state), "processing": .object(processing.mapValues(MCPJSON.string))])
        }
        static func person(_ person: CalendarParticipant) -> MCPJSON {
            .object(["participant_id": .string(person.id), "name": .string(person.name), "email": .optional(person.email), "organizer": person.organizer.map(MCPJSON.bool) ?? .null])
        }
    }
    /// List/search retain compact projections, not every transcript and summary in the library.
    struct ListingMeeting {
        let id: String
        let relative: String
        let card: MCPJSON
        let startedDate: Date?
        let participants: [CalendarParticipant]
        let speakingIDs: Set<String>
        let revision: String
        var started: String? { card["started_at"]?.string }
        init(_ meeting: Meeting) {
            id = meeting.id; relative = meeting.relative; card = meeting.card; startedDate = meeting.started.flatMap(MCPContract.date)
            participants = meeting.participants; revision = meeting.revision
            speakingIDs = Set(meeting.current.transcript?.labels?.compactMap { SpeakerNames.isUnknown($0) ? nil : meeting.current.names?.speakers[$0]?.participantID } ?? [])
        }
    }
    struct Snapshot {
        let meetings: [ListingMeeting]
        let warnings: [MCPJSON]
        let revision: String
    }
    static func materials(for listing: ListingMeeting, runtime: Runtime) throws -> Meeting {
        try runtime.check()
        guard !runtime.pendingDeletion(listing.relative) else { throw MCPFailure(.contentChanged) }
        let root = try MCPFiles.Directory.root(runtime.root)
        let value = try readMeeting(root: root, directory: root.directory(listing.relative), relative: listing.relative, runtime: runtime, includeArchives: false)
        guard value.id == listing.id, value.revision == listing.revision else { throw MCPFailure(.contentChanged) }
        return value
    }
    static func warning(_ code: MCPFailure.Code, _ meetingID: String, artifact: String? = nil) -> MCPJSON {
        var fields: [String: MCPJSON] = ["code": .string(code.rawValue), "meeting_id": .string(meetingID)]
        if let artifact { fields["artifact"] = .string(artifact) }
        return .object(fields)
    }
    static func scan(_ runtime: Runtime) throws -> Snapshot {
        try runtime.check()
        let root = try MCPFiles.Directory.root(runtime.root)
        let before = try root.stamp()
        let names = try root.entries(check: runtime.check).filter { !$0.hasPrefix(".") }
        var meetings: [ListingMeeting] = [], warnings: [MCPJSON] = []
        for name in names {
            try runtime.check()
            if runtime.pendingDeletion(name) { continue }
            let id = MCPContract.meetingID(root: runtime.root, relative: name)
            do {
                guard try root.entryStamp(name)?.isDirectory == true else { continue }
                let directory = try root.directory(name)
                if try directory.entryStamp("meta.json") == nil, try directory.entryStamp(".recording.json") == nil, runtime.recording[name] == nil { continue }
                let meeting = try readMeeting(root: root, directory: directory, relative: name, runtime: runtime, retainedVersion: "", includeArchives: false)
                if !runtime.pendingDeletion(name) { meetings.append(ListingMeeting(meeting)); warnings += meeting.warnings }
            } catch let error as MCPFailure {
                if error.code == .serverStopping { throw error }
                warnings.append(warning(error.code, id))
            } catch { warnings.append(warning(.dataUnreadable, id)) }
        }
        guard try before == root.stamp(), sameIdentity(try MCPFiles.Directory.root(runtime.root).stamp(), before) else { throw MCPFailure(.contentChanged) }
        let revisions = meetings.sorted { $0.id < $1.id }.map { $0.id + ":" + $0.revision }
        return Snapshot(meetings: meetings, warnings: warnings, revision: MCPContract.hash(MCPContract.framed([before.revision] + revisions + [MCPContract.hash(try MCPJSON.array(warnings).encoded())])))
    }
    static func meeting(_ id: String, runtime: Runtime, pinAudio: Bool = false, retainedVersion: String = "current", includeArchives: Bool = true, transcriptOnly: Bool = false, calendarDetails: Bool = false) throws -> Meeting {
        guard id.hasPrefix("m_"), id.count == 66, id.dropFirst(2).allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw MCPFailure(.meetingNotFound) }
        try runtime.check()
        let root = try MCPFiles.Directory.root(runtime.root)
        for name in try root.entries(check: runtime.check) where !name.hasPrefix(".") && MCPContract.meetingID(root: runtime.root, relative: name) == id {
            guard !runtime.pendingDeletion(name) else { throw MCPFailure(.meetingNotFound) }
            let value = try readMeeting(root: root, directory: root.directory(name), relative: name, runtime: runtime, pinAudio: pinAudio, retainedVersion: retainedVersion, includeArchives: includeArchives, transcriptOnly: transcriptOnly, calendarDetails: calendarDetails)
            guard !runtime.pendingDeletion(name) else { throw MCPFailure(.meetingNotFound) }
            return value
        }
        throw MCPFailure(.meetingNotFound)
    }
    private static func sameIdentity(_ left: MCPFiles.Stamp, _ right: MCPFiles.Stamp) -> Bool { left.device == right.device && left.inode == right.inode }
    private static func readMeeting(root: MCPFiles.Directory, directory: MCPFiles.Directory, relative: String, runtime: Runtime, pinAudio: Bool = false, retainedVersion: String = "current", includeArchives: Bool = true, transcriptOnly: Bool = false, calendarDetails: Bool = false) throws -> Meeting {
        for attempt in 0..<3 {
            do {
                return try SessionLock.withReadLock(descriptor: directory.fd, deadline: min(runtime.deadline, Date().addingTimeInterval(0.25)), check: runtime.check) {
                    try runtime.check()
                    let before = try directory.stamp()
                    guard try directory.entryStamp(".transcript-commit") == nil else { throw MCPFailure(.artifactNotReady) }
                    let read = Read(directory: directory, check: runtime.check, scope: transcriptOnly ? .transcript : calendarDetails ? .meeting : .inventory)
                    let marker = try read.bytes(".recording.json")
                    let metaBytes = try read.bytes("meta.json") ?? marker
                    guard let metaBytes else { throw MCPFailure(.dataUnreadable) }
                    let meta = try Read.metadata(metaBytes)
                    let recording = runtime.recording[relative].flatMap { ["recording", "paused"].contains($0) ? $0 : nil }
                    var versions = [try read.version(current: true, fallbackMeta: meta, retainedVersion: retainedVersion)]
                    var warnings: [MCPJSON] = []
                    let id = MCPContract.meetingID(root: runtime.root, relative: relative)
                    if includeArchives, try directory.entryStamp("transcripts") != nil {
                        let archives = try directory.directory("transcripts")
                        let archiveBefore = try archives.stamp()
                        for name in try archives.entries(check: runtime.check) where !name.hasPrefix(".") {
                            try runtime.check()
                            do {
                                let folder = try archives.directory(name)
                                let archiveRead = Read(directory: folder, check: runtime.check, scope: transcriptOnly ? .transcript : .inventory)
                                let version = try archiveRead.version(current: false, fallbackMeta: meta, retainedVersion: retainedVersion)
                                try archiveRead.validate()
                                guard version.transcript != nil else { throw MCPFailure(version.transcriptError ?? .dataUnreadable) }
                                guard let stamp = try archives.entryStamp(name), try sameIdentity(folder.stamp(), stamp) else { throw MCPFailure(.contentChanged) }
                                if !versions.contains(where: { $0.id == version.id }) { versions.append(version) }
                            } catch let error as MCPFailure {
                                if [.serverStopping, .contentChanged].contains(error.code) { throw error }
                                warnings.append(warning(error.code, id, artifact: "archive"))
                            }
                        }
                        guard try archives.stamp() == archiveBefore else { throw MCPFailure(.contentChanged) }
                    }
                    var audio: [Audio] = [], audioError: MCPFailure.Code?
                    let activeStages = runtime.processing[relative] ?? [:]
                    let audioBusy = marker != nil || recording != nil || activeStages["audio"] == "running"
                    if audioBusy { audioError = .artifactNotReady }
                    else {
                        do { audio = try read.audio(meetingID: id, meta: meta, pin: pinAudio) }
                        catch let error as MCPFailure { audioError = error.code }
                    }
                    for version in versions {
                        if version.transcript?.speakerMetadataTooLarge == true { warnings.append(warning(.responseTooLarge, id, artifact: "speakers")) }
                        for (role, error) in [("transcript", version.transcriptError), ("speakers", version.namesError), ("summary", version.summaryError)] {
                            if let error { warnings.append(warning(error, id, artifact: role)) }
                        }
                    }
                    if let audioError { warnings.append(warning(audioError, id, artifact: "audio")) }
                    try read.validate()
                    guard try directory.stamp() == before, try root.entryStamp(relative) == before,
                          sameIdentity(try MCPFiles.Directory.root(runtime.root).stamp(), try root.stamp()) else { throw MCPFailure(.contentChanged) }
                    guard !runtime.pendingDeletion(relative) else { throw MCPFailure(.meetingNotFound) }
                    let processing = processing(meta: meta, current: versions[0], supplied: activeStages)
                    let revision = MCPContract.hash(MCPContract.framed([before.revision, read.revision] + versions.map(\.revision) + audio.map(\.id) + [try String(decoding: MCPJSON.object(processing.mapValues(MCPJSON.string)).encoded(), as: UTF8.self), recording ?? ""]))
                    return Meeting(id: id, relative: relative, meta: meta, participantSource: read.metadataSource, metadataRevision: read.hashes["meta.json"] ?? read.hashes[".recording.json"] ?? "absent", versions: versions, audio: audio, audioError: audioError,
                                   recordingState: recording, processing: processing, revision: revision, warnings: warnings)
                }
            } catch let error as MCPFailure where error.code == .contentChanged && attempt < 2 { continue }
        }
        throw MCPFailure(.contentChanged)
    }
    private static func processing(meta: [String: MCPJSON], current: Version, supplied: [String: String]) -> [String: String] {
        var result = Dictionary(uniqueKeysWithValues: MCPContract.stages.map { ($0, "unknown") })
        func status(_ value: String?) -> String? {
            guard let value else { return nil }
            if value == "failed" || value.hasPrefix("failed:") { return "failed" }
            return ["pending", "deferred", "off", "done", "cancelled"].contains(value) ? value : nil
        }
        result["transcription"] = (meta["transcription_failed"]?.string != nil || meta["transcription_failed"]?.bool == true) ? "failed" : meta["transcription_deferred"]?.bool == true ? "deferred" : current.transcript != nil ? "done" : "unknown"
        result["summary"] = status(meta["summary_status"]?.string)
            ?? (current.summary != nil && !current.stale ? "done" : "unknown")
        result["speaker_naming"] = status(meta["speakers_status"]?.string) ?? (current.names != nil ? "done" : "unknown")
        let diarization = meta["diarization"]?["status"]?.string
        result["diarization"] = ["completed": "done", "skipped": "off", "not_applicable": "off"][diarization ?? ""] ?? status(diarization) ?? "unknown"
        for stage in MCPContract.stages {
            if let value = supplied[stage], MCPContract.states.contains(value) { result[stage] = value }
        }
        return result
    }
    private final class Read {
        let directory: MCPFiles.Directory
        let check: () throws -> Void
        let scope: MCPTextArtifacts.Scope
        var metadataSource: MCPFiles.AudioHandle?
        var stamps: [String: MCPFiles.Stamp?] = [:]
        var hashes: [String: String] = [:]
        init(directory: MCPFiles.Directory, check: @escaping () throws -> Void, scope: MCPTextArtifacts.Scope) { self.directory = directory; self.check = check; self.scope = scope }
        func bytes(_ name: String) throws -> Data? {
            guard let file = try opened(name) else { return nil }
            let document = try MCPTextArtifacts.document(file: file, role: name, scope: scope, check: check)
            guard try directory.entryStamp(name) == file.stamp else { throw MCPFailure(.contentChanged) }
            hashes[name] = document.hash
            if scope == .transcript && ["meta.json", ".recording.json"].contains(name) { metadataSource = file }
            return document.data
        }
        func opened(_ name: String) throws -> MCPFiles.AudioHandle? {
            let before = try directory.entryStamp(name)
            let file = try directory.file(name)
            guard before == file?.stamp else { throw MCPFailure(.contentChanged) }
            stamps.updateValue(before, forKey: name)
            if file == nil { hashes[name] = "absent" }
            return file
        }
        func validate() throws {
            for (name, stamp) in stamps { guard try directory.entryStamp(name) == stamp else { throw MCPFailure(.contentChanged) } }
            try check()
        }
        var revision: String { MCPContract.hash(MCPContract.framed(hashes.keys.sorted().flatMap { [$0, hashes[$0]!] })) }
        static func metadata(_ data: Data) throws -> [String: MCPJSON] {
            guard let meta = try MCPJSON.parse(data).object else { throw MCPFailure(.dataUnreadable) }
            for key in ["title", "trigger", "started", "ended", "summary_status", "speakers_status"] {
                if let value = meta[key], value != .null, value.string == nil { throw MCPFailure(.dataUnreadable) }
            }
            for key in ["summary_stale", "transcription_deferred"] {
                if let value = meta[key], value.bool == nil { throw MCPFailure(.dataUnreadable) }
            }
            if let failure = meta["transcription_failed"], failure.string == nil && failure.bool == nil { throw MCPFailure(.dataUnreadable) }
            if let duration = meta["duration_seconds"], duration != .null {
                guard let number = duration.number, number >= 0 else { throw MCPFailure(.dataUnreadable) }
            }
            for key in ["files", "start_offset_ms", "diarization", "calendar"] {
                if let value = meta[key], value != .null, value.object == nil { throw MCPFailure(.dataUnreadable) }
            }
            if let calendar = meta["calendar"]?.object {
                for key in ["title", "event_id", "association", "calendar_title", "agenda", "scheduled_start", "scheduled_end", "time_zone"] {
                    if let value = calendar[key], value != .null, value.string == nil { throw MCPFailure(.dataUnreadable) }
                }
                if let participants = calendar["participants"] {
                    guard (try? JSONDecoder().decode([CalendarParticipant].self, from: participants.encoded())) != nil else { throw MCPFailure(.dataUnreadable) }
                } else if let attendees = calendar["attendees"] {
                    guard let list = attendees.array, list.allSatisfy({ $0.string != nil }) else { throw MCPFailure(.dataUnreadable) }
                }
            }
            return meta
        }
        func version(current: Bool, fallbackMeta: [String: MCPJSON], retainedVersion: String) throws -> Version {
            var meta = current ? fallbackMeta : [:]
            if !current, let data = try bytes("meta.json") {
                meta = try Self.metadata(data)
            }
            var transcript: TranscriptDocument?, transcriptError: MCPFailure.Code?, id: String?
            do {
                if let file = try opened("transcript.json") {
                    transcript = try MCPTextArtifacts.Transcript(file: file, collectLabels: scope != .transcript, check: check)
                    hashes["transcript.json"] = transcript!.rawHash
                    id = try transcript?.versionID(timeline: bytes("diarization.json"))
                }
            } catch let error as MCPFailure {
                if [.serverStopping, .contentChanged].contains(error.code) { throw error }
                transcript = nil; transcriptError = error.code
            }
            var names: MCPTextArtifacts.Names?, namesSource: MCPFiles.AudioHandle?, namesError: MCPFailure.Code?
            do {
                if scope == .transcript {
                    namesSource = try opened("speakers.json")
                    if let namesSource { hashes["speakers.json"] = try MCPTextArtifacts.names(file: namesSource, labels: [], check: check).hash }
                } else if let file = try opened("speakers.json") {
                    let saved = try MCPTextArtifacts.names(file: file, labels: transcript?.labels ?? [], scope: scope, check: check)
                    names = saved.names; hashes["speakers.json"] = saved.hash
                }
            } catch let error as MCPFailure {
                if [.serverStopping, .contentChanged].contains(error.code) { throw error }
                namesError = error.code
            }
            var summary: MCPTextArtifacts.Summary?, summaryError: MCPFailure.Code?
            do {
                if scope != .transcript, let file = try opened("summary.md") {
                    summary = try MCPTextArtifacts.Summary(file: file, check: check)
                    hashes["summary.md"] = summary!.revision
                }
            } catch let error as MCPFailure {
                if [.serverStopping, .contentChanged].contains(error.code) { throw error }
                summaryError = error.code
            }
            if !(current && retainedVersion == "current") && id != retainedVersion {
                transcript?.discardSource(); summary?.discardSource(); namesSource = nil
            }
            return Version(id: id, current: current, transcript: transcript, transcriptError: transcriptError,
                           names: names, namesSource: namesSource, namesError: namesError, summary: summary, summaryError: summaryError, meta: meta, revision: revision)
        }
        func audio(meetingID: String, meta: [String: MCPJSON], pin: Bool) throws -> [Audio] {
            let allowed = ["mic": Set(["mic.caf", "audio.m4a"]), "system": Set(["system.caf", "audio.m4a"]), "source": Set(["source.m4a"])]
            guard let files = meta["files"]?.object else {
                if meta["files"] != nil { throw MCPFailure(.dataUnreadable) }
                return []
            }
            var rolesByName: [String: [String]] = [:]
            for (role, value) in files {
                guard let names = allowed[role] else { continue }
                guard let filename = value.string, names.contains(filename) else { throw MCPFailure(.dataUnreadable) }
                rolesByName[filename, default: []].append(role)
            }
            var audio: [Audio] = []
            for filename in rolesByName.keys.sorted() {
                guard let handle = try directory.file(filename) else { continue }
                stamps.updateValue(handle.stamp, forKey: filename)
                let roles = rolesByName[filename]!.sorted()
                var offsets: [String: MCPJSON] = [:]
                for role in roles {
                    if let value = meta["start_offset_ms"]?[role] {
                        guard let offset = try? MCPArguments(values: ["offset": value]).integer("offset", range: Int.min...Int.max) else { throw MCPFailure(.dataUnreadable) }
                        offsets[role] = .int(max(0, offset))
                    } else { offsets[role] = .number(0) }
                }
                let id = "a_" + MCPContract.hash(MCPContract.framed([meetingID, roles.joined(separator: ","), filename, handle.stamp.revision]))
                audio.append(Audio(id: id, roles: roles, filename: filename, offsets: offsets, stamp: handle.stamp, handle: pin ? handle : nil))
            }
            if let archive = audio.first(where: { $0.filename == "audio.m4a" }) { return [archive] }
            return audio
        }
    }
    static func openAudio(meetingID: String, audioID: String, runtime: Runtime) throws -> MCPFiles.AudioHandle {
        let meeting = try meeting(meetingID, runtime: runtime, pinAudio: true, includeArchives: false)
        if let error = meeting.audioError { throw MCPFailure(error) }
        guard let audio = meeting.audio.first(where: { $0.id == audioID }) else { throw MCPFailure(.artifactNotFound) }
        try runtime.check()
        guard !runtime.pendingDeletion(meeting.relative) else { throw MCPFailure(.meetingNotFound) }
        guard let handle = audio.handle else { throw MCPFailure(.artifactNotFound) }
        try handle.validate()
        return handle
    }
}
