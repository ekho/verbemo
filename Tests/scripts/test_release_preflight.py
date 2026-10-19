import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

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

    def test_historical_tags_do_not_impose_a_version_floor(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('fixture_manifest', self.root / 'scripts/release_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.git('tag', 'v99.0.0')
        self.assertEqual(module.validate_source(self.root, '0.1.0', self.sha), 1)

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
