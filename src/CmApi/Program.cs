using System.Text.Json;
using CmApi.Models;
using CmApi.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSingleton<OssiBridgeClient>();
builder.Services.AddHostedService<BridgeWarmupService>();
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
Directory.CreateDirectory(dataDir);

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
app.MapPost("/session/heartbeat", async (OssiBridgeClient bridge) =>
{
    try
    {
        var el = await bridge.PostAsync("session/heartbeat", new { });
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        return Results.Json(new { ok = false, error = ex.Message }, statusCode: 502);
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

// Channel-level detail from live `status trunk N` (Connected = port/raw only)
app.MapGet("/trunks/{tg:int}/detail", async (int tg, OssiBridgeClient bridge) =>
{
    if (tg < 1)
        return Results.BadRequest(new { ok = false, error = "tg must be >= 1" });
    try
    {
        var el = await bridge.GetAsync($"trunks/{tg}/detail");
        return Results.Json(el);
    }
    catch (Exception ex)
    {
        var msg = ex.Message ?? "";
        // Bridge returns 401 when OSSI session not connected
        var code = msg.Contains("Not connected", StringComparison.OrdinalIgnoreCase) ? 401 : 502;
        return Results.Json(new { ok = false, error = msg }, statusCode: code);
    }
});

app.Run();
