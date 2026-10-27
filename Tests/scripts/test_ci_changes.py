import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/ci_changes.py'


class ChangesTests(unittest.TestCase):
    def select(self, paths):
        self.assertTrue(SCRIPT.is_file(), 'CI needs a tested change selector')
        spec = importlib.util.spec_from_file_location('ci_changes', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return {key for key, enabled in module.select_checks(paths).items() if enabled}

    def test_platform_and_tool_changes_select_their_consumers(self):
        cases = [
            ('Sources/verbemo/Config.swift', {'macos_test', 'macos_build'}),
            ('Tests/verbemoTests/ConfigTests.swift', {'macos_test'}),
            ('Tests/QuietTestWindows/QuietTestWindows.m', {'macos_test'}),
            ('windows/src/Verbemo.App/Config.cs', {'windows_test', 'windows_build'}),
            ('windows/src/Verbemo.App/App.xaml.cs', {'windows_test', 'windows_build', 'scripts'}),
            ('windows/tests/Verbemo.Core.Tests/ConfigTests.cs', {'windows_test'}),
            ('windows/tests/Verbemo.Live.Harness/Program.cs', {'windows_test'}),
            ('landing/index.html', {'landing', 'scripts'}),
            ('README.md', {'scripts'}),
            ('.gitignore', {'scripts'}),
            ('windows/README.md', {'scripts'}),
            ('windows/BETA.md', {'scripts'}),
            ('windows/LIVE_TRANSCRIPTION.md', {'scripts'}),
            ('windows/packaging/README.md', {'scripts'}),
            ('windows/src/Verbemo.App/Assets/Verbemo.ico', {'windows_test', 'windows_build', 'scripts'}),
            ('docs/releasing.md', {'scripts'}),
            ('docs/superpowers/plans/example.md', set()),
            ('AGENTS.md', set()),
            ('scripts/release-automation/auto-release.mjs', {'automation', 'scripts'}),
            ('Tests/scripts/auto-release.test.mjs', {'automation'}),
            ('Tests/scripts/test_common_release.py', {'scripts'}),
            ('Tests/macos-scripts/test_app_icon.py', {'macos_scripts'}),
            ('windows/tests/test_workflow_safety.py', {'scripts'}),
            ('windows/tests/Test-ReleaseArtifacts.ps1', {'windows_test', 'scripts'}),
            ('windows/scripts/Build-Release.ps1', {'windows_test', 'windows_build', 'scripts'}),
            ('scripts/build-macos-preview.sh', {'macos_test', 'macos_build', 'macos_scripts', 'scripts'}),
            ('Package.resolved', {'macos_test', 'macos_build', 'scripts'}),
        ]
        for path, expected in cases:
            with self.subTest(path=path):
                self.assertEqual(self.select([path]), expected)

    def test_shared_inputs_and_unknown_build_files_fail_safe(self):
        both = {'macos_test', 'macos_build', 'windows_test', 'windows_build', 'scripts', 'macos_scripts'}
        for path in ('VERSION', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'scripts/release_manifest.py'):
            with self.subTest(path=path):
                self.assertEqual(self.select([path]), both)
        all_checks = both | {'landing', 'automation'}
        for path in ('.github/workflows/ci.yml', 'scripts/ci_changes.py', 'new-build.config'):
            with self.subTest(path=path):
                self.assertEqual(self.select([path]), all_checks)
        self.assertEqual(self.select([]), set())
        self.assertEqual(self.select(['Sources/verbemo/Config.swift', 'windows/src/New.cs']),
                         {'macos_test', 'macos_build', 'windows_test', 'windows_build'})

    def test_event_diff_handles_pr_history_push_deletions_and_renames(self):
        self.assertTrue(SCRIPT.is_file(), 'CI needs a tested change selector')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q', '-b', 'master')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            git('config', 'commit.gpgsign', 'false')
            def commit(path):
                file = root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('fixture')
                git('add', '.')
                git('commit', '-qm', 'fixture')
                return git('rev-parse', 'HEAD')
            base = commit('README.md')
            git('checkout', '-qb', 'feature')
            commit('Sources/verbemo/Config.swift')
            head = commit('docs/note.md')
            git('checkout', '-q', 'master')
            newer_base = commit('windows/src/New.cs')
            git('checkout', '-q', 'feature')
            def run(event_name, event):
                event_file, output = root / 'event.json', root / 'output'
                event_file.write_text(json.dumps(event))
                output.unlink(missing_ok=True)
                env = {**os.environ, 'GITHUB_EVENT_NAME': event_name,
                       'GITHUB_EVENT_PATH': str(event_file), 'GITHUB_OUTPUT': str(output)}
                result = subprocess.run([sys.executable, str(SCRIPT)], cwd=root, env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return {key for key, value in (line.split('=') for line in output.read_text().splitlines())
                        if value == 'true'}
            self.assertEqual(run('pull_request', {'pull_request': {'base': {'sha': newer_base}, 'head': {'sha': head}}}),
                             {'macos_test', 'macos_build'})
            self.assertEqual(run('push', {'before': base, 'after': head}), {'macos_test', 'macos_build'})
            (root / 'windows/src').mkdir(parents=True)
            git('mv', 'Sources/verbemo/Config.swift', 'windows/src/Moved.cs')
            git('commit', '-qm', 'rename across platforms')
            renamed = git('rev-parse', 'HEAD')
            self.assertEqual(run('push', {'before': head, 'after': renamed}),
                             {'macos_test', 'macos_build', 'windows_test', 'windows_build'})
            git('rm', 'windows/src/Moved.cs')
            git('commit', '-qm', 'delete')
            self.assertEqual(run('push', {'before': renamed, 'after': git('rev-parse', 'HEAD')}),
                             {'windows_test', 'windows_build'})
            for before in ('0' * 40, 'f' * 40):
                self.assertEqual(len(run('push', {'before': before, 'after': head})), 8)
            self.assertEqual(len(run('workflow_dispatch', {})), 8)


if __name__ == '__main__':
    unittest.main()
