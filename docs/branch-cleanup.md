# Safe cleanup of merged Verbemo branches

`scripts/cleanup-merged-branches.py` deletes only explicitly selected, unneeded
branches in `ekho/verbemo`. A merged head must be an ancestor of the freshly
fetched `origin/master`. Ancestry is the only merge test; the tool does not inspect
unmerged branch contents or create archive tags.

Running the script without arguments prints a read-only inventory. `inventory`
additionally saves it. Both fetch only origin heads with `--no-tags` and inspect
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
