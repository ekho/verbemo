import Foundation
import Testing
@testable import verbemo

struct ApplicationNavigationTests {
    @Test func settingsPreserveMeetingContextAndExplicitAllClearsSearch() {
        var state = ApplicationNavigationState()
        state.selectedSession = URL(fileURLWithPath: "/fixture/meeting")
        state.versionKey = "v1"
        state.resultTab = "transcript"
        state.query = "Анна"
        state.navigate(.transcription)
        state.navigate(.allMeetings)
        #expect(state.selectedSession != nil)
        #expect(state.versionKey == "v1")
        #expect(state.resultTab == "transcript")
        #expect(state.query == "Анна")
        state.showAllMeetings()
        #expect(state.query.isEmpty)
        #expect(!state.showsDetail)
    }
}

@Suite(.serialized)
@MainActor
struct ApplicationWindowTests {
    @Test(.freshHome) func destinationsShareOneWindowAndAboutHasNoToolbar() {
        let app = ApplicationWindow()
        let panel = app.panel
        for destination in ApplicationNavigationState.Destination.allCases {
            app.navigate(destination)
            #expect(app.panel === panel)
            #expect(app.toolbarIsHidden == (destination == .about))
            #expect(app.primaryActionsAreVisible == (destination == .allMeetings))
        }
        app.update(state: .recording, elapsed: "04:32")
        app.navigate(.general)
        #expect(app.recordingBarIsVisible)
        app.update(state: .idle, elapsed: nil)
        #expect(!app.recordingBarIsVisible)
    }
}
