namespace CmApi.Services;

/// <summary>
/// On IIS/app start, try to launch OSSI bridge in background so Login is faster.
/// Failure is non-fatal — Login will retry EnsureBridgeRunning.
/// </summary>
public sealed class BridgeWarmupService : IHostedService
{
    private readonly OssiBridgeClient _bridge;
    private readonly ILogger<BridgeWarmupService> _log;

    public BridgeWarmupService(OssiBridgeClient bridge, ILogger<BridgeWarmupService> log)
    {
        _bridge = bridge;
        _log = log;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await _bridge.EnsureBridgeRunningAsync(cancellationToken).ConfigureAwait(false);
                _log.LogInformation("OSSI bridge warmup OK");
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "OSSI bridge warmup deferred (will start on Login)");
            }
        }, cancellationToken);
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
