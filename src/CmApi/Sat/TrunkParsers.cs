using System.Globalization;
using System.Text.RegularExpressions;
using CmApi.Models;

namespace CmApi.Sat;

internal static partial class TrunkParsers
{
    // Example line fragments from list trunk-group (ANSI-stripped, columns may run together)
    [GeneratedRegex(@"^\s*(\d{1,4})\s+(\d{3,5})?\s*(isdn|sip|wats|co|tie|pri|fxo|fxs|h\.323|atm)?\s*(.+?)\s+(\d{1,3})\s+(\d{1,3})?\s+(\d{1,3})?\s*([yn])?\s*", RegexOptions.IgnoreCase)]
    private static partial Regex TrunkLineRegex();

    [GeneratedRegex(@"(\d{1,4})\s+(\d{3,5})\s*(isdn|sip|wats)\s+(.+?)\s{2,}(\d{1,3})", RegexOptions.IgnoreCase)]
    private static partial Regex TrunkLooseRegex();

    // Real CM lines (ANSI stripped) often look like:
    // 0001/0001001V101 in-service/idle   no
    // 0001/0017001V117 in-service/active no  002V201
    [GeneratedRegex(
        @"^(?<mem>\d{4}/\d{4})(?<port>\d{3}V\d{3}|\S+?)\s+(?<state>in-service/\S+|OOS/\S+|\S+)\s+(?<busy>yes|no)\s*(?<conn>.*)$",
        RegexOptions.IgnoreCase)]
    private static partial Regex ChannelLineRegex();

    public static List<TrunkGroupDto> ParseTrunkGroups(string visible)
    {
        var list = new List<TrunkGroupDto>();
        var seen = new HashSet<int>();

        foreach (var raw in visible.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length < 8) continue;
            if (line.Contains("TRUNK GROUPS", StringComparison.OrdinalIgnoreCase)) continue;
            if (line.Contains("Group Name", StringComparison.OrdinalIgnoreCase)) continue;
            if (line.Contains("press ", StringComparison.OrdinalIgnoreCase)) continue;
            if (line.StartsWith("Command", StringComparison.OrdinalIgnoreCase)) continue;
            if (line.StartsWith("list ", StringComparison.OrdinalIgnoreCase)) continue;
            if (line.StartsWith("Page", StringComparison.OrdinalIgnoreCase)) continue;

            // Prefer loose: TG TAC type name members
            var m = TrunkLooseRegex().Match(line);
            if (!m.Success)
            {
                // Fallback: starts with digits (type glued to TAC sometimes)
                var m2 = Regex.Match(line, @"^\s*(\d{1,4})\s+(\d{3,5})(isdn|sip|wats)(.+?)(\d{1,3})\s+\d", RegexOptions.IgnoreCase);
                if (!m2.Success) continue;
                m = m2;
            }

            if (!int.TryParse(m.Groups[1].Value, out var tg)) continue;
            if (!seen.Add(tg)) continue;

            var tac = m.Groups[2].Success ? m.Groups[2].Value.Trim() : "";
            var type = m.Groups[3].Success ? m.Groups[3].Value.Trim() : "";
            var name = m.Groups[4].Value.Trim();
            // clean name trailing junk
            name = Regex.Replace(name, @"\s{2,}", " ").Trim();
            if (name.Length > 40) name = name[..40].Trim();

            int.TryParse(m.Groups[5].Value, out var mem);

            list.Add(new TrunkGroupDto
            {
                Tg = tg,
                Tac = tac,
                Type = type,
                Name = name,
                Total = mem,
            });
        }

        list.Sort((a, b) => a.Tg.CompareTo(b.Tg));
        return list;
    }

    public static List<ChannelDto> ParseChannels(string visible)
    {
        var list = new List<ChannelDto>();
        var seen = new HashSet<string>();

        foreach (var raw in visible.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length < 10) continue;
            if (line.Contains("TRUNK GROUP STATUS", StringComparison.OrdinalIgnoreCase)) continue;
            if (line.Contains("Member", StringComparison.OrdinalIgnoreCase) && line.Contains("Port", StringComparison.OrdinalIgnoreCase)) continue;
            if (line.Contains("press ", StringComparison.OrdinalIgnoreCase)) continue;
            if (line.StartsWith("Command", StringComparison.OrdinalIgnoreCase)) continue;
            if (line.StartsWith("status ", StringComparison.OrdinalIgnoreCase)) continue;
            if (!line.Contains('/')) continue;

            var m = ChannelLineRegex().Match(line);
            if (!m.Success)
            {
                // Extra fallback: member+port glued
                m = Regex.Match(line,
                    @"^(?<mem>\d{4}/\d{4})(?<port>\d{3}V\d+)\s+(?<state>\S+)\s+(?<busy>yes|no)\s*(?<conn>.*)$",
                    RegexOptions.IgnoreCase);
                if (!m.Success) continue;
            }

            var member = m.Groups["mem"].Value;
            if (!seen.Add(member)) continue;

            var port = m.Groups["port"].Value;
            var state = m.Groups["state"].Value;
            var busy = m.Groups["busy"].Value;
            var conn = m.Groups["conn"].Value.Trim();

            // Best-effort: connected port / far end
            var caller = "";
            var called = "";
            var ext = "";
            if (!string.IsNullOrWhiteSpace(conn))
            {
                var parts = Regex.Split(conn.Trim(), @"\s+");
                if (parts.Length >= 1) caller = parts[0];
                if (parts.Length >= 2) called = parts[1];
                foreach (var p in parts)
                {
                    if (Regex.IsMatch(p, @"^\d{3,6}$"))
                    {
                        ext = p;
                        break;
                    }
                }
            }

            list.Add(new ChannelDto
            {
                Member = member,
                Port = port,
                ServiceState = state,
                MtceBusy = busy,
                ConnectedPorts = conn,
                Caller = caller,
                Called = called,
                Duration = "", // not on standard status trunk screen
                Extension = ext,
            });
        }

        return list;
    }

    public static void ApplyChannelStats(TrunkGroupDto tg, IReadOnlyList<ChannelDto> channels)
    {
        if (channels.Count == 0) return;
        var oos = channels.Count(c =>
            c.ServiceState.Contains("OOS", StringComparison.OrdinalIgnoreCase) ||
            c.ServiceState.Contains("out-of-service", StringComparison.OrdinalIgnoreCase));
        var inUse = channels.Count(c =>
            c.ServiceState.Contains("in-use", StringComparison.OrdinalIgnoreCase) ||
            c.ServiceState.Contains("active", StringComparison.OrdinalIgnoreCase));
        tg.Oos = oos;
        tg.InUse = inUse;
        if (tg.Total <= 0) tg.Total = channels.Count;
        if (tg.Total > 0)
            tg.UsagePct = Math.Round(100.0 * inUse / tg.Total, 1);
    }

    public static string SummaryFromDisplay(string visible)
    {
        // Collapse accidental multi-redraw garbage (same form repeated with single letters)
        var lines = visible.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 2)
            .Where(l => !l.StartsWith("display ", StringComparison.OrdinalIgnoreCase))
            .Where(l => !l.StartsWith("Command", StringComparison.OrdinalIgnoreCase))
            .Where(l => !l.Contains("press ", StringComparison.OrdinalIgnoreCase))
            .Where(l => l.Length > 1 || !char.IsLetter(l[0])) // drop single-letter noise
            .Distinct()
            .Take(50);
        return string.Join("\n", lines);
    }
}
