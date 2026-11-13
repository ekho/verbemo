import base64
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('preview_signing', ROOT / 'scripts/preview_signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class PreviewSigningTests(unittest.TestCase):
    def test_native_tool_timeout_does_not_echo_secret_input(self):
        with patch.object(signing.subprocess, 'run', side_effect=subprocess.TimeoutExpired(
                ['security', '-i'], 60, output=b'secret-input')) as process:
            with self.assertRaisesRegex(ValueError, '^preview signing: security timed out$'):
                signing.run(['security', '-i'], data=b'secret-input')
            self.assertEqual(process.call_args.kwargs['timeout'], 60)

    def test_credentials_are_never_imported_on_a_persistent_host(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(signing, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'disposable GitHub macOS runner'):
                signing.signed_build(['build'])
            run.assert_not_called()

    def test_missing_credentials_fail_without_an_ad_hoc_fallback(self):
        with patch.dict(os.environ, {'RUNNER_ENVIRONMENT': 'github-hosted'}, clear=True), \
                patch.object(signing.sys, 'platform', 'darwin'), patch.object(signing, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'credentials'):
                signing.signed_build(['build'])
            run.assert_not_called()

    def test_mismatched_private_identity_is_rejected_before_import_or_trust(self):
        env = {'RUNNER_ENVIRONMENT': 'github-hosted', 'VERBEMO_PREVIEW_CERTIFICATE_BASE64': 'YWJj',
               'VERBEMO_PREVIEW_CERTIFICATE_PASSWORD': 'fixture-password'}
        with patch.dict(os.environ, env, clear=True), patch.object(signing.sys, 'platform', 'darwin'), \
                patch.object(signing, 'certificate_der', side_effect=[b'pinned', b'unexpected']), \
                patch.object(signing, 'run', return_value=b'') as run:
            with self.assertRaisesRegex(ValueError, 'pinned public certificate'):
                signing.signed_build(['build'])
            self.assertFalse(any('import' in str(call) or 'trusted-cert' in str(call) for call in run.call_args_list))

    def test_success_and_failures_remove_private_material_without_logging_secrets(self):
        password = 'fixture-password-never-log'
        secret = base64.b64encode(b'fixture-private-archive').decode()
        env = {'RUNNER_ENVIRONMENT': 'github-hosted', 'VERBEMO_PREVIEW_CERTIFICATE_BASE64': secret,
               'VERBEMO_PREVIEW_CERTIFICATE_PASSWORD': password}
        for failure in (None, 'build', 'add-trusted-cert', 'delete-keychain'):
            with self.subTest(failure=failure):
                commands, security_commands = [], []

                def process(arguments, *, input=None, capture_output=False, env=None, timeout=None):
                    commands.append(arguments)
                    self.assertNotIn(password, arguments)
                    self.assertNotIn(secret, arguments)
                    output, code = b'', 0
                    if arguments == ['security', '-i']:
                        command = shlex.split(input.decode())
                        security_commands.append(command)
                        if command[0] == 'create-keychain':
                            Path(command[-1]).touch()
                    elif arguments == ['security', 'list-keychains', '-d', 'user']:
                        output = b'"/fixture/login.keychain-db"\n'
                    elif arguments[0] == 'build':
                        self.assertNotIn('VERBEMO_PREVIEW_CERTIFICATE_BASE64', env)
                        self.assertNotIn('VERBEMO_PREVIEW_CERTIFICATE_PASSWORD', env)
                        self.assertEqual(env['VERBEMO_PREVIEW_SIGN_ID'], hashlib.sha1(b'pinned').hexdigest().upper())
                    if failure in arguments:
                        code = 13
                    return subprocess.CompletedProcess(arguments, code, output, b'')

                output = io.StringIO()
                with patch.dict(os.environ, env, clear=True), patch.object(signing.sys, 'platform', 'darwin'), \
                        patch.object(signing, 'certificate_der', return_value=b'pinned'), \
                        patch.object(signing, 'check_updates'), patch.object(signing.subprocess, 'run', side_effect=process), \
                        redirect_stdout(output):
                    if failure is None:
                        signing.signed_build(['build'])
                    else:
                        with self.assertRaises(ValueError):
                            signing.signed_build(['build'])
                self.assertTrue(any(command[0] == 'import' for command in security_commands))
                self.assertFalse(any('remove-trusted-cert' in command for command in commands))
                deleted = next(command[-1] for command in commands if command[:2] == ['security', 'delete-keychain'])
                self.assertFalse(Path(deleted).parent.exists())
                self.assertEqual(commands[-1], ['security', 'list-keychains', '-d', 'user', '-s', '/fixture/login.keychain-db'])
                self.assertNotIn(password, output.getvalue())
                self.assertNotIn(secret, output.getvalue())

    def test_bundle_verification_requires_the_pinned_certificate_and_product_identity(self):
        for actual in (b'pinned', b'other'):
            with self.subTest(actual=actual), tempfile.TemporaryDirectory() as directory:
                calls = []

                def run(arguments, **kwargs):
                    calls.append(arguments)
                    option = next((arg for arg in arguments if arg.startswith('--extract-certificates=')), None)
                    if option:
                        prefix = Path(option.split('=', 1)[1])
                        prefix.with_name(prefix.name + '0').write_bytes(actual)
                    return b''

                with patch.object(signing, 'certificate_der', return_value=b'pinned'), patch.object(signing, 'run', side_effect=run):
                    if actual == b'pinned':
                        self.assertEqual(signing.verify_signature(Path(directory)), hashlib.sha256(actual).hexdigest().upper())
                    else:
                        with self.assertRaisesRegex(ValueError, 'pinned certificate'):
                            signing.verify_signature(Path(directory))
                requirement = calls[0][calls[0].index('-R') + 1]
                self.assertIn('identifier "name.ekho.verbemo"', requirement)
                self.assertIn(hashlib.sha1(b'pinned').hexdigest().upper(), requirement)


if __name__ == '__main__':
    unittest.main()
