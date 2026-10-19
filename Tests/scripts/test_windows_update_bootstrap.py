"""Source order guards supplement Windows kernel-object updater tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WindowsUpdateBootstrapTests(unittest.TestCase):
    def test_worker_bypasses_admission_and_hooks_run_for_both_launches(self):
        source = (ROOT / 'windows/src/Verbemo.App/App.xaml.cs').read_text()
        main = source[source.index('private static void Main()'):source.index('protected override void OnStartup')]
        self.assertLess(main.index('LiveSpeechWorker.Main'), main.index('new UpdateStartupAdmission'))
        self.assertLess(main.index('new UpdateStartupAdmission'), main.index('VelopackApp.Build()'))
        self.assertIn('SetAutoApplyOnStartup(startupAdmission.IsPrimary).Run()', main)
        self.assertLess(main.index('VelopackApp.Build()'), main.index('new App()'))
        self.assertNotIn('if (startupAdmission.IsPrimary)', main)
        self.assertIn('finally', main)
        self.assertIn('startupAdmission.Dispose()', main)

    def test_update_check_cannot_tear_down_or_restart_the_runtime(self):
        source = (ROOT / 'windows/src/Verbemo.App/App.xaml.cs').read_text()
        method = source[source.index('public static async Task CheckForUpdatesAsync()'):source.index('public static async Task QuitAsync()')]
        for forbidden in ('TearDownAsync(', 'RestartIntoUpdate(', 'ApplyUpdates', 'MessageBoxButton.YesNo'):
            self.assertNotIn(forbidden, method)
        self.assertIn('current.State.IsRecording || current.IsProcessing', method)


if __name__ == '__main__':
    unittest.main()
