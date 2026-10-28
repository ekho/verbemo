using Xunit;

namespace Verbemo.Live.Tests;

public sealed class McpReadReservationTests
{
    [Fact]
    public async Task Read_reservation_excludes_writers_without_publishing_activity()
    {
        await using var fixture = await SummaryRegenerationTests.Fixture.Create(); var processor = fixture.Processor; var events = 0; processor.StatusChanged += (_, _) => events++;
        using (var read = processor.TryReserveReadSession(fixture.Directory, () => false))
        {
            Assert.NotNull(read); Assert.False(processor.IsBusy); Assert.Null(processor.StatusFor(fixture.Directory)); Assert.Empty(processor.Activity.Running); Assert.Equal(0, processor.Activity.Waiting);
            Assert.Null(processor.TryReserveIdleSession(fixture.Directory)); Assert.Null(processor.TryReserveReadSession(fixture.Directory, () => false));
            await Assert.ThrowsAsync<InvalidOperationException>(() => processor.RegenerateSummaryAsync(fixture.Directory));
            await Assert.ThrowsAsync<InvalidOperationException>(() => processor.RetranscribeAsync(fixture.Directory, null));
            Assert.Equal(0, events); Assert.Equal(0, fixture.Calls);
        }
        Assert.Null(processor.TryReserveReadSession(fixture.Directory, () => true));
        using var writer = processor.TryReserveIdleSession(fixture.Directory); Assert.NotNull(writer); Assert.Null(processor.TryReserveReadSession(fixture.Directory, () => false));
    }

    [Fact]
    public async Task Queue_request_during_read_is_deferred_until_release()
    {
        await using var fixture = await SummaryRegenerationTests.Fixture.Create(); var processor = fixture.Processor;
        using (var read = processor.TryReserveReadSession(fixture.Directory, () => false)) { Assert.NotNull(read); processor.Enqueue(fixture.Directory); Assert.False(processor.IsBusy); Assert.Equal(0, processor.Activity.Waiting); }
        Assert.True(processor.IsBusy); Assert.Equal(1, processor.Activity.Waiting); Assert.Null(processor.TryReserveReadSession(fixture.Directory, () => false));
    }
    [Fact]
    public async Task Pending_deletion_check_does_not_invert_the_deletion_controller_lock_order()
    {
        await using var fixture = await SummaryRegenerationTests.Fixture.Create();
        using var read = fixture.Processor.TryReserveReadSession(fixture.Directory, () =>
        {
            using var writer = Task.Run(() => fixture.Processor.TryReserveIdleSession(fixture.Directory)).WaitAsync(TimeSpan.FromSeconds(2)).GetAwaiter().GetResult();
            Assert.NotNull(writer); return false;
        });
        Assert.NotNull(read);
    }

}
