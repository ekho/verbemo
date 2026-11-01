"""Verify the source-pinned macOS #73 delivery evidence without rerunning GUI actions."""
from pathlib import Path
import hashlib
import json
import subprocess

base = Path(__file__).resolve().parent
root = base.parents[5]
manifest = json.loads((base / 'verification.json').read_text())
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
subprocess.run(['git', 'diff', '--exit-code', manifest['source_commit'], '--', 'Sources', 'Tests'],
               cwd=root, check=True, stdout=subprocess.DEVNULL)
tests = manifest['tests']
assert (tests['passed'], tests['suites'], tests['skipped_tests'], tests['skipped_suites']) == (1378, 186, 23, 6)
log = Path(tests['raw_log'])
assert digest(log) == tests['raw_log_sha256']
assert 'Test run with 1378 tests in 186 suites passed' in log.read_text() and '✘' not in log.read_text()
assert digest(base / 'test-summary.txt') == tests['summary_sha256']
assert digest(Path(manifest['raw_build_log'])) == manifest['raw_build_log_sha256']
build = manifest['build']
assert build['source_commit'] == manifest['source_commit'] and build['build'] == '670'
app = Path(build['bundle'])
exe = app / 'Contents/MacOS/Verbemo'
assert digest(exe) == build['executable_sha256']
assert set(subprocess.check_output(['lipo', '-archs', str(exe)], text=True).split()) == {'arm64', 'x86_64'}
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
gui = manifest['gui']
for filename, expected in [(gui['checks_file'], gui['checks_sha256']),
                           (gui['screenshots_file'], gui['screenshots_sha256']),
                           (gui['artifact_hashes_file'], gui['artifact_hashes_sha256'])]:
    assert digest(base / filename) == expected, filename
shots = json.loads((base / gui['screenshots_file']).read_text())
assert len(shots) == gui['image_count'] == 30
assert len({shot['image'] for shot in shots}) == 30
for shot in shots:
    assert shot['source_commit'] == build['source_commit'] and shot['build'] == '670'
    assert digest(base / shot['image']) == shot['sha256']
    assert digest(base / shot['ax']) == shot['ax_sha256']
fixtures = Path(build['fixtures'])
actual = {str(path.relative_to(fixtures)): digest(path) for path in fixtures.rglob('*') if path.is_file()}
assert len(actual) == 433 and actual == json.loads((base / gui['artifact_hashes_file']).read_text())
assert len(list(fixtures.iterdir())) == 206
assert digest(base / manifest['review']['file']) == manifest['review']['sha256']
print('Mac #73 checkpoint passed: source48efd34,1378/186 tests,universal670,30 native captures,433 unchanged files')
