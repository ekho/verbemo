import Foundation

struct PreviewRelease: Equatable, Sendable {
    let version: String
    let downloadURL: URL

    private static let apiHost = "api.github.com"
    private static let releasePath = "/repos/ekho/verbemo/releases"
    private static let tagPrefix = "verbemo-v"

    static func latest(after installedVersion: String, session: URLSession = .shared) async throws -> PreviewRelease? {
        guard var highest = versionComponents(installedVersion) else { throw URLError(.cannotParseResponse) }

        var result: PreviewRelease?
        var page = 1
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        while true {
            let url = URL(string: "https://\(apiHost)\(releasePath)?per_page=100&page=\(page)")!
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            for release in try decoder.decode([GitHubRelease].self, from: data) {
                guard release.prerelease, !release.draft, release.tagName.hasPrefix(tagPrefix) else { continue }
                let version = String(release.tagName.dropFirst(tagPrefix.count))
                guard let components = versionComponents(version), highest.lexicographicallyPrecedes(components),
                      let downloadURL = release.downloadURL(version: version) else { continue }
                highest = components
                result = PreviewRelease(version: version, downloadURL: downloadURL)
            }

            guard let next = try nextPage(in: response, after: page) else { return result }
            page = next
        }
    }

    private static func versionComponents(_ version: String) -> [UInt]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt($0) }
        guard parts.count == 3, numbers.map({ String($0) }) == parts.map(String.init) else { return nil }
        return numbers
    }

    private static func nextPage(in response: HTTPURLResponse, after current: Int) throws -> Int? {
        for link in (response.value(forHTTPHeaderField: "Link") ?? "").split(separator: ",") {
            let fields = link.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.dropFirst().contains(#"rel="next""#), let target = fields.first else { continue }
            guard target.hasPrefix("<"), target.hasSuffix(">"),
                  let url = URLComponents(string: String(target.dropFirst().dropLast())),
                  url.scheme == "https", url.host == apiHost, url.port == nil,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  isReleasePath(url.path),
                  let value = url.queryItems?.first(where: { $0.name == "page" })?.value,
                  let page = Int(value), page > current else { throw URLError(.badServerResponse) }
            return page
        }
        return nil
    }

    private static func isReleasePath(_ path: String) -> Bool {
        if path == releasePath { return true }
        // GitHub can use a repository ID in Link. The request still uses the named repository.
        let parts = path.split(separator: "/")
        return parts.count == 3 && parts[0] == "repositories" && UInt(parts[1]) != nil && parts[2] == "releases"
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
            let browserDownloadUrl: String
        }

        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        func downloadURL(version: String) -> URL? {
            let filename = "Verbemo-\(version)-macos-universal.dmg"
            let expected = "https://github.com/ekho/verbemo/releases/download/\(tagName)/\(filename)"
            guard assets.contains(where: {
                $0.name == filename && $0.state == "uploaded" && $0.browserDownloadUrl == expected
            }) else { return nil }
            return URL(string: expected)
        }
    }
}
