# verbemo

A local-first meeting recorder for macOS. One SwiftPM package that is both the
application and its command line; `make app` wraps the binary in `Verbemo.app`.

## Start here

- `docs/pitfalls.md` — the constraints that are not visible from the code that
  depends on them, and the places believed correct on reasoning alone. Read it
  before changing anything about signing, the bundle, or where keys live.
- `.issues/` — tracked problems and post-mortems; `status:` in the frontmatter
  says whether each one is still open. The `rca-*` files are worth reading for
  the failure modes even where they are closed.
- `docs/releasing.md` — how to cut a release. **Read it in full before running
  `make release`.** It describes explicit preparation, publication and recovery commands.
- `docs/specs/2026-08-18-native-macos-app-design.md` — the design,
  including the places the code deliberately went its own way.
- `docs/old-macs.md` — what runs on Intel and on older macOS, what sets each
  limit, and which of it has actually been measured. Read it before answering
  any question that starts "does verbemo work on…".

## Working on it

```sh
make app SIGN_ID=-                       # local ad-hoc .build/Verbemo.app
cp -R .build/Verbemo.app /Applications/    # replace the installed copy
swift test                               # full suite; screenshot tests are opt-in,
                                         # LocalVQE tests skip until `make localvqe`
```

Quit the running app before replacing `/Applications/Verbemo.app` — deleting a
bundle does not stop the process using it, and the survivor answers the
doorbell the new copy is ringing.

Actual capture needs a recording. Automated tests complement runtime acceptance;
`docs/testing/setup-window-manual-checklist.md` covers
the setup window — most of it can be driven from a script, and the items that
genuinely need a person are marked. Before changing that window, read
`docs/testing/window-shots.md`: it renders both windows to PNG in both
appearances, and every layout defect this project has found was found by
looking at one.

## Two standing decisions

- **The Unix socket is cancelled.** The interface is the distributed-
  notification doorbell (`SetupRequest`, `RecordRequest`, `SingleInstance`) plus
  the `~/.local/bin/verbemo` symlink into the bundle. If something seems to need
  structured IPC, that is a new argument to make, not a plan to finish.
- **The bundle is assembled by `make app`**, not by an Xcode target. A second
  build system would have to be kept in step with the first.

## Commit messages

Use Conventional Commits. Every commit includes:

```text
Co-authored-by: OpenAI Codex <noreply@openai.com>
```

Read [AGENTS.md](AGENTS.md) for repository ownership, release and Windows test
requirements. Both platforms use the shared source, root `VERSION` and common
release route; `make release` prints guidance and intentionally does not publish.
Local ad-hoc macOS work does not require Apple membership. Signed releases do.
