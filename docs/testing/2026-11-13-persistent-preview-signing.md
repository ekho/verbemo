# Persistent macOS preview signing

## Local acceptance

Tested on macOS 26.7.1 (25G241), using the public certificate pinned in
`Packaging/preview-signing.pem`:

`252CFD3544656984A5EDAE30CF7E6F8C4F6F49C591923B4E391F3C7C88A0B965` (SHA-256).

Two different native executables were signed with this certificate and the same
identifier. Their file hashes differed, their designated requirements matched,
and both loaded a signed native library successfully. Strict signature
verification and execution also passed after temporary code-signing trust was
removed from the host.

The separate AppKit fixture `Verbemo Signing Check` used
`name.ekho.verbemo.signing-check` and only displayed `AXIsProcessTrusted()`:

1. Build 1 initially reported Accessibility denied.
2. With the user's permission, Accessibility was granted to the fixture. Build 1
   then reported granted.
3. The fixture was quit and replaced at the same path with build 2, signed with
   the same certificate. Its version and strict signature were checked.
4. Build 2 reported Accessibility granted without another permission change.

Temporary certificate trust had already been removed before the GUI test. After
the test, all fixture app bundles, its Accessibility entry, and the temporary
public certificate in the login keychain were removed. The original keychain
search list was restored. The installed Verbemo app's Accessibility entry stayed
enabled; its bundle was not replaced. The encrypted signing backup remains
outside Git.

## Automated local checks

- Shared Python release and selector tests: 128 passed. Fixture Git commits used
  a per-process `commit.gpgSign=false` override; host Git settings were unchanged.
- Python workflow checks under `windows/tests`: 20 passed with PyYAML 6.0.3,
  including cleanup dry-run/apply execution with macOS `/bin/bash` 3.2.
- Native macOS signing checks: 6 passed, including preview library-loading mode
  and rejection of preview flags for Developer ID releases.
- `bash -n scripts/build-macos-preview.sh` passed.
- The actual preview signing branch and receipt command were also executed with
  tool stubs under `/bin/bash` 3.2: both absent and present signing arguments passed.

These workflow tests ran on macOS and do not establish Windows GUI behavior.
Full application builds and suites are delegated to the actual CI/release runs;
their results must be inspected separately before merge.

## Scope and limits

This establishes Accessibility persistence for two native builds using the
preview identity on this Mac. It does not establish microphone or system-audio
permission persistence, or the full installed Verbemo update flow. The first
transition from ad-hoc signing to this certificate changes identity and can
require a one-time permission renewal. Returning to ad-hoc builds changes it
again.

The hosted release wrapper additionally checks two different binaries and a
native library with the imported identity before packaging, and verifies the
finished app against the pinned certificate. The preview remains unnotarized;
this certificate does not provide Developer ID or Gatekeeper acceptance.
