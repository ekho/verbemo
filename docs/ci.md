# GitHub Actions checks

`ci.yml` selects jobs from the full Git diff. Pull requests compare their head
with the merge base of the target branch; pushes compare the event's before and
after commits. Renames check both the old and new paths. Missing history,
workflow changes, unknown build inputs and manual CI runs select every check.

| Changed paths | Checks |
| --- | --- |
| `Sources/**`, `Package.swift`, `Package.resolved` | macOS tests and universal preview build |
| `Tests/verbemoTests/**` | macOS tests; no package build |
| `windows/src/**`, Windows build configuration | Windows tests and development package build |
| Windows test projects and harness | Windows tests; no package build |
| Windows packaging scripts | Windows tests, package build and shared script checks |
| `landing/**` | Landing and shared script checks on Linux |
| Release automation and its JavaScript tests | Version/changelog tests on Linux |
| Other `scripts/**`, `Tests/scripts/**`, Python workflow tests | Shared script checks on Linux; native build inputs also select macOS |
| `Tests/macos-scripts/**` | Packaging, signing and compatibility tests on macOS |
| `VERSION`, licenses, shared release scripts | Both platforms and packaging/script checks |
| General documentation | No platform tests or builds; active product-policy docs still run script checks |

The product identity guard always runs on Linux. Native tests run the complete
affected platform suite: there is no reliable source-to-individual-test dependency
map. macOS tests remain serial and require the final Swift Testing report.

Windows CI packaging waits for the separate Windows test job, then uses
`-Development -SkipTests`. Signed packaging rejects `-SkipTests`; release builds
keep their default full tests. CPU and Unicode checks still run on the actual
packaged Windows runtime. Each selected build uploads its own artifacts. The
combined manifest check runs only when both platform builds ran successfully;
ordinary CI does not publish releases.

`CI result` always runs and fails when a selected job fails or is cancelled.
It accepts jobs intentionally skipped by the selector. Use this stable check
for branch protection instead of requiring every conditional platform job.
The workflow itself has no event-level path filter, so documentation-only PRs
still receive a result. `workflow_dispatch` forces a full CI run.

The release workflow continues testing and building both platforms from the
same resolved version commit. Selective ordinary CI does not weaken release
validation or reuse packages from another source commit.
