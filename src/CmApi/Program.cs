using System.Text.Json;
using CmApi.Models;
using CmApi.Sat;
using CmApi.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSingleton<SessionStore>();
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

// No request body logging of passwords; no file logging of call data.
app.MapGet("/health", () => Results.Ok(new { ok = true, service = "CmApi", mode = "read-only-sat" }));

app.MapPost("/session/connect", (ConnectRequest req, SessionStore store, HttpContext http) =>
{
    if (string.IsNullOrWhiteSpace(req.Host) || string.IsNullOrWhiteSpace(req.Username))
        return Results.BadRequest(new ConnectResponse { Ok = false, Error = "host and username required" });

    // Tear down previous cookie session
    var old = http.Request.Cookies["cm_sid"];
    if (!string.IsNullOrEmpty(old)) store.Remove(old);

    var session = store.Create();
    try
    {
        session.WithLock(() =>
        {
            session.Client.Connect(
                req.Host.Trim(),
                req.Port <= 0 ? 5022 : req.Port,
                req.Username.Trim(),
                req.Password ?? "",
                string.IsNullOrWhiteSpace(req.TerminalType) ? "VT220" : req.TerminalType);
            // Prove read-only path works
            _ = session.Client.RunReadOnly("display time", maxPages: 1);
            session.ConnectedAt = DateTimeOffset.Now;
            session.LastSuccessAt = DateTimeOffset.Now;
            session.LastAttemptAt = DateTimeOffset.Now;
            session.LastError = null;
            return true;
        });

        http.Response.Cookies.Append("cm_sid", session.Id, new CookieOptions
        {
            HttpOnly = true,
            SameSite = SameSiteMode.Lax,
            Secure = http.Request.IsHttps,
            Path = "/",
            MaxAge = TimeSpan.FromHours(8),
        });

        return Results.Ok(new ConnectResponse
        {
            Ok = true,
            SessionId = session.Id,
            Host = session.Host,
            Banner = session.Client.Banner,
            ConnectedAt = session.ConnectedAt,
        });
    }
    catch (Exception ex)
    {
        store.Remove(session.Id);
        return Results.Json(new ConnectResponse { Ok = false, Error = ex.Message }, statusCode: 502);
    }
});

app.MapPost("/session/disconnect", (SessionStore store, HttpContext http) =>
{
    var sid = http.Request.Cookies["cm_sid"] ?? http.Request.Headers["X-Session-Id"].FirstOrDefault();
    store.Remove(sid);
    http.Response.Cookies.Delete("cm_sid");
    return Results.Ok(new { ok = true });
});

app.MapGet("/session/status", (SessionStore store, HttpContext http) =>
{
    var s = GetSession(store, http);
    if (s == null)
        return Results.Ok(new SessionStatusResponse { Connected = false });
    return Results.Ok(new SessionStatusResponse
    {
        Connected = s.Client.IsConnected,
        SessionId = s.Id,
        Host = s.Host,
        ConnectedAt = s.ConnectedAt,
        LastSuccessAt = s.LastSuccessAt,
        LastAttemptAt = s.LastAttemptAt,
        LastError = s.LastError,
    });
});

app.MapGet("/trunks", (SessionStore store, HttpContext http) =>
{
    var s = GetSession(store, http);
    if (s == null)
        return Results.Json(new TrunkListResponse { Ok = false, Error = "Not connected. Call /session/connect first." }, statusCode: 401);

    s.LastAttemptAt = DateTimeOffset.Now;
    try
    {
        var items = s.WithLock(() =>
        {
            var raw = s.Client.RunReadOnly("list trunk-group", maxPages: 25);
            return TrunkParsers.ParseTrunkGroups(raw);
        });

        s.TrunkCache = items;
        s.LastSuccessAt = DateTimeOffset.Now;
        s.LastError = null;

        return Results.Ok(new TrunkListResponse
        {
            Ok = true,
            Host = s.Host,
            LastSuccessAt = s.LastSuccessAt,
            LastAttemptAt = s.LastAttemptAt,
            Items = items,
        });
    }
    catch (Exception ex)
    {
        s.LastError = ex.Message;
        // Keep prior cache if any
        return Results.Json(new TrunkListResponse
        {
            Ok = false,
            Error = ex.Message,
            Host = s.Host,
            LastSuccessAt = s.LastSuccessAt,
            LastAttemptAt = s.LastAttemptAt,
            Items = s.TrunkCache,
        }, statusCode: 502);
    }
});

app.MapGet("/trunks/{tg:int}", (int tg, SessionStore store, HttpContext http) =>
{
    var s = GetSession(store, http);
    if (s == null)
        return Results.Json(new TrunkDetailResponse { Ok = false, Error = "Not connected." }, statusCode: 401);

    s.LastAttemptAt = DateTimeOffset.Now;
    try
    {
        var result = s.WithLock(() =>
        {
            // Status first (higher value for NOC); then display config
            var stRaw = s.Client.RunReadOnly($"status trunk {tg}", maxPages: 30);
            var channels = TrunkParsers.ParseChannels(stRaw);
            string cfgRaw = "";
            try
            {
                cfgRaw = s.Client.RunReadOnly($"display trunk-group {tg}", maxPages: 6);
            }
            catch
            {
                cfgRaw = "";
            }

            var cfg = s.TrunkCache.FirstOrDefault(x => x.Tg == tg) ?? new TrunkGroupDto { Tg = tg };
            TrunkParsers.ApplyChannelStats(cfg, channels);

            return new TrunkDetailResponse
            {
                Ok = true,
                LastSuccessAt = DateTimeOffset.Now,
                LastAttemptAt = DateTimeOffset.Now,
                Config = cfg,
                RawConfigHint = string.IsNullOrWhiteSpace(cfgRaw) ? null : TrunkParsers.SummaryFromDisplay(cfgRaw),
                RawStatusHint = channels.Count == 0 && !string.IsNullOrEmpty(stRaw)
                    ? (stRaw.Length > 1500 ? stRaw[..1500] : stRaw)
                    : null,
                Channels = channels,
            };
        });

        s.LastSuccessAt = result.LastSuccessAt;
        s.LastError = null;
        return Results.Ok(result);
    }
    catch (Exception ex)
    {
        s.LastError = ex.Message;
        return Results.Json(new TrunkDetailResponse
        {
            Ok = false,
            Error = ex.Message,
            LastSuccessAt = s.LastSuccessAt,
            LastAttemptAt = s.LastAttemptAt,
        }, statusCode: 502);
    }
});

app.Run();

static CmSession? GetSession(SessionStore store, HttpContext http)
{
    var sid = http.Request.Cookies["cm_sid"]
              ?? http.Request.Headers["X-Session-Id"].FirstOrDefault()
              ?? http.Request.Query["sid"].FirstOrDefault();
    var s = store.Get(sid);
    if (s == null) return null;
    if (!s.Client.IsConnected)
    {
        store.Remove(s.Id);
        return null;
    }
    return s;
}
