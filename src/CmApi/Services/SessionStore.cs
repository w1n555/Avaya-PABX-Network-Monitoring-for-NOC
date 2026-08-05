using System.Collections.Concurrent;
using CmApi.Models;
using CmApi.Sat;

namespace CmApi.Services;

public sealed class CmSession : IDisposable
{
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public SatClient Client { get; } = new();
    public DateTimeOffset ConnectedAt { get; set; }
    public DateTimeOffset? LastSuccessAt { get; set; }
    public DateTimeOffset? LastAttemptAt { get; set; }
    public string? LastError { get; set; }
    public List<TrunkGroupDto> TrunkCache { get; set; } = new();
    public string Host => Client.Host;

    private readonly SemaphoreSlim _lock = new(1, 1);
    public async Task<T> WithLockAsync<T>(Func<Task<T>> action)
    {
        await _lock.WaitAsync().ConfigureAwait(false);
        try { return await action().ConfigureAwait(false); }
        finally { _lock.Release(); }
    }

    public T WithLock<T>(Func<T> action)
    {
        _lock.Wait();
        try { return action(); }
        finally { _lock.Release(); }
    }

    public void Dispose()
    {
        Client.Dispose();
        _lock.Dispose();
    }
}

/// <summary>In-memory sessions only — no disk logging of credentials.</summary>
public sealed class SessionStore
{
    private readonly ConcurrentDictionary<string, CmSession> _sessions = new();

    public CmSession Create()
    {
        var s = new CmSession();
        _sessions[s.Id] = s;
        return s;
    }

    public CmSession? Get(string? id)
    {
        if (string.IsNullOrEmpty(id)) return null;
        return _sessions.TryGetValue(id, out var s) ? s : null;
    }

    public void Remove(string? id)
    {
        if (string.IsNullOrEmpty(id)) return;
        if (_sessions.TryRemove(id, out var s))
            s.Dispose();
    }
}
