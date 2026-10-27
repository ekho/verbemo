"""Select CI consumers from the complete event diff, without API file limits."""
import json
import os
from pathlib import Path
import subprocess

CHECKS = ('macos_test', 'macos_build', 'windows_test', 'windows_build',
          'scripts', 'macos_scripts', 'landing', 'automation')
MACOS = {'macos_test', 'macos_build'}
WINDOWS = {'windows_test', 'windows_build'}
SHARED = MACOS | WINDOWS | {'scripts', 'macos_scripts'}


def select_checks(paths):
    selected = set()
    for path in paths:
        if path.startswith('.github/workflows/') or path == 'scripts/ci_changes.py':
            selected.update(CHECKS)
        elif path in ('VERSION', 'LICENSE', 'THIRD-PARTY-NOTICES.md') or path in (
                'scripts/release.py', 'scripts/release_manifest.py', 'scripts/release_github.py', 'scripts/release.sh'):
            selected.update(SHARED)
        elif path.startswith('scripts/release-automation/'):
            selected.update(('automation', 'scripts'))
        elif path == 'Tests/scripts/auto-release.test.mjs':
            selected.add('automation')
        elif path.startswith('Tests/scripts/') or (path.startswith('windows/tests/') and path.endswith('.py')):
            selected.add('scripts')
        elif path.startswith('Tests/macos-scripts/'):
            selected.add('macos_scripts')
        elif path.startswith(('Tests/verbemoTests/', 'Tests/QuietTestWindows/')):
            selected.add('macos_test')
        elif path.startswith('Sources/'):
            selected.update(MACOS)
        elif path in ('Package.swift', 'Package.resolved'):
            selected.update(MACOS | {'scripts'})
        elif path == 'Makefile' or path.startswith(('Resources/', 'Packaging/')) or path.startswith((
                'scripts/build-', 'scripts/verify-', 'scripts/localvqe-')) or path == 'scripts/make-icon.swift':
            selected.update(MACOS | {'scripts', 'macos_scripts'})
        elif path.startswith('landing/'):
            selected.update(('landing', 'scripts'))
        elif path in ('.gitignore', 'README.md', 'SUPPORT.md', 'CLAUDE.md', 'PRIVACY.md', 'SECURITY.md',
                       'windows/README.md', 'windows/BETA.md', 'windows/LIVE_TRANSCRIPTION.md',
                       'windows/packaging/README.md',
                       'docs/old-macs.md', 'docs/releasing.md', 'docs/pitfalls.md',
                       'docs/analytics.md', 'docs/configuration.md') or path.startswith('docs/testing/'):
            selected.add('scripts')
        elif path.endswith('.md') or path.startswith(('docs/', '.github/ISSUE_TEMPLATE/')):
            continue
        elif path in ('windows/src/Verbemo.App/App.xaml.cs', 'windows/src/Verbemo.App/Assets/Verbemo.ico'):
            selected.update(WINDOWS | {'scripts'})
        elif path.startswith('windows/tests/'):
            selected.add('windows_test')
            if path.endswith('.ps1'):
                selected.add('scripts')
            if path.endswith('Test-NativeUnicodePaths.ps1'):
                selected.add('windows_build')
        elif path.startswith('windows/'):
            selected.update(WINDOWS)
            if path.startswith('windows/scripts/'):
                selected.add('scripts')
        elif path.startswith('scripts/') or path == '.github/dependabot.yml':
            selected.add('scripts')
        elif path != '.DS_Store':
            # Unknown build inputs must never silently lose platform coverage.
            selected.update(CHECKS)
    return {check: check in selected for check in CHECKS}


def event_paths(event_name, event):
    if event_name == 'pull_request':
        pr = event['pull_request']
        head = pr['head']['sha']
        base = subprocess.check_output(['git', 'merge-base', pr['base']['sha'], head], text=True).strip()
    elif event_name == 'push':
        base, head = event['before'], event['after']
    else:
        return None
    # Disable rename detection so moving across platforms checks both consumers.
    result = subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', '-z', base, head, '--'])
    return [os.fsdecode(path) for path in result.split(b'\0') if path]


if __name__ == '__main__':
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    try:
        paths = event_paths(os.environ['GITHUB_EVENT_NAME'], event)
    except subprocess.CalledProcessError:
        paths = None  # New/force-pushed history: spend the checks instead of guessing.
    checks = dict.fromkeys(CHECKS, True) if paths is None else select_checks(paths)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for check, enabled in checks.items():
            print(f'{check}={str(enabled).lower()}', file=output)
    print(json.dumps(checks, indent=2))
