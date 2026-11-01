import Foundation
import Testing
@testable import verbemo

struct MeetingTextSearchTests {
    @Test func findsCaseInsensitiveMatchesInOriginalUTF16Text() {
        let text = "🎙️ План PLAN план"
        let matches = MeetingTextSearch.matches(in: text, query: "  ПЛАН\n")
        #expect(matches == [NSRange(location: 4, length: 4), NSRange(location: 14, length: 4)])
        #expect(matches.map { (text as NSString).substring(with: $0) } == ["План", "план"])
        #expect(MeetingTextSearch.matches(in: text, query: "plan") == [NSRange(location: 9, length: 4)])
    }

    @Test func returnsNonOverlappingLiteralMatches() {
        #expect(MeetingTextSearch.matches(in: "aaaaa", query: "aa") == [
            NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)
        ])
        #expect(MeetingTextSearch.matches(in: "a.b aXb", query: "a.b") == [NSRange(location: 0, length: 3)])
        #expect(MeetingTextSearch.matches(in: "café cafe", query: "cafe") == [NSRange(location: 5, length: 4)])
    }

    @Test func emptyAndMissingQueriesHaveNoMatches() {
        for query in ["", " \n\t", "absent"] {
            #expect(MeetingTextSearch.matches(in: "Some text", query: query).isEmpty)
        }
        #expect(MeetingTextSearch.matches(in: "", query: "text").isEmpty)
    }
}
