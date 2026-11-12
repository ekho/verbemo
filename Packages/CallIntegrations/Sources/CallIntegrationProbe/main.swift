import Foundation
import CallIntegrations
import KTalkIntegration

@main struct Probe {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let url = URL(string: args[0]), let port = Int(args[1]),
              let count = Int(args[2]), (1...300).contains(count) else {
            FileHandle.standardError.write(Data("Usage: call-integration-probe https://SPACE.ktalk.ru PORT SAMPLES\nCDP only. Prints call metadata, never audio or tokens.\n".utf8))
            return
        }
        let integration: any CallIntegration = try KTalkIntegration(spaceURL: url, port: port, accessibilityEnabled: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for _ in 0..<count {
            let value = await integration.observe()
            print(String(decoding: try encoder.encode(value), as: UTF8.self))
            try await Task.sleep(for: .milliseconds(200))
        }
        await integration.stop()
    }
}
