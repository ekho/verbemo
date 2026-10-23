import Testing
@testable import verbemo

@MainActor
struct QuitRequestGateTests {
    @Test("A repeated terminate cannot enter AppKit's pending termination loop")
    func reentrantRequest() {
        let gate = QuitRequestGate()
        var calls = 0
        gate.perform {
            calls += 1
            gate.perform { calls += 1 }
        }
        #expect(calls == 1)
    }

    @Test("Declining the recording confirmation allows a later quit request")
    func cancelledConfirmationAllowsRetry() {
        let gate = QuitRequestGate()
        var calls = 0
        gate.perform { calls += 1 }
        gate.perform { calls += 1 }
        #expect(calls == 2)
    }
}
