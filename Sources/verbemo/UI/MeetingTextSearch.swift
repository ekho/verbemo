import Foundation

/// Ranges use the original text's UTF-16 offsets, as required by AppKit text views.
enum MeetingTextSearch {
    static func matches(in text: String, query: String) -> [NSRange] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var matches: [NSRange] = []
        var offset = 0
        while offset < source.length {
            let range = source.range(of: query, options: .caseInsensitive,
                                     range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound, range.length > 0 else { break }
            matches.append(range)
            offset = NSMaxRange(range)
        }
        return matches
    }
}
