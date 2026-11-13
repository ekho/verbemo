#!/usr/bin/env python3
"""Use the pinned preview identity on a disposable GitHub macOS runner."""
import base64
import hashlib
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile

CERTIFICATE = Path(__file__).resolve().parents[1] / 'Packaging/preview-signing.pem'


def run(arguments, *, data=None, env=None):
    try:
        result = subprocess.run(arguments, input=data, capture_output=True, env=env, timeout=60)
    except subprocess.TimeoutExpired as error:
        raise ValueError(f'preview signing: {Path(arguments[0]).name} timed out') from error
    if result.returncode:
        # security's interactive diagnostics can echo its secret-bearing input.
        detail = result.stderr.decode(errors='replace').strip() if arguments[0] == 'codesign' else ''
        raise ValueError(f'preview signing: {Path(arguments[0]).name} failed (exit {result.returncode}) {detail}'.strip())
    return result.stdout


def certificate_der(pem):
    return run(['openssl', 'x509', '-outform', 'DER'], data=pem)


def verify_signature(app):
    expected = certificate_der(CERTIFICATE.read_bytes())
    identity = hashlib.sha1(expected).hexdigest().upper()
    requirement = f'=identifier "name.ekho.verbemo" and certificate leaf = H"{identity}"'
    run(['codesign', '--verify', '--deep', '--strict', '-R', requirement, str(app)])
    with tempfile.TemporaryDirectory(prefix='verbemo-preview-verify-') as directory:
        prefix = Path(directory) / 'certificate'
        run(['codesign', '--display', f'--extract-certificates={prefix}', str(app)])
        if prefix.with_name('certificate0').read_bytes() != expected:
            raise ValueError('preview signing: app certificate does not match the pinned certificate')
    return hashlib.sha256(expected).hexdigest().upper()


def check_updates(directory, identity, keychain):
    """Exercise different code versions and a native library with the real identity."""
    library = directory / 'libanswer.dylib'
    source = directory / 'answer.c'
    source.write_text('int answer(void) { return 42; }\n')
    run(['xcrun', 'clang', '-dynamiclib', str(source), '-Wl,-install_name,@rpath/libanswer.dylib', '-o', str(library)])
    requirements, hashes = [], []
    for version in (1, 2):
        source = directory / f'check-{version}.c'
        source.write_text(f'extern int answer(void); int main(void) {{ return answer() == 42 ? 0 : {version}; }}\n')
        binary = directory / f'check-{version}'
        run(['xcrun', 'clang', str(source), '-L', str(directory), '-lanswer', '-Wl,-rpath,@executable_path', '-o', str(binary)])
        for code in (library, binary):
            run(['codesign', '--force', '--sign', identity, '--keychain', str(keychain),
                 '--identifier', 'name.ekho.verbemo.signing-check', '--options', '0', '--timestamp=none', str(code)])
            run(['codesign', '--verify', '--strict', str(code)])
        run([str(binary)])
        requirements.append(run(['codesign', '--display', '-r-', str(binary)]))
        hashes.append(hashlib.sha256(binary.read_bytes()).digest())
    if requirements[0] != requirements[1] or hashes[0] == hashes[1]:
        raise ValueError('preview signing: different builds must share the same designated requirement')
    app = directory / 'Signing Check.app'
    code = app / 'Contents/MacOS'
    code.mkdir(parents=True)
    shutil.copy2(binary, code / 'SigningCheck')
    shutil.copy2(library, code / library.name)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'name.ekho.verbemo', 'CFBundleExecutable': 'SigningCheck', 'CFBundlePackageType': 'APPL'}))
    run(['codesign', '--force', '--sign', identity, '--keychain', str(keychain),
         '--identifier', 'name.ekho.verbemo', '--options', '0', '--timestamp=none', str(app)])
    verify_signature(app)
    print('Verified persistent preview identity across two binaries, a native library, and an app bundle.', flush=True)


def signed_build(command):
    if sys.platform != 'darwin' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise ValueError('preview signing: credential import requires a disposable GitHub macOS runner')
    if not command:
        raise ValueError('preview signing: missing build command')
    try:
        archive = base64.b64decode(os.environ['VERBEMO_PREVIEW_CERTIFICATE_BASE64'], validate=True)
        password = os.environ['VERBEMO_PREVIEW_CERTIFICATE_PASSWORD']
    except (KeyError, ValueError) as error:
        raise ValueError('preview signing: missing or invalid preview credentials') from error
    if not archive or not password or any(c in password for c in '\n\r\0'):
        raise ValueError('preview signing: invalid preview credentials')
    expected = certificate_der(CERTIFICATE.read_bytes())
    identity = hashlib.sha1(expected).hexdigest().upper()
    original_search = shlex.split(run(['security', 'list-keychains', '-d', 'user']).decode())
    with tempfile.TemporaryDirectory(prefix='verbemo-preview-keys-') as temporary:
        directory = Path(temporary)
        archive_path = directory / 'certificate.p12'
        archive_path.write_bytes(archive)
        archive_path.chmod(0o600)
        pem = run(['openssl', 'pkcs12', '-in', str(archive_path), '-clcerts', '-nokeys', '-passin', 'stdin'],
                  data=(password + '\n').encode())
        if certificate_der(pem) != expected:
            raise ValueError('preview signing: credentials do not match the pinned public certificate')
        keychain = directory / 'preview.keychain-db'
        keychain_password = secrets.token_hex(32)

        def security(*arguments):
            try:
                result = subprocess.run(['security', '-i'], input=(shlex.join(arguments) + '\n').encode(),
                                        capture_output=True, timeout=60)
            except subprocess.TimeoutExpired as error:
                raise ValueError(f'preview signing: security {arguments[0]} timed out') from error
            if result.returncode or result.stderr.strip():
                raise ValueError(f'preview signing: security {arguments[0]} failed')

        try:
            security('create-keychain', '-p', keychain_password, str(keychain))
            security('set-keychain-settings', '-lut', '7200', str(keychain))
            security('unlock-keychain', '-p', keychain_password, str(keychain))
            security('import', str(archive_path), '-P', password, '-k', str(keychain), '-T', '/usr/bin/codesign')
            security('set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', keychain_password, str(keychain))
            run(['security', 'list-keychains', '-d', 'user', '-s', str(keychain), *original_search])
            # shortcut: trust lasts until the hosted VM is destroyed; require explicit removal before supporting persistent runners.
            run(['sudo', '-n', 'security', 'add-trusted-cert', '-d', '-r', 'trustRoot', '-p', 'codeSign',
                 '-k', str(keychain), str(CERTIFICATE)])
            check_updates(directory, identity, keychain)
            env = {key: value for key, value in os.environ.items()
                   if key not in ('VERBEMO_PREVIEW_CERTIFICATE_BASE64', 'VERBEMO_PREVIEW_CERTIFICATE_PASSWORD')}
            env.update(VERBEMO_PREVIEW_SIGN_ID=identity, VERBEMO_SIGN_KEYCHAIN=str(keychain))
            result = subprocess.run(command, env=env)
            if result.returncode:
                raise ValueError(f'preview signing: build failed (exit {result.returncode})')
        finally:
            try:
                if keychain.exists():
                    print('Deleting temporary preview keychain.', flush=True)
                    run(['security', 'delete-keychain', str(keychain)])
            finally:
                run(['security', 'list-keychains', '-d', 'user', '-s', *original_search])


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == 'verify':
            print(verify_signature(Path(sys.argv[2])))
        elif len(sys.argv) > 2 and sys.argv[1] == 'run':
            signed_build(sys.argv[2:])
        else:
            raise ValueError('usage: preview_signing.py verify APP | run COMMAND [ARG ...]')
    except (ValueError, OSError) as error:
        sys.exit(str(error))


if __name__ == '__main__':
    main()
