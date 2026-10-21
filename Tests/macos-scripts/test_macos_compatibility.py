import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts" / "verify-macos-compatibility.py"


class MacOSCompatibilityTests(unittest.TestCase):
    def test_accepts_an_app_whose_bundle_and_binary_run_on_the_declared_minimum(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Verbemo.app"
            executable = app / "Contents" / "MacOS" / "Verbemo"
            executable.parent.mkdir(parents=True)
            with (app / "Contents" / "Info.plist").open("wb") as destination:
                plistlib.dump({"LSMinimumSystemVersion": "14.2"}, destination)

            source = Path(temporary) / "main.c"
            source.write_text("int main(void) { return 0; }\n")
            subprocess.run([
                "xcrun", "clang", "-target", "arm64-apple-macos14.2",
                str(source), "-o", str(executable),
            ], check=True)

            completed = subprocess.run(
                ["python3", str(CHECKER), str(app), "14.2"],
                capture_output=True, text=True, check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("compatible with macOS 14.2", completed.stdout)

    def test_rejects_a_bundle_without_its_declared_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Verbemo.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            with (contents / "Info.plist").open("wb") as destination:
                plistlib.dump({
                    "CFBundleExecutable": "Verbemo",
                    "LSMinimumSystemVersion": "14.2",
                }, destination)

            completed = subprocess.run(
                ["python3", str(CHECKER), str(app), "14.2"],
                capture_output=True, text=True, check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("declared executable is missing", completed.stderr)

    def test_rejects_a_nested_binary_that_requires_a_newer_macos(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Verbemo.app"
            executable = app / "Contents" / "MacOS" / "Verbemo"
            framework = app / "Contents" / "Frameworks" / "Newer.dylib"
            executable.parent.mkdir(parents=True)
            framework.parent.mkdir(parents=True)
            with (app / "Contents" / "Info.plist").open("wb") as destination:
                plistlib.dump({
                    "CFBundleExecutable": "Verbemo",
                    "LSMinimumSystemVersion": "14.2",
                }, destination)

            source = Path(temporary) / "main.c"
            source.write_text("int main(void) { return 0; }\n")
            subprocess.run([
                "xcrun", "clang", "-target", "arm64-apple-macos14.2",
                str(source), "-o", str(executable),
            ], check=True)
            subprocess.run([
                "xcrun", "clang", "-target", "arm64-apple-macos15.0",
                "-dynamiclib", str(source), "-o", str(framework),
            ], check=True)

            completed = subprocess.run(
                ["python3", str(CHECKER), str(app), "14.2"],
                capture_output=True, text=True, check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("Newer.dylib: Mach-O requires macOS 15.0", completed.stderr)

    def test_rejects_a_nested_bundle_that_advertises_a_newer_macos(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Verbemo.app"
            executable = app / "Contents" / "MacOS" / "Verbemo"
            nested_info = app / "Contents" / "Frameworks" / "Updater.app" / "Contents" / "Info.plist"
            executable.parent.mkdir(parents=True)
            nested_info.parent.mkdir(parents=True)
            with (app / "Contents" / "Info.plist").open("wb") as destination:
                plistlib.dump({
                    "CFBundleExecutable": "Verbemo",
                    "LSMinimumSystemVersion": "14.2",
                }, destination)
            with nested_info.open("wb") as destination:
                plistlib.dump({"LSMinimumSystemVersion": "15.0"}, destination)

            source = Path(temporary) / "main.c"
            source.write_text("int main(void) { return 0; }\n")
            subprocess.run([
                "xcrun", "clang", "-target", "arm64-apple-macos14.2",
                str(source), "-o", str(executable),
            ], check=True)

            completed = subprocess.run(
                ["python3", str(CHECKER), str(app), "14.2"],
                capture_output=True, text=True, check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("Updater.app/Contents/Info.plist: requires macOS 15.0", completed.stderr)


if __name__ == "__main__":
    unittest.main()
