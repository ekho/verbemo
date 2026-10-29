using System.Text.Json;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.Core.MCP;

public sealed record McpConnectionContent(string Endpoint,string ConsoleCommand,string AgentPrompt,string ManualSteps,string? Error = null);

public static class McpConnectionInstructions
{
    public static readonly string[] Clients = ["ChatGPT / Codex", "Claude Desktop", "Claude Code", "OpenCode", "OpenChamber"];
    public static McpConnectionContent Create(string client,int port,string executable,bool readable=true)
    {
        if(!readable) return new("","","","",T("Fix config.json before copying connection instructions.","Исправьте config.json перед копированием настроек подключения."));
        if(port is <1024 or >65535) return new("","","","",T("Enter a port from 1024 to 65535.","Введите порт от 1024 до 65535."));
        if(!Clients.Contains(client) || string.IsNullOrWhiteSpace(executable)) return new("","","","",T("Select a client and an available executable.","Выберите клиент и доступный исполняемый файл."));
        var endpoint=$"http://127.0.0.1:{port}/mcp";
        var quoted="'"+executable.Replace("'","''",StringComparison.Ordinal)+"'";
        var json=JsonSerializer.Serialize(executable);
        var launch=$"& {quoted} mcp";
        var command=client switch
        {
            "ChatGPT / Codex"=>$"codex mcp add verbemo -- {quoted} mcp",
            "Claude Code"=>$"claude mcp add --transport stdio verbemo -- {quoted} mcp",
            "OpenCode"=>$"opencode mcp add verbemo -- {quoted} mcp",
            _=>launch,
        };
        var fragment=client switch
        {
            "Claude Desktop"=>"{\"mcpServers\":{\"verbemo\":{\"command\":"+json+",\"args\":[\"mcp\"]}}}",
            "OpenCode"=>"{\"mcp\":{\"servers\":{\"verbemo\":{\"type\":\"local\",\"command\":["+json+",\"mcp\"]}}}}",
            _=>"",
        };
        var manual=client switch
        {
            "ChatGPT / Codex"=>T("Run the registration command in PowerShell, then start a new Codex chat. ChatGPT web connectors cannot reach this local server.","Выполните команду регистрации в PowerShell, затем начните новый чат Codex. Веб-коннекторы ChatGPT не имеют доступа к этому локальному серверу."),
            "Claude Code"=>T("Run the registration command in PowerShell from your project directory. Start Claude Code and check /mcp. A signed-in client is required for runtime verification.","Выполните команду регистрации в PowerShell из каталога проекта. Запустите Claude Code и проверьте /mcp. Для проверки работы нужно войти в клиент."),
            "Claude Desktop"=>T("Open Settings → Desktop app → Extensions → Local MCP servers (older versions: Developer → Edit Config). Merge the verbemo entry below into %APPDATA%\\Claude\\claude_desktop_config.json, save and restart Claude Desktop. The console command only launches the bridge; it does not register a server.","Откройте Settings → Desktop app → Extensions → Local MCP servers (в старых версиях: Developer → Edit Config). Добавьте запись verbemo ниже в %APPDATA%\\Claude\\claude_desktop_config.json, сохраните и перезапустите Claude Desktop. Консольная команда только запускает мост, а не регистрирует сервер.")+"\n"+fragment,
            "OpenCode"=>T("For OpenCode v2, run the registration command in PowerShell or merge the entry below into project configuration. Save and start a new OpenCode session.","Для OpenCode v2 выполните команду регистрации в PowerShell или добавьте запись ниже в настройки проекта. Сохраните и начните новый сеанс OpenCode.")+"\n"+fragment,
            _=>T($"Use an OpenChamber backend running on this computer. Open Settings → MCP → Add server, choose Local, name verbemo, executable {executable}, arguments mcp. Save and enable the server. The console command only launches the bridge; it does not register a server. A remote backend cannot reach this computer's library.",$"Используйте серверную часть OpenChamber на этом компьютере. Откройте Settings → MCP → Add server, выберите Local, имя verbemo, исполняемый файл {executable}, аргументы mcp. Сохраните и включите сервер. Консольная команда только запускает мост, а не регистрирует сервер. Удалённая серверная часть не получит доступ к библиотеке этого компьютера."),
        };
        var prompt=T($"Configure the local Verbemo MCP bridge for {client} on this Windows computer. Preserve unrelated client configuration and other MCP servers. Keep Verbemo running with MCP enabled. Selected HTTP endpoint: {endpoint}. Executable: {executable}; arguments: mcp. The bridge reads the protected token itself; do not ask for, print, or paste a token. Use this PowerShell command where registration is supported (for Claude Desktop/OpenChamber it only launches the bridge):\n{command}\n\n{manual}\n\nVerify tools/list exposes exactly these eight tools: {string.Join(", ",McpContract.Tools)}. Read get_settings with keys mcp.enabled and mcp.port, then list_meetings with limit 1. Report connection failures without changing the recording library. Native audio downloads return local_path; optional --output-dir selects a private client-owned folder. This requires a local client/backend, not a cloud web chat.",
            $"Настрой локальный MCP-мост Verbemo для {client} на этом компьютере Windows. Сохрани посторонние настройки клиента и другие MCP-серверы. Verbemo должен работать с включённым MCP. Выбранный HTTP-адрес: {endpoint}. Исполняемый файл: {executable}; аргументы: mcp. Мост сам читает защищённый токен: не запрашивай, не печатай и не вставляй токен. Используй эту команду PowerShell там, где поддерживается регистрация (для Claude Desktop/OpenChamber она лишь запускает мост):\n{command}\n\n{manual}\n\nПроверь, что tools/list содержит ровно восемь инструментов: {string.Join(", ",McpContract.Tools)}. Прочитай get_settings с ключами mcp.enabled и mcp.port, затем list_meetings с limit 1. Сообщи об ошибках подключения, не меняя библиотеку записей. Загрузка исходного аудио возвращает local_path; необязательный --output-dir задаёт личный каталог клиента. Нужен локальный клиент или серверная часть на этом компьютере, а не облачный веб-чат.");
        return new(endpoint,command,prompt,manual);
    }
}
