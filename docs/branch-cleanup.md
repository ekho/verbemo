# Safe cleanup of merged Verbemo branches

`scripts/cleanup-merged-branches.py` deletes only explicitly selected, unneeded
branches in `ekho/verbemo`. A merged head must be an ancestor of the freshly
fetched `origin/master`. Ancestry is the only merge test; the tool does not inspect
unmerged branch contents or create archive tags.

Running the script without arguments prints a read-only inventory. `inventory`
additionally saves it. Both fetch only origin heads with `--refmap=` (ignoring additional configured
fetch destinations) and `--no-tags`, and inspect
remote heads/tags, local refs, all worktrees and every page of open GitHub PRs.
Fetching updates local origin tracking refs; it does not change remote refs.
The configured and resolved fetch/push URLs must point exclusively to the own
GitHub repository. `amanu` and `upstream` are never fetched or pushed.

Use the existing SSH access for Git transport. For GitHub inspection, capture
`gh auth token --hostname github.com --user ekho` without displaying it, pass it
as `GH_TOKEN` in the child process environment, and assert `gh api user --jq
.login` is `ekho`. Do not switch the global account, put tokens in arguments,
logs or Git, or use the default account without checking it. The script checks
the actor itself before paginated PR inspection.

## Inventory, backup and review

Run from the Verbemo checkout, with pushes paused during the cleanup window:

```sh
mkdir -p .git/migration/branch-cleanup
python3 scripts/cleanup-merged-branches.py inventory --output .git/migration/branch-cleanup/before.json
git bundle create .git/migration/branch-cleanup/before.bundle --all
git bundle verify .git/migration/branch-cleanup/before.bundle
```

Review `before.json`. `merged: true` alone does not authorize deletion: select
only branches whose purpose is finished. `master`, the current branch, every
worktree branch, and source branches of open own-repository PRs are protected.
`codex/amanu-baseline` remains needed: `AGENTS.md` explicitly assigns it the
original fork master preservation role. `codex/verbemo-independent-releases`
remains active until its own merge. All unmerged heads retain their names/SHA.

Before live deletion, independently review the implementation, exact candidate
names/SHA, and the fresh bundle. Prove restoration in an empty temporary bare
repository, fetching `+refs/*:refs/*` from the bundle, then compare every restored
ref/SHA to `all_refs` in inventory and run `git fsck --full --no-reflogs`.
Keep this evidence under `.git/migration/`, outside tracked files.

## Explicit application

After the candidate list has been reviewed, replace the example name below with
that exact list; there is no automatic “delete all merged” command:

```sh
python3 scripts/cleanup-merged-branches.py apply \
  --inventory .git/migration/branch-cleanup/before.json \
  --bundle .git/migration/branch-cleanup/before.bundle \
  --branches completed-branch
```

`apply` requires the original local refs and verifies the complete bundle,
restores all refs into an empty temporary bare repository and runs fsck. It saves
`before.bundle.verified.json` with the SHA-256 and exact restored refs. Immediately
before each deletion it fetches origin again and repeats master/head, ancestry,
PR, current branch, worktree, local SHA and tag checks. A changed master or
candidate head requires a new inventory and bundle, even if it remains merged.

Remote deletion sends the full ref and exact checked SHA using
`--force-with-lease=refs/heads/<name>:<SHA>`. Local deletion uses
`git update-ref -d refs/heads/<name> <SHA>` after another worktree check. A local
head must equal the remote head and the inventory SHA. These are separate
operations, so a failed local deletion can follow a successful remote deletion.
The script stops immediately and saves actual state in
`before.json.result.json`; it never continues with later branches after failure
or blindly retries. The result file also prevents reusing an applied inventory.

After application the result verifies that every unselected remote head and
local/remote tag retains its SHA, `amanu`/`upstream` tracking refs are unchanged,
deleted refs are absent, and deleted heads are ancestors of the checked master.
The restored bundle additionally retains every original ref and its history.
Keep the original inventory, bundle, verification evidence and result together.

Git does not provide one transaction covering GitHub PR creation, worktree
attachment, master movement and remote/local deletion. Pausing concurrent work
is required; fresh checks narrow this window and exact SHA comparisons protect
candidate heads. A concurrent PR/worktree/master change after the final check
cannot be atomically locked by this script. Inspect a stopped result and fresh
refs before deciding whether to restore or start a new inventory.

For recovery, first restore the bundle into an empty bare repository and verify
refs again. Restore only the missing reviewed refs from that repository; do not
force-push a whole bundle or overwrite refs that have since changed. Remote
restoration must use a missing-ref lease, and local restoration must use an
expected absent old SHA. Existing tags and unrelated branches remain untouched.

## Validation

```sh
python3 -m unittest discover -s Tests/scripts -p 'test_branch_cleanup.py'
```

The fixtures use real temporary bare/local Git repositories and a temporary SSH
transport, never a production CLI bypass. They cover unmerged/changed heads,
master/current/worktree/PR/baseline protection, origin ownership, tags and other
remotes, explicit selection, stale bundles, exact remote/local SHA races,
partial failures, and complete empty-repository restoration.

Live cleanup status and exact names/SHA are recorded in the Task 10 report and
`.git/migration/task-10/` evidence. Source changes and fixtures do not themselves
establish that any live branch was deleted.

## Verified cleanup — 2026-10-19

After independent implementation review and its scoped correction review, the
coordinator explicitly selected these ten completed merged topic refs as
unneeded. The reviewed script at `a11aaa9c596c9e60f18037a989f989a1f39c6d0f`
deleted exactly their checked remote heads:

| Branch | Deleted head SHA |
|---|---|
| `codex/analytics-delivery` | `258e1b5c4704fac2cf35fdb36dfba2851537cf2a` |
| `codex/api-providers-0.6.4` | `4bf973e983e0c5ed02725bfd33e3cc8bd51c200e` |
| `codex/autorecord-setup-macos` | `fa74e85ab801623a5943d22a7ed45c7a130397f1` |
| `codex/local-speaker-diarization` | `6df610ac6dd83d21305e3ffa8d5cc3174df2d304` |
| `codex/macos-0.6.0` | `1e298c9922297a6a71c0935eb15141bc6275f5ee` |
| `codex/macos-ready-0.6.3` | `a7d1e8f2ef2b2ff8c038f387738efa009cbdda7d` |
| `codex/stable-localvqe-source-digests` | `8bef7922f53eb20ab8105b1d7dca1407b40a4609` |
| `codex/windows-downloads-0.6.4` | `48b5ffc071b362dc79cf0c8edf9afafafe78fa5a` |
| `codex/windows-downloads-0.6.5` | `77b29905a65c2166c46645ab07a12a3529afc4e8` |
| `codex/windows-release-routing` | `d91d02e9caa97fea9c4a4b0e7f25561ba0511825` |

The preserved master is `3acf63317ee26bab51c6b71ad7375f05d04e69be`;
every deleted head is its ancestor. No corresponding local topic heads existed,
so the actual changes were ten remote-head deletions and ten origin-tracking
ref removals; zero local-head deletions. The batch completed without failures.

The fresh before snapshot is `.git/migration/task-10/fix1-before.json`.
Backup `.git/migration/task-10/fix1-before.bundle` is 10,637,876 bytes, SHA-256
`77b140f1b90329a9ac84463b5c6fd01fcd6cdeed49bf8d9ab08bd7af48489fe4`.
Verification before and after application restored all 127 original refs into
empty bare repositories and passed `git fsck --full --no-reflogs`.

Actual events are in `fix1-before.json.result.json`; a separate fresh
`after-apply.json` and `after-apply-proof.json` establish 27 remaining remote
heads, all 25 unmerged heads at their original names/SHA, and all 46 remote tags
unchanged. Every remaining local ref matches its before SHA (117 refs); local
tags and amanu/upstream tracking refs are unchanged. The needed baseline and
current worktree/open-PR branch remain. Deleted history remains reachable from
preserved master and from the verified backup. These files and
`after-apply-bundle-restore.log` are under `.git/migration/task-10/`.

The after comparison finished before the documentation-result commit moved the
active local feature head. No public release, site publication or merge was
part of this cleanup.
