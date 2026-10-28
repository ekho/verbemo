import Foundation
import CryptoKit
import Darwin

/// Descriptor-backed readers for the two pageable artifacts. No whole-document text allocation.
enum MCPTextArtifacts {
    struct UTF8Decoder {
        private var pending = Data()
        mutating func append(_ data: Data) throws -> String {
            var bytes = pending; bytes.append(data)
            var end = bytes.count
            if let last = bytes.last, last >= 0x80 {
                var lead = bytes.count - 1
                while lead > 0, bytes[lead] & 0xc0 == 0x80 { lead -= 1 }
                let byte = bytes[lead]
                let width = byte < 0xe0 ? 2 : byte < 0xf0 ? 3 : 4
                if bytes.count - lead < width { end = lead }
            }
            guard let text = String(data: bytes.prefix(end), encoding: .utf8) else { throw MCPFailure(.dataUnreadable) }
            pending = Data(bytes.suffix(from: end))
            guard pending.count <= 3 else { throw MCPFailure(.dataUnreadable) }
            return text
        }
        func finish() throws { guard pending.isEmpty else { throw MCPFailure(.dataUnreadable) } }
    }
    final class Summary {
        private var retainedFile: MCPFiles.AudioHandle?
        let revision: String
        init(file: MCPFiles.AudioHandle, check: () throws -> Void) throws {
            self.retainedFile = file
            var hash = SHA256(), utf8 = UTF8Decoder(), offset: Int64 = 0
            while offset < file.size {
                try check()
                let data = try file.read(offset: offset, count: Int(min(65536, file.size - offset)))
                guard !data.isEmpty else { throw MCPFailure(.contentChanged) }
                hash.update(data: data); _ = try utf8.append(data); offset += Int64(data.count)
            }
            try utf8.finish(); try file.validate()
            revision = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func discardSource() { retainedFile = nil }
        private func source() throws -> MCPFiles.AudioHandle {
            guard let retainedFile else { throw MCPFailure(.artifactNotReady) }; return retainedFile
        }
        func page(offset: Int, check: () throws -> Void) throws -> (text: String, next: Int?) {
            let file = try source()
            try check()
            guard offset >= 0, Int64(offset) <= file.size else { throw MCPFailure(.invalidCursor) }
            let bytes = try file.read(offset: Int64(offset), count: Int(min(65536, file.size - Int64(offset))))
            if let first = bytes.first, first & 0xc0 == 0x80 { throw MCPFailure(.invalidCursor) }
            var utf8 = UTF8Decoder()
            let text = try utf8.append(bytes)
            if Int64(offset + bytes.count) == file.size { try utf8.finish() }
            let end = offset + text.utf8.count
            try file.validate()
            return (text, Int64(end) < file.size ? end : nil)
        }
        func search(query: String, check: () throws -> Void, emit: (String, Int) throws -> Bool) throws {
            let file = try source()
            var matcher = Matcher(query: query), decoder = UTF8Decoder(), offset: Int64 = 0
            while offset < file.size {
                try check()
                let data = try file.read(offset: offset, count: Int(min(65536, file.size - offset)))
                guard !data.isEmpty else { throw MCPFailure(.contentChanged) }
                offset += Int64(data.count)
                if try !matcher.append(decoder.append(data), final: offset == file.size, emit: emit) { return }
            }
            try decoder.finish(); try file.validate()
        }
    }
    /// One bounded overlap window; match_offset counts UTF-8 bytes in the original material.
    struct Matcher {
        let query: String
        private var buffer = ""
        private var base = 0
        private var processed = 0
        init(query: String) { self.query = query }
        mutating func append(_ text: String, final: Bool, emit: (String, Int) throws -> Bool) throws -> Bool {
            buffer += text
            let reserve = max(4096, query.utf8.count * 4 + 1600)
            let safeBytes = final ? buffer.utf8.count : max(0, buffer.utf8.count - reserve)
            if safeBytes == 0, !final { return true }
            var start = buffer.startIndex
            while start < buffer.endIndex,
                  let range = buffer.range(of: query, options: [.caseInsensitive, .literal], range: start..<buffer.endIndex, locale: Locale(identifier: "en_US_POSIX")) {
                let offset = buffer[..<range.lowerBound].utf8.count
                if !final, offset >= safeBytes { break }
                if base + offset >= processed {
                    let begin = buffer.index(range.lowerBound, offsetBy: -120, limitedBy: buffer.startIndex) ?? buffer.startIndex
                    let end = buffer.index(begin, offsetBy: 400, limitedBy: buffer.endIndex) ?? buffer.endIndex
                    if try !emit(String(buffer[begin..<end]), base + offset) { return false }
                }
                start = range.upperBound
            }
            processed = base + safeBytes
            var drop = max(0, safeBytes - 1600)
            let utf8 = buffer.utf8
            var index = utf8.index(utf8.startIndex, offsetBy: drop)
            while drop > 0, index < utf8.endIndex, utf8[index] & 0xc0 == 0x80 { drop -= 1; index = utf8.index(before: index) }
            if let boundary = String.Index(index, within: buffer), drop > 0 {
                buffer = String(buffer[boundary...]); base += drop
            }
            return true
        }
    }
    struct Location {
        let rawStart: Int64
        let rawEnd: Int64
        let textStart: Int64
        let textBytes: Int
        let speaker: String?
        let start_ms: Int
        let end_ms: Int
    }
    final class Transcript {
        struct Segment: Decodable {
            let speaker: String?
            let start_ms: Int
            let end_ms: Int
            let text: String
        }
        private var retainedFile: MCPFiles.AudioHandle?
        let engine: String
        let model: String
        let created_at: String
        let createdDate: Date
        let rawHash: String
        let labels: Set<String>?
        let segmentCount: Int
        let unknownSegments: Int
        let speakerMetadataTooLarge: Bool
        private let arrayOffset: Int64
        private let semantic: SHA256
        init(file: MCPFiles.AudioHandle, collectLabels: Bool = true, check: @escaping () throws -> Void) throws {
            self.retainedFile = file
            let reader = Reader(file: file, check: check)
            var header: [String: String] = [:], segments: Int64?, keys: Set<String> = []
            try reader.object { candidate in
                guard let key = candidate, ["engine", "model", "created_at", "segments"].contains(key) else { try reader.skip(); return }
                guard keys.insert(key).inserted else { throw MCPFailure(.dataUnreadable) }
                if ["engine", "model", "created_at"].contains(key) { header[key] = try reader.stringValue() }
                else if key == "segments" { segments = reader.position; try reader.skip() }
                else { try reader.skip() }
            }
            try reader.end()
            guard let engine = header["engine"], let model = header["model"], let created = header["created_at"],
                  let date = MCPContract.date(created), let segments else { throw MCPFailure(.dataUnreadable) }
            self.engine = engine; self.model = model; created_at = created; createdDate = date; arrayOffset = segments
            rawHash = reader.hash.finalize().map { String(format: "%02x", $0) }.joined()
            let milliseconds = date.timeIntervalSince1970 * 1000
            guard milliseconds.isFinite, milliseconds > Double(Int64.min), milliseconds < Double(Int64.max) else { throw MCPFailure(.dataUnreadable) }
            var hash = SHA256()
            for value in [engine, model, String(Int64(milliseconds.rounded()))] { hash.update(data: Data(MCPContract.framed([value]).utf8)) }
            let turns = Reader(file: file, check: check, offset: segments)
            var count = 0, unknown = 0, labels: Set<String> = [], labelBytes = 2, oversizedLabels = false
            try turns.array {
                let location = try turns.segment()
                if collectLabels, !oversizedLabels, let speaker = location.speaker, !speaker.isEmpty, labels.insert(speaker).inserted {
                    let scalar = try MCPJSON.string(speaker).encoded()
                    let quoted = try MCPJSON.string(String(decoding: scalar, as: UTF8.self)).encoded()
                    // This lower bound already exceeds a complete reply, even without field names.
                    labelBytes += scalar.count + quoted.count
                    if labelBytes > MCPContract.hardResponseBytes { oversizedLabels = true; labels.removeAll() }
                }
                if location.speaker?.isEmpty != false || SpeakerNames.isUnknown(location.speaker ?? "") { unknown += 1 }
                for value in [location.speaker ?? "", String(location.start_ms), String(location.end_ms)] { hash.update(data: Data(MCPContract.framed([value]).utf8)) }
                hash.update(data: Data("\(location.textBytes):".utf8))
                if location.rawEnd - location.rawStart <= MCPContract.hardResponseBytes {
                    let decoded = try Self.decode(file: file, location: location, check: check)
                    hash.update(data: Data(decoded.text.utf8))
                } else {
                    let text = Reader(file: file, check: check, offset: location.textStart)
                    _ = try text.string { hash.update(data: $0) }
                }
                count += 1
                return true
            }
            try file.validate()
            semantic = hash; self.labels = collectLabels && !oversizedLabels ? labels : nil; segmentCount = count; unknownSegments = unknown; speakerMetadataTooLarge = oversizedLabels
        }
        func versionID(timeline: Data?) throws -> String {
            var generation = ""
            if let timeline {
                let json = try MCPJSON.parse(timeline)
                if json["schemaVersion"] == .number(1), json["transcriptSHA256"] == .string(rawHash),
                   let value = json["generationFingerprint"]?.string, value.utf8.count == 64,
                   value.allSatisfy({ $0.isASCII && $0.isHexDigit }) { generation = value }
            }
            var hash = semantic; hash.update(data: Data(MCPContract.framed([generation]).utf8))
            return "v_" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func discardSource() { retainedFile = nil }
        private func source() throws -> MCPFiles.AudioHandle {
            guard let retainedFile else { throw MCPFailure(.artifactNotReady) }; return retainedFile
        }
        func each(check: @escaping () throws -> Void, _ body: (Int, Location) throws -> Bool) throws {
            let file = try source()
            let reader = Reader(file: file, check: check, offset: arrayOffset)
            var index = 0
            try reader.array { let location = try reader.segment(); let more = try body(index, location); index += 1; return more }
            try file.validate()
        }
        func segment(_ location: Location, check: @escaping () throws -> Void) throws -> Segment { try Self.decode(file: source(), location: location, check: check) }
        private static func decode(file: MCPFiles.AudioHandle, location: Location, check: @escaping () throws -> Void = {}) throws -> Segment {
            if location.rawEnd - location.rawStart > MCPContract.hardResponseBytes {
                guard location.textBytes <= MCPContract.hardResponseBytes else { throw MCPFailure(.responseTooLarge) }
                let reader = Reader(file: file, check: check, offset: location.textStart)
                return Segment(speaker: location.speaker, start_ms: location.start_ms, end_ms: location.end_ms, text: try reader.stringValue())
            }
            var data = Data(), offset = location.rawStart
            while offset < location.rawEnd {
                let chunk = try file.read(offset: offset, count: Int(min(65536, location.rawEnd - offset)))
                guard !chunk.isEmpty else { throw MCPFailure(.contentChanged) }
                data.append(chunk); offset += Int64(chunk.count)
            }
            do { return try JSONDecoder().decode(Segment.self, from: data) }
            catch { throw MCPFailure(.dataUnreadable) }
        }
        func search(_ location: Location, query: String, check: @escaping () throws -> Void, emit: (String, Int) throws -> Bool) throws -> Bool {
            let file = try source()
            var matcher = Matcher(query: query), utf8 = UTF8Decoder(), more = true
            let reader = Reader(file: file, check: check, offset: location.textStart)
            _ = try reader.string { data in
                if more { more = try matcher.append(utf8.append(data), final: false, emit: emit) }
            }
            try utf8.finish()
            if more { more = try matcher.append("", final: true, emit: emit) }
            return more
        }
    }

    enum Scope { case meeting, inventory, transcript }
    struct Names: Decodable { let speakers: [String: SpeakerNames.Entry] }
    static func names(file: MCPFiles.AudioHandle, labels: Set<String>, scope: Scope = .transcript, check: @escaping () throws -> Void) throws -> (names: Names, hash: String) {
        let saved = try document(file: file, role: "speakers.json", scope: scope, labels: labels, check: check)
        do { return (try JSONDecoder().decode(Names.self, from: saved.data), saved.hash) }
        catch { throw MCPFailure(.dataUnreadable) }
    }
    static func participantIDs(file: MCPFiles.AudioHandle, requested: Set<String>, check: @escaping () throws -> Void) throws -> Set<String> {
        guard !requested.isEmpty else { return [] }
        let reader = Reader(file: file, check: check)
        var modern: Set<String>?, legacy: Set<String> = [], rootKeys: Set<String> = []
        let maximum = requested.map { $0.utf8.count }.max() ?? 0
        try reader.object { key in
            guard key == "calendar" else { try reader.skip(); return }
            guard rootKeys.insert("calendar").inserted else { throw MCPFailure(.dataUnreadable) }
            if try reader.peek() == 110 { try reader.skip(); return }
            var calendarKeys: Set<String> = []
            try reader.object { field in
                if let field, ["participants", "attendees"].contains(field), !calendarKeys.insert(field).inserted { throw MCPFailure(.dataUnreadable) }
                if field == "participants" {
                    var found: Set<String> = []
                    try reader.array {
                        var id: String?, hasID = false, hasName = false, keys: Set<String> = []
                        try reader.object { candidate in
                            guard let key = candidate, ["id", "name", "email", "organizer"].contains(key) else { try reader.skip(); return }
                            guard keys.insert(key).inserted else { throw MCPFailure(.dataUnreadable) }
                            switch key {
                            case "id": hasID = true; id = try reader.stringCandidate(maximum: maximum)
                            case "name": hasName = true; _ = try reader.string()
                            case "email":
                                if try reader.peek() == 110 { try reader.expectNull() } else { _ = try reader.string() }
                            default: try reader.expectBooleanOrNull()
                            }
                        }
                        guard hasID, hasName else { throw MCPFailure(.dataUnreadable) }
                        if let id, !id.isEmpty, requested.contains(id) { found.insert(id) }
                        return true
                    }
                    modern = found
                } else if field == "attendees" {
                    var index = 0
                    try reader.array {
                        _ = try reader.string()
                        let id = "legacy-\(index)"; index += 1
                        if requested.contains(id) { legacy.insert(id) }
                        return true
                    }
                } else { try reader.skip() }
            }
        }
        try reader.end()
        return modern ?? legacy
    }
    /// Project only persisted fields used by MCP; skipped private fields may be arbitrarily large.
    static func document(file: MCPFiles.AudioHandle, role: String, scope: Scope = .meeting, labels: Set<String>? = nil, check: @escaping () throws -> Void) throws -> (data: Data, hash: String) {
        let reader = Reader(file: file, check: check, scope: scope, labels: labels)
        let policy: Projection
        switch role {
        case "meta.json", ".recording.json": policy = .meta
        case "speakers.json": policy = .names
        case "diarization.json": policy = .timeline
        default: throw MCPFailure(.dataUnreadable)
        }
        let result = try reader.project(policy)
        try reader.end()
        return (result, reader.hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private enum Projection { case meta, calendar, participants, attendees, person, names, speakers, speaker, files, offsets, diarization, timeline, scalar, status }
    /// A private token scanner for the saved transcript schema, with a 64 KiB input buffer.
    private final class Reader {
        let file: MCPFiles.AudioHandle
        let check: () throws -> Void
        private let scope: Scope
        private let selectedLabels: Set<String>?
        private var buffer: [UInt8] = []
        private var index = 0
        private var start: Int64
        var hash = SHA256()
        var position: Int64 { start + Int64(index) }
        init(file: MCPFiles.AudioHandle, check: @escaping () throws -> Void, offset: Int64 = 0, scope: Scope = .meeting, labels: Set<String>? = nil) {
            self.file = file; self.check = check; start = offset; self.scope = scope; self.selectedLabels = labels
        }
        private func refill() throws {
            guard index >= max(0, buffer.count - 1) else { return }
            start += Int64(index); index = 0
            try check()
            let data = try file.read(offset: start, count: Int(min(65536, max(0, file.size - start))))
            hash.update(data: data); buffer = Array(data); buffer.append(0)
        }
        func peek() throws -> UInt8? {
            try refill()
            return index < buffer.count - 1 ? buffer[index] : nil
        }
        private func byte() throws -> UInt8 {
            guard let value = try peek() else { throw MCPFailure(.dataUnreadable) }
            index += 1; return value
        }
        func space() throws { while let value = try peek(), [9, 10, 13, 32].contains(value) { index += 1 } }
        func expect(_ value: UInt8) throws { try space(); guard try byte() == value else { throw MCPFailure(.dataUnreadable) } }
        func end() throws { try space(); guard try peek() == nil else { throw MCPFailure(.dataUnreadable) }; try file.validate() }
        func object(_ body: (String?) throws -> Void) throws {
            try expect(123); try space()
            if try peek() == 125 { index += 1; return }
            while true {
                let key = try stringCandidate(maximum: MCPContract.hardResponseBytes)
                try expect(58); try space(); try body(key); try space()
                let next = try byte()
                if next == 125 { return }
                guard next == 44 else { throw MCPFailure(.dataUnreadable) }
            }
        }
        func array(_ body: () throws -> Bool) throws {
            try expect(91); try space()
            if try peek() == 93 { index += 1; return }
            while true {
                try space()
                if try !body() { return }
                try space(); let next = try byte()
                if next == 93 { return }
                guard next == 44 else { throw MCPFailure(.dataUnreadable) }
            }
        }
        func stringCandidate(maximum: Int) throws -> String? {
            var bytes = Data(), oversized = false
            _ = try string { part in
                if !oversized {
                    if part.count > maximum - bytes.count { oversized = true; bytes.removeAll() }
                    else { bytes.append(part) }
                }
            }
            return oversized ? nil : String(data: bytes, encoding: .utf8)
        }
        func expectNull() throws { guard try primitive() == Data("null".utf8) else { throw MCPFailure(.dataUnreadable) } }
        func expectBooleanOrNull() throws {
            let data = try primitive()
            guard [Data("true".utf8), Data("false".utf8), Data("null".utf8)].contains(data) else { throw MCPFailure(.dataUnreadable) }
        }
        func stringValue(maximum: Int = MCPContract.hardResponseBytes) throws -> String {
            var bytes = Data()
            _ = try string { data in
                guard data.count <= maximum - bytes.count else { throw MCPFailure(.responseTooLarge) }
                bytes.append(data)
            }
            guard let value = String(data: bytes, encoding: .utf8) else { throw MCPFailure(.dataUnreadable) }
            return value
        }
        private static let delimiters: [CChar] = [34, 92] + (1...31).map(CChar.init) + [0]
        /// Decodes escapes incrementally; callback chunks may split an ordinary UTF-8 scalar.
        func string(_ consume: (Data) throws -> Void = { _ in }) throws -> Int {
            try expect(34)
            var length = 0, utf8 = UTF8Decoder()
            while true {
                try refill()
                guard index < buffer.count - 1 else { throw MCPFailure(.dataUnreadable) }
                let span = buffer.withUnsafeBufferPointer { bytes in
                    Self.delimiters.withUnsafeBufferPointer { delimiters in
                        Int(strcspn(UnsafeRawPointer(bytes.baseAddress! + index).assumingMemoryBound(to: CChar.self), delimiters.baseAddress!))
                    }
                }
                if span > 0 {
                    let data = Data(buffer[index..<(index + span)])
                    _ = try utf8.append(data); try consume(data); length += data.count; index += span
                }
                if index == buffer.count - 1 { continue }
                let next = try byte()
                try utf8.finish()
                if next == 34 { return length }
                guard next == 92 else { throw MCPFailure(.dataUnreadable) }
                let escaped = try byte(), data: Data
                switch escaped {
                case 34, 47, 92: data = Data([escaped])
                case 98: data = Data([8])
                case 102: data = Data([12])
                case 110: data = Data([10])
                case 114: data = Data([13])
                case 116: data = Data([9])
                case 117:
                    var scalar = try hex()
                    if (0xd800...0xdbff).contains(scalar) {
                        guard try byte() == 92, try byte() == 117 else { throw MCPFailure(.dataUnreadable) }
                        let low = try hex()
                        guard (0xdc00...0xdfff).contains(low) else { throw MCPFailure(.dataUnreadable) }
                        scalar = 0x10000 + (scalar - 0xd800) * 0x400 + low - 0xdc00
                    }
                    guard let value = UnicodeScalar(scalar) else { throw MCPFailure(.dataUnreadable) }
                    data = Data(String(value).utf8)
                default: throw MCPFailure(.dataUnreadable)
                }
                try consume(data); length += data.count
            }
        }
        private func hex() throws -> UInt32 {
            var result: UInt32 = 0
            for _ in 0..<4 {
                let value = try byte(), digit: UInt32
                switch value {
                case 48...57: digit = UInt32(value - 48)
                case 65...70: digit = UInt32(value - 55)
                case 97...102: digit = UInt32(value - 87)
                default: throw MCPFailure(.dataUnreadable)
                }
                result = result * 16 + digit
            }
            return result
        }
        private func primitive() throws -> Data {
            try space(); var result = Data()
            while let value = try peek(), ![9, 10, 13, 32, 44, 93, 125].contains(value) {
                guard result.count < 128 else { throw MCPFailure(.dataUnreadable) }
                result.append(value); index += 1
            }
            guard !result.isEmpty, (try? JSONDecoder().decode(MCPJSON.self, from: result)) != nil else { throw MCPFailure(.dataUnreadable) }
            return result
        }
        func skip(depth: Int = 0) throws {
            guard depth <= 64 else { throw MCPFailure(.dataUnreadable) }
            try space()
            switch try peek() {
            case 34: _ = try string()
            case 123: try object { _ in try skip(depth: depth + 1) }
            case 91: try array { try skip(depth: depth + 1); return true }
            default: _ = try primitive()
            }
        }
        func project(_ policy: Projection) throws -> Data {
            if policy == .scalar {
                if try peek() == 34 { return try JSONEncoder().encode(stringValue()) }
                return try primitive()
            }
            if policy == .status {
                var prefix = Data(), total = 0
                _ = try string { bytes in
                    total += bytes.count
                    prefix.append(bytes.prefix(max(0, 16 - prefix.count)))
                }
                let value = String(decoding: prefix, as: UTF8.self)
                let safe = value.hasPrefix("failed:") ? "failed" : total <= 16 && (MCPContract.states + ["completed", "partial", "skipped", "not_applicable"]).contains(value) ? value : "unknown"
                return try JSONEncoder().encode(safe)
            }
            var output = Data()
            func append(_ bytes: Data) throws {
                guard bytes.count <= MCPContract.hardResponseBytes - output.count else { throw MCPFailure(.responseTooLarge) }
                output.append(bytes)
            }
            if policy == .participants || policy == .attendees {
                try append(Data("[".utf8)); var first = true
                try array {
                    if !first { try append(Data(",".utf8)) }; first = false
                    try append(project(policy == .participants ? .person : .scalar)); return true
                }
                try append(Data("]".utf8)); return output
            }
            var fields: [String: Projection]
            switch policy {
            case .meta:
                fields = ["title": .scalar, "trigger": .scalar, "started": .scalar, "ended": .scalar, "duration_seconds": .scalar,
                          "summary_stale": .scalar, "summary_status": .status, "speakers_status": .status,
                          "transcription_failed": .scalar, "transcription_deferred": .scalar, "calendar": .calendar,
                          "files": .files, "start_offset_ms": .offsets, "diarization": .diarization]
            case .calendar:
                fields = ["title": .scalar, "event_id": .scalar, "association": .scalar, "calendar_title": .scalar, "agenda": .scalar,
                          "scheduled_start": .scalar, "scheduled_end": .scalar, "time_zone": .scalar, "participants": .participants, "attendees": .attendees]
            case .person: fields = ["id": .scalar, "name": .scalar, "email": .scalar, "organizer": .scalar]
            case .names: fields = ["created_at": .scalar, "speakers": .speakers]
            case .speaker: fields = ["name": .scalar, "source": .scalar, "participantID": .scalar]
            case .files, .offsets: fields = ["mic": .scalar, "system": .scalar, "source": .scalar]
            case .diarization: fields = ["status": .status]
            case .timeline: fields = ["schemaVersion": .scalar, "transcriptSHA256": .scalar, "generationFingerprint": .scalar]
            default: fields = [:]
            }
            if scope == .transcript && policy == .meta { fields = [:] }
            if scope != .meeting && policy == .calendar { fields.removeValue(forKey: "agenda") }
            if policy == .names { fields.removeValue(forKey: "created_at") }
            if scope == .inventory && policy == .speaker { fields.removeValue(forKey: "name") }
            try append(Data("{".utf8)); var first = true, keys: Set<String> = []
            try object { candidate in
                guard let key = candidate else {
                    if policy == .speakers && selectedLabels == nil { throw MCPFailure(.responseTooLarge) }
                    try skip(); return
                }
                if policy == .speakers, let selectedLabels, !selectedLabels.contains(key) { try skip(); return }
                let selected = policy == .speakers ? Projection.speaker : fields[key]
                guard let selected else { try skip(); return }
                guard keys.insert(key).inserted else { throw MCPFailure(.dataUnreadable) }
                if !first { try append(Data(",".utf8)) }; first = false
                try append(JSONEncoder().encode(key)); try append(Data(":".utf8))
                if try peek() == 110 { try append(project(.scalar)) }
                else { try append(project(selected)) }
            }
            try append(Data("}".utf8)); return output
        }
        func segment() throws -> Location {
            try space(); let begin = position
            var speaker: String?, start: Int?, end: Int?, textStart: Int64?, bytes = 0, keys: Set<String> = []
            try object { candidate in
                guard let key = candidate, ["speaker", "start_ms", "end_ms", "text"].contains(key) else { try skip(); return }
                guard keys.insert(key).inserted else { throw MCPFailure(.dataUnreadable) }
                switch key {
                case "speaker":
                    if try peek() == 110 { guard try primitive() == Data("null".utf8) else { throw MCPFailure(.dataUnreadable) } }
                    else { speaker = try stringValue() }
                case "start_ms", "end_ms":
                    guard let value = try? JSONDecoder().decode(Int.self, from: primitive()) else { throw MCPFailure(.dataUnreadable) }
                    if key == "start_ms" { start = value } else { end = value }
                case "text": textStart = position; bytes = try string()
                default: try skip()
                }
            }
            guard let start, let end, let textStart, start >= 0, end >= start else { throw MCPFailure(.dataUnreadable) }
            return Location(rawStart: begin, rawEnd: position, textStart: textStart, textBytes: bytes, speaker: speaker, start_ms: start, end_ms: end)
        }
    }
}
