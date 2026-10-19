# Verbemo pitfalls

The [original Amanu pitfalls](history/amanu-pitfalls.md) preserve dated failures
and measurements. They are historical evidence; recheck them on current Verbemo
before claiming runtime acceptance. See [Support](../SUPPORT.md) for user diagnosis.

## Identity, data and permissions

The bundle identifier is `name.ekho.verbemo`. Its own macOS configuration lives in
`~/.config/verbemo`, models in `~/Library/Application Support/verbemo/models`,
and recordings default to `~/Verbemo Recordings`. Windows uses
`%LOCALAPPDATA%\Verbemo Data` and `%USERPROFILE%\Verbemo Recordings`.
Do not migrate, delete or overwrite Amanu data automatically. Reading shared
provider credentials does not authorize writing the shared files.

macOS attributes privacy grants to the launch context and code identity. Launch
the bundle with Launch Services for a permission test; a CLI launched from a
terminal can exercise Terminal's grants. Permission prompts, login items,
audio capture and calendar access need actual runtime checks.

Quit the running app and confirm no recording is active before replacing its
bundle. Deleting a bundle does not terminate its process or release its doorbell.
Tests use sandbox homes; do not edit the user's real configuration for a test.

## Local signing and public signing

`make app SIGN_ID=-` is the local ad-hoc route. It does not require membership
or release credentials and is not a notarized distribution. Ad-hoc native
libraries cannot satisfy hardened library validation through a Team ID; the
local route clears hardened runtime flags. Certificate signing retains them.
Nested code must be signed before its containing bundle.

Signed macOS releases require the project's own Developer ID, notarization and
Sparkle key material. Signed Windows packages require an own Authenticode
certificate and verified timestamp. Missing credentials fail the release
preflight; they do not block local development. Keep secrets outside Git and logs.

## Common release and update boundaries

Both platforms must match one source SHA, version and build number. Keep full
Git history and a clean tree. The common validator requires both signed receipts,
all files and their actual hashes; a Windows Development receipt is not publishable.
See [the release runbook](releasing.md) for exact CLI and recovery steps.

The publisher verifies public downloads before latest promotion. GitHub's REST
API does not provide an atomic compare-and-swap for latest. Every external
publisher must coordinate with the workflow's repository-wide release lock.
Never replace a published asset or tag to recover a failed stage.

Windows installs a pending update only at the next normal primary startup,
before runtime starts. A secondary launch must not trigger Velopack autoapply.
The interactive check/download path does not exit or restart the application.

Builds and CI do not establish hardware, installer, recording or update
acceptance. Record the exact app/package hashes and the checks actually performed.
