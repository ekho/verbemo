using Verbemo.Core.Configuration;
using Microsoft.Win32;

namespace Verbemo.App;

public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true)
            ?? Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        if (enabled)
        {
            var executable = Environment.ProcessPath
                ?? throw new InvalidOperationException("Cannot determine the Verbemo executable path.");
            key.SetValue(ProductIdentity.StartupEntryName, $"\"{executable}\" --background", RegistryValueKind.String);
        }
        else
        {
            key.DeleteValue(ProductIdentity.StartupEntryName, throwOnMissingValue: false);
        }
    }
}
