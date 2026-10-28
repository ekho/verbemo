using System.Globalization;
using System.Buffers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Verbemo.Core.MCP;

/// <summary>Strict streaming JSON and UTF-8: source size is independent of response size.</summary>
internal static class McpTextArtifacts
{
    private static void ValidateUtf8(Decoder decoder, ReadOnlySpan<byte> bytes, bool final)
    {
        Span<char> characters = stackalloc char[1024];
        try
        {
            bool completed;
            do { decoder.Convert(bytes, characters, final, out var used, out _, out completed); bytes = bytes[used..]; } while (!completed);
        }
        catch (DecoderFallbackException) { throw new McpFailure("data_unreadable"); }
    }
    internal sealed record Text(long Start, long End, long Bytes, string? Value);
    internal sealed record Segment(long Index, long Start, long End, string? Speaker, Text Text);
    internal sealed class Reader(McpFiles.AudioHandle file, Action check, long offset = 0)
    {
        private static readonly SearchValues<byte> StringSpecial = SearchValues.Create(Enumerable.Range(0, 32).Select(x => (byte)x).Concat(new byte[] { 34, 92 }).ToArray());
        private byte[] buffer = []; private long projectedBytes; private long bufferStart; private long position = offset;
        public long Position => position;
        private int Peek() { if (position >= file.Size) return -1; if (buffer.Length == 0 || position < bufferStart || position >= bufferStart + buffer.Length) { check(); bufferStart = position; buffer = file.Read(position, 65536); } return buffer[(int)(position - bufferStart)]; }
        private int Take() { var b = Peek(); if (b < 0) throw new McpFailure("data_unreadable"); position++; return b; }
        private void Space() { while (Peek() is 32 or 9 or 10 or 13) position++; }
        private void Expect(int value) { Space(); if (Take() != value) throw new McpFailure("data_unreadable"); }
        public void End() { Space(); if (Peek() != -1) throw new McpFailure("data_unreadable"); file.Validate(); }
        public Text String(int retain = 0, Action<byte[]>? emit = null)
        {
            Space(); var start = position; Expect('"'); long count = 0; var bytes = new List<byte>(4096); var decoder = McpContract.Utf8.GetDecoder(); using var saved = retain > 0 ? new MemoryStream() : null;
            void Flush(bool final)
            {
                var chunk = bytes.ToArray();
                ValidateUtf8(decoder, chunk, final);
                count += chunk.Length; if (saved is not null && count <= retain) saved.Write(chunk);
                emit?.Invoke(chunk); bytes.Clear();
            }
            void Add(byte value) { bytes.Add(value); if (bytes.Count >= 4096) Flush(false); }
            int Hex() { var result = 0; for (var i = 0; i < 4; i++) { var b = Take(); var n = b is >= '0' and <= '9' ? b - '0' : b is >= 'a' and <= 'f' ? b - 'a' + 10 : b is >= 'A' and <= 'F' ? b - 'A' + 10 : -1; if (n < 0) throw new McpFailure("data_unreadable"); result = result * 16 + n; } return result; }
            while (true)
            {
                var next = Peek();
                if (next >= 32 && next is not (34 or 92))
                {
                    if (bytes.Count > 0) Flush(false);
                    var span = buffer.AsSpan((int)(position - bufferStart)); var stop = span.IndexOfAny(StringSpecial);
                    if (stop >= 0) span = span[..stop];
                    ValidateUtf8(decoder, span, false);
                    count += span.Length; if (saved is not null && count <= retain) saved.Write(span); if (emit is not null) emit(span.ToArray()); position += span.Length; continue;
                }
                var b = Take(); if (b == '"') break; if (b < 32) throw new McpFailure("data_unreadable");
                if (b != '\\') { Add((byte)b); continue; }
                b = Take();
                if (b == 'u')
                {
                    var scalar = Hex();
                    if (scalar is >= 0xd800 and <= 0xdbff) { if (Take() != '\\' || Take() != 'u') throw new McpFailure("data_unreadable"); var low = Hex(); if (low is < 0xdc00 or > 0xdfff) throw new McpFailure("data_unreadable"); scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00; }
                    else if (scalar is >= 0xdc00 and <= 0xdfff) throw new McpFailure("data_unreadable");
                    foreach (var encoded in McpContract.Utf8.GetBytes(char.ConvertFromUtf32(scalar))) Add(encoded);
                }
                else Add(b switch { '"' => (byte)'"', '\\' => (byte)'\\', '/' => (byte)'/', 'b' => 8, 'f' => 12, 'n' => 10, 'r' => 13, 't' => 9, _ => throw new McpFailure("data_unreadable") });
            }
            Flush(true); return new(start, position, count, saved is not null && count <= retain ? McpContract.Utf8.GetString(saved.ToArray()) : null);
        }
        public string RequiredString() => String(McpContract.HardResponseBytes).Value ?? throw new McpFailure("response_too_large");
        public void Object(Action<string?> property)
        {
            Expect('{'); Space(); if (Peek() == '}') { position++; return; }
            while (true) { var key = String(McpContract.HardResponseBytes).Value; Expect(':'); property(key); Space(); var b = Take(); if (b == '}') break; if (b != ',') throw new McpFailure("data_unreadable"); }
        }
        public void Array(Action<long> item)
        {
            Expect('['); Space(); if (Peek() == ']') { position++; return; } long index = 0;
            while (true) { item(index++); Space(); var b = Take(); if (b == ']') break; if (b != ',') throw new McpFailure("data_unreadable"); }
        }
        public JsonNode? Scalar()
        {
            Space(); if (Peek() == '"') return JsonValue.Create(RequiredString()); var text = new StringBuilder();
            while (Peek() >= 0 && Peek() is not (32 or 9 or 10 or 13 or ',' or '}' or ']')) { if (text.Length == 128) throw new McpFailure("data_unreadable"); text.Append((char)Take()); }
            try { var value = JsonNode.Parse(text.ToString()); if (value is JsonArray or JsonObject) throw new McpFailure("data_unreadable"); return value; } catch (System.Text.Json.JsonException) { throw new McpFailure("data_unreadable"); }
        }
        public bool Null()
        {
            Space(); if (Peek() != 'n') return false;
            if (Scalar() is not null) throw new McpFailure("data_unreadable"); return true;
        }
        public void Skip(int depth = 0)
        {
            if (depth > 128) throw new McpFailure("data_unreadable"); Space();
            if (Peek() == '"') String(); else if (Peek() == '{') Object(_ => Skip(depth + 1)); else if (Peek() == '[') Array(_ => Skip(depth + 1)); else Scalar();
        }
        public JsonNode? Project(Func<string[], bool> include, string[]? path = null, int depth = 0)
        {
            path ??= []; projectedBytes += 8; if (projectedBytes > McpContract.HardResponseBytes) throw new McpFailure("response_too_large"); if (depth > 128) throw new McpFailure("data_unreadable"); Space();
            if (Peek() == '{') { var obj = new JsonObject(); Object(key => { if (key is null || !include([..path, key])) { Skip(depth + 1); return; } if (obj.ContainsKey(key)) throw new McpFailure("data_unreadable"); obj[key] = Project(include, [..path, key], depth + 1); }); return obj; }
            if (Peek() == '[') { var arr = new JsonArray(); Array(_ => { arr.Add(Project(include, path, depth + 1)); if (arr.Count > McpContract.HardResponseBytes / 8) throw new McpFailure("response_too_large"); }); return arr; }
            var scalar = Scalar(); projectedBytes += scalar is JsonValue value && value.TryGetValue<string>(out var text) ? McpContract.Utf8.GetByteCount(text) : 32; if (projectedBytes > McpContract.HardResponseBytes) throw new McpFailure("response_too_large"); return scalar;
        }
        public Segment ReadSegment(long index)
        {
            string? speaker = null; long? start = null, end = null; Text? text = null; var keys = new HashSet<string>();
            Object(key => {
                if (key is not ("speaker" or "start_ms" or "end_ms" or "text")) { Skip(); return; }
                if (!keys.Add(key)) throw new McpFailure("data_unreadable");
                switch (key) { case "text": text = String(); break; case "speaker": var value = Scalar(); speaker = value is null ? null : McpContract.Text(value) ?? throw new McpFailure("data_unreadable"); break; case "start_ms": start = McpContract.Integer(Scalar()); break; case "end_ms": end = McpContract.Integer(Scalar()); break; }
            });
            if (start is null or < 0 || end is null || end < start || text is null) throw new McpFailure("data_unreadable"); return new(index, start.Value, end.Value, speaker, text);
        }
    }
    internal sealed class Transcript
    {
        private readonly McpFiles.AudioHandle file; private readonly Action check; private readonly long arrayOffset;
        public string Engine { get; } public string Model { get; } public string CreatedAt { get; } public DateTimeOffset CreatedDate { get; }
        public string RawHash { get; } public string Id { get; } public long Count { get; private set; } public long Unknown { get; private set; }
        public HashSet<string>? Labels { get; private set; } = [];
        public Transcript(McpFiles.AudioHandle file, Action check, string generation = "", bool labels = true)
        {
            this.file = file; this.check = check; var reader = new Reader(file, check); var headers = new Dictionary<string, string>(); long? segments = null;
            reader.Object(key => { if (key is "engine" or "model" or "created_at") { if (!headers.TryAdd(key, reader.RequiredString())) throw new McpFailure("data_unreadable"); } else if (key == "segments") { if (segments is not null) throw new McpFailure("data_unreadable"); segments = reader.Position; reader.Skip(); } else reader.Skip(); }); reader.End();
            if (!headers.TryGetValue("engine", out var engine) || !headers.TryGetValue("model", out var model) || !headers.TryGetValue("created_at", out var created) || McpContract.Date(created) is not { } date || segments is null) throw new McpFailure("data_unreadable");
            Engine = engine; Model = model; CreatedAt = created; CreatedDate = date; arrayOffset = segments.Value; RawHash = file.Hash(check);
            if (!labels) Labels = null; using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            void Frame(string value) { hash.AppendData(McpContract.Utf8.GetBytes(McpContract.Framed([value]))); }
            Frame(Engine); Frame(Model); Frame(CreatedDate.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture)); var labelBytes = 0;
            Each(segment => { Count++; if (McpContract.Unknown(segment.Speaker)) Unknown++; if (segment.Speaker is { Length: > 0 } label && Labels is not null && Labels.Add(label)) { labelBytes += McpContract.Utf8.GetByteCount(label); if (labelBytes > McpContract.HardResponseBytes / 4 || Labels.Count > 16384) Labels = null; }
                Frame(segment.Speaker ?? ""); Frame(segment.Start.ToString(CultureInfo.InvariantCulture)); Frame(segment.End.ToString(CultureInfo.InvariantCulture)); hash.AppendData(McpContract.Utf8.GetBytes(segment.Text.Bytes.ToString(CultureInfo.InvariantCulture) + ":")); new Reader(file, check, segment.Text.Start).String(emit: hash.AppendData); return true; });
            Frame(generation); Id = "v_" + Convert.ToHexStringLower(hash.GetHashAndReset());
        }
        private sealed class StopIteration : Exception;
        public void Each(Func<Segment, bool> emit)
        {
            var reader = new Reader(file, check, arrayOffset);
            try { reader.Array(index => { check(); if (!emit(reader.ReadSegment(index))) throw new StopIteration(); }); } catch (StopIteration) { }
            file.Validate();
        }
        public string Text(Segment segment) => new Reader(file, check, segment.Text.Start).RequiredString();
        public void Search(Segment segment, string query, Func<string, long, bool> emit)
        {
            var matcher = new Matcher(query, emit); var decoder = McpContract.Utf8.GetDecoder();
            try { new Reader(file, check, segment.Text.Start).String(emit: bytes => { var chars = new char[McpContract.Utf8.GetMaxCharCount(bytes.Length)]; var count = decoder.GetChars(bytes, chars, false); if (!matcher.Append(new string(chars, 0, count), false)) throw new StopIteration(); }); matcher.Append("", true); } catch (StopIteration) { }
        }
    }
    internal sealed class Summary
    {
        private readonly McpFiles.AudioHandle file; private readonly Action check;
        public string Revision { get; }
        public Summary(McpFiles.AudioHandle file, Action check) { this.file = file; this.check = check; var decoder = McpContract.Utf8.GetDecoder(); using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256); for (long offset = 0; offset < file.Size;) { check(); var bytes = file.Read(offset, 65536); offset += bytes.Length; ValidateUtf8(decoder, bytes, offset == file.Size); hash.AppendData(bytes); } Revision = Convert.ToHexStringLower(hash.GetHashAndReset()); }
        public (string Text, long? Next) Page(long offset)
        {
            if (offset < 0 || offset > file.Size) throw new McpFailure("invalid_cursor"); check(); var bytes = file.Read(offset, 65536); var count = bytes.Length;
            if (count > 0 && (bytes[0] & 0xc0) == 0x80) throw new McpFailure("invalid_cursor");
            if (offset + count < file.Size) { var lead = count - 1; while (lead > 0 && (bytes[lead] & 0xc0) == 0x80) lead--; var width = bytes[lead] < 0x80 ? 1 : bytes[lead] < 0xe0 ? 2 : bytes[lead] < 0xf0 ? 3 : 4; if (count - lead < width) count = lead; }
            try { return (McpContract.Utf8.GetString(bytes, 0, count), offset + count < file.Size ? offset + count : null); } catch (DecoderFallbackException) { throw new McpFailure("data_unreadable"); }
        }
        public void Search(string query, Func<string, long, bool> emit)
        {
            var matcher = new Matcher(query, emit); var decoder = McpContract.Utf8.GetDecoder();
            for (long offset = 0; offset < file.Size;) { check(); var bytes = file.Read(offset, 65536); offset += bytes.Length; var chars = new char[McpContract.Utf8.GetMaxCharCount(bytes.Length)]; var count = decoder.GetChars(bytes, chars, offset == file.Size); if (!matcher.Append(new string(chars, 0, count), offset == file.Size)) return; }
        }
    }
    private sealed class Matcher(string query, Func<string, long, bool> emit)
    {
        private string buffer = ""; private long baseOffset, processed;
        public bool Append(string text, bool final)
        {
            buffer += text; var safe = final ? buffer.Length : Math.Max(0, buffer.Length - Math.Max(4096, query.Length * 4 + 1600));
            for (var start = 0; start < buffer.Length;) { var at = buffer.IndexOf(query, start, StringComparison.OrdinalIgnoreCase); if (at < 0 || (!final && at >= safe)) break; var offset = baseOffset + McpContract.Utf8.GetByteCount(buffer.AsSpan(0, at)); if (offset >= processed) { var begin = Math.Max(0, at - 120); if (begin > 0 && char.IsLowSurrogate(buffer[begin])) begin--; var end = Math.Min(buffer.Length, begin + 400); if (end < buffer.Length && char.IsLowSurrogate(buffer[end])) end--; if (!emit(buffer[begin..end], offset)) return false; } start = at + query.Length; }
            if (safe < buffer.Length && safe > 0 && char.IsLowSurrogate(buffer[safe])) safe--; processed = baseOffset + McpContract.Utf8.GetByteCount(buffer.AsSpan(0, safe)); var drop = Math.Max(0, safe - 1600); if (drop < buffer.Length && drop > 0 && char.IsLowSurrogate(buffer[drop])) drop--; baseOffset += McpContract.Utf8.GetByteCount(buffer.AsSpan(0, drop)); buffer = buffer[drop..]; return true;
        }
    }
}
