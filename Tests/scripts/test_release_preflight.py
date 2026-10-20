import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        for name in ('build-macos-release.sh', 'release_manifest.py'):
            source = ROOT / 'scripts' / name
            self.assertTrue(source.is_file(), f'missing {name}')
            shutil.copyfile(source, self.root / 'scripts' / name)
        (self.root / 'VERSION').write_text('0.1.0\n')
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'core.excludesFile', os.devnull)
        (self.root / '.git/info/exclude').write_text('')
        self.git('remote', 'add', 'origin', 'git@github.com:ekho/verbemo.git')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.sha = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def run_builder(self, expected, version='0.1.0', commit=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith('VERBEMO_')}
        result = subprocess.run(['bash', str(self.root / 'scripts/build-macos-release.sh'),
                                 '--version', version, '--source-commit', commit or self.sha,
                                 '--output', str(self.root / 'dist')], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stderr)
        self.assertFalse((self.root / '.build').exists())
        self.assertFalse((self.root / 'dist').exists())

    def test_missing_credentials_stop_before_build_or_network(self):
        self.run_builder('VERBEMO_SIGN_ID')

    def test_preview_preflight_checks_source_without_requiring_certificates(self):
        command = [sys.executable, '-B', str(self.root / 'scripts/release_manifest.py'), 'preflight',
                   '--root', str(self.root), '--version', '0.1.0', '--source-commit', self.sha,
                   '--output', str(self.root / 'dist'), '--prerelease']
        env = {key: value for key, value in os.environ.items() if not key.startswith('VERBEMO_')}
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '1')
        self.assertFalse((self.root / 'dist').exists())
        self.git('remote', 'set-url', 'origin', 'https://github.com/other/repo.git')
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('origin', result.stderr)

    def test_preview_builder_stops_before_building_from_the_wrong_repository(self):
        script = self.root / 'scripts/build-macos-preview.sh'
        shutil.copyfile(ROOT / 'scripts/build-macos-preview.sh', script)
        self.git('add', '.')
        self.git('commit', '-qm', 'preview builder')
        sha = self.git('rev-parse', 'HEAD')
        self.git('remote', 'set-url', 'origin', 'https://github.com/other/repo.git')
        result = subprocess.run(['bash', str(script), '--version', '0.1.0', '--source-commit', sha,
                                 '--output', str(self.root / 'dist')], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('origin', result.stderr)
        self.assertFalse((self.root / '.build').exists())
        self.assertFalse((self.root / 'dist').exists())

    def test_historical_tags_do_not_impose_a_version_floor(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('fixture_manifest', self.root / 'scripts/release_manifest.py')
        module = importlib.util.module_from_spec(spec)
        with patch('sys.pycache_prefix', None), patch('sys.dont_write_bytecode', False):
            with patch('sys.dont_write_bytecode', True):
                spec.loader.exec_module(module)
            self.assertFalse(sys.dont_write_bytecode)
        self.assertEqual(self.git('status', '--porcelain', '--untracked-files=all'), '')
        self.git('tag', 'v99.0.0')
        self.assertEqual(module.validate_source(self.root, '0.1.0', self.sha), 1)
        (self.root / 'VERSION').write_text('0.1.1\n')
        with self.assertRaisesRegex(ValueError, 'dirty'):
            module.validate_source(self.root, '0.1.0', self.sha)

    def test_cold_cli_and_ordinary_import_caches_preserve_clean_source(self):
        for name in ('release.py', 'release_github.py'):
            shutil.copyfile(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        shutil.copyfile(ROOT / '.gitignore', self.root / '.gitignore')
        self.git('add', '.')
        self.git('commit', '-qm', 'production CLI fixture')
        sha = self.git('rev-parse', 'HEAD')
        self.assertFalse((self.root / 'scripts/__pycache__').exists())
        # Override Apple Python's external cache and any inherited -B setting.
        normal_python = ('import sys; sys.pycache_prefix = None; '
                         'sys.dont_write_bytecode = False; sys.path.insert(0, "scripts"); ')

        def preflight():
            return subprocess.run([sys.executable, '-c', normal_python +
                                   'import runpy; sys.argv = ["scripts/release.py", '
                                   '"preflight", "--ref", "HEAD", "--version", "0.1.0"]; '
                                   'runpy.run_path("scripts/release.py", run_name="__main__")'],
                                  cwd=self.root, capture_output=True, text=True)

        for state in ('cold', 'after ordinary imports'):
            with self.subTest(state=state):
                if state != 'cold':
                    shutil.rmtree(self.root / 'scripts/__pycache__')
                    subprocess.run([sys.executable, '-c', normal_python +
                                    'import release_manifest, release_github'],
                                   cwd=self.root, check=True, capture_output=True, text=True)
                result = preflight()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout),
                                 {'source_commit': sha, 'version': '0.1.0', 'build_number': 2})
                self.assertTrue(list((self.root / 'scripts/__pycache__').glob('*.pyc')))
                self.assertEqual(self.git('status', '--porcelain', '--untracked-files=all'), '')

        for name, content in (('VERSION', '0.1.1\n'), ('unrelated.py', '# untracked source\n')):
            with self.subTest(dirty_source=name):
                path = self.root / name
                path.write_text(content)
                result = preflight()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('working tree is dirty', result.stderr)
                if name == 'VERSION':
                    path.write_text('0.1.0\n')
                else:
                    path.unlink()

    def test_wrong_origin(self):
        self.git('remote', 'set-url', 'origin', 'git@github.com:somebody/other.git')
        self.run_builder('origin')

    def test_wrong_version(self):
        self.run_builder('VERSION', version='0.2.0')

    def test_wrong_sha(self):
        self.run_builder('source commit', commit='a' * 40)

    def test_dirty_tree(self):
        (self.root / 'VERSION').write_text('0.1.0\n#dirty')
        self.run_builder('dirty')

    def test_shallow_history(self):
        (self.root / '.git/shallow').write_text(self.sha + '\n')
        self.run_builder('shallow')

    def test_existing_versioned_dmg_is_never_replaced(self):
        (self.root / 'dist').mkdir()
        dmg = self.root / 'dist/Verbemo-0.1.0-macos-universal.dmg'
        dmg.write_bytes(b'published bytes')
        # Keep the output ignored as in a real checkout.
        (self.root / '.git/info/exclude').write_text('dist/\n')
        result = subprocess.run(['bash', str(self.root / 'scripts/build-macos-release.sh'), '--version',
                                 '0.1.0', '--source-commit', self.sha, '--output', str(dmg.parent)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exists', result.stderr)
        self.assertEqual(dmg.read_bytes(), b'published bytes')


if __name__ == '__main__':
    unittest.main()
