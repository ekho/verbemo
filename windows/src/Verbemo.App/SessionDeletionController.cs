using System.IO;
namespace Verbemo.App;

internal sealed class SessionDeletionController(Func<string, IDisposable?> reserve, Action<string> recycle,
    Func<CancellationToken, Task>? delay = null) : IDisposable
{
    private sealed record Pending(IDisposable Reservation, CancellationTokenSource Cancellation);
    private readonly Dictionary<string, Pending> pending = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<Task> work = [];
    private readonly Lock gate = new();
    private bool disposed;
    public event EventHandler? Changed;
    public event EventHandler<Exception>? Failed;
    public Task WhenIdle { get { lock(gate) return Task.WhenAll(work.ToArray()); } }
    public bool IsPending(string directory) { lock(gate) return pending.ContainsKey(directory); }

    public void Schedule(string directory)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (pending.ContainsKey(directory)) return;
            var reservation = reserve(directory) ?? throw new InvalidOperationException("This meeting is being processed.");
            var entry = new Pending(reservation, new CancellationTokenSource());
            pending.Add(directory, entry);
            work.Add(CompleteAsync(directory, entry));
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Undo(string directory)
    {
        lock(gate)
        {
            if (!pending.Remove(directory, out var entry)) return;
            entry.Cancellation.Cancel();
            entry.Reservation.Dispose();
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private async Task CompleteAsync(string directory, Pending entry)
    {
        try
        {
            await (delay?.Invoke(entry.Cancellation.Token) ?? Task.Delay(TimeSpan.FromSeconds(6.5), entry.Cancellation.Token)).ConfigureAwait(false);
            lock (gate)
            {
                if (entry.Cancellation.IsCancellationRequested || !pending.Remove(directory)) return;
                try { recycle(directory); }
                finally { entry.Reservation.Dispose(); }
            }
        }
        catch (OperationCanceledException) when (entry.Cancellation.IsCancellationRequested) { }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        { Failed?.Invoke(this, error); }
        finally { entry.Cancellation.Dispose(); Changed?.Invoke(this, EventArgs.Empty); }
    }

    public void Dispose()
    {
        lock(gate)
        {
            if (disposed) return;
            disposed = true;
            foreach (var key in pending.Keys.ToArray()) Undo(key);
        }
    }
}
