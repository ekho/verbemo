import Foundation
import Testing
@testable import verbemo

struct PreviewReleaseTests {
    @Test func picksHighestVersionAcrossPages() async throws {
        let first = "[\(release("0.21.9"))]"
        let second = "[\(release("0.21.10")),\(release("0.21.8"))]"
        let next = #"<https://api.github.com/repositories/123/releases?per_page=100&page=2>; rel="next""#
        let http = StubHTTP { request, _ in
            guard request.path == "/repos/ekho/verbemo/releases" else { return .status(404) }
            return request.url.query?.contains("page=2") == true
                ? .json(200, second) : .json(200, first, headers: ["Link": next])
        }

        let result = try #require(await PreviewRelease.latest(after: "0.21.7", session: http.session))
        #expect(result.version == "0.21.10")
        #expect(result.downloadURL.absoluteString == "https://github.com/ekho/verbemo/releases/download/verbemo-v0.21.10/Verbemo-0.21.10-macos-universal.dmg")
    }

    @Test func skipsReleasesThatCannotUpdatePreview() async throws {
        let entries = [
            release("2.0.0", prerelease: false),
            release("1.0.0", draft: true),
            release("0.99.01"),
            release("0.99.0", tag: "v0.99.0"),
            release("0.98.0", assetName: "Verbemo-0.98.0-windows-x64-Setup.exe"),
            release("0.97.0", state: "starter"),
            release("0.96.0", url: "https://example.com/Verbemo-0.96.0-macos-universal.dmg"),
            release("0.95.0", url: "https://github.com/ekho/verbemo/releases/download/verbemo-v0.94.0/Verbemo-0.95.0-macos-universal.dmg"),
            release("0.94.0", url: "https://github.com/other/verbemo/releases/download/verbemo-v0.94.0/Verbemo-0.94.0-macos-universal.dmg"),
            release("0.21.2"), release("0.21.1"),
        ].joined(separator: ",")
        let http = StubHTTP { _, _ in .json(200, "[\(entries)]") }

        #expect(try await PreviewRelease.latest(after: "0.21.2", session: http.session) == nil)
        #expect(try await PreviewRelease.latest(after: "0.21.1", session: http.session)?.version == "0.21.2")
    }

    @Test func rejectsPaginationOutsideGitHubReleaseEndpoint() async {
        let next = #"<https://example.com/repos/ekho/verbemo/releases?page=2>; rel="next""#
        let http = StubHTTP { _, _ in .json(200, "[]", headers: ["Link": next]) }

        await #expect(throws: URLError.self) {
            _ = try await PreviewRelease.latest(after: "0.21.0", session: http.session)
        }
        #expect(http.requests.count == 1)
    }

    @Test func distinguishesAPIErrorFromNoUpdate() async {
        let http = StubHTTP { _, _ in .status(403) }

        await #expect(throws: URLError.self) {
            _ = try await PreviewRelease.latest(after: "0.21.0", session: http.session)
        }
    }

    private func release(
        _ version: String, prerelease: Bool = true, draft: Bool = false, tag: String? = nil,
        assetName: String? = nil, state: String = "uploaded", url: String? = nil
    ) -> String {
        let tag = tag ?? "verbemo-v\(version)"
        let assetName = assetName ?? "Verbemo-\(version)-macos-universal.dmg"
        let url = url ?? "https://github.com/ekho/verbemo/releases/download/\(tag)/\(assetName)"
        return """
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),"assets":[
          {"name":"\(assetName)","state":"\(state)","browser_download_url":"\(url)"}
        ]}
        """
    }
}
