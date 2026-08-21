using System.Diagnostics;
using System.Net.NetworkInformation;

namespace CmApi.Services;

/// <summary>
/// Portable CDR TCP logger: listen 0.0.0.0:{port} under the site folder.
/// Skip if already listening. Never taskkill. Never fail Login.
/// </summary>
public sealed class CdrLoggerHost
{
    private readonly string _siteRoot;
    private readonly IConfiguration _config;
    private readonly ILogger<CdrLoggerHost> _log;
    private readonly SemaphoreSlim _startLock = new(1, 1);
    private DateTimeOffset _lastAttemptUtc = DateTimeOffset.MinValue;

    public CdrLoggerHost(string siteRoot, IConfiguration config, ILogger<CdrLoggerHost> log)
    {
        _siteRoot = siteRoot;
        _config = config;
        _log = log;
    }

    public bool Enabled =>
        !string.Equals(_config["CdrLogger:Enabled"], "false", StringComparison.OrdinalIgnoreCase);

    public int Port
    {
        get
        {
            var s = _config["CdrLogger:Port"];
            if (int.TryParse(s, out var p) && p is > 0 and < 65536) return p;
            return 9000;
        }
    }

    public string Bind
    {
        get
        {
            var b = (_config["CdrLogger:Bind"] ?? "0.0.0.0").Trim();
            return string.IsNullOrWhiteSpace(b) ? "0.0.0.0" : b;
        }
    }

    public bool IsListening() => PortIsListening(Port);

    public async Task<CdrEnsureResult> EnsureRunningAsync(CancellationToken ct = default)
    {
        var port = Port;
        var bind = Bind;
        if (!Enabled)
            return new CdrEnsureResult(true, false, "disabled", port, bind, IsListening());

        if (IsListening())
            return new CdrEnsureResult(true, false, "already-listening", port, bind, true);

        if (DateTimeOffset.UtcNow - _lastAttemptUtc < TimeSpan.FromSeconds(20))
            return new CdrEnsureResult(true, false, "cooldown", port, bind, false);

        await _startLock.WaitAsync(ct).ConfigureAwait(false);
        Mutex? cross = null;
        try
        {
            try
            {
                cross = new Mutex(false, @"Global\CM-NOC-CdrLogger-" + port);
                if (!cross.WaitOne(TimeSpan.FromSeconds(3), false))
                    return new CdrEnsureResult(true, false, "start-in-progress", port, bind, IsListening());
            }
            catch
            {
                cross = null;
            }

            if (IsListening())
                return new CdrEnsureResult(true, false, "already-listening", port, bind, true);

            _lastAttemptUtc = DateTimeOffset.UtcNow;
            try
            {
                StartLoggerProcess(port, bind);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "CDR logger Process.Start failed");
                return new CdrEnsureResult(false, true, ex.Message, port, bind, false);
            }

            for (var i = 0; i < 12; i++)
            {
                await Task.Delay(250, ct).ConfigureAwait(false);
                if (IsListening())
                {
                    _log.LogInformation("CDR logger listening {Bind}:{Port}", bind, port);
                    return new CdrEnsureResult(true, true, "started", port, bind, true);
                }
            }

            _log.LogWarning("CDR logger did not bind {Bind}:{Port} within 3s", bind, port);
            return new CdrEnsureResult(false, true, "start-timeout", port, bind, false);
        }
        finally
        {
            try { cross?.ReleaseMutex(); } catch { /* ignore */ }
            try { cross?.Dispose(); } catch { /* ignore */ }
            _startLock.Release();
        }
    }

    private void StartLoggerProcess(int port, string bind)
    {
        var cdrLink = Path.Combine(_siteRoot, "cdr-link");
        var script = Path.Combine(cdrLink, "cdr_logger.py");
        if (!File.Exists(script))
            throw new InvalidOperationException("cdr_logger.py not found at " + script);

        var logDir = Path.Combine(cdrLink, "cdr");
        Directory.CreateDirectory(logDir);
        Directory.CreateDirectory(Path.Combine(cdrLink, "logs"));

        var bat = Path.Combine(cdrLink, "ensure-cdr-logger.bat");
        if (File.Exists(bat))
        {
            var psiBat = new ProcessStartInfo
            {
                FileName = bat,
                Arguments = $"{port} {bind}",
                WorkingDirectory = cdrLink,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                CreateNoWindow = true,
            };
            Process.Start(psiBat);
            _log.LogInformation("Started CDR logger via bat port={Port} bind={Bind}", port, bind);
            return;
        }

        var py = ResolvePython();
        var psi = new ProcessStartInfo
        {
            FileName = py,
            Arguments = $"\"{script}\" --host {bind} --port {port} --log-dir \"{logDir}\"",
            WorkingDirectory = cdrLink,
            UseShellExecute = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            CreateNoWindow = true,
        };
        var p = Process.Start(psi);
        if (p == null)
            throw new InvalidOperationException("Process.Start returned null for " + py);
        _log.LogInformation("Started CDR logger PID {Pid} via {Python}", p.Id, py);
    }

    private string ResolvePython()
    {
        var configured = _config["OssiBridge:Python"] ?? _config["CdrLogger:Python"];
        if (!string.IsNullOrWhiteSpace(configured) && File.Exists(configured.Trim()))
            return configured.Trim();

        foreach (var rel in new[]
                 {
                     Path.Combine("python", ".venv", "Scripts", "python.exe"),
                     Path.Combine("python", "runtime", "python.exe"),
                 })
        {
            var p = Path.Combine(_siteRoot, rel);
            if (File.Exists(p)) return p;
        }

        return "python";
    }

    public static bool PortIsListening(int port)
    {
        try
        {
            foreach (var ep in IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners())
            {
                if (ep.Port == port) return true;
            }
        }
        catch
        {
            /* ignore */
        }

        return false;
    }
}

public sealed record CdrEnsureResult(
    bool Ok,
    bool Started,
    string Reason,
    int Port,
    string Bind,
    bool Listening);
