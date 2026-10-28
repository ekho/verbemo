import Foundation

enum MCPConnectionInstructions {
    enum Client: String, CaseIterable {
        case codex = "ChatGPT / Codex", desktop = "Claude Desktop", claude = "Claude Code"
        case opencode = "OpenCode", openchamber = "OpenChamber"
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func text(client: Client, port: Int, executable: String) -> String {
        guard (1024...65535).contains(port) else { return "Select a valid MCP port (1024–65535) before copying instructions." }
        let command = shellQuote(executable)
        let jsonCommand = String(decoding: (try? MCPJSON.string(executable).encoded()) ?? Data(), as: UTF8.self)
        let prefix = "Selected HTTP endpoint: http://127.0.0.1:\(port)/mcp\nKeep Verbemo running and enable MCP in General settings. The local stdio bridge reads Verbemo settings and its protected token; it downloads audio into private local files. These instructions apply to clients running on this computer, not a cloud web chat.\n\n"
        let steps: String
        switch client {
        case .codex:
            steps = "In a terminal, register the local bridge for Codex:\ncodex mcp add verbemo -- \(command) mcp\nThen start a new Codex chat. ChatGPT web connectors cannot reach this local server."
        case .desktop:
            steps = "Open Claude Desktop Settings → Desktop app → Extensions → Local MCP servers (older versions: Developer → Edit Config). Merge this entry into mcpServers in ~/Library/Application Support/Claude/claude_desktop_config.json, preserving other servers, then restart Claude Desktop:\n{\"mcpServers\":{\"verbemo\":{\"command\":\(jsonCommand),\"args\":[\"mcp\"]}}}"
        case .claude:
            steps = "From your project directory run:\nclaude mcp add --transport stdio verbemo -- \(command) mcp\nStart Claude Code and check /mcp. Runtime compatibility requires a signed-in client."
        case .opencode:
            steps = "For OpenCode v2 run:\nopencode mcp add verbemo -- \(command) mcp\nOr merge into your project configuration:\n{\"mcp\":{\"servers\":{\"verbemo\":{\"type\":\"local\",\"command\":[\(jsonCommand),\"mcp\"]}}}}"
        case .openchamber:
            steps = "Use an OpenChamber backend running on this computer. Open Settings → MCP → Add server, choose Local, name verbemo, executable \(executable), arguments: mcp. If the UI has one command field, use:\n\(command) mcp\nSave and enable the server. A remote backend cannot access this computer's library."
        }
        return prefix + steps + "\n\nOptional bridge argument: --output-dir followed by a client-owned private directory. Without it, the bridge creates a private temporary directory per process. Files remain available to the agent after download; delete them when finished. Never paste a token into chat."
    }
}
