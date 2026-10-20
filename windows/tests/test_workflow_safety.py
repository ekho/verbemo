from pathlib import Path
import os
import re
import json
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


def workflow(name):
    return yaml.load((ROOT / '.github/workflows' / name).read_text(), Loader=yaml.BaseLoader)


class CommonReleaseWorkflowTests(unittest.TestCase):
    def test_automatic_release_uses_the_version_commit_and_gates_both_platforms(self):
        data = workflow('release.yml')
        self.assertEqual(data['on'].get('push', {}).get('branches'), ['master'])
        self.assertIn('auto', data['on']['workflow_dispatch']['inputs']['operation']['options'])
        jobs = data['jobs']
        self.assertEqual(jobs['resolve']['outputs']['release'], '${{ steps.version.outputs.release }}')
        for name in ('macos', 'windows'):
            self.assertEqual(jobs[name]['if'], "needs.resolve.outputs.release != 'false'")
        self.assertIn("needs.resolve.outputs.release != 'false'", jobs['publish']['if'])
        self.assertEqual(jobs['publish']['permissions'], {'contents': 'write', 'actions': 'write'})
        continuation = next(s for s in jobs['publish']['steps'] if s.get('name') == 'Release changes merged during this build')
        self.assertEqual(continuation['env']['SOURCE_COMMIT'], '${{ needs.resolve.outputs.source_commit }}')
        self.assertIn("inputs.operation == 'auto'", continuation['if'])

    def test_version_push_refuses_a_concurrent_merge_and_reuses_pending_source(self):
        step = next(s for s in workflow('release.yml')['jobs']['resolve']['steps']
                    if s.get('name') == 'Persist the version and select the exact build source')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, local = root / 'remote.git', root / 'local'
            def git(*args):
                return subprocess.check_output(['git', *args], text=True, stderr=subprocess.PIPE).strip()
            git('init', '--bare', '-q', str(remote))
            git('init', '-q', '-b', 'master', str(local))
            git('-C', str(local), 'remote', 'add', 'origin', str(remote))
            def commit(message):
                git('-C', str(local), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '--allow-empty', '-qm', message)
                return git('-C', str(local), 'rev-parse', 'HEAD')
            candidate = commit('candidate')
            git('-C', str(local), 'push', '-q', 'origin', 'HEAD:master')
            newer = commit('concurrent merge')
            git('-C', str(local), 'push', '-q', 'origin', 'HEAD:master')
            git('-C', str(local), 'checkout', '--detach', '-q', candidate)
            env = {**os.environ, 'SOURCE_COMMIT': candidate, 'CREATED': 'true'}
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', step['run']], cwd=local,
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(git('--git-dir', str(remote), 'rev-parse', 'master'), newer)
            env['CREATED'] = 'false'
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', step['run']], cwd=local,
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(git('-C', str(local), 'rev-parse', 'HEAD'), candidate)
            self.assertEqual(git('--git-dir', str(remote), 'rev-parse', 'master'), newer)

    def test_only_newer_master_dispatches_another_automatic_release(self):
        step = next(s for s in workflow('release.yml')['jobs']['publish']['steps']
                    if s.get('name') == 'Release changes merged during this build')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh, trace = root / 'gh', root / 'dispatch.json'
            gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if sys.argv[1:] == ['api', 'repos/ekho/verbemo/git/ref/heads/master', '--jq', '.object.sha']:
    if os.environ.get('API_FAIL'): sys.exit(1)
    print(os.environ['REMOTE_HEAD'])
else:
    Path(os.environ['TRACE']).write_text(json.dumps(sys.argv[1:]))
''')
            gh.chmod(0o755)
            env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                   'SOURCE_COMMIT': 'a' * 40, 'TRACE': str(trace)}
            for head, fails, dispatches in [('a' * 40, False, False), ('b' * 40, False, True),
                                           ('b' * 40, True, False)]:
                with self.subTest(head=head, api_fails=fails):
                    trace.unlink(missing_ok=True)
                    env['REMOTE_HEAD'] = head
                    env['API_FAIL'] = '1' if fails else ''
                    result = subprocess.run(['bash', '-euo', 'pipefail', '-c', step['run']],
                                            env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, not fails, result.stderr)
                    self.assertEqual(trace.exists(), dispatches)
                    if dispatches:
                        self.assertEqual(json.loads(trace.read_text()), ['workflow', 'run', 'release.yml',
                                         '--repo', 'ekho/verbemo', '--ref', 'master', '-f', 'ref=master',
                                         '-f', 'operation=auto'])

    def test_windows_packaging_file_inputs_exist(self):
        builder = (ROOT / 'windows/scripts/Build-Release.ps1').read_text()
        arguments = builder.split('$arguments = @(', 1)[1].split('$signatureTool =', 1)[0]
        files = re.findall(r"'--(?:icon|releaseNotes)', \(Join-Path \$windowsRoot '([^']+)'\)", arguments)
        self.assertTrue(files, 'Expected checked-in packaging file inputs')
        for name in files:
            with self.subTest(file=name):
                self.assertTrue((ROOT / 'windows' / name).is_file(), f'Missing packaging input: {name}')

    def test_ci_checks_out_and_asserts_exact_event_head_with_full_history(self):
        for name, job in workflow('ci.yml')['jobs'].items():
            with self.subTest(job=name):
                steps = job['steps']
                checkout = next(s for s in steps if s.get('uses', '').startswith('actions/checkout@'))
                self.assertEqual(checkout.get('with', {}).get('ref'),
                                 '${{ github.event.pull_request.head.sha || github.sha }}')
                self.assertEqual(checkout['with']['fetch-depth'], '0')
                proof = next(s for s in steps if s.get('name') == 'Verify source checkout')
                self.assertEqual(steps.index(proof), steps.index(checkout) + 1)
                self.assertEqual(proof['env']['EXPECTED_SOURCE_COMMIT'],
                                 '${{ github.event.pull_request.head.sha || github.sha }}')
                self.assertNotIn('${{', proof['run'])
                self.assertIn('git rev-parse HEAD', proof['run'])
                self.assertIn('git rev-parse --is-shallow-repository', proof['run'])
                if name == 'windows':
                    self.assertEqual(proof['shell'], 'pwsh')
                    self.assertEqual(proof['run'].count("if ($LASTEXITCODE -ne 0) { throw"), 2)
                    self.assertIn("if ($actual -cne $env:EXPECTED_SOURCE_COMMIT) { throw", proof['run'])
                    self.assertIn("if ($shallow -cne 'false') { throw", proof['run'])

    def test_ci_macos_checkout_assertion_rejects_mismatch_and_shallow_history(self):
        proof = next((s for s in workflow('ci.yml')['jobs']['test']['steps']
                      if s.get('name') == 'Verify source checkout'), None)
        self.assertIsNotNone(proof, 'CI must verify the checked-out source before builds')
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(['git', '-C', directory, *args], text=True).strip()
            git('init', '-q')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                'commit', '--allow-empty', '-qm', 'fixture')
            sha = git('rev-parse', 'HEAD')
            for expected, shallow, success in ((sha, False, True), ('0' * 40, False, False),
                                               (sha, True, False)):
                with self.subTest(expected=expected, shallow=shallow):
                    if shallow:
                        (Path(directory) / '.git/shallow').write_text(sha + '\n')
                    result = subprocess.run(['bash', '-euo', 'pipefail', '-c', proof['run']],
                                            cwd=directory, env={**os.environ, 'EXPECTED_SOURCE_COMMIT': expected},
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                    self.assertIn(sha, result.stdout)

    def test_prepare_default_and_only_version_publish_resume_have_write_permission(self):
        data = workflow('release.yml')
        self.assertEqual(data['on']['workflow_dispatch']['inputs']['operation']['default'], 'prepare')
        self.assertEqual(data['permissions'], {'contents': 'read'})
        self.assertEqual(data['concurrency'], {'group': 'verbemo-release', 'cancel-in-progress': 'false'})
        writers = {name for name, job in data['jobs'].items() if job.get('permissions', {}).get('contents') == 'write'}
        self.assertEqual(writers, {'resolve', 'publish', 'resume'})
        self.assertFalse((ROOT / '.github/workflows/windows-beta.yml').exists())

    def test_both_builds_use_one_resolved_commit_with_full_history(self):
        jobs = workflow('release.yml')['jobs']
        self.assertEqual(set(jobs['aggregate']['needs']), {'resolve', 'macos', 'windows'})
        for platform in ('macos', 'windows'):
            job = jobs[platform]
            self.assertEqual(job['needs'], 'resolve')
            checkout = next(s for s in job['steps'] if s.get('uses', '').startswith('actions/checkout@'))
            self.assertEqual(checkout['with']['ref'], '${{ needs.resolve.outputs.source_commit }}')
            self.assertEqual(checkout['with']['fetch-depth'], '0')
        for job in jobs.values():
            for step in job['steps']:
                self.assertNotIn('${{ inputs.', step.get('run', ''))

    def test_resume_has_no_build_signing_artifact_or_dependency(self):
        job = workflow('release.yml')['jobs']['resume']
        self.assertNotIn('needs', job)
        self.assertNotIn('secrets.', str(job))
        self.assertNotIn('upload-artifact', str(job))
        runs = '\n'.join(s.get('run', '') for s in job['steps'])
        self.assertIn('release.py resume --tag', runs)
        self.assertNotIn('Build-Release', runs)

    def test_own_credentials_are_scoped_to_signing_steps_and_cleaned(self):
        jobs = workflow('release.yml')['jobs']
        for name, job in jobs.items():
            self.assertNotIn('secrets.', str(job.get('env', {})))
            for step in job['steps']:
                if 'secrets.' in str(step):
                    self.assertIn(name, ('macos', 'windows'))
                    self.assertIn('Build signed', step['name'])
                    self.assertIn('VERBEMO_', str(step['env']))
        mac = next(s for s in jobs['macos']['steps'] if 'Build signed' in s.get('name', ''))
        for key in ('MACOS_CERTIFICATE', 'NOTARY_KEY', 'SPARKLE_PRIVATE_KEY'):
            self.assertIn('VERBEMO_' + key + '_BASE64', mac['env'])
        self.assertIn('trap cleanup EXIT', mac['run'])
        self.assertIn('security delete-keychain', mac['run'])
        win = next(s for s in jobs['windows']['steps'] if 'Build signed' in s.get('name', ''))
        self.assertIn('finally', win['run'])
        self.assertIn('Remove-Item -LiteralPath $keyDir', win['run'])

    def test_push_pr_ci_builds_both_without_secrets_and_retains_metadata_checks(self):
        data = workflow('ci.yml')
        self.assertIn('push', data['on'])
        self.assertIn('pull_request', data['on'])
        self.assertEqual(data['permissions'], {'contents': 'read'})
        self.assertNotIn('secrets.', str(data))
        mac = '\n'.join(s.get('run', '') for s in data['jobs']['test']['steps'])
        win = '\n'.join(s.get('run', '') for s in data['jobs']['windows']['steps'])
        self.assertIn('swift test --no-parallel', mac)
        self.assertIn('make app SIGN_ID=-', mac)
        self.assertIn('test_independent_product.py --all', mac)
        self.assertIn('Test-ReleaseInstallerName.ps1', win)
        self.assertIn('Test-ReleaseArtifacts.ps1', win)
        self.assertIn('-Development', win)
        builder = (ROOT / 'windows/scripts/Build-Release.ps1').read_text()
        self.assertIn('Verbemo.Core.Tests', builder)
        self.assertIn('Verbemo.Live.Tests', builder)
        self.assertIn('dotnet publish', builder)

    def test_windows_development_artifacts_are_checked_and_retained_without_publication(self):
        job = workflow('ci.yml')['jobs']['windows']
        steps = job['steps']
        native = next(s for s in steps if s.get('name') == 'Verify packaged native CPU and Unicode paths')
        self.assertIn('Verbemo-$version-windows-x64-Portable.zip', native['run'])
        self.assertIn("'current/local-runtime'", native['run'])
        self.assertIn('Test-NativeCpu.ps1 -RuntimeDirectory $runtime', native['run'])
        self.assertIn('Test-NativeUnicodePaths.ps1 -RuntimeDirectory $runtime', native['run'])
        self.assertIn('finally', native['run'])
        upload = next(s for s in steps if s.get('uses', '').startswith('actions/upload-artifact@'))
        self.assertLess(steps.index(native), steps.index(upload))
        self.assertEqual(upload['with']['retention-days'], '7')
        self.assertEqual(upload['with']['if-no-files-found'], 'error')
        self.assertIn('windows-development', upload['with']['name'])
        self.assertIn('${{ github.sha }}', upload['with']['name'])
        self.assertEqual(upload['with']['path'], '${{ runner.temp }}/verbemo-development/*')
        self.assertNotIn('gh release', str(job))
        self.assertNotIn('release.py publish', str(job))
        self.assertNotIn('secrets.', str(job))

    def test_readme_downloads_use_read_only_own_public_manifest_policy(self):
        data = workflow('readme-downloads.yml')
        self.assertEqual(data['permissions'], {'contents': 'read'})
        self.assertNotIn('workflow_run', data['on'])
        steps = data['jobs']['verify']['steps']
        checkout = next(step for step in steps if step.get('uses', '').startswith('actions/checkout@'))
        self.assertEqual(checkout['with']['ref'], 'master')
        self.assertEqual(checkout['with']['persist-credentials'], 'false')
        self.assertEqual([step['run'] for step in steps if 'run' in step],
                         ['python3 scripts/update-readme-downloads.py --check --public'])
        self.assertNotIn('secrets.', str(data))
        self.assertNotIn('contents: write', str(data))


if __name__ == '__main__':
    unittest.main()
