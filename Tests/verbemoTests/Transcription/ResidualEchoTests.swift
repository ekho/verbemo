import Testing
@testable import verbemo

struct ResidualEchoTests {
    @Test("Word-sized ASR fragments are cleaned as a phrase without swallowing a local interruption")
    func wordSizedEcho() {
        let phrase = ["давайте", "сначала", "посмотрим", "на", "новый", "вариант", "этого", "экрана"]
        var segments: [Transcript.Segment] = []
        for (i, word) in phrase.enumerated() {
            segments.append(.init(speaker: "them", start_ms: i * 200, end_ms: i * 200 + 190, text: word))
            segments.append(.init(speaker: "me A", start_ms: i * 200 + 50, end_ms: i * 200 + 240, text: word))
        }
        segments.append(.init(speaker: "me B", start_ms: 1200, end_ms: 1900, text: "А что добавить?"))
        segments.sort { $0.start_ms < $1.start_ms }
        let result = EchoFilter.dropResidualEchoes(segments)
        #expect(result.filter { $0.speaker.hasPrefix("me") }.map(\.text) == ["А что добавить?"])
    }
    @Test("After audio cancellation short agreements and partly matching local sentences survive")
    func preservesLocalWords() {
        let segments: [Transcript.Segment] = [
            .init(speaker: "them", start_ms: 0, end_ms: 4000, text: "Да, в пятницу мы можем встретиться после обеда"),
            .init(speaker: "me", start_ms: 1000, end_ms: 1500, text: "Да, в пятницу"),
            .init(speaker: "me", start_ms: 1600, end_ms: 3000, text: "В пятницу мы можем встретиться только вечером"),
        ]
        #expect(EchoFilter.dropResidualEchoes(segments).count == 3)
    }

    @Test("Only a whole identical long overlapping phrase is a residual text duplicate")
    func exactWholePhrase() {
        let text = "мы можем встретиться в пятницу после обеда"
        let segments: [Transcript.Segment] = [
            .init(speaker: "them A", start_ms: 0, end_ms: 4000, text: text),
            .init(speaker: "me A", start_ms: 100, end_ms: 4100, text: text),
            .init(speaker: "me A", start_ms: 5000, end_ms: 9000, text: text),
        ]
        let result = EchoFilter.dropResidualEchoes(segments)
        #expect(result.count == 2)
        #expect(result.last?.start_ms == 5000)
    }
}
