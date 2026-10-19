#!/usr/bin/env python3
"""Explicit, ancestry-only cleanup of ekho/verbemo branches with recoverable evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

OWN_ORIGINS = {'git@github.com:ekho/verbemo.git', 'https://github.com/ekho/verbemo.git'}
NEEDED = {'codex/amanu-baseline'}


class CleanupError(ValueError):
    pass


def command(args, cwd=None):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        # Do not print transport diagnostics, which can contain credentials.
        raise CleanupError(f'{args[0]} {args[1]} failed (exit {result.returncode})')
    return result.stdout.strip()


def write_json(path, data):
    path = Path(path)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def open_prs():
    if command(['gh', 'api', 'user', '--jq', '.login']) != 'ekho':
        raise CleanupError('GH_TOKEN must identify ekho; do not switch the global gh account')
    pages = json.loads(command(['gh', 'api', '--paginate', '--slurp',
                               'repos/ekho/verbemo/pulls?state=open&per_page=100']))
    return [pr for page in pages for pr in page]


class Repository:
    def __init__(self, path):
        self.path = Path(path).resolve()

    def git(self, *args):
        return command(['git', *args], self.path)

    def require_origin(self):
        # Check both configured endpoints and resolved URLs (including insteadOf).
        for args in [('config', '--get-all', 'remote.origin.url'),
                     ('remote', 'get-url', '--all', 'origin'),
                     ('remote', 'get-url', '--push', '--all', 'origin')]:
            urls = self.git(*args).splitlines()
            if len(urls) != 1 or urls[0] not in OWN_ORIGINS:
                raise CleanupError('origin must point only to ekho/verbemo on GitHub')

    def refs(self):
        return dict(line.split(' ', 1) for line in self.git(
            'for-each-ref', '--format=%(refname) %(objectname)').splitlines())

    def remote_refs(self):
        refs = {}
        for line in self.git('ls-remote', '--refs', 'origin').splitlines():
            sha, name = line.split('\t')
            refs[name] = sha
        return refs

    def ancestor(self, sha, master):
        result = subprocess.run(['git', 'merge-base', '--is-ancestor', sha, master],
                                cwd=self.path, capture_output=True)
        if result.returncode not in (0, 1):
            raise CleanupError('cannot establish ancestry')
        return result.returncode == 0

    def snapshot(self):
        self.require_origin()
        self.git('fetch', '--refmap=', '--no-tags', '--no-write-fetch-head', '--recurse-submodules=no', '--prune', 'origin',
                 '+refs/heads/*:refs/remotes/origin/*')
        remote = self.remote_refs()
        heads = {ref.removeprefix('refs/heads/'): sha for ref, sha in remote.items()
                 if ref.startswith('refs/heads/')}
        if 'master' not in heads:
            raise CleanupError('origin/master is missing')
        refs = self.refs()
        for name, sha in heads.items():
            if refs.get('refs/remotes/origin/' + name) != sha:
                raise CleanupError('origin changed during fetch; take a new inventory')
        current = self.git('symbolic-ref', '--quiet', 'HEAD')
        worktrees = self.git('worktree', 'list', '--porcelain')
        worktree_branches = [line[7:] for line in worktrees.splitlines() if line.startswith('branch ')]
        prs = open_prs()
        pr_branches = {pr['head']['ref'] for pr in prs
                       if pr['head'].get('repo') and pr['head']['repo']['full_name'] == 'ekho/verbemo'}
        branches = {}
        for name, sha in heads.items():
            protected = []
            if name == 'master':
                protected.append('master')
            if 'refs/heads/' + name == current:
                protected.append('current')
            if 'refs/heads/' + name in worktree_branches:
                protected.append('worktree')
            if name in pr_branches:
                protected.append('open-pr')
            if name in NEEDED:
                protected.append('needed')
            branches[name] = {'sha': sha, 'merged': self.ancestor(sha, heads['master']),
                              'protected': protected}
        return {'version': 1, 'created_at': datetime.now(timezone.utc).isoformat(),
                'repository': str(self.path), 'master': heads['master'], 'branches': branches,
                'remote_heads': heads,
                'remote_tags': {k: v for k, v in remote.items() if k.startswith('refs/tags/')},
                'all_refs': refs, 'current': current, 'worktrees': worktrees, 'open_prs': prs}


def inventory(repo, output):
    data = repo.snapshot()
    write_json(output, data)
    return data


def verify_bundle(repo, bundle, expected):
    bundle = Path(bundle).resolve()
    repo.git('bundle', 'verify', str(bundle))
    advertised = dict(line.split(' ', 1)[::-1] for line in repo.git(
        'bundle', 'list-heads', str(bundle)).splitlines() if not line.endswith(' HEAD'))
    if advertised != expected:
        raise CleanupError('bundle refs differ from the fresh inventory; create a fresh --all bundle')
    with tempfile.TemporaryDirectory(prefix='verbemo-restore-', dir=bundle.parent) as folder:
        command(['git', 'init', '--bare', folder])
        command(['git', 'fetch', str(bundle), '+refs/*:refs/*'], folder)
        restored = dict(line.split(' ', 1) for line in command(
            ['git', 'for-each-ref', '--format=%(refname) %(objectname)'], folder).splitlines())
        if restored != expected:
            raise CleanupError('empty-repository restore differs from inventory')
        command(['git', 'fsck', '--full', '--no-reflogs'], folder)
    evidence = {'bundle': str(bundle), 'sha256': hashlib.sha256(bundle.read_bytes()).hexdigest(),
                'verified_at': datetime.now(timezone.utc).isoformat(), 'restored_refs': restored,
                'git_bundle_verify': 'passed', 'empty_repository_restore_and_fsck': 'passed'}
    write_json(str(bundle) + '.verified.json', evidence)
    return evidence


def check_candidate(repo, before, fresh, name):
    if fresh['master'] != before['master']:
        raise CleanupError('master changed; take a new inventory')
    original = before['branches'].get(name)
    now = fresh['branches'].get(name)
    if not original or not now or original['sha'] != now['sha']:
        raise CleanupError(f'{name}: head changed; take a new inventory')
    if original['protected'] or now['protected'] or not original['merged'] or not now['merged']:
        raise CleanupError(f'{name}: branch is protected or unmerged')
    local_ref = 'refs/heads/' + name
    expected_local = before['all_refs'].get(local_ref)
    if fresh['all_refs'].get(local_ref) != expected_local:
        raise CleanupError(f'{name}: local head changed; take a new inventory')
    if expected_local is not None and expected_local != original['sha']:
        raise CleanupError(f'{name}: local and remote head differ')
    if fresh['remote_tags'] != before['remote_tags']:
        raise CleanupError('remote tags changed; take a new inventory')
    local_tags = lambda data: {k: v for k, v in data['all_refs'].items() if k.startswith('refs/tags/')}
    if local_tags(fresh) != local_tags(before):
        raise CleanupError('local tags changed; take a new inventory')


def preservation(before, after, deleted):
    if before['remote_tags'] != after['remote_tags']:
        raise CleanupError('remote tag preservation check failed')
    for ref, sha in before['all_refs'].items():
        if ref.startswith(('refs/tags/', 'refs/remotes/amanu/', 'refs/remotes/upstream/')):
            if after['all_refs'].get(ref) != sha:
                raise CleanupError(f'preservation check failed: {ref}')
    for name, branch in before['branches'].items():
        if name not in deleted and after['remote_heads'].get(name) != branch['sha']:
            raise CleanupError(f'preservation check failed: {name}')
    for name in deleted:
        if name in after['remote_heads'] or 'refs/heads/' + name in after['all_refs']:
            raise CleanupError(f'deletion verification failed: {name}')


def apply(repo, inventory_path, bundle, branches):
    if not branches or len(set(branches)) != len(branches):
        raise CleanupError('supply a nonempty explicit list of unique unneeded branches')
    before = json.loads(Path(inventory_path).read_text())
    if before['repository'] != str(repo.path) or before['version'] != 1:
        raise CleanupError('inventory belongs to another repository or version')
    fresh = repo.snapshot()
    for name in branches:
        repo.git('check-ref-format', 'refs/heads/' + name)
        check_candidate(repo, before, fresh, name)
    if before['all_refs'] != fresh['all_refs']:
        raise CleanupError('local refs changed; take a new inventory and bundle')
    evidence = verify_bundle(repo, bundle, before['all_refs'])
    result_path = Path(str(inventory_path) + '.result.json')
    with result_path.open('x') as stream:
        json.dump({'status': 'started'}, stream)
    result = {'status': 'started', 'requested': branches, 'deleted': [], 'events': [],
              'master': before['master'], 'backup': evidence}
    try:
        for name in branches:
            fresh = repo.snapshot()
            check_candidate(repo, before, fresh, name)
            sha = before['branches'][name]['sha']
            repo.require_origin()
            repo.git('push', '--no-follow-tags', '--recurse-submodules=no',
                     f'--force-with-lease=refs/heads/{name}:{sha}', 'origin', f':refs/heads/{name}')
            result['events'].append({'branch': name, 'sha': sha, 'remote_deleted': True})
            write_json(result_path, result)
            # Recheck worktrees and local SHA after the remote operation too.
            worktrees = repo.git('worktree', 'list', '--porcelain').splitlines()
            if 'branch refs/heads/' + name in worktrees:
                raise CleanupError(f'{name}: worktree appeared after remote deletion')
            if 'refs/heads/' + name in before['all_refs']:
                repo.git('update-ref', '-d', 'refs/heads/' + name, sha)
            result['deleted'].append(name)
            write_json(result_path, result)
        result['after'] = repo.snapshot()
        preservation(before, result['after'], result['deleted'])
        for name in result['deleted']:
            if not repo.ancestor(before['branches'][name]['sha'], before['master']):
                raise CleanupError('deleted history is no longer reachable from checked master')
        result['status'] = 'complete'
    except Exception as error:
        result['status'] = 'stopped'
        result['error'] = str(error)
        try:
            result['after'] = repo.snapshot()
        except Exception:
            # Preserve known results even when remote inspection is unavailable.
            result['after'] = {'all_refs': repo.refs()}
            try:
                result['after']['remote_refs'] = repo.remote_refs()
            except CleanupError as inspection_error:
                result['after']['remote_inspection_error'] = str(inspection_error)
        write_json(result_path, result)
        raise CleanupError(f'cleanup stopped; inspect {result_path}') from error
    write_json(result_path, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action')
    inv = sub.add_parser('inventory')
    inv.add_argument('--output', required=True)
    run = sub.add_parser('apply')
    run.add_argument('--inventory', required=True)
    run.add_argument('--bundle', required=True)
    run.add_argument('--branches', nargs='+', required=True)
    args = parser.parse_args()
    repo = Repository(Path.cwd())
    try:
        if args.action == 'apply':
            data = apply(repo, args.inventory, args.bundle, args.branches)
        elif args.action == 'inventory':
            data = inventory(repo, args.output)
        else:
            data = repo.snapshot()
        print(json.dumps(data, indent=2, sort_keys=True))
    except (ValueError, OSError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
