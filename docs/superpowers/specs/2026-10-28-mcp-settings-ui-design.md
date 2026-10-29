# MCP settings UI revision

Date: 2026-10-28. Approved user requirements relayed from side chat
`01a1833c-fd40-7390-b83b-d3a6de83533b`. This supersedes the General-page and
separate-instructions-window portions of the #63 design, on both platforms.
It is an implementation requirement, not a claim of completed GUI acceptance.

## Chosen approach and boundary

The user chose a dedicated **MCP** destination in existing native settings,
with one card and inline collapsible sections. The earlier General controls
and instruction sheet are to be removed. A separate service/window, cloud
connection, extra tools, or changes to authentication/storage/lifecycle are
outside this revision. Deliver a reviewable PR and checks; stop before PR merge.

## Disabled state

Only the card's MCP title/toggle row exists when MCP is disabled. Hide port,
status, addresses, token, buttons, client selector, instructions, explanations,
and even disclosure headings. Hidden contents must be absent from accessibility
and keyboard traversal, not merely disabled. Settings navigation and the ordinary
page heading remain visible. No duplicate MCP controls remain in General.

## Enabled state

Use one card with three sections that expand in place; never open an instruction
window/sheet/dialog.

- **Server / Сервер:** actual listening/error state, editable port, selected
  endpoint separate from active endpoint; explain that changing port disconnects
  active clients. Enabled is not proof of listening. A compact actual state and
  active port may remain in the collapsed section heading.
- **Connection / Подключение:** five-client selector and the three blocks below.
- **Access / Доступ:** token for direct HTTP, masked as `***`, copy, the explanation
  “При копировании будет подставлен полный токен” / “Copying inserts the full token”,
  and Rotate token / Заменить токен. Explain native bridge reads the token itself.

Implementation choice consistent with the proposed sketch: Connection starts
expanded; Server and Access collapsed. Keep selection/disclosure state in memory
across a temporary off/on toggle. Do not add a new persistence mechanism for this.

## Connection content

Keep ChatGPT / Codex, Claude Desktop, Claude Code, OpenCode and OpenChamber.
Generate independently readable text/code blocks, each with its own Copy button:

1. **MCP URL:** `http://127.0.0.1:<selected valid port>/mcp`, never a token URL.
2. **Console command:** verified platform/client registration syntax using the
   actual executable, correct shell escaping and actual `mcp [--output-dir ...]`
   arguments. No invented `--port` or registration flags.
3. **Agent prompt:** complete localized text the user can pass to a local agent
   to configure that client and verify its available tools. Include actual
   executable/arguments/endpoint and the relevant valid command/config fragment,
   preserve unrelated client configuration, and explain app-running/local-backend
   limits. This UI only supplies/copies text; it does not execute it.

Controller ruling: for Claude Desktop/OpenChamber, where no supported console
registration command is established, the console block contains the real native
bridge launch command, explicitly labelled as such. The prompt/manual explanation
must describe the supported configuration route and its limits, never claim that
launching the bridge registers a client. Plain client-specific manual steps below
the blocks explain exactly where to configure/save/restart. They are ordinary
text, not a fourth copy card. Native stdio commands/prompts contain no token.

Selected port changes update every dependent displayed/copied block. Invalid
port or unreadable configuration prevents dependent copy actions and explains
why, without a ready-looking incorrect config. Off-state hides all these controls.
Keep selected-vs-active distinction when binding fails or edits are unapplied.
Use existing RU/EN localization for headings, instructions, errors and prompts;
command names and parameters are not translated. Long commands wrap in a narrow
window without widening the page.

## Secret-safe copy contract

Display and accessibility expose only `***`, never the token in values, tooltip,
help, diagnostic or logs. The dedicated token field resolves the current secret
only inside an explicit copy action; never cache a pre-rotation key for copying.
Button, Cmd+C/Ctrl+C and the standard context-menu Copy all use the same copy
policy. Button copies the full original block. Selecting any part of the masked
token and copying yields the full current token, not literal asterisks; ordinary
nonsecret text selection keeps native semantics. No selection need not invent a
copy operation. Rotation immediately changes the next copied key.

Current standard instruction blocks are secret-free, so only the dedicated token
field needs substitution. Do not introduce an extra token-bearing HTTP config
feature. If any existing displayed text includes a secret, the same substitution
rule applies to button/selection/hotkey/context copy. Clipboard writes occur only
on explicit user action. Synthetic clipboard assertions compare in-process and
print only pass/fail, never actual/expected secrets.

## Implementation and tests

macOS: use existing settings navigation and page mapping; extract this card into
`Sources/verbemo/UI/MCPSettingsView.swift` rather than enlarging the existing
SettingsController instruction-sheet code. Keep narrowly scoped copy-field
behavior in that component. Extend pure `MCPConnectionInstructions` to produce
URL/command/prompt/manual text independently with existing localization.

Windows: use existing ApplicationDestination/navigation, SettingsContentView and
SetupForm mappings. Create `windows/src/Verbemo.App/MCP/McpSettingsView.cs` for the
card and its copy handling; keep pure localized content in Core's
`McpConnectionInstructions.cs`. Avoid duplicate generic schema editors and empty
More options content in the MCP page. Follow existing settings mapping tests.

Meaningful RED/GREEN tests cover dedicated destination/no General duplicate;
off-state only toggle including AX/tab order; inline disclosure/no sheet;
all five generated clients, nondefault then changed/invalid port and executable
with spaces/quotes; failed-start selected-vs-active state; RU/EN/narrow layout;
synthetic masked token button/hotkey/context copying, selection, rotation and no
secret in visible/AX text. Use native clipboard with a private/test fixture and
restore prior clipboard when the test owns it; do not publish clipboard contents.

Actual isolated macOS and available Windows GUI checks remain necessary in
addition to tests. Verify keyboard navigation and accessible disclosure states.
Do not reopen Claude Code/Desktop personal profiles: user explicitly accepted
both clients as unverified. Existing native client/audio evidence remains scoped
to its recorded revisions, and new UI acceptance must record the new revision.
