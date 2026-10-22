import Foundation
import Testing

@testable import verbemo

struct CLIDiagnosticTests {
    @Test("Failed CLI output retains the reason after a banner and removes meeting echoes", arguments: [false, true])
    func echoIsNotADiagnostic(reformatted: Bool) async throws {
        let input = "Take notes.\nPrivate discussion about quota and timeout.\nWe ship the secret project on Monday."
        let echo = reformatted
            ? "> Take notes. Private discussion about quota and\n> timeout. We ship the secret\n> project on Monday."
            : input
        let output = String(repeating: "banner line\n", count: 150) + echo + "\nERROR: model is unsupported\n"
        let script = "printf '%s' \"$1\" >&2; printf '%s' \"$2\"; exit 7"
        do {
            _ = try await LLMBackend.run(executable: "/bin/sh", arguments: ["-c", script, "test", output, echo], input: input, timeout: 5)
            Issue.record("Expected failure")
        } catch let error as LLMError {
            guard case .exit(let code, let diagnostic) = error else { Issue.record("Wrong error"); return }
            #expect(code == 7)
            #expect(diagnostic.contains("model is unsupported"))
            #expect(diagnostic.contains("stderr:"))
            #expect(diagnostic.contains("stdout:"))
            #expect(!diagnostic.contains("secret"))
            #expect(!diagnostic.contains("quota"))
            #expect(!error.isUsageLimit)
            #expect(!error.isTransient)
            #expect(diagnostic.count <= 1500)
        }
    }

    @Test("Streams cannot join into a service error marker")
    func streamsStaySeparate() async throws {
        do {
            _ = try await LLMBackend.run(executable: "/bin/sh", arguments: ["-c", "printf rate >&2; printf ' limit'; exit 1"], input: "", timeout: 5)
            Issue.record("Expected failure")
        } catch let error as LLMError {
            #expect(!error.isUsageLimit)
            #expect(error.description.contains("stderr:"))
            #expect(error.description.contains("stdout:"))
        }
    }

    @Test("Credential values in CLI diagnostics are not persisted")
    func credentialsAreRedacted() async throws {
        do {
            _ = try await LLMBackend.run(executable: "/bin/sh", arguments: ["-c", "printf '%s' 'ERROR: token=private-test-value Authorization: Bearer fake-test-bearer sk-test-1234567890'; exit 1"], input: "", timeout: 5)
            Issue.record("Expected failure")
        } catch let error as LLMError {
            #expect(!error.description.contains("private-test-value"))
            #expect(!error.description.contains("fake-test-bearer"))
            #expect(!error.description.contains("sk-test-1234567890"))
        }
    }
    @Test("A long diagnostic keeps the complete final reason within the bound")
    func keepsTail() {
        let output = (1...200).map { "trace line \($0)" }.joined(separator: "\n") + "\nfatal: actual reason"
        let text = LLMBackend.failureText(stderr: Data(output.utf8), stdout: Data(), input: "")
        #expect(text.hasSuffix("fatal: actual reason"))
        #expect(!text.contains("trace line 1\n"))
        #expect(text.count <= 1010)
    }

    @Test("Confirmed CLI sign-in failures require login, not a background retry", arguments: [
        "Failed to authenticate: OAuth session expired and could not be refreshed",
        "API Error: 401 Invalid API key · Please run /login",
        "Not logged in", "Please run codex login",
        "ERROR: Your access token could not be refreshed. Please log out and sign in again.",
        "OAuth token expired", "OAuth token revoked",
    ])
    func signedOut(message: String) {
        let error = LLMError.exit(1, message)
        #expect(error.isSignedOut)
        #expect(!error.isTransient)
        #expect(!error.isUsageLimit)
        #expect(LLMError.signInAdvice(error, backend: "codex-cli")?.contains("codex login") == true)
        #expect(LLMError.signInAdvice(error, backend: "ollama") == nil)
    }

    @Test("Generic authentication and earlier MCP chatter do not classify CLI login")
    func unrelatedAuth() {
        for message in ["mcp: calendar failed to authenticate", "mcp: Not logged in",
                        "Not logged in to the calendar server", "ERROR: model unsupported",
                        "not logged in\nstep 1\nstep 2\nstep 3\nERROR: bad model"] {
            #expect(!LLMError.exit(1, message).isSignedOut)
        }
        #expect(!LLMError.http(401, "Please run /login").isSignedOut)
        let stderr = "ERROR: Your access token could not be refreshed. Please log out and sign in again."
        let text = LLMBackend.failureText(stderr: Data(stderr.utf8), stdout: Data("a\nb\nc\nd\ne".utf8), input: "")
        #expect(LLMError.exit(1, text).isSignedOut, "stdout must not bury stderr's verdict")
    }

    @Test("Truncated and numbered echoes cannot leak meeting text or change error classification", arguments: [false, true])
    func partialEcho(numbered: Bool) {
        let input = "Take notes.\nthem: The private project exceeded quota.\nme: See you on Monday."
        let output = numbered
            ? "1 Take notes.\n2 them: The private project exceeded quota.\n3 me: See you\n4 on Monday.\nERROR: model unsupported"
            : "Take notes.\nthem: The private project exceeded quota.\nERROR: model unsupported"
        let text = LLMBackend.failureText(stderr: Data(output.utf8), stdout: Data(output.utf8), input: input)
        #expect(!text.contains("private project"))
        #expect(!text.contains("See you"))
        #expect(!LLMError.exit(1, text).isUsageLimit)
        #expect(text.contains("model unsupported"))
    }

    @Test("Quoted credential values are redacted completely")
    func quotedSecrets() {
        let output = #"ERROR: {"password": "correct horse battery staple", "access_token": "two words"} secret='private value'"#
        let text = LLMBackend.failureText(stderr: Data(output.utf8), stdout: Data(), input: "")
        for word in ["correct", "horse", "battery", "staple", "two", "words", "private", "value"] {
            #expect(!text.contains(word))
        }
    }

    @Test("An interrupted quoted credential is still redacted", arguments: ["\"", "'"])
    func interruptedSecret(quote: String) {
        let output = "ERROR: token=\(quote)private-test-value"
        let text = LLMBackend.failureText(stderr: Data(output.utf8), stdout: Data(), input: "")
        #expect(!text.contains("private-test-value"))
    }

}
