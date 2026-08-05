using System.Text;
using Renci.SshNet;

namespace CmApi.Sat;

/// <summary>
/// Read-only Avaya CM SAT over SSH. Terminal VT220. Never issues change/save.
/// </summary>
public sealed class SatClient : IDisposable
{
    private readonly object _gate = new();
    private SshClient? _ssh;
    private ShellStream? _shell;

    public string Host { get; private set; } = "";
    public int Port { get; private set; } = 5022;
    public string TerminalType { get; private set; } = "VT220";
    public string Banner { get; private set; } = "";
    public bool IsConnected => _ssh?.IsConnected == true && _shell != null;

    public static readonly string CancelPf1 = "\x1bOP";
    public static readonly string NextPage = "\x1b[6~";

    public void Connect(string host, int port, string username, string password, string terminalType = "VT220")
    {
        lock (_gate)
        {
            Disconnect();
            Host = host;
            Port = port;
            TerminalType = string.IsNullOrWhiteSpace(terminalType) ? "VT220" : terminalType.Trim();

            // Avaya SAT often advertises keyboard-interactive (not pure "password")
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
            _shell = _ssh.CreateShellStream("xterm", 140, 50, 800, 600, 8192);
            Thread.Sleep(800);
            var intro = ReadAvailable(TimeSpan.FromSeconds(5));
            Banner = AnsiHelper.VisibleText(intro);

            // Answer terminal type prompt
            if (Banner.Contains("Terminal Type", StringComparison.OrdinalIgnoreCase) ||
                intro.Contains("Terminal Type", StringComparison.OrdinalIgnoreCase))
            {
                _shell.Write(TerminalType + "\r");
                Thread.Sleep(500);
                var after = ReadAvailable(TimeSpan.FromSeconds(8));
                Banner += "\n" + AnsiHelper.VisibleText(after);
            }

            if (!Banner.Contains("Command:", StringComparison.OrdinalIgnoreCase) &&
                !afterHasCommand(Banner))
            {
                // try enter once
                _shell.Write("\r");
                Thread.Sleep(400);
                Banner += "\n" + AnsiHelper.VisibleText(ReadAvailable(TimeSpan.FromSeconds(3)));
            }

            if (!Banner.Contains("Command:", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("SAT Command: prompt not reached after terminal type. Check account / terminal.");
        }
    }

    private static bool afterHasCommand(string s) =>
        s.Contains("Command:", StringComparison.OrdinalIgnoreCase);

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

    public string RunReadOnly(string command, int maxPages = 20)
    {
        if (command.IndexOf("change", StringComparison.OrdinalIgnoreCase) >= 0 ||
            command.IndexOf("add ", StringComparison.OrdinalIgnoreCase) >= 0 ||
            command.IndexOf("remove", StringComparison.OrdinalIgnoreCase) >= 0 ||
            command.IndexOf("save ", StringComparison.OrdinalIgnoreCase) >= 0 ||
            command.StartsWith("busyout", StringComparison.OrdinalIgnoreCase) ||
            command.StartsWith("release", StringComparison.OrdinalIgnoreCase) ||
            command.StartsWith("reset", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Blocked non-read-only command: " + command);
        }

        lock (_gate)
        {
            if (_shell == null || _ssh?.IsConnected != true)
                throw new InvalidOperationException("Not connected to CM SAT.");

            EnsureCommandPrompt();
            // Clear any residual input buffer noise
            _ = ReadAvailable(TimeSpan.FromMilliseconds(150));

            _shell.Write(command.Trim() + "\r");
            Thread.Sleep(1200);
            var sb = new StringBuilder();
            sb.Append(ReadAvailable(TimeSpan.FromSeconds(12)));

            for (var i = 0; i < maxPages; i++)
            {
                var text = sb.ToString();
                var needsNext =
                    text.Contains("NEXT PAGE", StringComparison.OrdinalIgnoreCase) ||
                    text.Contains("press NEXT", StringComparison.OrdinalIgnoreCase) ||
                    text.Contains("to continue", StringComparison.OrdinalIgnoreCase);
                // avoid infinite next when already completed
                if (needsNext && !text.Contains("Command successfully completed", StringComparison.OrdinalIgnoreCase))
                {
                    // Prefer PF2 then PageDown (Avaya mappings vary)
                    _shell.Write("\x1bOQ");
                    Thread.Sleep(200);
                    _shell.Write(NextPage);
                    Thread.Sleep(500);
                    var more = ReadAvailable(TimeSpan.FromSeconds(6));
                    if (string.IsNullOrWhiteSpace(more)) break;
                    sb.Append(more);
                }
                else break;
            }

            // Cancel back to Command:
            for (var i = 0; i < 6; i++)
            {
                var cur = sb.ToString();
                if (EndsWithCommandPrompt(cur)) break;
                _shell.Write(CancelPf1);
                Thread.Sleep(350);
                sb.Append(ReadAvailable(TimeSpan.FromSeconds(2.5)));
            }

            return AnsiHelper.VisibleText(sb.ToString());
        }
    }

    private void EnsureCommandPrompt()
    {
        for (var i = 0; i < 6; i++)
        {
            var peek = ReadAvailable(TimeSpan.FromMilliseconds(400));
            if (EndsWithCommandPrompt(peek) || (string.IsNullOrEmpty(peek) && i > 0))
            {
                // empty after cancel often means ready
                if (EndsWithCommandPrompt(peek) || i >= 2) return;
            }
            _shell!.Write(CancelPf1);
            Thread.Sleep(300);
        }
    }

    private static bool EndsWithCommandPrompt(string buf)
    {
        if (string.IsNullOrEmpty(buf)) return false;
        var v = AnsiHelper.VisibleText(buf);
        // last non-empty line is Command:
        var lines = v.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (lines.Length == 0) return false;
        var last = lines[^1];
        return last.StartsWith("Command:", StringComparison.OrdinalIgnoreCase) ||
               last.Equals("Command:", StringComparison.OrdinalIgnoreCase) ||
               v.Contains("Command successfully completed", StringComparison.OrdinalIgnoreCase);
    }

    private string ReadAvailable(TimeSpan timeout)
    {
        if (_shell == null) return "";
        var sb = new StringBuilder();
        var end = DateTime.UtcNow + timeout;
        var lastData = DateTime.UtcNow;
        var buffer = new byte[8192];
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
            if (!readAny && sb.Length > 0 && (DateTime.UtcNow - lastData).TotalMilliseconds > 1000)
                break;
            if (!readAny)
                Thread.Sleep(60);
        }
        return sb.ToString();
    }
}
