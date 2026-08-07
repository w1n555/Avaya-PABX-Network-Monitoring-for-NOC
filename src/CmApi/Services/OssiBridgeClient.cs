using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace CmApi.Services;

/// <summary>
/// HTTP client for local Python OSSI bridge (avaya-ossi).
/// Auto-starts the bridge on 127.0.0.1 when Login / API needs it — no manual start.
/// </summary>
public sealed class OssiBridgeClient
{
    public const string DefaultBase = "http://127.0.0.1:18765";
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly HttpClient _http;
    private readonly ILogger<OssiBridgeClient> _log;
    private readonly string _dataDir;
    private readonly string _pythonDir;
    private readonly string _pythonExe;
    private readonly string? _ossiSrc;
    private readonly string _logDir;
    private readonly SemaphoreSlim _startLock = new(1, 1);

    public OssiBridgeClient(IConfiguration config, ILogger<OssiBridgeClient> log)
    {
        _log = log;
        var baseUrl = config["OssiBridge:BaseUrl"] ?? DefaultBase;
        // Prefer config from install.ps1; else derive from api\ publish folder → parent site root
        var siteRoot = config["OssiBridge:SiteRoot"];
        if (string.IsNullOrWhiteSpace(siteRoot))
            siteRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
        siteRoot = siteRoot.Trim();

        _dataDir = string.IsNullOrWhiteSpace(config["OssiBridge:DataDir"])
            ? Path.Combine(siteRoot, "data")
            : config["OssiBridge:DataDir"]!.Trim();
        _pythonDir = Path.Combine(siteRoot, "python");

        var ossiSrcCfg = config["OssiBridge:OssiSrc"];
        if (!string.IsNullOrWhiteSpace(ossiSrcCfg) && Directory.Exists(ossiSrcCfg))
            _ossiSrc = ossiSrcCfg.Trim();
        else
        {
            var vendored = Path.Combine(siteRoot, "vendor", "avaya-ossi", "src");
            _ossiSrc = Directory.Exists(vendored) ? vendored : null;
        }

        _logDir = Path.Combine(_dataDir, "logs");
        Directory.CreateDirectory(_dataDir);
        Directory.CreateDirectory(_logDir);

        var configuredPy = config["OssiBridge:Python"];
        if (!string.IsNullOrWhiteSpace(configuredPy) && File.Exists(configuredPy.Trim()))
            _pythonExe = configuredPy.Trim();
        else
            _pythonExe = FindPythonWithAvayaOssi();

        _http = new HttpClient
        {
            BaseAddress = new Uri(baseUrl.TrimEnd('/') + "/"),
            Timeout = TimeSpan.FromMinutes(3),
        };

        _log.LogInformation("OssiBridge python={Python} scriptDir={Dir}", _pythonExe, _pythonDir);
    }

    private List<string> PythonCandidates()
    {
        // Portable: site venv first, then standard install locations only (no user-specific tools)
        var list = new List<string>
        {
            Path.Combine(_pythonDir, @".venv\Scripts\python.exe"),
        };
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        foreach (var ver in new[] { "Python313", "Python312", "Python311" })
        {
            list.Add(Path.Combine(local, "Programs", "Python", ver, "python.exe"));
            list.Add(Path.Combine(pf, ver, "python.exe"));
        }
        // Common AllUsers silent-install layouts
        list.Add(@"C:\Python313\python.exe");
        list.Add(@"C:\Python312\python.exe");
        list.Add(@"C:\Python311\python.exe");
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "where.exe",
                Arguments = "python",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi);
            if (p != null)
            {
                var output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(3000);
                foreach (var line in output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                    list.Add(line.Trim());
            }
        }
        catch { /* ignore */ }
        list.Add("python");
        return list;
    }

    private string FindPythonWithAvayaOssi()
    {
        foreach (var c in PythonCandidates())
        {
            if (c != "python" && !File.Exists(c))
                continue;
            if (CanImportAvayaOssi(c))
                return c;
        }
        // fall back to first existing file even if import check failed (will surface error on start)
        foreach (var c in PythonCandidates())
        {
            if (c == "python" || File.Exists(c))
                return c;
        }
        return "python";
    }

    private bool CanImportAvayaOssi(string pythonExe)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = pythonExe,
                ArgumentList = { "-c", "import avaya_ossi" },
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            if (!string.IsNullOrWhiteSpace(_ossiSrc) && Directory.Exists(_ossiSrc))
                psi.Environment["PYTHONPATH"] = PrependPath(psi.Environment, "PYTHONPATH", _ossiSrc);

            using var p = Process.Start(psi);
            if (p == null) return false;
            if (!p.WaitForExit(8000))
            {
                try { p.Kill(true); } catch { /* ignore */ }
                return false;
            }
            return p.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    private static string PrependPath(System.Collections.Generic.IDictionary<string, string?> env, string key, string value)
    {
        env.TryGetValue(key, out var cur);
        if (string.IsNullOrEmpty(cur)) return value;
        return value + Path.PathSeparator + cur;
    }

    /// <summary>Start bridge if needed. Safe to call on every Login / request.</summary>
    public async Task EnsureBridgeRunningAsync(CancellationToken ct = default)
    {
        if (await HealthyAsync(ct).ConfigureAwait(false))
            return;

        await _startLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (await HealthyAsync(ct).ConfigureAwait(false))
                return;

            Exception? startEx = null;
            try
            {
                StartBridgeProcess();
            }
            catch (Exception ex)
            {
                startEx = ex;
                _log.LogWarning(ex, "Direct Process.Start failed; trying scheduled task CM-NOC-OSSI-Bridge");
                TryRunScheduledTask();
            }

            for (var i = 0; i < 40; i++)
            {
                await Task.Delay(250, ct).ConfigureAwait(false);
                if (await HealthyAsync(ct).ConfigureAwait(false))
                {
                    _log.LogInformation("OSSI bridge is healthy");
                    return;
                }
            }

            var errTail = ReadLogTail(Path.Combine(_logDir, "bridge.stderr.log"), 1200);
            var hint = startEx?.Message ?? "";
            throw new InvalidOperationException(
                "OSSI bridge did not start on 127.0.0.1:18765. " +
                "Login needs the bridge auto-running. " +
                "Once as Admin run: scripts\\install-bridge-autostart.ps1 " +
                "or ensure site venv python works. " +
                hint + " " +
                (string.IsNullOrEmpty(errTail) ? "" : "stderr: " + errTail));
        }
        finally
        {
            _startLock.Release();
        }
    }

    private static void TryRunScheduledTask()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "schtasks.exe",
                Arguments = "/Run /TN \"CM-NOC-OSSI-Bridge\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using var p = Process.Start(psi);
            p?.WaitForExit(8000);
        }
        catch
        {
            /* optional path */
        }
    }

    private void StartBridgeProcess()
    {
        var script = Path.Combine(_pythonDir, "ossi_service.py");
        if (!File.Exists(script))
            throw new InvalidOperationException("ossi_service.py not found at " + script);

        var stdoutLog = Path.Combine(_logDir, "bridge.stdout.log");
        var stderrLog = Path.Combine(_logDir, "bridge.stderr.log");

        var psi = new ProcessStartInfo
        {
            FileName = _pythonExe,
            WorkingDirectory = _pythonDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            // Don't keep parent wait handles that IIS might care about
            RedirectStandardInput = false,
        };
        psi.ArgumentList.Add(script);
        psi.ArgumentList.Add("--host");
        psi.ArgumentList.Add("127.0.0.1");
        psi.ArgumentList.Add("--port");
        psi.ArgumentList.Add("18765");
        psi.ArgumentList.Add("--data-dir");
        psi.ArgumentList.Add(_dataDir);

        if (!string.IsNullOrWhiteSpace(_ossiSrc) && Directory.Exists(_ossiSrc))
        {
            psi.Environment["PYTHONPATH"] = PrependPath(psi.Environment, "PYTHONPATH", _ossiSrc!);
        }

        try
        {
            var p = Process.Start(psi);
            if (p == null)
                throw new InvalidOperationException("Process.Start returned null for " + _pythonExe);

            // Drain pipes to log files so the process never blocks on full buffers
            _ = Task.Run(() => PumpStream(p.StandardOutput, stdoutLog));
            _ = Task.Run(() => PumpStream(p.StandardError, stderrLog));

            _log.LogInformation("Started OSSI bridge PID {Pid} via {Python}", p.Id, _pythonExe);
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                $"Cannot start Python OSSI bridge (exe={_pythonExe}). {ex.Message}",
                ex);
        }
    }

    private static void PumpStream(StreamReader reader, string path)
    {
        try
        {
            using var w = new StreamWriter(path, append: true, Encoding.UTF8) { AutoFlush = true };
            while (!reader.EndOfStream)
            {
                var line = reader.ReadLine();
                if (line != null)
                    w.WriteLine(line);
            }
        }
        catch { /* ignore */ }
    }

    private static string ReadLogTail(string path, int maxChars)
    {
        try
        {
            if (!File.Exists(path)) return "";
            var text = File.ReadAllText(path);
            return text.Length <= maxChars ? text : text[^maxChars..];
        }
        catch { return ""; }
    }

    public async Task<bool> HealthyAsync(CancellationToken ct = default)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(2));
            using var res = await _http.GetAsync("health", cts.Token).ConfigureAwait(false);
            return res.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    public async Task<JsonElement> GetAsync(string path, CancellationToken ct = default)
    {
        await EnsureBridgeRunningAsync(ct).ConfigureAwait(false);
        using var res = await _http.GetAsync(path.TrimStart('/'), ct).ConfigureAwait(false);
        var text = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!res.IsSuccessStatusCode)
            throw new InvalidOperationException(ExtractError(text) ?? res.ReasonPhrase ?? "bridge error");
        return JsonSerializer.Deserialize<JsonElement>(text, JsonOpts);
    }

    private static readonly JsonSerializerOptions CamelJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public async Task<JsonElement> PostAsync(string path, object? body, CancellationToken ct = default)
    {
        await EnsureBridgeRunningAsync(ct).ConfigureAwait(false);
        // Use StringContent so Content-Length is set (Python bridge needs it; chunked can empty body)
        var json = JsonSerializer.Serialize(body ?? new { }, CamelJson);
        using var content = new StringContent(json, Encoding.UTF8, "application/json");
        using var res = await _http.PostAsync(path.TrimStart('/'), content, ct).ConfigureAwait(false);
        var text = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!res.IsSuccessStatusCode)
            throw new InvalidOperationException(ExtractError(text) ?? res.ReasonPhrase ?? "bridge error");
        return JsonSerializer.Deserialize<JsonElement>(text, JsonOpts);
    }

    public async Task<JsonElement> PutAsync(string path, object? body, CancellationToken ct = default)
    {
        await EnsureBridgeRunningAsync(ct).ConfigureAwait(false);
        var json = JsonSerializer.Serialize(body ?? new { }, CamelJson);
        using var content = new StringContent(json, Encoding.UTF8, "application/json");
        using var res = await _http.PutAsync(path.TrimStart('/'), content, ct).ConfigureAwait(false);
        var text = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!res.IsSuccessStatusCode)
            throw new InvalidOperationException(ExtractError(text) ?? res.ReasonPhrase ?? "bridge error");
        return JsonSerializer.Deserialize<JsonElement>(text, JsonOpts);
    }

    private static string? ExtractError(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            if (doc.RootElement.TryGetProperty("error", out var e))
                return e.GetString();
        }
        catch { /* ignore */ }
        return text.Length > 300 ? text[..300] : text;
    }
}
