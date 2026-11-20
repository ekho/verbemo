import json
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "Resources" / "Verbemo.icon"
CLASSIC_ICON = ROOT / "Resources" / "Verbemo.icns"
BUILD_SCRIPT = ROOT / "scripts" / "build-app-icon.sh"


@unittest.skipUnless(sys.platform == "darwin", "icon generation uses AppKit")
class IconGenerationTests(unittest.TestCase):
    def test_one_source_generates_all_platform_sizes(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = subprocess.run(
                ["swift", str(ROOT / "scripts" / "make-icon.swift"), str(output)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            classic = (output / "Resources/Verbemo.icns").read_bytes()
            self.assertEqual(classic[:4], b"icns")
            self.assertEqual(struct.unpack(">I", classic[4:8])[0], len(classic))

            windows = (output / "windows/src/Verbemo.App/Assets/Verbemo.ico").read_bytes()
            self.assertEqual(struct.unpack("<HHH", windows[:6]), (0, 1, 7))
            sizes = []
            for index in range(7):
                width, height, _, _, planes, depth, length, offset = struct.unpack_from(
                    "<BBBBHHII", windows, 6 + index * 16)
                width, height = width or 256, height or 256
                sizes.append(width)
                self.assertEqual((height, planes, depth), (width, 1, 32))
                data = windows[offset:offset + length]
                self.assertEqual(len(data), length)
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(struct.unpack(">II", data[16:24]), (width, height))
            self.assertEqual(sizes, [16, 24, 32, 48, 64, 128, 256])

            for path, size in [("landing/assets/icon.png", 512),
                               ("landing/assets/icon-180.png", 180)]:
                data = (output / path).read_bytes()
                self.assertEqual(struct.unpack(">II", data[16:24]), (size, size))
            foreground = output / "Resources/Verbemo.icon/Assets/Verbemo-wave.png"
            check_foreground = subprocess.run([
                "swift", "-e", """
import AppKit
let image = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
for y in 0..<(image.pixelsHigh / 3) {
    for x in 0..<image.pixelsWide {
        if image.colorAt(x: x, y: y)!.alphaComponent != 0 {
            FileHandle.standardError.write(Data("jade tile leaked into the foreground".utf8))
            exit(1)
        }
    }
}
if image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh * 64 / 100)!.alphaComponent <= 0.9 {
    FileHandle.standardError.write(Data("ivory wave was removed".utf8))
    exit(1)
}
""", str(foreground)], capture_output=True, text=True, check=False)
            self.assertEqual(check_foreground.returncode, 0, check_foreground.stderr[-2000:])


def xcode_major_version():
    result = subprocess.run(
        ["xcodebuild", "-version"], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        return None
    first = result.stdout.splitlines()[0].split()
    return int(first[1].split(".")[0]) if len(first) > 1 else None


@unittest.skipUnless(
    (xcode_major_version() or 0) >= 26,
    "Icon Composer assets require Xcode 26 or later",
)
class AppIconTests(unittest.TestCase):
    def test_build_keeps_classic_icon_and_all_macos_appearances(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = subprocess.run(
                [str(BUILD_SCRIPT), str(ICON), str(CLASSIC_ICON), str(output), "14.2"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with (ROOT / "Packaging/Verbemo-Info.plist").open("rb") as file:
                app_info = plistlib.load(file)
            self.assertEqual((output / (app_info["CFBundleIconFile"] + ".icns")).read_bytes(),
                             CLASSIC_ICON.read_bytes())

            catalog = subprocess.run(
                ["assetutil", "--info", str(output / "Assets.car")],
                capture_output=True,
                text=True,
                check=True,
            )
            renditions = json.loads(catalog.stdout)
            stacks = {
                item.get("Appearance"): item
                for item in renditions
                if item.get("AssetType") == "IconImageStack"
                and item.get("Name") == app_info["CFBundleIconName"]
            }
            self.assertEqual(
                set(stacks),
                {
                    "NSAppearanceNameAqua",
                    "NSAppearanceNameDarkAqua",
                    "ISAppearanceTintable",
                },
            )
            for appearance, stack in stacks.items():
                self.assertGreaterEqual(
                    stack["LayerCount"],
                    2,
                    f"{appearance} lost the wave foreground layer",
                )

            groups = {
                item.get("Appearance"): item
                for item in renditions
                if item.get("AssetType") == "IconGroup"
                and item.get("Name") == app_info["CFBundleIconName"] + "/Group"
            }
            self.assertEqual(set(groups), set(stacks))
            for appearance, group in groups.items():
                layer = group["Layers"][0]
                self.assertEqual(
                    layer["AssetType"],
                    "Image",
                    f"{appearance} must preserve the raster wave",
                )
                self.assertFalse(layer["Opaque"])
                width, height = map(int, layer["LayerSize"].split(","))
                self.assertGreaterEqual(width, 1200)
                self.assertGreaterEqual(height, 1200)


if __name__ == "__main__":
    unittest.main()
