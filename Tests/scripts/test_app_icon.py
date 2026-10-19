import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "Resources" / "Verbemo.icon"
CLASSIC_ICON = ROOT / "Resources" / "Verbemo.icns"
BUILD_SCRIPT = ROOT / "scripts" / "build-app-icon.sh"


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
    def test_icon_composer_asset_builds_all_macos_appearances(self):
        self.assertTrue(
            (ICON / "icon.json").is_file(),
            "Resources/Verbemo.icon/icon.json is missing",
        )

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            partial_plist = output / "partial.plist"
            result = subprocess.run(
                [
                    "xcrun",
                    "actool",
                    "--compile",
                    str(output),
                    "--platform",
                    "macosx",
                    "--minimum-deployment-target",
                    "14.2",
                    "--app-icon",
                    "Verbemo",
                    "--output-partial-info-plist",
                    str(partial_plist),
                    str(ICON),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((output / "Assets.car").is_file())
            self.assertTrue((output / "Verbemo.icns").is_file())

            with partial_plist.open("rb") as file:
                generated_info = plistlib.load(file)
            self.assertEqual(generated_info["CFBundleIconName"], "Verbemo")
            self.assertEqual(generated_info["CFBundleIconFile"], "Verbemo")

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
                and item.get("Name") == "Verbemo"
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
                    f"{appearance} lost the feather foreground layer",
                )

            groups = {
                item.get("Appearance"): item
                for item in renditions
                if item.get("AssetType") == "IconGroup"
                and item.get("Name") == "Verbemo/Group"
            }
            self.assertEqual(set(groups), set(stacks))
            for appearance, group in groups.items():
                layer = group["Layers"][0]
                self.assertEqual(
                    layer["AssetType"],
                    "Image",
                    f"{appearance} must preserve the hollow raster outline",
                )
                self.assertFalse(layer["Opaque"])
                width, height = map(int, layer["LayerSize"].split(","))
                self.assertGreaterEqual(width, 1200)
                self.assertGreaterEqual(height, 1200)

    def test_app_icon_build_keeps_the_classic_fallback(self):
        self.assertTrue(BUILD_SCRIPT.is_file(), "scripts/build-app-icon.sh is missing")

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = subprocess.run(
                [
                    str(BUILD_SCRIPT),
                    str(ICON),
                    str(CLASSIC_ICON),
                    str(output),
                    "14.2",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((output / "Assets.car").is_file())
            self.assertEqual(
                (output / "Verbemo.icns").read_bytes(),
                CLASSIC_ICON.read_bytes(),
            )


if __name__ == "__main__":
    unittest.main()
