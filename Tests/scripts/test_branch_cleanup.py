import importlib.util
import json
import os
from pathlib import Path
import subprocess
import shlex
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/cleanup-merged-branches.py'


class BranchCleanupTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), 'branch cleanup implementation is missing')
        spec = importlib.util.spec_from_file_location('branch_cleanup', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.remote = self.root / 'origin.git'
        self.local = self.root / 'local'
        self.run_git(self.root, 'init', '--bare', str(self.remote))
        self.run_git(self.root, 'init', '-b', 'master', str(self.local))
        self.run_git(self.local, 'config', 'user.email', 'fixture@example.invalid')
        self.run_git(self.local, 'config', 'user.name', 'Fixture')
        (self.local / 'file').write_text('base')
        self.run_git(self.local, 'add', 'file')
        self.run_git(self.local, 'commit', '-m', 'base')
        # Exercise real upload/receive-pack with an SSH transport fixture.
        ssh = self.root / 'ssh'
        ssh.write_text('#!/bin/sh\ncase \"$*\" in\n'
                       '*git-upload-pack*) exec git-upload-pack ' + shlex.quote(str(self.remote)) + ';;\n'
                       '*git-receive-pack*) exec git-receive-pack ' + shlex.quote(str(self.remote)) + ';;\n'
                       '*) exit 1;;\nesac\n')
        ssh.chmod(0o755)
        transport = patch.dict(os.environ, {'GIT_SSH_COMMAND': str(ssh), 'GIT_SSH_VARIANT': 'ssh'})
        transport.start()
        self.addCleanup(transport.stop)
        self.run_git(self.local, 'remote', 'add', 'origin', 'git@github.com:ekho/verbemo.git')
        self.run_git(self.local, 'branch', 'merged')
        self.run_git(self.local, 'tag', 'existing')
        self.run_git(self.local, 'push', 'origin', '--all')
        self.run_git(self.local, 'push', 'origin', '--tags')
        self.run_git(self.local, 'switch', '-c', 'active')
        self.prs = []
        self.repo = self.module.Repository(self.local)
        self.pr_patch = patch.object(self.module, 'open_prs', lambda: self.prs.copy())
        self.pr_patch.start()
        self.addCleanup(self.pr_patch.stop)
        self.inventory_path = self.root / 'inventory.json'
        self.bundle = self.root / 'backup.bundle'

    def run_git(self, cwd, *args):
        result = subprocess.run(['git', *args], cwd=cwd, text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def refs(self, remote=None):
        return self.run_git(remote or self.remote, 'show-ref')

    def prepare(self):
        data = self.module.inventory(self.repo, self.inventory_path)
        self.run_git(self.local, 'bundle', 'create', str(self.bundle), '--all')
        return data

    def apply(self, *branches):
        return self.module.apply(self.repo, self.inventory_path, self.bundle, list(branches))

    def rejected(self, *branches):
        before = self.refs()
        with self.assertRaises((ValueError, self.module.CleanupError)):
            self.apply(*branches)
        self.assertEqual(self.refs(), before)

    def test_UnmergedBranchIsPreserved(self):
        (self.local / 'file').write_text('new')
        self.run_git(self.local, 'commit', '-am', 'unmerged')
        self.run_git(self.local, 'push', 'origin', 'active:unmerged')
        data = self.prepare()
        self.assertFalse(data['branches']['unmerged']['merged'])
        self.rejected('unmerged')

    def test_ChangedHeadIsPreserved(self):
        self.prepare()
        (self.local / 'file').write_text('new')
        self.run_git(self.local, 'commit', '-am', 'new merged head')
        self.run_git(self.local, 'push', 'origin', 'active:master', 'active:merged')
        self.rejected('merged')

    def test_MasterAndWorktreeBranchesArePreserved(self):
        self.run_git(self.local, 'push', 'origin', 'active')
        self.run_git(self.local, 'branch', 'checked-out')
        self.run_git(self.local, 'push', 'origin', 'checked-out')
        self.prepare()
        self.run_git(self.local, 'worktree', 'add', str(self.root / 'worktree'), 'checked-out')
        for name in ('master', 'active', 'checked-out'):
            with self.subTest(branch=name):
                self.rejected(name)

    def test_OpenPRIsPreserved(self):
        self.prepare()
        self.prs.append({'number': 1, 'head': {'ref': 'merged', 'repo': {'full_name': 'ekho/verbemo'}}})
        self.rejected('merged')

    def test_OtherRemotesUntouched(self):
        other = self.root / 'other.git'
        self.run_git(self.root, 'init', '--bare', str(other))
        for remote in ('amanu', 'upstream'):
            self.run_git(self.local, 'remote', 'add', remote, str(other))
            self.run_git(self.local, 'push', remote, 'master')
            self.run_git(self.local, 'fetch', remote)
        before = self.refs(other)
        tracking = self.run_git(self.local, 'for-each-ref', 'refs/remotes/amanu', 'refs/remotes/upstream')
        self.prepare()
        self.apply('merged')
        self.assertEqual(self.refs(other), before)
        self.assertEqual(self.run_git(self.local, 'for-each-ref', 'refs/remotes/amanu', 'refs/remotes/upstream'), tracking)

    def test_ExtraOriginFetchMappingsPreserveOtherRefsAndLocalTags(self):
        base = self.run_git(self.local, 'rev-parse', 'master')
        self.run_git(self.local, 'update-ref', 'refs/remotes/upstream/master', base)
        self.run_git(self.local, 'tag', 'master', base)
        self.run_git(self.local, 'commit', '--allow-empty', '-m', 'advance origin master')
        advanced = self.run_git(self.local, 'rev-parse', 'HEAD')
        self.assertNotEqual(base, advanced)
        self.run_git(self.local, 'push', 'origin', 'active:master')
        for mapping in ('+refs/heads/*:refs/remotes/upstream/*', '+refs/heads/*:refs/tags/*'):
            self.run_git(self.local, 'config', '--add', 'remote.origin.fetch', mapping)
        self.module.inventory(self.repo, self.inventory_path)
        with self.subTest(ref='upstream tracking'):
            self.assertEqual(self.run_git(self.local, 'rev-parse', 'refs/remotes/upstream/master'), base)
        with self.subTest(ref='local tag'):
            self.assertEqual(self.run_git(self.local, 'rev-parse', 'refs/tags/master'), base)
        self.assertEqual(self.run_git(self.local, 'rev-parse', 'refs/remotes/origin/master'), advanced)

    def test_BundleRestoresDeletedRefs(self):
        before = self.prepare()
        result = self.apply('merged')
        self.assertEqual(result['status'], 'complete')
        self.assertNotIn('refs/heads/merged', self.refs())
        self.assertNotIn('refs/heads/merged', self.refs(self.local))
        evidence = json.loads(Path(str(self.bundle) + '.verified.json').read_text())
        self.assertEqual(evidence['restored_refs'], before['all_refs'])
        restored = self.root / 'restore.git'
        self.run_git(self.root, 'init', '--bare', str(restored))
        self.run_git(restored, 'fetch', str(self.bundle), '+refs/*:refs/*')
        self.assertEqual(self.run_git(restored, 'rev-parse', 'refs/heads/merged'), before['branches']['merged']['sha'])
        self.assertEqual(self.run_git(self.remote, 'rev-parse', 'refs/tags/existing'), before['remote_tags']['refs/tags/existing'])

    def test_LocalChangedHeadIsPreserved(self):
        self.prepare()
        self.run_git(self.local, 'update-ref', 'refs/heads/merged', 'HEAD', 'refs/heads/merged')
        # A distinct local head must block even if the remote head is unchanged.
        self.run_git(self.local, 'commit', '--allow-empty', '-m', 'local change')
        self.run_git(self.local, 'branch', '-f', 'merged', 'HEAD')
        self.rejected('merged')

    def test_BaselineIsNeeded(self):
        self.run_git(self.local, 'push', 'origin', 'master:codex/amanu-baseline')
        data = self.prepare()
        self.assertIn('needed', data['branches']['codex/amanu-baseline']['protected'])
        self.rejected('codex/amanu-baseline')

    def test_WrongOriginRejectedBeforeMutation(self):
        self.prepare()
        self.run_git(self.local, 'remote', 'set-url', 'origin', str(self.remote))
        self.rejected('merged')

    def test_StaleBundleRejected(self):
        self.prepare()
        self.run_git(self.local, 'tag', 'later')
        self.rejected('merged')

    def test_ExplicitListOnlyAndInventoryHasNoRemoteMutation(self):
        before = self.refs()
        self.prepare()
        self.assertEqual(self.refs(), before)
        self.rejected()

    def test_ChangedHeadEvenWhenStillMergedIsPreserved(self):
        self.run_git(self.local, 'commit', '--allow-empty', '-m', 'later master')
        self.run_git(self.local, 'push', 'origin', 'active:master')
        self.prepare()
        self.run_git(self.local, 'push', 'origin', 'active:merged')
        self.rejected('merged')

    def test_MasterChangeAloneIsPreserved(self):
        self.prepare()
        self.run_git(self.local, 'commit', '--allow-empty', '-m', 'later master')
        self.run_git(self.local, 'push', 'origin', 'active:master')
        self.rejected('merged')

    def test_ExactRemoteLeaseRejectsRace(self):
        self.run_git(self.local, 'commit', '--allow-empty', '-m', 'later master')
        self.run_git(self.local, 'push', 'origin', 'active:master')
        self.prepare()
        newer = self.run_git(self.local, 'rev-parse', 'HEAD')
        original = self.repo.git
        def race(*args):
            if args[0] == 'push':
                self.run_git(self.remote, 'update-ref', 'refs/heads/merged', newer)
            return original(*args)
        with patch.object(self.repo, 'git', race), self.assertRaises(self.module.CleanupError):
            self.apply('merged')
        self.assertEqual(self.run_git(self.remote, 'rev-parse', 'refs/heads/merged'), newer)
        self.assertIn('refs/heads/merged', self.refs(self.local))

    def test_ExactLocalCASRejectsRace(self):
        self.run_git(self.local, 'commit', '--allow-empty', '-m', 'later master')
        newer = self.run_git(self.local, 'rev-parse', 'HEAD')
        self.run_git(self.local, 'push', 'origin', 'active:master')
        self.prepare()
        original = self.repo.git
        def race(*args):
            if args[:2] == ('update-ref', '-d'):
                self.run_git(self.local, 'update-ref', 'refs/heads/merged', newer)
            return original(*args)
        with patch.object(self.repo, 'git', race), self.assertRaises(self.module.CleanupError):
            self.apply('merged')
        self.assertEqual(self.run_git(self.local, 'rev-parse', 'refs/heads/merged'), newer)
        result = json.loads(Path(str(self.inventory_path) + '.result.json').read_text())
        self.assertEqual(result['status'], 'stopped')
        self.assertTrue(result['events'][0]['remote_deleted'])

    def test_BundleMustContainFreshAllRefs(self):
        self.prepare()
        self.run_git(self.local, 'tag', 'later')
        self.module.inventory(self.repo, self.inventory_path)
        self.rejected('merged')

    def test_StateInspectionOutageStillPersistsStoppedResult(self):
        self.prepare()
        original_git, original_snapshot, original_remote = self.repo.git, self.repo.snapshot, self.repo.remote_refs
        deleted = False
        def transport(*args):
            nonlocal deleted
            value = original_git(*args)
            if args[0] == 'push':
                deleted = True
            return value
        def snapshot():
            if deleted:
                raise self.module.CleanupError('PR inspection unavailable')
            return original_snapshot()
        def remote():
            if deleted:
                raise self.module.CleanupError('remote inspection unavailable')
            return original_remote()
        with patch.object(self.repo, 'git', transport), patch.object(self.repo, 'snapshot', snapshot), patch.object(self.repo, 'remote_refs', remote):
            with self.assertRaises(self.module.CleanupError):
                self.apply('merged')
        result = json.loads(Path(str(self.inventory_path) + '.result.json').read_text())
        self.assertEqual(result['status'], 'stopped')
        self.assertEqual(result['after']['remote_inspection_error'], 'remote inspection unavailable')
        self.assertTrue(result['events'][0]['remote_deleted'])

    def test_PartialFailureStopsAndPersistsActualResult(self):
        self.run_git(self.local, 'branch', 'second')
        self.run_git(self.local, 'branch', 'third')
        self.run_git(self.local, 'push', 'origin', 'second', 'third')
        self.prepare()
        hook = self.remote / 'hooks/update'
        hook.write_text('#!/bin/sh\n[ "$1" != "refs/heads/second" ]\n')
        hook.chmod(0o755)
        with self.assertRaises(self.module.CleanupError):
            self.apply('merged', 'second', 'third')
        data = json.loads(Path(str(self.inventory_path) + '.result.json').read_text())
        self.assertEqual(data['status'], 'stopped')
        self.assertNotIn('merged', data['after']['remote_heads'])
        self.assertIn('second', data['after']['remote_heads'])
        self.assertIn('third', data['after']['remote_heads'])


if __name__ == '__main__':
    unittest.main()
