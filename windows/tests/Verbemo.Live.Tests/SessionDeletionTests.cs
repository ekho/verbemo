using Verbemo.App;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class SessionDeletionTests
{
    [Fact]
    public async Task Undo_and_shutdown_cancel_before_recycle_and_release_reservation()
    {
        var released = 0;
        var recycled = 0;
        var delay = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var controller = new SessionDeletionController(_ => new Release(() => released++), _ => recycled++,
            token => delay.Task.WaitAsync(token));
        controller.Schedule("one");
        Assert.True(controller.IsPending("one"));
        controller.Undo("one");
        Assert.Equal(1, released);
        controller.Schedule("two");
        controller.Dispose();
        delay.TrySetResult();
        await controller.WhenIdle;
        Assert.Equal(2, released);
        Assert.Equal(0, recycled);
    }
    [Fact]
    public async Task Recycle_failure_restores_visibility_and_reports_error()
    {
        var delay = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var controller = new SessionDeletionController(_ => new Release(() => {}), _ => throw new IOException("Denied"),
            token => delay.Task.WaitAsync(token));
        Exception? error = null;
        controller.Failed += (_, e) => error = e;
        controller.Schedule("one");
        delay.TrySetResult();
        await controller.WhenIdle;
        Assert.False(controller.IsPending("one"));
        Assert.IsType<IOException>(error);
    }
    private sealed class Release(Action action) : IDisposable { public void Dispose() => action(); }
}
