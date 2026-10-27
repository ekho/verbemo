"""Exercise the actual DMG, including Finder metadata and copied app signatures."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / 'scripts/build-dmg.sh'


@unittest.skipUnless(sys.platform == 'darwin', 'DMG packaging requires macOS')
class DMGTests(unittest.TestCase):
    def run_command(self, *args):
        result = subprocess.run(args, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout.decode() + result.stderr.decode())
        return result.stdout

    def test_image_preserves_signed_app_and_portable_retina_layout(self):
        self.assertTrue(BUILDER.is_file(), 'shared DMG builder is missing')
        from ds_store import DSStore
        from mac_alias import Alias

        with tempfile.TemporaryDirectory(prefix="verbemo dmg ' юникод ") as directory:
            work = Path(directory)
            app = work / 'input/Verbemo.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Resources').mkdir()
            shutil.copyfile('/usr/bin/true', app / 'Contents/MacOS/verbemo')
            (app / 'Contents/MacOS/verbemo').chmod(0o755)
            (app / 'Contents/Resources/target.txt').write_text('preserve me')
            (app / 'Contents/Resources/link.txt').symlink_to('target.txt')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'verbemo', 'CFBundleIdentifier': 'name.ekho.verbemo.dmg-test',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            }))
            self.run_command('codesign', '--force', '--sign', '-', str(app))
            seal = (app / 'Contents/_CodeSignature/CodeResources').read_bytes()
            dmg = work / 'Test Preview.dmg'
            self.run_command('bash', str(BUILDER), str(app), 'Verbemo DMG Test Preview', str(dmg))
            mount = work / 'mounted'
            mount.mkdir()
            self.run_command('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg))
            try:
                self.assertEqual(os.readlink(mount / 'Applications'), '/Applications')
                self.assertEqual((mount / '.VolumeIcon.icns').read_bytes(),
                                 (ROOT / 'Resources/Verbemo.icns').read_bytes())
                with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
                    app_position = store['Verbemo.app']['Iloc']
                    target_position = store['Applications']['Iloc']
                    self.assertLess(app_position[0], target_position[0])
                    self.assertEqual(app_position[1], target_position[1])
                    view = store['.']['icvp']
                    alias = Alias.from_bytes(view['backgroundImageAlias'])
                    self.assertEqual(alias.volume.name, 'Verbemo DMG Test Preview')
                    self.assertEqual(alias.target.filename, '.background.tiff')
                    self.assertEqual(view['backgroundType'], 2)
                    self.assertFalse(store['.']['bwsp']['ShowToolbar'])
                background = mount / '.background.tiff'
                self.assertTrue(background.is_file())
                # AppKit reports logical size separately from the 1x/2x pixel sizes.
                representations = self.run_command('swift', '-e', r'''
import AppKit
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
for rep in NSBitmapImageRep.imageReps(with: data) {
    print("\(rep.pixelsWide)x\(rep.pixelsHigh) \(Int(rep.size.width))x\(Int(rep.size.height))")
}
''', str(background)).decode().splitlines()
                self.assertEqual(set(representations), {'660x420 660x420', '1320x840 660x420'})
                installed = work / 'copied/Verbemo.app'
                self.run_command('ditto', str(mount / 'Verbemo.app'), str(installed))
                self.run_command('codesign', '--verify', '--deep', '--strict', str(installed))
                self.assertEqual((installed / 'Contents/_CodeSignature/CodeResources').read_bytes(), seal)
                self.assertEqual(os.readlink(installed / 'Contents/Resources/link.txt'), 'target.txt')
                self.assertTrue(os.access(installed / 'Contents/MacOS/verbemo', os.X_OK))
            finally:
                self.run_command('hdiutil', 'detach', str(mount))
            self.assertEqual((app / 'Contents/_CodeSignature/CodeResources').read_bytes(), seal)

    def test_existing_output_is_never_overwritten(self):
        self.assertTrue(BUILDER.is_file(), 'shared DMG builder is missing')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'existing.dmg'
            output.write_bytes(b'keep published bytes')
            app = Path(directory) / 'Verbemo.app'
            app.mkdir()
            result = subprocess.run(['bash', str(BUILDER), str(app), 'Test', str(output)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('already exists', result.stderr)
            self.assertEqual(output.read_bytes(), b'keep published bytes')

    def test_missing_app_fails_without_creating_an_image(self):
        self.assertTrue(BUILDER.is_file(), 'shared DMG builder is missing')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'absent.dmg'
            result = subprocess.run(['bash', str(BUILDER), str(Path(directory) / 'missing.app'),
                                     'Test', str(output)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_failed_final_flush_removes_only_its_new_output(self):
        # Run the builder's publisher alone so a file-size limit affects its close,
        # rather than hdiutil's earlier writes of the source image.
        publisher = BUILDER.read_text().split("<<'PY'\n", 1)[1].split('\nPY', 1)[0]
        limit = '''
import resource, signal
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
resource.setrlimit(resource.RLIMIT_FSIZE, (65536, 65536))
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'source.dmg'
            source.write_bytes(b'x' * 65537)
            for existing in (False, True):
                with self.subTest(existing=existing):
                    output = Path(directory) / 'output.dmg'
                    if existing:
                        output.write_bytes(b'keep published bytes')
                    result = subprocess.run([sys.executable, '-c', limit + publisher,
                                             str(source), str(output)], capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    if existing:
                        self.assertEqual(output.read_bytes(), b'keep published bytes')
                    else:
                        self.assertFalse(output.exists(), 'failed final flush left a partial DMG')


if __name__ == '__main__':
    unittest.main()
