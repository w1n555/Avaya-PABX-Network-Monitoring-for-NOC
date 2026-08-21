namespace CmApi.Services;

/// <summary>
/// IIS start: ensure CDR logger is listening so CM can push before anyone logs in.
/// Failure is non-fatal — Login / CDR tab will retry.
/// </summary>
public sealed class CdrLoggerWarmupService : IHostedService
{
    private readonly CdrLoggerHost _host;
    private readonly ILogger<CdrLoggerWarmupService> _log;

    public CdrLoggerWarmupService(CdrLoggerHost host, ILogger<CdrLoggerWarmupService> log)
    {
        _host = host;
        _log = log;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                var r = await _host.EnsureRunningAsync(cancellationToken).ConfigureAwait(false);
                _log.LogInformation("CDR logger warmup {Reason} listening={Listening}", r.Reason, r.Listening);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "CDR logger warmup deferred (will start on Login)");
            }
        }, cancellationToken);
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
