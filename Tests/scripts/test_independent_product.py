"""Independence guard. Unit discovery enforces Task 4's migrated scope.

Run `python3 Tests/scripts/test_independent_product.py --all` for the final
runtime/build/release/site gate. It intentionally fails until Tasks 5–8 migrate
updaters, packaging/CI, About, and the site. Those owners must expand MIGRATED
or make the full gate mandatory before final review; no finding is waived.
Historical/provenance docs, licenses and dependency sources are outside active
product scope. User-selected paths and third-party dependency names are allowed.
"""
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ACTIVE = ("Sources", "windows/src", "windows/scripts", "scripts", ".github",
          "landing", "Packaging", "Makefile", "Package.swift", "README.md",
          "docs/releasing.md")
MIGRATED = ("Sources/verbemo/Analytics", "Sources/verbemo/Settings",
            "Sources/verbemo/Home.swift", "Sources/verbemo/UI/SetupForm.swift",
            "Sources/verbemo/UI/ConfigWatch.swift", "Sources/verbemo/Verbemo.swift",
            "Sources/verbemo/Config.swift", "Sources/verbemo/App", "Sources/verbemo/Setup",
            "Sources/verbemo/Sessions", "Sources/verbemo/Summary", "Sources/verbemo/Transcription",
            "Sources/verbemo/RecordingSession.swift", "Sources/verbemo/UI/RecordingsWindow.swift",
            "Sources/verbemo/UI/SetupWindow.swift", "Sources/verbemo/UI/SettingsWindow.swift",
            "windows/src/Verbemo.App/VerbemoRuntime.cs", "windows/src/Verbemo.App/ProcessingCoordinator.cs",
            "windows/src/Verbemo.App/AnalyticsService.cs",
            "windows/src/Verbemo.App/SetupForm.cs", "windows/src/Verbemo.Core/Analytics",
            "windows/src/Verbemo.Core/Configuration")
PENDING = {"Tasks 5/6": "updaters and Packaging/Verbemo-Info.plist",
           "Task 7": "scripts, Makefile, .github, Windows release scripts",
           "Task 8": "About/source links, README, docs/releasing.md, landing (including telemetry)"}
OLD_KEY = "/AxdBBPOFIca/y7RYwvi83FE6WqnIAjkVV0nTkRq9/c="


def in_scope(path, scopes):
    return any(path == scope or path.startswith(scope + "/") for scope in scopes)


def violations(path, text):
    if not in_scope(path, ACTIVE):
        return []
    rules = {
        "author-domain": r"(?:[\w-]+\.)?amanu\.me\b|samat\.me/amanu\b",
        "author-repository": r"(?:gsamat|ekho)/amanu(?:\b|/)",
        "author-sparkle-key": re.escape(OLD_KEY),
        "author-publisher": r"Fands Software LLC",
        "inherited-environment": r"\bAMANU_[A-Z0-9_]+\b",
    }
    if path.startswith("landing/"):
        rules["site-telemetry"] = r"new\s+Image\s*\(|sendBeacon\s*\(|umami|[/]m\?"
    if "/Analytics/" in path or path.endswith("/AnalyticsService.cs"):
        rules["analytics-transport"] = (
            r"URLSession|URLRequest|PostAsJsonAsync|SendAsync|Guid\.NewGuid|UUID\(\)|"
            r"PeriodicTimer|DispatchSource\.makeTimerSource|File\.Write|Data\(contentsOf:"
        )
    hits = []
    for number, line in enumerate(text.splitlines(), 1):
        # Patterns in release helpers may escape dots in literal URL regexes.
        normalized = line.replace(r"\.", ".")
        for rule, pattern in rules.items():
            if re.search(pattern, normalized, re.IGNORECASE if rule != "inherited-environment" else 0):
                hits.append(f"{path}:{number}: {rule}")
    return hits


def scan(root, scopes):
    found = []
    for scope in scopes:
        target = root / scope
        files = target.rglob("*") if target.is_dir() else [target]
        for path in sorted(files):
            if not path.is_file():
                continue
            try:
                content = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            found.extend(violations(path.relative_to(root).as_posix(), content))
    return found


class IndependenceDetectorTests(unittest.TestCase):
    def test_active_fixtures_reject_inherited_service_identity_and_publisher(self):
        fixtures = [
            ("Sources/verbemo/Updater.swift", 'URL(string: "https://amanu.me/appcast.xml")', "author-domain"),
            ("windows/src/App/Updates.cs", 'new GithubSource("https://github.com/gsamat/amanu")', "author-repository"),
            ("scripts/release.sh", 'REPO="gsamat/amanu"', "author-repository"),
            ("Packaging/Verbemo-Info.plist", "/AxdBBPOFIca/y7RYwvi83FE6WqnIAjkVV0nTkRq9/c=", "author-sparkle-key"),
            ("windows/scripts/sign.ps1", "CN=Fands Software LLC", "author-publisher"),
            ("Sources/verbemo/Home.swift", 'env["AMANU_HOME"]', "inherited-environment"),
            ("landing/script.js", '(new Image()).src = "/m?p=/";', "site-telemetry"),
            ("Sources/verbemo/Analytics/Sender.swift", 'URLSession.shared.data(for: request)', "analytics-transport"),
        ]
        for path, source, rule in fixtures:
            with self.subTest(path=path, rule=rule):
                self.assertTrue(any(rule in hit for hit in violations(path, source)))

    def test_dependency_names_selected_paths_and_provenance_are_allowed(self):
        fixtures = [
            ("Package.swift", '.package(url: "https://github.com/FluidInference/FluidAudio", from: "1.0.0")'),
            ("Sources/verbemo/Config.swift", 'selectedPath = "/Users/me/Amanu Recordings"'),
            ("Sources/verbemo/Providers.swift", 'env["OPENAI_API_KEY"]; env["CODEX_HOME"]'),
            ("docs/windows-source-import.md", 'Imported https://github.com/gsamat/amanu at pinned commit'),
            ("LICENSE", 'Copyright (c) Amanu authors'),
        ]
        for path, source in fixtures:
            with self.subTest(path=path):
                self.assertEqual(violations(path, source), [])

    def test_scan_checks_new_files_inside_declared_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/verbemo/Analytics/NewSender.swift"
            source.parent.mkdir(parents=True)
            source.write_text('let endpoint = "https://stats.amanu.me/api/batch"')
            self.assertTrue(scan(root, MIGRATED))

    def test_migrated_repository_surfaces_have_no_inherited_services(self):
        for scope in MIGRATED:
            self.assertTrue((ROOT / scope).exists(), f"Declared migrated scope missing: {scope}")
        self.assertEqual(scan(ROOT, MIGRATED), [])
        self.assertFalse((ROOT / "scripts/analytics").exists(), "analytics infrastructure must be removed")


if __name__ == "__main__":
    if "--all" in sys.argv:
        hits = scan(ROOT, ACTIVE)
        print("Full independence guard: runtime/build/release/site")
        print("\n".join(hits) if hits else "PASS: no inherited product services")
        sys.exit(bool(hits))
    unittest.main()
