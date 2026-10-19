namespace Verbemo.App;

/// <summary>Holds primary ownership from before Velopack startup until the app exits.</summary>
internal sealed class UpdateStartupAdmission : IDisposable
{
    private readonly Mutex mutex;
    private bool disposed;
    public bool IsPrimary { get; }
    public EventWaitHandle Doorbell { get; }

    public UpdateStartupAdmission(string instanceName, string doorbellName)
    {
        mutex = new Mutex(initiallyOwned: true, instanceName, out var primary);
        IsPrimary = primary;
        try
        {
            // A secondary launch may arrive while the primary is still inside Velopack.Run.
            Doorbell = new EventWaitHandle(false, EventResetMode.AutoReset, doorbellName);
        }
        catch
        {
            try { if (IsPrimary) mutex.ReleaseMutex(); }
            finally { mutex.Dispose(); }
            throw;
        }
    }

    public bool SignalExistingInstance()
    {
        if (IsPrimary) return false;
        return Doorbell.Set();
    }

    // Mutex ownership belongs to the startup thread; Main disposes on that same thread.
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        try { Doorbell.Dispose(); }
        finally
        {
            try { if (IsPrimary) mutex.ReleaseMutex(); }
            finally { mutex.Dispose(); }
        }
    }
}
