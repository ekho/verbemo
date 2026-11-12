# Swift code navigation for Codex

This worktree connects Codex to Serena 2.1.0 over local stdio. Serena uses the
selected Xcode toolchain's SourceKit-LSP to inspect Swift symbols, declarations,
references, implementations and diagnostics.

## Configuration

| File | Purpose |
| --- | --- |
| `.codex/config.toml` | Project MCP registration, pinned Serena version and tool allowlist |
| `.serena/project.yml` | Swift project, read-only tools, Serena memories disabled, SourceKit options |

The SourceKit preparation mode is `build`: the default lightweight preparation
reported missing `CTranscribe` in this package, even after a separate successful
build. Serena passes this option during LSP initialization. It costs more CPU
and disk space during initial preparation.

Serena's Python environment, download cache, logs and user settings live under
`.build/serena/`; its symbol cache lives under `.serena/cache/`. SourceKit's
default index build lives under `.build/index-build/`. These generated files are
ignored by Git. Xcode and `uv` remain host prerequisites; no global Codex
configuration is required.

## Starting it

Open **the worktree root** as a trusted Codex project. The MCP `cwd` is `.` and
the cache paths are relative to that directory. Start a new chat after adding
the configuration; restart Codex if the server has not appeared. Existing chats
may retain their previous tool list.

Prerequisites on macOS:

```sh
uv --version
xcrun --find sourcekit-lsp
sourcekit-lsp --help
```

`uv` selects Python 3.13 for Serena, reusing an installed interpreter or downloading
one into the local Python directory. The first start needs network access to
download Serena and any missing SwiftPM dependencies. System Python is unchanged.

Check registration from the worktree root:

```sh
codex mcp get serena --json
```

This checks configuration, not LSP readiness. In a new chat, call Serena's
`initial_instructions` and `get_current_config`, then use a symbol query to check
the active project. Codex exposes eight read-only tools from this configuration.

Serena also has its own project trust setting. On a fresh checkout, after its
first start, set `trusted_project_path_patterns` in the generated
`.build/serena/home/serena_config.yml` to a list containing **only this worktree's
absolute root** (`pwd -P`), then restart the server. Without that entry Serena
ignores the project's SourceKit initialization options. Do not commit that runtime
config: Serena stores a generated authentication secret in it.

## Use and troubleshooting

- Start with `get_symbols_overview` or `find_symbol`, then follow declarations
  and references. Give a `relative_path` to narrow the search.
- Serena locations use zero-based line numbers. Convert them before citing
  one-based editor lines.
- First startup and changes to package dependencies can trigger background
  builds. Empty or partial results are not evidence that a symbol is unused.
  Cross-check important reference searches with `rg` and run the relevant tests.
- Inspect `.build/serena/home/logs/` for startup or indexing failures. For missing
  native modules, check the selected Xcode and prepare the same build directory:

  ```sh
  swift build --build-system native --scratch-path .build/index-build \
    --target verbemo --enable-index-store
  ```

  Then restart the MCP server. A successful build alone does not prove that the
  language server has finished indexing.
- Keep `enabled_tools` in the Codex config aligned with `fixed_tools` in the
  Serena project. Serena's MCP catalog can advertise tools disabled for the
  active project, so both lists are intentional.
- Keep the explicit defaults in `project.yml`: Serena expands incomplete project
  configurations on startup. Review this file when upgrading the pinned version.

This setup covers Swift on macOS. It does not configure the Windows C# language
server. LSP diagnostics supplement the build, tests and real application checks.

## Validation and known limits (2026-11-12)

Checked with Codex CLI 0.167.0, Serena 2.1.0 and Xcode 27.2 / Swift 6.4.2:

- Codex's MCP runtime connects and exposes exactly the eight allowed tools.
- Symbol lookup returns `StudioMeetingHeaderState` and its members, including
  `@MainActor` information. Declaration lookup resolves `KTalkIntegration` from
  the main target into `Packages/CallIntegrations`.
- Codex's diagnostics tool reports a deliberate `String`-to-`Int` return-type
  error in a temporary file in the main target. The file was removed afterward.
- The native index build and the repository's full product identity guard pass.
- Reference search is **not complete** in the tested toolchain. It finds the
  `DedicatedThread.run` calls in GigaAM preparation/transcription and Whisper
  transcription, but misses the call in `WhisperCPPRuntime.prepare` (currently
  `WhisperEngine.swift:360`, one-based), even after a successful native build.
  The raw SourceKit response also misses it. Do not use this tool alone to decide
  that an API is unused or that all its callers have been updated.
- SourceKit logs indexing failures for Swift Argument Parser's documentation
  plugins (`unexpected input file: .../swiftc`). The application target build
  succeeds; plugin indexing is not established by that result.

The explicit native SwiftPM backend currently matches SourceKit's build/index
directory. SwiftPM warns that this backend is deprecated; recheck the setup when
upgrading Xcode or Serena. Full application tests, UI/audio and Windows behavior
were outside this tooling change.

References: [Serena's Codex integration](https://oraios.github.io/serena/02-usage/030_clients.html#codex-cli-and-app),
[Codex MCP configuration](https://developers.openai.com/codex/mcp),
[SourceKit-LSP configuration](https://github.com/swiftlang/sourcekit-lsp/blob/main/Documentation/Configuration%20File.md).
