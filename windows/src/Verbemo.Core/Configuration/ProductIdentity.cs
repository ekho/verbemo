namespace Verbemo.Core.Configuration;

public static class ProductIdentity
{
    public const string CredentialPrefix = "Verbemo/";
    public const string StartupEntryName = "Verbemo";
    public const string InstanceName = "Local\\Verbemo.Desktop.SingleInstance";
    public const string DoorbellName = "Local\\Verbemo.Desktop.ShowWindow";
    public const string TestDataEnvironmentVariable = "VERBEMO_TEST_DATA";

    public static string DataDirectory(string localAppData) => Path.Combine(localAppData, "Verbemo Data");
    public static string RecordingsDirectory(string home) => Path.Combine(home, "Verbemo Recordings");
}
