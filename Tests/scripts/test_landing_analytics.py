import shutil
import subprocess
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

class LandingAnalyticsTests(unittest.TestCase):
    def test_page_and_download_clicks_make_no_analytics_requests(self):
        node = shutil.which('node')
        self.assertIsNotNone(node, 'Node.js is required to verify the site script')
        harness = r"""
const fs = require('fs');
const fail = () => { throw Error('unexpected analytics transport'); };
global.Image = class { set src(value) { fail(); } };
global.screen = {width: 1440, height: 900};
global.devicePixelRatio = 2;
global.fetch = fail;
global.XMLHttpRequest = fail;
global.navigator = { userAgent: 'Windows', sendBeacon: fail };
global.location = { origin: 'http://localhost', pathname: '/ru/' };
global.document = { title: 'Verbemo', referrer: '', getElementById() { return null; }, querySelectorAll() { return []; } };
eval(fs.readFileSync(process.argv[1], 'utf8'));
"""
        result = subprocess.run([node, '-e', harness, str(ROOT / 'landing/script.js')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
