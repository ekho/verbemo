import Foundation
import Testing
@testable import verbemo

@MainActor
struct PreviewUpdatesTests {
    @Test func dailyCheckSurvivesRestartAndManualCheckRunsImmediately() async throws {
        let suite = "PreviewUpdatesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let lookup = Lookup()
        let first = PreviewUpdates(defaults: defaults, now: { clock.now }, lookup: lookup.run)
        await first.start()?.value
        #expect(lookup.requests == 1)

        clock.now += 23 * 3600
        let restarted = PreviewUpdates(defaults: defaults, now: { clock.now }, lookup: lookup.run)
        #expect(restarted.start() == nil)
        await restarted.checkManually().value
        #expect(lookup.requests == 2)
        #expect(restarted.state == .upToDate)

        clock.now += 3600
        await restarted.start()?.value
        #expect(lookup.requests == 3)
    }

    @Test func manualCheckSharesBackgroundRequestAndShowsItsError() async throws {
        let suite = "PreviewUpdatesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = Gate()
        let lookup = Lookup(gate: gate, error: URLError(.notConnectedToInternet))
        let updates = PreviewUpdates(defaults: defaults, lookup: lookup.run)

        let background = try #require(updates.start())
        await lookup.started.pass()
        let manual = updates.checkManually()
        #expect(updates.state == .checking)
        gate.open()
        await manual.value
        await background.value
        #expect(lookup.requests == 1)
        #expect(updates.state == .failed)
    }

    @Test func backgroundCheckPublishesAvailableRelease() async throws {
        let suite = "PreviewUpdatesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try #require(URL(string: "https://github.com/ekho/verbemo/releases/download/verbemo-v0.22.0/Verbemo-0.22.0-macos-universal.dmg"))
        let release = PreviewRelease(version: "0.22.0", downloadURL: url)
        let updates = PreviewUpdates(defaults: defaults, lookup: { release })

        await updates.start()?.value
        #expect(updates.state == .available(release))
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    @MainActor
    private final class Lookup {
        var requests = 0
        let started = Gate()
        let gate: Gate?
        let error: URLError?

        init(gate: Gate? = nil, error: URLError? = nil) {
            self.gate = gate
            self.error = error
        }

        func run() async throws -> PreviewRelease? {
            requests += 1
            started.open()
            await gate?.pass()
            if let error { throw error }
            return nil
        }
    }
}
