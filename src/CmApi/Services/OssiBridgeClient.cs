using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;

namespace CmApi.Services;

/// <summary>
/// HTTP client for local Python OSSI bridge (avaya-ossi).
/// Bridge must listen on 127.0.0.1 — never exposed publicly.
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
    private static readonly object StartGate = new();

    public OssiBridgeClient(IConfiguration config, ILogger<OssiBridgeClient> log)
    {
        _log = log;
        var baseUrl = config["OssiBridge:BaseUrl"] ?? DefaultBase;
        _dataDir = config["OssiBridge:DataDir"]
                   ?? Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "data"));
        // Prefer site root python/ next to wwwroot CM
        var siteRoot = config["OssiBridge:SiteRoot"]
                       ?? Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
        _pythonDir = Path.Combine(siteRoot, "python");
        _pythonExe = config["OssiBridge:Python"]
                     ?? FindPython();

        _http = new HttpClient
        {
            BaseAddress = new Uri(baseUrl.TrimEnd('/') + "/"),
            Timeout = TimeSpan.FromMinutes(3),
        };
    }

    private static string FindPython()
    {
        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                @"hermes\hermes-agent\venv\Scripts\python.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                @"Programs\Python\Python312\python.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                @"Programs\Python\Python311\python.exe"),
            @"C:\Python311\python.exe",
            "python",
        };
        foreach (var c in candidates)
        {
            if (c == "python") return c;
            if (File.Exists(c)) return c;
        }
        return "python";
    }

    public async Task EnsureBridgeRunningAsync(CancellationToken ct = default)
    {
        if (await HealthyAsync(ct).ConfigureAwait(false))
            return;

        lock (StartGate)
        {
            // double-check
        }

        if (await HealthyAsync(ct).ConfigureAwait(false))
            return;

        var script = Path.Combine(_pythonDir, "ossi_service.py");
        if (!File.Exists(script))
            throw new InvalidOperationException("ossi_service.py not found at " + script);

        Directory.CreateDirectory(_dataDir);
        var psi = new ProcessStartInfo
        {
            FileName = _pythonExe,
            ArgumentList = { script, "--host", "127.0.0.1", "--port", "18765", "--data-dir", _dataDir },
            WorkingDirectory = _pythonDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        try
        {
            var p = Process.Start(psi);
            if (p == null)
                throw new InvalidOperationException("Failed to start OSSI bridge process");
            _log.LogInformation("Started OSSI bridge PID {Pid}", p.Id);
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                "Cannot start Python OSSI bridge. Install avaya-ossi and ensure Python path is set. " + ex.Message,
                ex);
        }

        for (var i = 0; i < 20; i++)
        {
            await Task.Delay(250, ct).ConfigureAwait(false);
            if (await HealthyAsync(ct).ConfigureAwait(false))
                return;
        }

        throw new InvalidOperationException("OSSI bridge did not become healthy on 127.0.0.1:18765");
    }

    public async Task<bool> HealthyAsync(CancellationToken ct = default)
    {
        try
        {
            using var res = await _http.GetAsync("health", ct).ConfigureAwait(false);
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

    public async Task<JsonElement> PostAsync(string path, object? body, CancellationToken ct = default)
    {
        await EnsureBridgeRunningAsync(ct).ConfigureAwait(false);
        using var res = await _http.PostAsJsonAsync(path.TrimStart('/'), body ?? new { }, ct)
            .ConfigureAwait(false);
        var text = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!res.IsSuccessStatusCode)
            throw new InvalidOperationException(ExtractError(text) ?? res.ReasonPhrase ?? "bridge error");
        return JsonSerializer.Deserialize<JsonElement>(text, JsonOpts);
    }

    public async Task<JsonElement> PutAsync(string path, object? body, CancellationToken ct = default)
    {
        await EnsureBridgeRunningAsync(ct).ConfigureAwait(false);
        using var res = await _http.PutAsJsonAsync(path.TrimStart('/'), body ?? new { }, ct)
            .ConfigureAwait(false);
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
