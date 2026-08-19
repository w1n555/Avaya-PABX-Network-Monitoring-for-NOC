using System.Text.Json;
using CmApi.Models;
using CmApi.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSingleton<OssiBridgeClient>();
builder.Services.AddHostedService<BridgeWarmupService>();
builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase;
});
builder.Services.AddCors(o =>
{
    o.AddDefaultPolicy(p => p
        .AllowAnyHeader()
        .AllowAnyMethod()
        .SetIsOriginAllowed(_ => true)
        .AllowCredentials());
});

builder.WebHost.UseIIS();
builder.WebHost.UseIISIntegration();

var app = builder.Build();
app.UseCors();

// Resolve data dir relative to published api/ → site root data/
var siteRoot = Path.GetFullPath(Path.Combine(app.Environment.ContentRootPath, ".."));
var dataDir = Path.Combine(siteRoot, "data");
var dataLiveDir = Path.Combine(siteRoot, "data_live");
Directory.CreateDirectory(dataDir);
var cdrFiles = new CmApi.Services.CdrFileService(siteRoot);

static async Task<IResult> ReadAlarmsFallback(string siteRoot, string dataLiveDir)
{
    foreach (var p in new[]
             {
                 Path.Combine(siteRoot, "alarms_cache.json"),
                 Path.Combine(dataLiveDir, "alarms.json"),
                 Path.Combine(siteRoot, "data", "alarms.json"),
             })
    {
        if (!File.Exists(p)) continue;
        try
        {
            var json = await File.ReadAllTextAsync(p);
            return Results.Content(json, "application/json");
        }
        catch { /* try next */ }
    }
    return Results.Json(new
    {
        ok = true,
        active = Array.Empty<object>(),
        resolved = Array.Empty<object>(),
        mtceTypes = Array.Empty<string>(),
        summary = new { activeMajor = 0, activeMinor = 0, activeWarning = 0, activeTotal = 0 },
    });
}

app.MapGet("/health", async (OssiBridgeClient bridge, HttpRequest req) =>
{
    var ensure = string.Equals(req.Query["ensure"], "1", StringComparison.OrdinalIgnoreCase)
                 || string.Equals(req.Query["ensure"], "true", StringComparison.OrdinalIgnoreCase);
    var bridgeOk = false;
    string? bridgeError = null;
    try
    {
        if (ensure)
            await bridge.EnsureBridgeRunningAsync();
        bridgeOk = await bridge.HealthyAsync();
    }
    catch (Exception ex)
    {
        bridgeError = ex.Message;
    }
    return Results.Ok(new
    {
        ok = true,
        service = "CmApi",
        mode = "ossi-bridge-auto",
        ossiPackage = "avaya-ossi (AVAYA-OSSI-2026)",
        bridgeHealthy = bridgeOk,
        bridgeAutoStart = true,
        bridgeError,
    });
});

app.MapPost("/session/connect", async (ConnectRequest req, OssiBridgeClient bridge) =>
{
    if (string.IsNullOrWhiteSpace(req.Host) || string.IsNullOrWhiteSpace(req.Username))
        return Results.BadRequest(new ConnectResponse { Ok = false, Error = "host and username required" });
    if (string.IsNullOrEmpty(req.Password))
        return Results.BadRequest(new ConnectResponse { Ok = false, Error = "password required" });

    try
    {
        // Always auto-start OSSI bridge here if needed (no manual start-ossi-bridge.ps1)
        await bridge.EnsureBridgeRunningAsync();

        var el = await bridge.PostAsync("session/connect", new
        {
            host = req.Host.Trim(),
            port = req.Port <= 0 ? 5022 : req.Port,
            username = req.Username.Trim(),
            password = req.Password,
            pin = req.Pin ?? "",
        });
        return Results.Ok(new ConnectResponse
        {
            Ok = true,
            Host = req.Host.Trim(),
            Username = req.Username.Trim(),
            ConnectedAt = DateTimeOffset.Now,
            TrunkData = el.TryGetProperty("trunkData", out var td) ? JsonSerializer.Deserialize<object>(td.GetRawText()) : null,
        });
    }
    catch (Exception ex)
    {
        return Results.Json(new ConnectResponse { Ok = false, Error = ex.Message }, statusCode: 502);
    }
});

app.MapPost("/session/disconnect", async (OssiBridgeClient bridge) =>
{
    try
    {
        await bridge.PostAsync("session/disconnect", new { });
        return Results.Ok(new { ok = true });
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
    }
});

// Browser open keep-alive; if no heartbeat ~90s, bridge logs off OSSI
// Light path: no bridge auto-start storm; soft 200 on transient failure so UI does not thrash
// Forward { tab } so bridge knows which page is open (AUTO 60s is tab-scoped in the browser)
app.MapPost("/session/heartbeat", async (HttpRequest req, OssiBridgeClient bridge) =>
{
    try
    {
        string tab = "trunk";
        try
        {
            using var doc = await JsonDocument.ParseAsync(req.Body);
            if (doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.TryGetProperty("tab", out var t)
                && t.ValueKind == JsonValueKind.String)
            {
                var s = (t.GetString() ?? "").Trim().ToLowerInvariant();
                if (s is "trunk" or "alarm" or "cdr" or "station" or "vdn" or "gateway" or "extension" or "map")
                    tab = s;
            }
        }
        catch
        {
            /* empty / invalid body → default trunk */
        }

        var el = await bridge.PostLightAsync("session/heartbeat", new { tab });
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        // Soft-fail: keep browser quiet; next poll retries. Do not force 502 every 30s.
        return Results.Json(new { ok = false, soft = true, error = ex.Message });
    }
});

app.MapGet("/session/status", async (OssiBridgeClient bridge) =>
{
    try
    {
        var el = await bridge.GetAsync("session");
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Ok(new { ok = true, connected = false, error = ex.Message });
    }
});

app.MapPost("/refresh", async (OssiBridgeClient bridge) =>
{
    try
    {
        var el = await bridge.PostAsync("refresh", new { });
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
    }
});

// Single TG progressive update
app.MapPost("/refresh/one", async (TgRequest req, OssiBridgeClient bridge) =>
{
    if (req.Tg < 1)
        return Results.BadRequest(new { ok = false, error = "tg must be >= 1" });
    try
    {
        var el = await bridge.PostAsync("refresh/one", new { tg = req.Tg });
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
    }
});

// CM System Time + Time Sync (OSSI display time; UI polls hourly)
app.MapGet("/cm-time", async (HttpRequest req, OssiBridgeClient bridge) =>
{
    try
    {
        var force = string.Equals(req.Query["force"], "1", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(req.Query["force"], "true", StringComparison.OrdinalIgnoreCase);
        var path = force ? "cm-time?force=1" : "cm-time";
        var el = await bridge.GetAsync(path);
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
    }
});

app.MapGet("/trunk-data", async (OssiBridgeClient bridge) =>
{
    try
    {
        var el = await bridge.GetAsync("trunk-data");
        return Results.Json(el);
    }
    catch
    {
        // fallback: read file from disk if bridge down mid-read
        var path = Path.Combine(dataDir, "trunk_data.json");
        if (File.Exists(path))
        {
            var json = await File.ReadAllTextAsync(path);
            return Results.Content("{\"ok\":true,\"data\":" + json + "}", "application/json");
        }
        return Results.Json(new { ok = false, error = "No trunk data" }, statusCode: 503);
    }
});

// Alarms — OSSI display alarms; file fallback for offline / no bridge
app.MapGet("/alarms", async (HttpRequest req, OssiBridgeClient bridge) =>
{
    var force = string.Equals(req.Query["force"], "1", StringComparison.OrdinalIgnoreCase)
                || string.Equals(req.Query["refresh"], "1", StringComparison.OrdinalIgnoreCase);
    try
    {
        var path = force ? "alarms?force=1" : "alarms";
        var el = await bridge.GetAsync(path);
        return Results.Json(el);
    }
    catch
    {
        return await ReadAlarmsFallback(siteRoot, dataLiveDir);
    }
});

app.MapPost("/alarms/refresh", async (OssiBridgeClient bridge) =>
{
    try
    {
        var el = await bridge.PostAsync("alarms/refresh", new { });
        return Results.Json(el);
    }
    catch
    {
        return await ReadAlarmsFallback(siteRoot, dataLiveDir);
    }
});

static async Task<IResult> ReadGatewaysFallback(string siteRoot, string dataLiveDir)
{
    foreach (var p in new[]
             {
                 Path.Combine(siteRoot, "gateways_cache.json"),
                 Path.Combine(dataLiveDir, "gateways.json"),
                 Path.Combine(siteRoot, "data", "gateways.json"),
             })
    {
        if (!File.Exists(p)) continue;
        try
        {
            var json = await File.ReadAllTextAsync(p);
            return Results.Content(json, "application/json");
        }
        catch { /* try next */ }
    }
    return Results.Json(new
    {
        ok = true,
        items = Array.Empty<object>(),
        summary = new { total = 0, up = 0, down = 0, mj = 0, mn = 0, wn = 0 },
    });
}

app.MapGet("/gateways", async (HttpRequest req, OssiBridgeClient bridge) =>
{
    var force = string.Equals(req.Query["force"], "1", StringComparison.OrdinalIgnoreCase)
                || string.Equals(req.Query["refresh"], "1", StringComparison.OrdinalIgnoreCase);
    try
    {
        var path = force ? "gateways?force=1" : "gateways";
        var el = await bridge.GetAsync(path);
        return Results.Json(el);
    }
    catch
    {
        return await ReadGatewaysFallback(siteRoot, dataLiveDir);
    }
});

app.MapPost("/gateways/refresh", async (OssiBridgeClient bridge) =>
{
    try
    {
        var el = await bridge.PostAsync("gateways/refresh", new { });
        return Results.Json(el);
    }
    catch
    {
        return await ReadGatewaysFallback(siteRoot, dataLiveDir);
    }
});

app.MapGet("/gateways/{mg:int}/config", async (int mg, HttpRequest req, OssiBridgeClient bridge) =>
{
    if (mg < 1)
        return Results.BadRequest(new { ok = false, error = "mg must be >= 1" });
    try
    {
        var force = string.Equals(req.Query["force"], "1", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(req.Query["refresh"], "1", StringComparison.OrdinalIgnoreCase);
        var path = force ? $"gateways/{mg}/config?force=1" : $"gateways/{mg}/config";
        var el = await bridge.GetAsync(path);
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        var msg = ex.Message ?? "";
        var code = msg.Contains("Not connected", StringComparison.OrdinalIgnoreCase) ? 401 : 502;
        return Results.Json(new { ok = false, error = msg }, statusCode: code);
    }
});

app.MapGet("/monitored", async (OssiBridgeClient bridge) =>
{
    try
    {
        var el = await bridge.GetAsync("monitored");
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
    }
});

app.MapPost("/monitored/add", async (TgRequest req, OssiBridgeClient bridge) =>
{
    if (req.Tg < 1)
        return Results.BadRequest(new { ok = false, error = "tg must be >= 1" });
    try
    {
        var el = await bridge.PostAsync("monitored/add", new { tg = req.Tg, note = req.Note ?? "" });
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
    }
});

app.MapPost("/monitored/remove", async (TgRequest req, OssiBridgeClient bridge) =>
{
    try
    {
        var el = await bridge.PostAsync("monitored/remove", new { tg = req.Tg });
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
    }
});

app.MapPost("/monitored/note", async (NoteRequest req, OssiBridgeClient bridge) =>
{
    if (req.Tg < 1)
        return Results.BadRequest(new { ok = false, error = "tg must be >= 1" });
    try
    {
        var el = await bridge.PostAsync("monitored/note", new { tg = req.Tg, note = req.Note ?? "" });
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
    }
});

app.MapPut("/monitored", async (MonitoredPutRequest req, OssiBridgeClient bridge) =>
{
    try
    {
        object body;
        if (req.Items is { Count: > 0 })
        {
            body = new
            {
                items = req.Items.Select(i => new { tg = i.Tg, order = i.Order, note = i.Note ?? "" }),
                refreshStatus = req.RefreshStatus,
            };
        }
        else
        {
            body = new
            {
                trunks = req.Trunks ?? new List<int>(),
                refreshStatus = req.RefreshStatus,
            };
        }
        var el = await bridge.PutAsync("monitored", body);
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
    }
});

// Channel detail: cache from 60s poll by default; ?force=1 re-runs status trunk
app.MapGet("/trunks/{tg:int}/detail", async (int tg, HttpRequest req, OssiBridgeClient bridge) =>
{
    if (tg < 1)
        return Results.BadRequest(new { ok = false, error = "tg must be >= 1" });
    try
    {
        var force = string.Equals(req.Query["force"], "1", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(req.Query["force"], "true", StringComparison.OrdinalIgnoreCase);
        var path = force ? $"trunks/{tg}/detail?force=1" : $"trunks/{tg}/detail";
        var el = await bridge.GetAsync(path);
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        var msg = ex.Message ?? "";
        var code = msg.Contains("Not connected", StringComparison.OrdinalIgnoreCase) ? 401 : 502;
        return Results.Json(new { ok = false, error = msg }, statusCode: code);
    }
});

// ---------- CDR daily files (cdr-link/cdr/YYYYMMDD.txt) ----------
app.MapGet("/cdr/status", () =>
{
    var days = cdrFiles.ListDays(null, null);
    var logger = cdrFiles.GetLoggerSnapshot();
    return Results.Ok(new
    {
        ok = true,
        cdrDir = cdrFiles.CdrDirectory,
        dayCount = days.Count,
        days,
        latest = days.Count > 0 ? days[^1] : null,
        loggerUp = logger.Listening,
        loggerPort = logger.Port,
        todayFile = logger.TodayFile,
        lastCall = logger.LastWrite,
        lastCallAgeSec = logger.LastWriteAgeSec,
        todayBytes = logger.TodayBytes,
    });
});

app.MapGet("/cdr/logger", () =>
{
    var logger = cdrFiles.GetLoggerSnapshot();
    return Results.Ok(new
    {
        ok = true,
        up = logger.Listening,
        port = logger.Port,
        todayFile = logger.TodayFile,
        lastCall = logger.LastWrite,
        lastCallAgeSec = logger.LastWriteAgeSec,
        todayBytes = logger.TodayBytes,
    });
});

app.MapGet("/cdr/files", (string? from, string? to) =>
{
    DateOnly? f = null, t = null;
    if (!string.IsNullOrWhiteSpace(from) && DateOnly.TryParse(from, out var fd)) f = fd;
    if (!string.IsNullOrWhiteSpace(to) && DateOnly.TryParse(to, out var td)) t = td;
    var days = cdrFiles.ListDays(f, t);
    return Results.Ok(new { ok = true, days, count = days.Count, cdrDir = cdrFiles.CdrDirectory });
});

// Scan one day — UI calls per-day for progress %
app.MapGet("/cdr/scan-day", (string date, string? calling, string? called, string? trunk, string? dir, int? minDur, int? maxMatches) =>
{
    try
    {
        // date: yyyy-MM-dd or yyyyMMdd
        var key = date.Replace("-", "").Trim();
        if (key.Length != 8 || !key.All(char.IsDigit))
            return Results.BadRequest(new { ok = false, error = "date must be yyyy-MM-dd or yyyyMMdd" });

        var filter = new CmApi.Services.CdrFilter
        {
            Calling = calling,
            Called = called,
            Trunk = trunk,
            Dir = dir,
            MinDur = minDur ?? 0,
        };
        var result = cdrFiles.ScanDay(key, filter, maxMatches ?? 500);
        return Results.Ok(result);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message, detail = ex.ToString() }, statusCode: 500);
    }
});

app.Run();
