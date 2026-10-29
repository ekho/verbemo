import Foundation

enum MCPQueries {
    static let listKeys: Set<String> = ["started_from", "started_before", "title_contains", "participants", "participant_scope", "participant_match", "has_transcript", "has_summary", "has_audio", "participant_assignment", "processing_stage", "processing_state", "sort", "limit", "cursor"]
    /// Synchronous filesystem work: transport must run this off the UI/event-loop thread.
    static func call(_ tool: String, arguments: [String: MCPJSON], runtime: MCPLibrary.Runtime, settings: MCPSettings? = nil) throws -> MCPJSON {
        try runtime.check()
        let args = MCPArguments(values: arguments)
        let result: MCPJSON
        switch tool {
        case "get_settings":
            try args.validateKeys(["keys"])
            guard let settings else { throw MCPFailure(.dataUnreadable) }
            result = try settings.project(keys: args.strings("keys"))
        case "list_meetings", "search_meetings":
            try args.validateKeys(tool == "list_meetings" ? listKeys : listKeys.union(["query", "scope"]))
            let filter = try Filter(args)
            let query: String?
            if tool == "search_meetings" {
                guard let text = try args.string("query"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPFailure(.invalidParams) }
                query = text
            } else { query = nil }
            let scope = try args.choice("scope", ["transcript", "summary", "both"], default: "both")!
            let snapshot = try MCPLibrary.scan(runtime)
            let meetings = filter.sorted(snapshot.meetings.filter(filter.matches))
            let offset = try MCPCursor.offset(arguments: arguments, operation: tool, revision: snapshot.revision)
            let limit = try args.integer("limit", default: 20, range: 1...100)!
            if let query {
                result = try search(meetings, query: query, scope: scope, offset: offset, limit: limit, arguments: arguments, snapshot: snapshot, runtime: runtime)
            } else {
                let cards = meetings.map(\.card)
                let page = try page(cards, offset: offset, limit: limit)
                result = try listing(page.items, next: page.next, arguments: arguments, tool: tool, revision: snapshot.revision, warnings: snapshot.warnings)
            }
        case "get_meeting", "list_transcript_versions", "get_meeting_transcript", "get_meeting_summary", "get_meeting_audio":
            let allowed: Set<String>
            switch tool {
            case "list_transcript_versions": allowed = ["meeting_id", "limit", "cursor"]
            case "get_meeting_transcript": allowed = ["meeting_id", "version_id", "start_ms", "end_ms", "limit", "cursor"]
            case "get_meeting_summary": allowed = ["meeting_id", "version_id", "cursor"]
            default: allowed = ["meeting_id"]
            }
            try args.validateKeys(allowed)
            guard let id = try args.string("meeting_id"), !id.isEmpty else { throw MCPFailure(.invalidParams) }
            // Validate all parameters before touching the library or resolving opaque IDs.
            let start = try args.integer("start_ms", default: 0)!
            let end = try args.integer("end_ms")
            guard end.map({ $0 > start }) ?? true else { throw MCPFailure(.invalidParams) }
            let limit = try args.integer("limit", default: tool == "get_meeting_transcript" ? 100 : 20, range: 1...(tool == "get_meeting_transcript" ? 500 : 100))!
            let selector = try args.string("version_id", default: "current")!
            let meeting = try MCPLibrary.meeting(id, runtime: runtime, retainedVersion: ["get_meeting_transcript", "get_meeting_summary"].contains(tool) ? selector : "", includeArchives: ["get_meeting", "list_transcript_versions"].contains(tool) || selector != "current", transcriptOnly: tool == "get_meeting_transcript", calendarDetails: tool == "get_meeting")
            switch tool {
            case "get_meeting": result = try details(meeting)
            case "list_transcript_versions":
                let versions = meeting.versions.filter { $0.transcript != nil }.sorted {
                    let left = $0.transcript?.createdDate ?? .distantPast
                    let right = $1.transcript?.createdDate ?? .distantPast
                    return left == right ? ($0.id ?? "") < ($1.id ?? "") : left > right
                }
                let offset = try MCPCursor.offset(arguments: arguments, operation: tool, revision: meeting.revision)
                guard offset <= versions.count else { throw MCPFailure(.invalidCursor) }
                var cards: [MCPJSON] = [], index = offset, size = 0
                while index < versions.count, cards.count < limit {
                    let card: MCPJSON
                    do { card = try versionCard(versions[index], meeting: meeting) }
                    catch let failure as MCPFailure where failure.code == .responseTooLarge && !cards.isEmpty { break }
                    let bytes = try card.encoded().count
                    if !cards.isEmpty && size + bytes > MCPContract.softTextBytes { break }
                    cards.append(card); size += bytes; index += 1
                }
                result = try listing(cards, next: index < versions.count ? index : nil, arguments: arguments, tool: tool, revision: meeting.revision, warnings: meeting.warnings)
            case "get_meeting_audio": result = try audio(meeting, runtime: runtime)
            default:
                let version: MCPLibrary.Version
                if selector == "current" { version = meeting.current }
                else if let selected = meeting.versions.first(where: { $0.id == selector }) { version = selected }
                else { throw MCPFailure(.versionNotFound) }
                if tool == "get_meeting_transcript" {
                    if let error = version.transcriptError { throw MCPFailure(error) }
                    guard let transcript = version.transcript, let versionID = version.id else { throw MCPFailure(.artifactNotFound) }
                    if let error = version.namesError { throw MCPFailure(error) }
                    let revision = MCPContract.hash(MCPContract.framed([version.revision, meeting.metadataRevision]))
                    let offset = try MCPCursor.offset(arguments: arguments, operation: tool, revision: revision, version: versionID)
                    var selected: [(Int, MCPLibrary.TranscriptDocument.Segment)] = [], position = 0, textBytes = 0, selectedBytes = 0, more = false
                    try transcript.each(check: runtime.check) { index, location in
                        guard (arguments["start_ms"] == nil || location.end_ms > start) && (end.map { location.start_ms < $0 } ?? true) else { return true }
                        defer { position += 1 }
                        if position < offset { return true }
                        let bytes = location.textBytes + (location.speaker?.utf8.count ?? 0) + 256
                        if selected.count == limit || (!selected.isEmpty && (textBytes + location.textBytes > MCPContract.softTextBytes || selectedBytes + bytes > MCPContract.hardResponseBytes)) { more = true; return false }
                        guard bytes <= MCPContract.hardResponseBytes else { throw MCPFailure(.responseTooLarge) }
                        selected.append((index, try transcript.segment(location, check: runtime.check)))
                        textBytes += location.textBytes; selectedBytes += bytes
                        return true
                    }
                    guard offset <= position else { throw MCPFailure(.invalidCursor) }
                    while true {
                        do {
                            let labels = Set(selected.compactMap { $0.1.speaker }.filter { !$0.isEmpty && !SpeakerNames.isUnknown($0) })
                            let names = try version.savedNames(for: labels, check: runtime.check)
                            let existing = try meeting.existingParticipants(Set(names.values.compactMap(\.participantID)), check: runtime.check)
                            let projected: [MCPJSON] = selected.map { index, segment in
                                let name = segment.speaker.flatMap { names[$0] }
                                let participant = name?.participantID.flatMap { existing.contains($0) ? $0 : nil }
                                return .object(["segment_index": .int(index), "start_ms": .int(segment.start_ms),
                                                "end_ms": .int(segment.end_ms), "speaker_id": .optional(segment.speaker),
                                                "speaker_name": .optional(name?.name), "participant_id": .optional(participant), "text": .string(segment.text)])
                            }
                            result = try MCPContract.checkSize(.object(["meeting_id": .string(id), "version_id": .string(versionID), "revision": .string(revision),
                                                                      "language": .null, "engine": .string(transcript.engine), "model": .string(transcript.model),
                                                                      "segments": .array(projected), "next_cursor": try MCPCursor.next(more ? offset + projected.count : nil, arguments: arguments, operation: tool, revision: revision, version: versionID)]))
                            break
                        } catch let failure as MCPFailure where failure.code == .responseTooLarge && selected.count > 1 {
                            selected.removeLast(max(1, selected.count / 2)); more = true
                        }
                    }
                } else {
                    if let error = version.summaryError { throw MCPFailure(error) }
                    guard let summary = version.summary else { throw MCPFailure(.artifactNotFound) }
                    let offset = try MCPCursor.offset(arguments: arguments, operation: tool, revision: version.revision, version: version.id)
                    let page = try summary.page(offset: offset, check: runtime.check)
                    result = .object(["meeting_id": .string(id), "version_id": .optional(version.id), "revision": .string(version.revision),
                                      "source_version_id": .null, "stale": .bool(version.stale), "markdown": .string(page.text),
                                      "next_cursor": try MCPCursor.next(page.next, arguments: arguments, operation: tool, revision: version.revision, version: version.id)])
                }
            }
        default: throw MCPFailure(.unknownTool)
        }
        try runtime.check()
        return try MCPContract.checkSize(result)
    }
    private static func page(_ values: [MCPJSON], offset: Int, limit: Int) throws -> (items: [MCPJSON], next: Int?) {
        guard offset <= values.count else { throw MCPFailure(.invalidCursor) }
        var items: [MCPJSON] = [], size = 0, index = offset
        while index < values.count, items.count < limit {
            let item = values[index]
            let bytes = try item.encoded().count
            if !items.isEmpty, size + bytes > MCPContract.softTextBytes { break }
            items.append(item); size += bytes; index += 1
        }
        return (items, index < values.count ? index : nil)
    }
    private static func listing(_ items: [MCPJSON], next: Int?, arguments: [String: MCPJSON], tool: String, revision: String, warnings: [MCPJSON]) throws -> MCPJSON {
        .object(["items": .array(items), "next_cursor": try MCPCursor.next(next, arguments: arguments, operation: tool, revision: revision), "revision": .string(revision), "partial": .bool(!warnings.isEmpty), "warnings": .array(warnings)])
    }
    private static func details(_ meeting: MCPLibrary.Meeting) throws -> MCPJSON {
        if meeting.current.transcript?.speakerMetadataTooLarge == true || meeting.current.namesError == .responseTooLarge { throw MCPFailure(.responseTooLarge) }
        var card = meeting.card.object!
        let assignment = meeting.assignment
        card["current_version_id"] = .optional(meeting.current.id)
        card["version_count"] = .int(meeting.versions.filter { $0.transcript != nil }.count)
        card["linked_speakers"] = .integer(assignment.linked)
        card["unlinked_speakers"] = .integer(assignment.unlinked)
        card["unknown_segments"] = .integer(assignment.unknown)
        card["speakers"] = .array((meeting.current.transcript?.labels ?? []).sorted().map { label in
            let name = SpeakerNames.isUnknown(label) ? nil : meeting.current.names?.speakers[label]
            let participant = name?.participantID.flatMap { id in meeting.participants.contains(where: { $0.id == id }) ? id : nil }
            return .object(["speaker_id": .string(label), "speaker_name": .optional(name?.name), "participant_id": .optional(participant)])
        })
        if let calendar = meeting.calendar {
            card["calendar"] = .object(["event_id": .optional(calendar.eventID), "association": .optional(calendar.association),
                                       "title": .optional(meeting.meta["calendar"]?["title"]?.string), "calendar_title": .optional(calendar.calendarTitle), "agenda": .optional(calendar.agenda),
                                       "scheduled_start": .optional(calendar.start.flatMap { MCPContract.date($0) != nil ? $0 : nil }), "scheduled_end": .optional(calendar.end.flatMap { MCPContract.date($0) != nil ? $0 : nil }), "time_zone": .optional(calendar.timeZoneIdentifier)])
        } else { card["calendar"] = .null }
        card["partial"] = .bool(!meeting.warnings.isEmpty)
        card["warnings"] = .array(meeting.warnings)
        return .object(card)
    }
    private static func versionCard(_ version: MCPLibrary.Version, meeting: MCPLibrary.Meeting) throws -> MCPJSON {
        if version.transcript?.speakerMetadataTooLarge == true { throw MCPFailure(.responseTooLarge) }
        return .object(["version_id": .optional(version.id), "created_at": .optional(version.transcript?.created_at),
                 "engine": .optional(version.transcript?.engine), "model": .optional(version.transcript?.model), "is_current": .bool(version.current),
                 "has_summary": version.hasSummary, "summary_stale": .bool(version.stale), "participant_assignment": .string(version.assignment(participants: meeting.participants).state),
                 "speakers": .array((version.transcript?.labels ?? []).sorted().map(MCPJSON.string))])
    }
    private static func audio(_ meeting: MCPLibrary.Meeting, runtime: MCPLibrary.Runtime) throws -> MCPJSON {
        if let error = meeting.audioError { throw MCPFailure(error) }
        guard !meeting.audio.isEmpty else { throw MCPFailure(.artifactNotFound) }
        guard (1024...65535).contains(runtime.port) else { throw MCPFailure(.invalidParams) }
        var links: [MCPJSON] = []
        let items: [MCPJSON] = meeting.audio.map { audio in
            let uri = "http://127.0.0.1:\(runtime.port)/audio/\(meeting.id)/\(audio.id)"
            links.append(.object(["type": .string("resource_link"), "uri": .string(uri), "name": .string(audio.filename), "mimeType": .string(audio.mime), "size": .int(Int(audio.stamp.size))]))
            return .object(["audio_id": .string(audio.id), "role": .string(audio.roles.joined(separator: "+")), "roles": .array(audio.roles.map(MCPJSON.string)),
                            "filename": .string(audio.filename), "mime_type": .string(audio.mime), "size_bytes": .int(Int(audio.stamp.size)),
                            "duration_ms": .null, "start_offset_ms": audio.offsets[audio.roles[0]] ?? .number(0), "role_offsets_ms": .object(audio.offsets),
                            "preferred": .bool(audio.filename == "audio.m4a"), "download_uri": .string(uri)])
        }
        return .object(["meeting_id": .string(meeting.id), "items": .array(items), "resources": .array(links)])
    }
    private static func search(_ meetings: [MCPLibrary.ListingMeeting], query: String, scope: String, offset: Int, limit: Int,
                               arguments: [String: MCPJSON], snapshot: MCPLibrary.Snapshot, runtime: MCPLibrary.Runtime) throws -> MCPJSON {
        var position = 0, items: [MCPJSON] = [], textBytes = 0, more = false
        func match(_ snippet: String, at matchOffset: Int, base: [String: MCPJSON]) throws -> Bool {
            try runtime.check()
            defer { position += 1 }
            if position < offset { return true }
            if items.count == limit || (!items.isEmpty && textBytes + snippet.utf8.count > MCPContract.softTextBytes) { more = true; return false }
            var item = base
            item["snippet"] = .string(snippet); item["match_offset"] = .int(matchOffset)
            items.append(.object(item)); textBytes += snippet.utf8.count
            return true
        }
        outer: for listing in meetings {
            try runtime.check()
            let meeting = try MCPLibrary.materials(for: listing, runtime: runtime)
            let version = meeting.current
            if scope != "summary", let transcript = version.transcript {
                try transcript.each(check: runtime.check) { index, segment in
                    try transcript.search(segment, query: query, check: runtime.check) { snippet, position in
                        try match(snippet, at: position, base: ["meeting_id": .string(meeting.id), "version_id": .optional(version.id), "material": .string("transcript"),
                                                              "segment_index": .int(index), "start_ms": .int(segment.start_ms), "end_ms": .int(segment.end_ms)])
                    }
                }
                if more { break outer }
            }
            if scope != "transcript", let summary = version.summary {
                try summary.search(query: query, check: runtime.check) { snippet, position in
                    try match(snippet, at: position, base: ["meeting_id": .string(meeting.id), "version_id": .optional(version.id), "material": .string("summary"), "stale": .bool(version.stale), "source_version_id": .null])
                }
                if more { break }
            }
        }
        guard offset <= position else { throw MCPFailure(.invalidCursor) }
        return try listing(items, next: more ? offset + items.count : nil, arguments: arguments, tool: "search_meetings", revision: snapshot.revision, warnings: snapshot.warnings)
    }
    private struct Filter {
        let from: Date?, before: Date?, title: String?, participants: [String], participantScope: String, participantMatch: String
        let transcript: Bool?, summary: Bool?, audio: Bool?, assignment: String?, stage: String?, state: String?, sort: String
        init(_ args: MCPArguments) throws {
            func date(_ key: String) throws -> Date? {
                guard let value = try args.string(key) else { return nil }
                guard let result = MCPContract.date(value) else { throw MCPFailure(.invalidParams) }
                return result
            }
            func bool(_ key: String) throws -> Bool? {
                guard let value = args.values[key] else { return nil }
                guard let bool = value.bool else { throw MCPFailure(.invalidParams) }
                return bool
            }
            from = try date("started_from"); before = try date("started_before")
            guard from == nil || before == nil || from! < before! else { throw MCPFailure(.invalidParams) }
            title = try args.string("title_contains")
            participants = try args.strings("participants") ?? []
            guard participants.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw MCPFailure(.invalidParams) }
            participantScope = try args.choice("participant_scope", ["listed", "speaking"], default: "listed")!
            participantMatch = try args.choice("participant_match", ["any", "all"], default: "any")!
            transcript = try bool("has_transcript"); summary = try bool("has_summary"); audio = try bool("has_audio")
            assignment = try args.choice("participant_assignment", ["complete", "incomplete", "unknown"])
            stage = try args.choice("processing_stage", MCPContract.stages)
            state = try args.choice("processing_state", MCPContract.states)
            guard (stage == nil) == (state == nil) else { throw MCPFailure(.invalidParams) }
            sort = try args.choice("sort", ["started_desc", "started_asc"], default: "started_desc")!
            _ = try args.integer("limit", default: 20, range: 1...100)
        }
        func matches(_ meeting: MCPLibrary.ListingMeeting) -> Bool {
            if from != nil || before != nil {
                guard let started = meeting.startedDate, from.map({ started >= $0 }) ?? true, before.map({ started < $0 }) ?? true else { return false }
            }
            if let title, !(meeting.card["title"]?.string ?? "").localizedCaseInsensitiveContains(title) { return false }
            for (filter, actual) in [(transcript, meeting.card["has_transcript"] ?? .null), (summary, meeting.card["has_summary"] ?? .null), (audio, meeting.card["has_audio"] ?? .null)] {
                if let filter, actual != .bool(filter) { return false }
            }
            if let assignment, meeting.card["participant_assignment"]?.string != assignment { return false }
            if let stage, let state, meeting.card["processing"]?[stage]?.string != state { return false }
            if !participants.isEmpty {
                let linked = meeting.speakingIDs
                let roster = meeting.participants.filter { participantScope == "listed" || linked.contains($0.id) }
                func match(_ query: String) -> Bool {
                    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return roster.contains { person in
                        normalized.contains("@") ? person.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized : person.name.localizedCaseInsensitiveContains(query)
                    }
                }
                if participantMatch == "all" ? !participants.allSatisfy(match) : !participants.contains(where: match) { return false }
            }
            return true
        }
        func sorted(_ meetings: [MCPLibrary.ListingMeeting]) -> [MCPLibrary.ListingMeeting] {
            meetings.sorted {
                let left = $0.startedDate, right = $1.startedDate
                if left == right { return $0.id < $1.id }
                guard let left else { return false }
                guard let right else { return true }
                return sort == "started_desc" ? left > right : left < right
            }
        }
    }
}
