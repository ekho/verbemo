import ArgumentParser

/// Kept so existing CLI users receive an explicit disabled status.
struct AnalyticsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analytics",
        abstract: "Show the disabled product analytics status."
    )

    @Argument(help: "`off` confirms the disabled state; analytics cannot be enabled.")
    var state: String?

    func run() throws {
        if let state {
            switch state.lowercased() {
            case "off": break
            case "on":
                throw ValidationError("Product analytics is disabled in Verbemo and cannot be enabled.")
            default:
                throw ValidationError("Use `verbemo analytics` or `verbemo analytics off`.")
            }
        }
        print("analytics: disabled (no usage statistics are collected or sent)")
    }
}
