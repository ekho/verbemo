from pathlib import Path
import os
import re
import json
import importlib.util
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


def workflow(name):
    return yaml.load((ROOT / '.github/workflows' / name).read_text(), Loader=yaml.BaseLoader)


class CommonReleaseWorkflowTests(unittest.TestCase):
    def test_preview_distribution_uses_no_release_credentials_and_keeps_signed_mode(self):
        data = workflow('release.yml')
        distribution = data['on']['workflow_dispatch']['inputs'].get('distribution', {})
        self.assertEqual(distribution.get('default'), 'preview')
        self.assertEqual(distribution.get('options'), ['preview', 'signed'])
        jobs = data['jobs']
        self.assertEqual(jobs['resolve']['outputs']['prerelease'], '${{ steps.distribution.outputs.prerelease }}')
        for platform in ('macos', 'windows'):
            steps = jobs[platform]['steps']
            preview = next(s for s in steps if s.get('name') == f'Build unsigned {platform} preview artifacts')
            self.assertEqual(preview['if'], "needs.resolve.outputs.prerelease == 'true'")
            self.assertNotIn('secrets.', str(preview))
            signed = next(s for s in steps if s.get('name', '').startswith('Build signed'))
            self.assertEqual(signed['if'], "needs.resolve.outputs.prerelease != 'true'")

    def test_pr_ci_validates_both_platform_artifact_sets_without_publication(self):
        data = workflow('ci.yml')
        job = data['jobs'].get('preview', {})
        self.assertEqual(set(job.get('needs', [])), {'macos-build', 'windows-build'})
        self.assertNotIn('secrets.', str(job))
        self.assertNotIn('permissions', job)
        command = '\n'.join(step.get('run', '') for step in job['steps'])
        self.assertIn('release.py prepare', command)
        for flag in ('--prerelease', '--dry-run'):
            self.assertIn(flag, command)
        self.assertNotIn('release.py publish', command)

    def test_both_platforms_are_enabled_and_downloaded_by_exact_id(self):
        ci, release = workflow('ci.yml'), workflow('release.yml')
        self.assertEqual(ci['jobs']['windows']['if'], "needs.changes.outputs.windows_test == 'true'")
        self.assertEqual(release['jobs']['windows']['if'], "needs.resolve.outputs.release != 'false'")
        for data, sources, consumer in ((ci, ('macos-build', 'windows-build'), 'preview'),
                                        (release, ('macos', 'windows'), 'aggregate')):
            for source in sources:
                self.assertEqual(data['jobs'][source]['outputs']['artifact_id'], '${{ steps.artifacts.outputs.artifact-id }}')
                upload = next(s for s in data['jobs'][source]['steps'] if s.get('id') == 'artifacts')
                self.assertTrue(upload['uses'].startswith('actions/upload-artifact@'))
            download = next(s for s in data['jobs'][consumer]['steps'] if s.get('uses', '').startswith('actions/download-artifact@'))
            self.assertEqual(download['with']['artifact-ids'], ','.join('${{ needs.' + source + '.outputs.artifact_id }}' for source in sources))
            self.assertEqual(download['with']['merge-multiple'], 'true')
            self.assertNotIn('--macos-only', str(data))
        step = next(s for s in release['jobs']['resolve']['steps'] if s.get('id') == 'distribution')
        for distribution, expected in (('preview', 'true'), ('signed', 'false')):
            with self.subTest(distribution=distribution), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'output'
                env = {**os.environ, 'GITHUB_OUTPUT': str(output), 'DISTRIBUTION': distribution}
                result = subprocess.run(['bash', '-euo', 'pipefail', '-c', step['run']], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(), f'prerelease={expected}\n')

    def test_both_platform_artifacts_are_validated_from_the_merged_download_directory(self):
        spec = importlib.util.spec_from_file_location('workflow_manifest', ROOT / 'scripts/release_manifest.py')
        manifest = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(manifest)
        spec = importlib.util.spec_from_file_location('workflow_fixtures', ROOT / 'Tests/scripts/test_release_manifest.py')
        fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixtures)
        version = (ROOT / 'VERSION').read_text().strip()
        source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        build = int(subprocess.check_output(['git', 'rev-list', '--count', 'HEAD'], cwd=ROOT, text=True))
        for filename, job_name, writes_metadata in (('ci.yml', 'preview', False), ('release.yml', 'aggregate', True)):
            with self.subTest(workflow=filename), tempfile.TemporaryDirectory() as directory:
                job = workflow(filename)['jobs'][job_name]
                download = next(s for s in job['steps'] if s.get('uses', '').startswith('actions/download-artifact@'))
                artifacts = Path(download['with']['path'].replace('${{ runner.temp }}', directory))
                artifacts.mkdir()
                (artifacts / manifest.dmg_name(version)).write_bytes(b'ad-hoc preview DMG')
                manifest.write_macos_receipt(artifacts, version, source, build, prerelease=True)
                helper = fixtures.WindowsManifestTests()
                helper.module = manifest
                receipt = helper.fixture(artifacts, version=version, commit=source, build=build)
                receipt['publishable'] = False
                receipt['signature'] = {'authenticode': 'unsigned-development', 'timestamp': 'unverified',
                                        'certificate_thumbprint': None}
                (artifacts / 'windows-build.json').write_text(json.dumps(receipt))
                step = next(s for s in job['steps'] if 'release.py prepare' in s.get('run', ''))
                env = {**os.environ, 'RUNNER_TEMP': directory, 'RELEASE_VERSION': version,
                       'SOURCE_COMMIT': source, 'BUILD_NUMBER': str(build), 'PRERELEASE': 'true'}
                result = subprocess.run(['bash', '-euo', 'pipefail', '-c', step['run']], cwd=ROOT,
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('platforms', json.loads(result.stdout))
                self.assertEqual((artifacts / 'release-manifest.json').exists(), writes_metadata)
                self.assertEqual((artifacts / 'SHA256SUMS').exists(), writes_metadata)

    def test_automatic_release_uses_the_version_commit_and_gates_both_platforms(self):
        data = workflow('release.yml')
        self.assertEqual(data['on'].get('push', {}).get('branches'), ['master'])
        self.assertIn('auto', data['on']['workflow_dispatch']['inputs']['operation']['options'])
        jobs = data['jobs']
        self.assertEqual(jobs['resolve']['outputs']['release'], '${{ steps.version.outputs.release }}')
        for platform in ('macos', 'windows'):
            self.assertEqual(jobs[platform]['if'], "needs.resolve.outputs.release != 'false'")
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
                   'SOURCE_COMMIT': 'a' * 40, 'TRACE': str(trace), 'DISTRIBUTION': 'preview'}
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
                                         '-f', 'operation=auto', '-f', 'distribution=preview'])

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
                if name == 'result':
                    continue
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
                if name in ('windows', 'windows-build'):
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

    def test_push_pr_ci_retains_both_platform_routes_without_secrets(self):
        data = workflow('ci.yml')
        self.assertIn('push', data['on'])
        self.assertIn('pull_request', data['on'])
        self.assertEqual(data['permissions'], {'contents': 'read'})
        self.assertNotIn('secrets.', str(data))
        mac = '\n'.join(s.get('run', '') for s in data['jobs']['test']['steps'])
        win = '\n'.join(s.get('run', '') for s in data['jobs']['windows']['steps'])
        self.assertIn('swift test --no-parallel', mac)
        self.assertNotIn('build-macos-preview.sh', mac)
        changes = str(data['jobs']['changes'])
        self.assertIn('test_independent_product.py --all', changes)
        self.assertIn('build-macos-preview.sh', str(data['jobs']['macos-build']))
        self.assertIn('Test-ReleaseInstallerName.ps1', win)
        self.assertIn('Test-ReleaseArtifacts.ps1', win)
        self.assertIn('-Development -SkipTests', str(data['jobs']['windows-build']))
        self.assertNotIn('Build-Release.ps1', win)
        self.assertIn('Verbemo.Core.Tests', win)
        self.assertIn('Verbemo.Live.Tests', win)
        builder = (ROOT / 'windows/scripts/Build-Release.ps1').read_text()
        self.assertIn('Verbemo.Core.Tests', builder)
        self.assertIn('Verbemo.Live.Tests', builder)
        self.assertIn('dotnet publish', builder)

    def test_windows_development_artifacts_are_checked_and_retained_without_publication(self):
        job = workflow('ci.yml')['jobs']['windows-build']
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

    def test_platform_tests_and_builds_are_separate_and_skips_are_reported(self):
        jobs = workflow('ci.yml')['jobs']
        self.assertIn('macos-build', jobs)
        self.assertIn('windows-build', jobs)
        for name, flag in (('macos-build', 'macos_build'), ('windows-build', 'windows_build')):
            self.assertEqual(jobs[name]['if'], f"needs.changes.outputs.{flag} == 'true'")
        self.assertEqual(set(jobs['windows-build']['needs']), {'changes', 'windows'})
        self.assertEqual(jobs['checks']['runs-on'], 'ubuntu-latest')
        self.assertIn('always()', jobs['result']['if'])
        self.assertEqual(set(jobs['result']['needs']),
                         {'changes', 'checks', 'test', 'windows', 'macos-build', 'windows-build', 'preview'})
        self.assertIn("needs['macos-build'].result == 'success'", jobs['preview']['if'])
        self.assertIn("needs['windows-build'].result == 'success'", jobs['preview']['if'])
        # The result command must reject real failures while allowing intentional skips.
        step = jobs['result']['steps'][0]
        for result, success in [('success', True), ('skipped', True), ('failure', False), ('cancelled', False)]:
            with self.subTest(result=result):
                env = {**os.environ, 'NEEDS': json.dumps({'check': {'result': result}})}
                run = subprocess.run(['bash', '-euo', 'pipefail', '-c', step['run']],
                                     env=env, capture_output=True, text=True)
                self.assertEqual(run.returncode == 0, success, run.stdout + run.stderr)

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
