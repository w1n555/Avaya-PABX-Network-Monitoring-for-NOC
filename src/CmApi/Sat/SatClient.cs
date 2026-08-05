using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using Renci.SshNet;

namespace CmApi.Sat;

/// <summary>One SAT exchange for UI debug (not written to disk).</summary>
public sealed class SatIoTrace
{
    public DateTimeOffset At { get; set; }
    public string Command { get; set; } = "";
    public long DurationMs { get; set; }
    public bool Ok { get; set; }
    public string? Error { get; set; }
    public string OutputPreview { get; set; } = "";
    public int OutputLength { get; set; }
    public int PagesFetched { get; set; }
}

/// <summary>
/// Read-only Avaya CM SAT over SSH. Terminal VT220. Never issues change/save.
/// </summary>
public sealed class SatClient : IDisposable
{
    private readonly object _gate = new();
    private SshClient? _ssh;
    private ShellStream? _shell;
    private readonly ConcurrentQueue<SatIoTrace> _traces = new();
    private const int MaxTraces = 20;

    public string Host { get; private set; } = "";
    public int Port { get; private set; } = 5022;
    public string TerminalType { get; private set; } = "VT220";
    public string Banner { get; private set; } = "";
    public bool IsConnected => _ssh?.IsConnected == true && _shell != null;

    // Avaya VT220 mappings (ASA-style)
    public static readonly string CancelPf1 = "\x1bOP";      // PF1 Cancel
    public static readonly string NextPagePf2 = "\x1bOQ";  // PF2 Next
    public static readonly string NextPageKey = "\x1b[6~"; // PageDown

    public IReadOnlyList<SatIoTrace> GetTraces() => _traces.ToArray();

    public void Connect(string host, int port, string username, string password, string terminalType = "VT220")
    {
        lock (_gate)
        {
            Disconnect();
            Host = host;
            Port = port;
            TerminalType = string.IsNullOrWhiteSpace(terminalType) ? "VT220" : terminalType.Trim();

            var kbi = new KeyboardInteractiveAuthenticationMethod(username);
            kbi.AuthenticationPrompt += (_, e) =>
            {
                foreach (var prompt in e.Prompts)
                    prompt.Response = password;
            };
            var pwd = new PasswordAuthenticationMethod(username, password);
            var conn = new Renci.SshNet.ConnectionInfo(host, port, username, kbi, pwd)
            {
                Timeout = TimeSpan.FromSeconds(20),
            };

            _ssh = new SshClient(conn);
            _ssh.Connect();
            // larger terminal reduces "more" paging for status lists
            _shell = _ssh.CreateShellStream("vt220", 160, 60, 1024, 768, 16384);
            Thread.Sleep(700);
            var intro = ReadAvailable(TimeSpan.FromSeconds(5));
            Banner = AnsiHelper.VisibleText(intro);

            if (Banner.Contains("Terminal Type", StringComparison.OrdinalIgnoreCase) ||
                intro.Contains("Terminal Type", StringComparison.OrdinalIgnoreCase))
            {
                WriteRaw(TerminalType + "\r");
                Thread.Sleep(400);
                Banner += "\n" + AnsiHelper.VisibleText(ReadAvailable(TimeSpan.FromSeconds(8)));
            }

            if (!Banner.Contains("Command:", StringComparison.OrdinalIgnoreCase))
            {
                WriteRaw("\r");
                Thread.Sleep(300);
                Banner += "\n" + AnsiHelper.VisibleText(ReadAvailable(TimeSpan.FromSeconds(3)));
            }

            if (!Banner.Contains("Command:", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("SAT Command: prompt not reached after terminal type.");

            ForceCommandPrompt(maxAttempts: 4);
        }
    }

    public void Disconnect()
    {
        lock (_gate)
        {
            try { _shell?.Dispose(); } catch { /* ignore */ }
            try { if (_ssh?.IsConnected == true) _ssh.Disconnect(); } catch { /* ignore */ }
            try { _ssh?.Dispose(); } catch { /* ignore */ }
            _shell = null;
            _ssh = null;
        }
    }

    public void Dispose() => Disconnect();

    /// <param name="maxPages">0 = first screen only (no next-page). Good for display forms with many pages.</param>
    public string RunReadOnly(string command, int maxPages = 5)
    {
        if (IsBlocked(command))
            throw new InvalidOperationException("Blocked non-read-only command: " + command);

        lock (_gate)
        {
            if (_shell == null || _ssh?.IsConnected != true)
                throw new InvalidOperationException("Not connected to CM SAT.");

            var sw = Stopwatch.StartNew();
            var pages = 0;
            try
            {
                // Critical: must be at Command: or each keystroke edits the open form
                // (symptoms: single letters d,i,s,p... with form redraw — what you saw)
                ForceCommandPrompt(maxAttempts: 10);
                Drain(150);

                // Send whole command at once + CR
                WriteRaw(command.Trim() + "\r");
                Thread.Sleep(800);

                var sb = new StringBuilder();
                sb.Append(ReadAvailable(TimeSpan.FromSeconds(8)));

                // Only page when maxPages > 0 and prompt asks for NEXT PAGE
                for (var i = 0; i < maxPages; i++)
                {
                    var text = sb.ToString();
                    if (!NeedsNextPage(text)) break;
                    if (text.Contains("Command successfully completed", StringComparison.OrdinalIgnoreCase))
                        break;

                    WriteRaw(NextPagePf2);
                    Thread.Sleep(150);
                    WriteRaw(NextPageKey);
                    Thread.Sleep(400);
                    var more = ReadAvailable(TimeSpan.FromSeconds(4));
                    if (string.IsNullOrWhiteSpace(more)) break;
                    sb.Append(more);
                    pages++;
                }

                // Leave form — Cancel only (do NOT keep paging remaining 20 pages)
                ForceCommandPrompt(maxAttempts: 8);

                var visible = AnsiHelper.VisibleText(sb.ToString());
                sw.Stop();
                PushTrace(new SatIoTrace
                {
                    At = DateTimeOffset.Now,
                    Command = command,
                    DurationMs = sw.ElapsedMilliseconds,
                    Ok = true,
                    OutputPreview = Truncate(visible, 4000),
                    OutputLength = visible.Length,
                    PagesFetched = pages,
                });
                return visible;
            }
            catch (Exception ex)
            {
                sw.Stop();
                try { ForceCommandPrompt(maxAttempts: 5); } catch { /* ignore */ }
                PushTrace(new SatIoTrace
                {
                    At = DateTimeOffset.Now,
                    Command = command,
                    DurationMs = sw.ElapsedMilliseconds,
                    Ok = false,
                    Error = ex.Message,
                    OutputPreview = "",
                    OutputLength = 0,
                    PagesFetched = pages,
                });
                throw;
            }
        }
    }

    private void PushTrace(SatIoTrace t)
    {
        _traces.Enqueue(t);
        while (_traces.Count > MaxTraces && _traces.TryDequeue(out _)) { }
    }

    private static bool IsBlocked(string command)
    {
        var c = command.Trim();
        return c.StartsWith("change", StringComparison.OrdinalIgnoreCase)
               || c.StartsWith("add ", StringComparison.OrdinalIgnoreCase)
               || c.StartsWith("remove", StringComparison.OrdinalIgnoreCase)
               || c.StartsWith("save ", StringComparison.OrdinalIgnoreCase)
               || c.StartsWith("busyout", StringComparison.OrdinalIgnoreCase)
               || c.StartsWith("release", StringComparison.OrdinalIgnoreCase)
               || c.StartsWith("reset", StringComparison.OrdinalIgnoreCase);
    }

    private static bool NeedsNextPage(string text)
    {
        // Prefer explicit NEXT PAGE — avoid matching unrelated "to continue"
        return text.Contains("NEXT PAGE", StringComparison.OrdinalIgnoreCase)
               || text.Contains("press NEXT", StringComparison.OrdinalIgnoreCase)
               || text.Contains("--More--", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Hammer Cancel until Command: prompt is visible.</summary>
    private void ForceCommandPrompt(int maxAttempts)
    {
        for (var i = 0; i < maxAttempts; i++)
        {
            var peek = ReadAvailable(TimeSpan.FromMilliseconds(350));
            var vis = AnsiHelper.VisibleText(peek);
            if (HasCommandPrompt(vis) || HasCommandPrompt(peek))
                return;

            // still on a form: Cancel (PF1), then Esc as fallback
            WriteRaw(CancelPf1);
            Thread.Sleep(200);
            if (i % 3 == 2)
            {
                WriteRaw("\x1b\x1b");
                Thread.Sleep(100);
            }
        }

        // last drain
        var last = AnsiHelper.VisibleText(ReadAvailable(TimeSpan.FromMilliseconds(500)));
        if (!HasCommandPrompt(last))
        {
            // not fatal — next Write may still fail; caller will notice
        }
    }

    private static bool HasCommandPrompt(string buf)
    {
        if (string.IsNullOrEmpty(buf)) return false;
        // Avoid false positive from "Command successfully completed" mid-form
        if (buf.Contains("Command:", StringComparison.OrdinalIgnoreCase))
        {
            // if still showing NEXT PAGE / form header without clean prompt, treat carefully
            var lines = buf.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            for (var i = lines.Length - 1; i >= 0 && i >= lines.Length - 5; i--)
            {
                if (lines[i].StartsWith("Command:", StringComparison.OrdinalIgnoreCase))
                    return true;
            }
        }
        return false;
    }

    private void WriteRaw(string s)
    {
        if (_shell == null) return;
        // Write entire string (not char-by-char)
        _shell.Write(s);
        _shell.Flush();
    }

    private void Drain(int ms)
    {
        ReadAvailable(TimeSpan.FromMilliseconds(ms));
    }

    private string ReadAvailable(TimeSpan timeout)
    {
        if (_shell == null) return "";
        var sb = new StringBuilder();
        var end = DateTime.UtcNow + timeout;
        var lastData = DateTime.UtcNow;
        var buffer = new byte[16384];
        while (DateTime.UtcNow < end)
        {
            var readAny = false;
            while (_shell.DataAvailable)
            {
                var n = _shell.Read(buffer, 0, buffer.Length);
                if (n <= 0) break;
                sb.Append(Encoding.UTF8.GetString(buffer, 0, n));
                readAny = true;
                lastData = DateTime.UtcNow;
            }
            // idle after data → done
            if (!readAny && sb.Length > 0 && (DateTime.UtcNow - lastData).TotalMilliseconds > 450)
                break;
            if (!readAny)
                Thread.Sleep(40);
        }
        return sb.ToString();
    }

    private static string Truncate(string s, int max)
    {
        if (string.IsNullOrEmpty(s) || s.Length <= max) return s;
        return s[..max] + "\n...[truncated]...";
    }
}
