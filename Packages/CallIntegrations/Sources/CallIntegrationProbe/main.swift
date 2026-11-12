import Foundation
import CallIntegrations
import KTalkIntegration

@main struct Probe {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 4, args[2] == "--audio", let url = URL(string: args[0]),
           let port = Int(args[1]), let count = Int(args[3]), (1...300).contains(count) {
            try await audio(space: url, port: port, count: count)
            return
        }
        guard args.count == 3, let url = URL(string: args[0]), let port = Int(args[1]),
              let count = Int(args[2]), (1...300).contains(count) else {
            FileHandle.standardError.write(Data("Usage: call-integration-probe https://SPACE.ktalk.ru PORT [--audio] SAMPLES\nCDP only. --audio captures participant PCM and prints counts/peaks; no raw audio or tokens.\n".utf8))
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

    private static func audio(space: URL, port: Int, count: Int) async throws {
        let integration = try KTalkIntegration(spaceURL: space, port: port, accessibilityEnabled: false)
        let observation = await integration.observe()
        guard observation.participation == .inCall, let call = observation.call else {
            await integration.stop(); throw CallAudioFailure.unavailable
        }
        let capture = try await integration.makeAudioCapture(for: call.id)
        do {
            try await capture.start()
            var received = 0
            for try await event in capture.events {
                let row: [String: Any]
                switch event {
                case .track(let track): row = ["type": "track", "id": track.id, "generation": track.generation]
                case .audio(let chunk): row = ["type": "audio", "id": chunk.trackID, "generation": chunk.generation,
                    "frame": chunk.frameStart, "samples": chunk.samples.count, "peak": chunk.samples.map(abs).max() ?? 0]
                case .removed(let id): row = ["type": "removed", "id": id]
                case .heartbeat(let frame, _): row = ["type": "heartbeat", "frame": frame]
                case .ended: row = ["type": "ended"]
                }
                print(String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self))
                received += 1
                if received >= count { break }
            }
            await capture.stop(); await integration.stop()
        } catch {
            await capture.stop(); await integration.stop()
            throw error
        }
    }
}
