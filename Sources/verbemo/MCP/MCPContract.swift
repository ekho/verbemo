import Foundation
import CryptoKit

/// JSON without Foundation's NSNumber/bool ambiguity at the protocol boundary.
indirect enum MCPJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), int(Int), number(Double), string(String), array([MCPJSON]), object([String: MCPJSON])
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let integer = try? value.decode(Int.self) { self = .int(integer) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let array = try? value.decode([MCPJSON].self) { self = .array(array) }
        else { self = .object(try value.decode([String: MCPJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let flag): try value.encode(flag)
        case .int(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .string(let text): try value.encode(text)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
    static func == (left: Self, right: Self) -> Bool {
        switch (left, right) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.int(let a), .number(let b)), (.number(let b), .int(let a)): Int(exactly: b) == a
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }
    subscript(_ key: String) -> Self? { object?[key] }
    var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? {
        switch self { case .int(let value): Double(value); case .number(let value): value; default: nil }
    }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    static func optional(_ value: String?) -> Self { value.map(Self.string) ?? .null }
    static func integer(_ value: Int?) -> Self { value.map(Self.int) ?? .null }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static func parse(_ data: Data) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw MCPFailure(.dataUnreadable) }
    }
}

struct MCPFailure: Error, Sendable, Equatable {
    enum Code: String, Sendable {
        case meetingNotFound = "meeting_not_found", versionNotFound = "version_not_found"
        case artifactNotFound = "artifact_not_found", artifactNotReady = "artifact_not_ready"
        case dataUnreadable = "data_unreadable", contentChanged = "content_changed"
        case invalidCursor = "invalid_cursor", responseTooLarge = "response_too_large"
        case serverStopping = "server_stopping", invalidParams = "invalid_params", unknownTool = "unknown_tool"
    }
    let code: Code
    init(_ code: Code) { self.code = code }
    var retryable: Bool { [.artifactNotReady, .contentChanged].contains(code) }
    var json: MCPJSON {
        .object(["code": .string(code.rawValue), "message": .string(code.rawValue), "retryable": .bool(retryable)])
    }
}

enum MCPContract {
    static let tools = ["list_meetings", "get_meeting", "list_transcript_versions", "get_meeting_transcript", "get_meeting_summary", "search_meetings", "get_meeting_audio", "get_settings"]
    static let softTextBytes = 64 * 1024
    static let hardResponseBytes = 1024 * 1024
    static let stages = ["transcription", "diarization", "speaker_naming", "summary"]
    static let states = ["pending", "running", "deferred", "failed", "off", "done", "cancelled", "unknown"]
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ value: String) -> String { hash(Data(value.utf8)) }
    static func framed(_ values: [String]) -> String { values.map { "\($0.utf8.count):\($0)" }.joined() }
    static func date(_ text: String) -> Date? {
        guard text.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func normalizedRoot(_ root: URL) -> URL {
        var parts: [String] = []
        for part in root.path.split(separator: "/") {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if part != "." { parts.append(String(part)) }
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: true)
    }
    static func meetingID(root: URL, relative: String) -> String {
        "m_" + hash("verbemo-meeting-v1\0" + normalizedRoot(root).path + "\0" + relative)
    }
    /// This is the CallToolResult shape. Transport must include precisely these content blocks.
    static func resultEnvelope(_ value: MCPJSON) throws -> MCPJSON {
        let text = String(decoding: try value.encoded(), as: UTF8.self)
        var content: [MCPJSON] = [.object(["type": .string("text"), "text": .string(text)])]
        if let resources = value["resources"]?.array { content += resources }
        return .object(["isError": .bool(false), "structuredContent": value, "content": .array(content)])
    }
    static func checkSize(_ value: MCPJSON) throws -> MCPJSON {
        // Transport also checks its final JSON-RPC envelope after inserting the request id.
        guard try resultEnvelope(value).encoded().count <= hardResponseBytes else { throw MCPFailure(.responseTooLarge) }
        return value
    }
}

struct MCPArguments {
    let values: [String: MCPJSON]
    func string(_ key: String, default fallback: String? = nil) throws -> String? {
        guard let value = values[key] else { return fallback }
        guard let result = value.string else { throw MCPFailure(.invalidParams) }
        return result
    }
    func integer(_ key: String, default fallback: Int? = nil, range: ClosedRange<Int> = 0...Int.max) throws -> Int? {
        guard let value = values[key] else { return fallback }
        if case .int(let integer) = value {
            guard range.contains(integer) else { throw MCPFailure(.invalidParams) }; return integer
        }
        guard let number = value.number, number.isFinite, number.rounded() == number,
              number >= Double(range.lowerBound), number < Double(Int.max), number <= Double(range.upperBound) else { throw MCPFailure(.invalidParams) }
        return Int(number)
    }
    func choice(_ key: String, _ options: [String], default fallback: String? = nil) throws -> String? {
        guard let result = try string(key, default: fallback) else { return nil }
        guard options.contains(result) else { throw MCPFailure(.invalidParams) }
        return result
    }
    func strings(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        guard let array = value.array, array.allSatisfy({ $0.string != nil }) else { throw MCPFailure(.invalidParams) }
        return array.compactMap(\.string)
    }
    func validateKeys(_ allowed: Set<String>) throws {
        guard Set(values.keys).isSubset(of: allowed) else { throw MCPFailure(.invalidParams) }
    }
}

struct MCPCursor: Codable {
    let format: Int
    let digest: String
    let revision: String
    let version: String?
    let offset: Int
    static func offset(arguments: [String: MCPJSON], operation: String, revision: String, version: String? = nil) throws -> Int {
        guard let value = arguments["cursor"] else { return 0 }
        guard let text = value.string, text.utf8.count <= 4096,
              !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw MCPFailure(.invalidCursor) }
        let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4)),
              let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.format == 1, cursor.offset >= 0,
              cursor.digest == (try digest(arguments, operation)) else { throw MCPFailure(.invalidCursor) }
        guard cursor.revision == revision, cursor.version == version else { throw MCPFailure(.contentChanged) }
        return cursor.offset
    }
    static func next(_ offset: Int?, arguments: [String: MCPJSON], operation: String, revision: String, version: String? = nil) throws -> MCPJSON {
        guard let offset else { return .null }
        let cursor = Self(format: 1, digest: try digest(arguments, operation), revision: revision, version: version, offset: offset)
        let data = try JSONEncoder().encode(cursor)
        return .string(data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
    }
    private static func digest(_ arguments: [String: MCPJSON], _ operation: String) throws -> String {
        var values = arguments
        values.removeValue(forKey: "cursor")
        values["operation"] = .string(operation)
        return MCPContract.hash(try MCPJSON.object(values).encoded())
    }
}
