import Foundation
import Testing
@testable import verbemo

struct MeetingActionStateTests {
    @Test func finalTranscriptIsRequiredForSummary() {
        for ready in [false, true] {
            let state = MeetingActionState(transcriptReady: ready, summaryReady: false,
                hasAudio: true, isRecording: false, isBusy: false,
                configReadable: true, transcriptionEnabled: true, summaryEnabled: true)
            #expect((state.reason(for: .regenerateSummary) == nil) == ready)
            #expect((state.reason(for: .copyTranscript) == nil) == ready)
            #expect(state.reason(for: .copySummary) != nil)
        }
    }
    @Test func busyMissingAudioAndDisabledServiceAreIndependent() {
        var state = MeetingActionState(transcriptReady: true, summaryReady: true,
            hasAudio: false, isRecording: false, isBusy: false,
            configReadable: true, transcriptionEnabled: true, summaryEnabled: true)
        #expect(state.reason(for: .retranscribe) != nil)
        #expect(state.reason(for: .regenerateSummary) == nil)
        state.isBusy = true
        #expect(state.reason(for: .regenerateSummary) != nil)
        #expect(state.reason(for: .delete) != nil)
        #expect(state.reason(for: .copySummary) == nil)
        state.isBusy = false
        state.summaryEnabled = false
        #expect(state.reason(for: .regenerateSummary) != nil)
        state.summaryEnabled = true
        state.configReadable = false
        #expect(state.reason(for: .regenerateSummary) != nil)
        #expect(state.reason(for: .copyTranscript) == nil)
    }
}
