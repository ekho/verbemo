from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SparkleSignatureTests(unittest.TestCase):
    def test_cryptokit_verifies_rfc8032_vector_and_rejects_other_public_key(self):
        import base64
        import os
        import subprocess
        import sys
        if sys.platform != 'darwin':
            self.skipTest('CryptoKit verification requires macOS')
        # RFC 8032 test vector 1: public information only, no key generation.
        key = bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
        signature = bytes.fromhex('e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f'
                                  'b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')
        with tempfile.TemporaryDirectory() as directory:
            message = Path(directory) / 'message'
            message.write_bytes(b'')
            for public, expected in [(key, 0), (bytes(32), 1)]:
                env = dict(os.environ, VERBEMO_SPARKLE_PUBLIC_KEY=base64.b64encode(public).decode())
                result = subprocess.run(['swift', str(ROOT / 'scripts/verify-sparkle-signature.swift'),
                                         str(message), base64.b64encode(signature).decode()],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected:
                    self.assertIn('public/private key mismatch', result.stderr)
