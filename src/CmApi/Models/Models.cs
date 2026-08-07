namespace CmApi.Models;

public sealed class ConnectRequest
{
    public string Host { get; set; } = "";
    public int Port { get; set; } = 5022;
    public string Username { get; set; } = "";
    public string Password { get; set; } = "";
    public string? Pin { get; set; }
}

public sealed class ConnectResponse
{
    public bool Ok { get; set; }
    public string? Host { get; set; }
    public string? Username { get; set; }
    public string? Error { get; set; }
    public DateTimeOffset? ConnectedAt { get; set; }
    public object? TrunkData { get; set; }
}

public sealed class TgRequest
{
    public int Tg { get; set; }
}

public sealed class MonitoredPutRequest
{
    public List<int> Trunks { get; set; } = new();
}
