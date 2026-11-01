"""Validate the B1 delivery checkpoint against its source and captured evidence."""
from pathlib import Path
import hashlib
import json
import subprocess

base = Path(__file__).resolve().parent
root = base.parents[4]
manifest = json.loads((base / "verification.json").read_text())
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
subprocess.run(["git", "diff", "--exit-code", manifest["source_commit"], "--", "Sources", "Tests"],
               cwd=root, check=True, stdout=subprocess.DEVNULL)
assert manifest["full_tests"]["passed"] == 1370
assert manifest["full_tests"]["suites"] == 186
log = Path("/tmp/verbemo-ux73-b1-delivery-full.log")
assert digest(log) == manifest["full_tests"]["raw_log_sha256"]
assert "Test run with 1370 tests in 186 suites passed" in log.read_text()
assert "✘" not in log.read_text()
assert digest(base / "test-summary.txt") == manifest["full_tests"]["summary_sha256"]
assert digest(base / "gui-checks.json") == manifest["gui"]["checks_sha256"]
assert digest(base / "artifact-hashes.json") == manifest["gui"]["artifact_hashes_sha256"]
for name, expected in manifest["source_files"].items():
    assert digest(root / name) == expected, name
assert len(manifest["gui"]["images"]) == 12
for shot in manifest["gui"]["images"]:
    path = base / shot["file"]
    assert digest(path) == shot["sha256"], path
    assert digest(path.with_suffix(".ax.txt")) == shot["accessibility_sha256"], path
build = json.loads((base / "build.json").read_text())
assert build["source_commit"] == manifest["source_commit"]
assert digest(Path(build["bundle"]) / "Contents/MacOS/Verbemo") == build["executable_sha256"]
fixtures = Path(build["fixtures"])
actual = {str(path.relative_to(fixtures)): digest(path) for path in fixtures.rglob("*") if path.is_file()}
assert actual == json.loads((base / "artifact-hashes.json").read_text())
assert len(actual) == 430
print("B1 checkpoint passed: source,1370/186 tests,package,12 native captures,430 unchanged files")
