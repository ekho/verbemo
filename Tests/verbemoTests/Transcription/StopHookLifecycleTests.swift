import Darwin
import Foundation
import Testing
@testable import verbemo

@Suite(.freshHome)
struct StopHookLifecycleTests {
    @Test("Hook cancellation waits for its direct shell and holds the meeting claim")
    func cancellationWaitsForHookShell() async throws {
        let dir = try SessionFixture.make()
        let pidFile = dir.appendingPathComponent("hook.pid")
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: dir)
        }
        StopHook.owe(dir)
        let operations = ProcessingOperations()
        let task = Task {
            try await operations.run(session: dir, kind: .postProcessing) {
                await StopHook.fireIfOwed(dir, command:
                    "exec /bin/sh -c 'echo $$ > hook.pid; trap \"exit 0\" TERM; while [ ! -f hook.release ]; do :; done; echo completed > hook.completed' hook")
            }
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(SessionClaim.isHeld(dir))
        let entry = try #require(operations.snapshot().first)
        await operations.cancelAndWait(entry.id)
        #expect(try await task.value)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(!SessionClaim.isHeld(dir))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("hook.completed").path))
        #expect(SessionState.value(dir, StopHook.key) as? String == StopHook.fired)
        #expect(!(await StopHook.fireIfOwed(dir, command: "true")))
    }

    @Test("Cancellation before accepting a hook preserves its debt and launches nothing")
    func preCancelledHookRemainsOwed() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        StopHook.owe(dir)
        let start = Gate()
        let task = Task {
            await start.pass()
            return await StopHook.fireIfOwed(dir, command: "exec /bin/sh -c ': > hook.launched' hook")
        }
        task.cancel()
        start.open()
        #expect(!(await task.value))
        #expect(SessionState.value(dir, StopHook.key) as? String == StopHook.owed)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("hook.launched").path))
        #expect(!SessionClaim.isHeld(dir))
    }
}
