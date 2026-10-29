using System.Text.Json.Nodes;
using Verbemo.Core.MCP;
using Xunit;

namespace Verbemo.Core.Tests;

public sealed class McpContractTests
{
    internal static JsonObject Fixture => JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "MCP", "contract.json")))!.AsObject();

    [Fact]
    public void Shared_semantic_ids_preserve_native_text_and_integer_timestamps()
    {
        foreach (var vector in Fixture["semantic_ids"]!.AsArray())
            Assert.Equal(vector!["expected"]!.GetValue<string>(), McpContract.VersionId(vector["transcript"]!.AsObject(), vector["generation"]!.GetValue<string>()));
    }

    [Fact]
    public void Shared_invalid_parameters_are_rejected_before_library_access()
    {
        var runtime = new McpLibrary.Runtime(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()));
        foreach (var vector in Fixture["parameter_errors"]!.AsArray())
        {
            var error = Assert.Throws<McpFailure>(() => McpQueries.Call(vector!["tool"]!.GetValue<string>(), vector["arguments"]!.AsObject(), runtime));
            Assert.Equal(vector!["code"]!.GetValue<string>(), error.Code);
        }
    }
}
