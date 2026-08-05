namespace CmApi.Models;

public sealed class ConnectRequest
{
    public string Host { get; set; } = "172.29.88.12";
    public int Port { get; set; } = 5022;
    public string Username { get; set; } = "";
    public string Password { get; set; } = "";
    public string TerminalType { get; set; } = "VT220";
}

public sealed class ConnectResponse
{
    public bool Ok { get; set; }
    public string? SessionId { get; set; }
    public string? Host { get; set; }
    public string? Banner { get; set; }
    public string? Error { get; set; }
    public DateTimeOffset? ConnectedAt { get; set; }
}

public sealed class TrunkGroupDto
{
    public int Tg { get; set; }
    public string Tac { get; set; } = "";
    public string Type { get; set; } = "";
    public string Name { get; set; } = "";
    public int Total { get; set; }
    public int? InUse { get; set; }
    public int? Oos { get; set; }
    public double? UsagePct { get; set; }
    public string Tn { get; set; } = "";
    public string Cor { get; set; } = "";
    public string Cdr { get; set; } = "";
}

public sealed class TrunkListResponse
{
    public bool Ok { get; set; }
    public string? Error { get; set; }
    public DateTimeOffset? LastSuccessAt { get; set; }
    public DateTimeOffset? LastAttemptAt { get; set; }
    public string? Host { get; set; }
    public IReadOnlyList<TrunkGroupDto> Items { get; set; } = Array.Empty<TrunkGroupDto>();
    public object? SatTraces { get; set; }
}

public sealed class ChannelDto
{
    public string Member { get; set; } = "";
    public string Port { get; set; } = "";
    public string ServiceState { get; set; } = "";
    public string MtceBusy { get; set; } = "";
    public string ConnectedPorts { get; set; } = "";
    /// <summary>Best-effort; often empty when idle or not present on SAT screen.</summary>
    public string Caller { get; set; } = "";
    public string Called { get; set; } = "";
    public string Duration { get; set; } = "";
    public string Extension { get; set; } = "";
}

public sealed class TrunkDetailResponse
{
    public bool Ok { get; set; }
    public string? Error { get; set; }
    public DateTimeOffset? LastSuccessAt { get; set; }
    public DateTimeOffset? LastAttemptAt { get; set; }
    public TrunkGroupDto? Config { get; set; }
    public string? RawConfigHint { get; set; }
    /// <summary>Debug aid: truncated visible status text if parse yields 0 channels.</summary>
    public string? RawStatusHint { get; set; }
    public IReadOnlyList<ChannelDto> Channels { get; set; } = Array.Empty<ChannelDto>();
    public object? SatTraces { get; set; }
}

public sealed class SessionStatusResponse
{
    public bool Connected { get; set; }
    public string? SessionId { get; set; }
    public string? Host { get; set; }
    public DateTimeOffset? ConnectedAt { get; set; }
    public DateTimeOffset? LastSuccessAt { get; set; }
    public DateTimeOffset? LastAttemptAt { get; set; }
    public string? LastError { get; set; }
}
