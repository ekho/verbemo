using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Verbemo.Core.Configuration;

public static class EmailAddresses
{
    public static List<string> Normalize(IEnumerable<string> addresses) => addresses
        .Select(address => address.Trim().ToLowerInvariant()).Where(address => address.Length > 0)
        .Distinct(StringComparer.Ordinal).ToList();

    public static List<string>? Parse(string text)
    {
        var addresses = Normalize(text.Split([',', ';', '\r', '\n']));
        return addresses.All(address => Regex.IsMatch(address, @"^[^\s@,;<>]+@[^\s@,;<>]+$")) ? addresses : null;
    }
}

// Keep the existing config key readable when it contains a single address.
public sealed class EmailAddressesConverter : JsonConverter<List<string>>
{
    public override bool HandleNull => true;

    public override List<string> Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType switch
        {
            JsonTokenType.Null => [],
            JsonTokenType.String => EmailAddresses.Normalize([reader.GetString()!]),
            _ => EmailAddresses.Normalize(JsonSerializer.Deserialize<List<string>>(ref reader, options) ?? []),
        };

    public override void Write(Utf8JsonWriter writer, List<string> value, JsonSerializerOptions options) =>
        JsonSerializer.Serialize(writer, EmailAddresses.Normalize(value), options);
}
