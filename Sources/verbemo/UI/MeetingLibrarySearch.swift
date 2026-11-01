import Foundation
import CryptoKit

/// Search current artifacts one meeting at a time; never retain the whole library's text.
enum MeetingLibrarySearch {
    struct Input: Sendable { let dir: URL; let title: String; let metadata: [String] }
    enum Source: Sendable { case title, metadata, transcript, summary }
    struct Hit: Sendable, Equatable {
        let source: Source
        let segment: Int?
        let excerpt: String
        let query: String
        let revision: String?
    }
    struct Outcome: Sendable {
        var hits: [URL: Hit] = [:]
        var unreadable = 0
    }
    static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isCurrent(_ hit: Hit, in dir: URL) -> Bool {
        let file = hit.source == .summary ? "summary.md" : hit.segment == nil ? "transcript.md" : "transcript.json"
        guard let data = try? read(dir.appendingPathComponent(file)) else { return false }
        return revision(data) == hit.revision
    }
    static func search(_ inputs: [Input], query: String) throws -> Outcome {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Outcome() }
        func match(_ text: String, source: Source, segment: Int? = nil, revision: String? = nil) -> Hit? {
            let range = (text as NSString).range(of: query, options: .caseInsensitive)
            guard range.location != NSNotFound, let found = Range(range, in: text) else { return nil }
            let start = text.index(found.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(start, offsetBy: max(160, query.count + 40), limitedBy: text.endIndex) ?? text.endIndex
            let excerpt = (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
            return Hit(source: source, segment: segment, excerpt: String(excerpt), query: query, revision: revision)
        }
        var outcome = Outcome()
        for input in inputs {
            try Task.checkCancellation()
            if let hit = match(input.title, source: .title)
                ?? input.metadata.lazy.compactMap({ match($0, source: .metadata) }).first {
                outcome.hits[input.dir] = hit
                continue
            }
            var unreadable = false
            var hit: Hit?
            do {
                if let data = try read(input.dir.appendingPathComponent("transcript.json")) {
                    let transcript = try JSONDecoder().decode(Transcript.self, from: data)
                    let version = revision(data)
                    for (index, segment) in transcript.segments.enumerated() {
                        try Task.checkCancellation()
                        if let found = match(segment.text, source: .transcript, segment: index, revision: version) {
                            hit = found; break
                        }
                    }
                } else if let data = try read(input.dir.appendingPathComponent("transcript.md")) {
                    guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                    hit = match(MarkdownPreview.searchableText(text), source: .transcript, revision: revision(data))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { unreadable = true }
            if hit == nil {
                try Task.checkCancellation()
                do {
                    if let data = try read(input.dir.appendingPathComponent("summary.md")) {
                        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                        hit = match(MarkdownPreview.searchableText(text), source: .summary, revision: revision(data))
                    }
                } catch { unreadable = true }
            }
            if let hit { outcome.hits[input.dir] = hit }
            if unreadable { outcome.unreadable += 1 }
        }
        return outcome
    }
    private static func read(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            if let error = error as? CocoaError, [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) { return nil }
            throw error
        }
        // Refuse linked/oversized artifacts explicitly; callers report an incomplete search.
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 32 * 1024 * 1024 else {
            throw CocoaError(.fileReadNoPermission)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}
