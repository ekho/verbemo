using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Verbemo.Core.MCP;

/// <summary>Ancestor handles deny delete/rename until the path walk and snapshot finish.</summary>
public static class McpFiles
{
    [StructLayout(LayoutKind.Sequential)] private struct Info
    {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint GetFileType(SafeFileHandle file);
    public sealed record Stamp(uint Volume, ulong Identity, long Size, long Modified, uint Attributes)
    {
        public string Revision => $"{Volume}:{Identity}:{Size}:{Modified}:{Attributes}";
        public bool IsDirectory => (Attributes & 16) != 0;
    }
    private static McpFailure Failure(int error) => new(error is 32 or 33 ? "artifact_not_ready" : "data_unreadable");
    private static Stamp Stat(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) throw Failure(Marshal.GetLastWin32Error());
        if ((info.Attributes & 1024) != 0 || GetFileType(handle) != 1) throw new McpFailure("data_unreadable");
        return new(info.Volume, ((ulong)info.IndexHigh << 32) | info.IndexLow, (long)(((ulong)info.SizeHigh << 32) | info.SizeLow), ((long)info.Write.dwHighDateTime << 32) | (uint)info.Write.dwLowDateTime, info.Attributes);
    }
    private static SafeFileHandle? Open(string path, bool directory, bool missing)
    {
        // Held files exclude in-place writers, keeping hashes and later reads consistent.
        // Delete sharing still permits rename/deletion while the original file stays pinned.
        var handle = CreateFileW(path, 0x80000000u, directory ? 3u : 5u, IntPtr.Zero, 3, 0x00200000u | (directory ? 0x02000000u : 0), IntPtr.Zero);
        if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); if (missing && error is 2 or 3) return null; throw Failure(error); }
        try { if (Stat(handle).IsDirectory != directory) throw new McpFailure("data_unreadable"); return handle; }
        catch { handle.Dispose(); throw; }
    }
    private static void Component(string name) { if (string.IsNullOrEmpty(name) || name is "." or ".." || name.IndexOfAny(['/', '\\', ':', '\0']) >= 0 || name.EndsWith('.') || name.EndsWith(' ')) throw new McpFailure("data_unreadable"); }
    public sealed class DirectoryHandle : IDisposable
    {
        private readonly List<SafeFileHandle> ancestors;
        private readonly SafeFileHandle handle;
        internal string PathName { get; }
        private DirectoryHandle(string path, SafeFileHandle handle, List<SafeFileHandle>? ancestors = null) { PathName = path; this.handle = handle; this.ancestors = ancestors ?? []; }
        public static DirectoryHandle Root(string path)
        {
            path = Path.GetFullPath(path); var root = Path.GetPathRoot(path)!;
            if (root.Length != 3 || root[1] != ':') throw new McpFailure("data_unreadable");
            var handles = new List<SafeFileHandle>();
            try
            {
                var current = root; handles.Add(Open(current, true, false)!);
                foreach (var part in path[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries)) { Component(part); current = Path.Combine(current, part); handles.Add(Open(current, true, false)!); }
                var last = handles[^1]; handles.RemoveAt(handles.Count - 1); return new(path, last, handles);
            }
            catch { foreach (var h in handles) h.Dispose(); throw; }
        }
        public Stamp Stamp => Stat(handle);
        public DirectoryHandle? Directory(string name, bool missing = false) { Component(name); var child = Open(Path.Combine(PathName, name), true, missing); return child is null ? null : new(Path.Combine(PathName, name), child); }
        public AudioHandle? File(string name) { Component(name); var child = Open(Path.Combine(PathName, name), false, true); return child is null ? null : new(child); }
        public string[] Directories()
        {
            try { return System.IO.Directory.EnumerateDirectories(PathName).Select(Path.GetFileName).Cast<string>().Order(StringComparer.Ordinal).ToArray(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new McpFailure("data_unreadable"); }
        }
        public string[] Entries()
        {
            try { return System.IO.Directory.EnumerateFileSystemEntries(PathName).Select(Path.GetFileName).Cast<string>().Order(StringComparer.Ordinal).ToArray(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new McpFailure("data_unreadable"); }
        }
        public void Dispose() { handle.Dispose(); foreach (var h in ancestors.AsEnumerable().Reverse()) h.Dispose(); }
    }
    public sealed class AudioHandle : IDisposable
    {
        private readonly SafeFileHandle handle;
        public Stamp Stamp { get; }
        public long Size => Stamp.Size;
        internal AudioHandle(SafeFileHandle handle) { this.handle = handle; Stamp = Stat(handle); }
        public void Validate() { if (Stat(handle) != Stamp) throw new McpFailure("content_changed"); }
        public byte[] Read(long offset, int count)
        {
            if (offset < 0 || count is < 0 or > 65536) throw new McpFailure("invalid_params");
            Validate(); var bytes = new byte[(int)Math.Min(count, Math.Max(0, Size - offset))]; var read = 0;
            try { while (read < bytes.Length) { var n = RandomAccess.Read(handle, bytes.AsSpan(read), offset + read); if (n == 0) throw new McpFailure("content_changed"); read += n; } }
            catch (IOException) { throw new McpFailure("data_unreadable"); }
            Validate(); return bytes;
        }
        internal string Hash(Action check)
        {
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            for (long offset = 0; offset < Size;) { check(); var bytes = Read(offset, 65536); hash.AppendData(bytes); offset += bytes.Length; }
            Validate(); return Convert.ToHexStringLower(hash.GetHashAndReset());
        }
        public void Dispose() => handle.Dispose();
    }
}
