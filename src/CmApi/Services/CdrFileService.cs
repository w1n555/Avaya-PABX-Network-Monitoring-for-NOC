using System.Globalization;
using System.Text.RegularExpressions;

namespace CmApi.Services;

/// <summary>
/// Reads daily Avaya CDR text files from siteRoot/cdr-link/cdr (YYYYMMDD.txt).
/// </summary>
public sealed class CdrFileService
{
    private readonly string _cdrDir;
    private static readonly Regex DayFileRe = new(@"^(\d{8})\.txt$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public CdrFileService(string siteRoot)
    {
        _cdrDir = Path.Combine(siteRoot, "cdr-link", "cdr");
        Directory.CreateDirectory(_cdrDir);
    }

    public string CdrDirectory => _cdrDir;

    public IReadOnlyList<string> ListDays(DateOnly? from, DateOnly? to)
    {
        if (!Directory.Exists(_cdrDir))
            return Array.Empty<string>();

        var days = new List<string>();
        foreach (var path in Directory.EnumerateFiles(_cdrDir, "*.txt"))
        {
            var name = Path.GetFileName(path);
            var m = DayFileRe.Match(name);
            if (!m.Success) continue;
            var key = m.Groups[1].Value;
            if (!DateOnly.TryParseExact(key, "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
                continue;
            if (from.HasValue && d < from.Value) continue;
            if (to.HasValue && d > to.Value) continue;
            days.Add(key);
        }
        days.Sort(StringComparer.Ordinal);
        return days;
    }

    public CdrDayScanResult ScanDay(string yyyymmdd, CdrFilter filter, int maxMatches = 500)
    {
        var pathTxt = Path.Combine(_cdrDir, yyyymmdd + ".txt");
        var pathTxtUpper = Path.Combine(_cdrDir, yyyymmdd + ".TXT");
        var path = File.Exists(pathTxt) ? pathTxt : (File.Exists(pathTxtUpper) ? pathTxtUpper : null);

        var hourly = new int[24];
        var matched = new List<CdrRecordDto>();
        var totalInFile = 0;
        var parseOk = 0;
        var matchTotal = 0;

        if (path == null)
        {
            return new CdrDayScanResult
            {
                Ok = true,
                Date = yyyymmdd,
                FileExists = false,
                TotalInFile = 0,
                ParseOk = 0,
                MatchCount = 0,
                MatchCountTotal = 0,
                Hourly = hourly,
                Matches = matched,
            };
        }

        // Share ReadWrite so live logger can keep appending today's file
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var reader = new StreamReader(fs, detectEncodingFromByteOrderMarks: true))
        {
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                if (string.IsNullOrWhiteSpace(line) || line.StartsWith('#'))
                    continue;

                CdrRecordDto? rec;
                try
                {
                    rec = ParseLine(line);
                }
                catch
                {
                    continue;
                }
                if (rec == null)
                    continue;

                totalInFile++;
                if (!rec.ParseOk)
                    continue; // skip keep-alives / half-lines

                parseOk++;

                // hourly counts only well-parsed CDR
                if (rec.Hour is >= 0 and <= 23)
                    hourly[rec.Hour]++;

                if (!filter.Matches(rec))
                    continue;

                matchTotal++;
                if (matched.Count < maxMatches)
                    matched.Add(rec);
            }
        }

        return new CdrDayScanResult
        {
            Ok = true,
            Date = yyyymmdd,
            FileExists = true,
            FileName = Path.GetFileName(path),
            TotalInFile = totalInFile,
            ParseOk = parseOk,
            MatchCount = matchTotal,
            MatchCountTotal = matchTotal,
            Hourly = hourly,
            Matches = matched,
        };
    }

    public static CdrRecordDto? ParseLine(string line)
    {
        // Format from logger:
        // recv_local|raw|date|time|sec_dur|cond|code_used|code_dial|dialed_num|clg|in_trk|in_crt|calling|out_crt|...
        var parts = line.Split('|');
        if (parts.Length < 2)
            return null;

        var recvLocal = parts[0].Trim();
        var raw = parts[1].Trim();

        // Skip pure keep-alive banners like "11:20 08/10"
        if (parts.Length < 5 && Regex.IsMatch(raw, @"^\d{1,2}:\d{2}\s+\d{1,2}/\d{1,2}$"))
            return null;
        if (raw.Length <= 2 && parts.Length < 5)
            return null;

        string date = parts.Length > 2 ? parts[2].Trim() : "";
        string time = parts.Length > 3 ? parts[3].Trim() : "";
        string secDur = parts.Length > 4 ? parts[4].Trim() : "";
        string cond = parts.Length > 5 ? parts[5].Trim() : "";
        string codeUsed = parts.Length > 6 ? parts[6].Trim() : "";
        string codeDial = parts.Length > 7 ? parts[7].Trim() : "";
        string dialed = parts.Length > 8 ? parts[8].Trim() : "";
        string clg = parts.Length > 9 ? parts[9].Trim() : "";
        string inTrk = parts.Length > 10 ? parts[10].Trim() : "";
        string inCrt = parts.Length > 11 ? parts[11].Trim() : "";
        string calling = parts.Length > 12 ? parts[12].Trim() : "";
        string outCrt = parts.Length > 13 ? parts[13].Trim() : "";

        // Prefer logger-split pipe fields when they look valid (date MMDDYY + time HHMM)
        var pipeOk = Regex.IsMatch(date, @"^\d{6}$") && Regex.IsMatch(time, @"^\d{4}$");
        if (!pipeOk)
        {
            // Fallback: re-parse fixed-width raw from CM customized layout
            var fromRaw = TryParseRawFixed(raw);
            if (fromRaw != null)
            {
                date = fromRaw.Value.date;
                time = fromRaw.Value.time;
                secDur = fromRaw.Value.secDur;
                cond = fromRaw.Value.cond;
                codeUsed = fromRaw.Value.codeUsed;
                codeDial = fromRaw.Value.codeDial;
                dialed = fromRaw.Value.dialed;
                clg = fromRaw.Value.clg;
                inTrk = fromRaw.Value.inTrk;
                inCrt = fromRaw.Value.inCrt;
                calling = fromRaw.Value.calling;
                outCrt = fromRaw.Value.outCrt;
            }
        }

        // Hour from time HHMM or recv_local
        int hour = -1;
        if (time.Length >= 4 && int.TryParse(time.AsSpan(0, 2), out var h) && h is >= 0 and <= 23)
            hour = h;
        else if (DateTime.TryParse(recvLocal, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var dt))
            hour = dt.Hour;

        int durationSec = 0;
        if (int.TryParse(secDur, out var dsec))
            durationSec = dsec;

        // Prefer CM condition code for direction when present (7/A out, 9 in)
        var dir = InferDirection(cond, calling, dialed, clg);

        var parseOk = date.Length >= 6 && time.Length >= 4;

        return new CdrRecordDto
        {
            RecvLocal = recvLocal,
            Raw = raw.Length > 120 ? raw[..120] : raw,
            Date = date,
            Time = time,
            Hour = hour,
            DurationSec = durationSec,
            Cond = cond,
            CodeUsed = codeUsed,
            CodeDial = codeDial,
            DialedNum = dialed,
            ClgNum = clg,
            InTrk = inTrk,
            InCrt = inCrt,
            CallingNum = string.IsNullOrEmpty(calling) ? clg : calling,
            OutCrt = outCrt,
            Dir = dir,
            ParseOk = parseOk,
        };
    }

    private static (string date, string time, string secDur, string cond, string codeUsed, string codeDial,
        string dialed, string clg, string inTrk, string inCrt, string calling, string outCrt)? TryParseRawFixed(string raw)
    {
        // Strip spaces collapse carefully — use fixed positions from CM customized layout
        // date6 sp time4 sp sec-dur5 sp cond1 sp code-used4 sp code-dial4 sp dialed23 sp clg15 sp in-trk4 sp in-crt4 sp calling15 sp out-crt4
        var s = raw.Replace("\r", "").Replace("\n", "");
        if (s.Length < 90)
            return null;
        // Must start with 6 digits date (MMDDYY)
        var head = s.Length >= 6 ? s.Substring(0, 6) : s;
        if (!Regex.IsMatch(head, @"^\d{6}$"))
            return null;

        try
        {
            string Take(int start, int len) =>
                start + len <= s.Length ? s.Substring(start, len).Trim() : "";

            // positions from CUSTOM_FIELDS cumulative
            // 0 date6, 6 sp, 7 time4, 11 sp, 12 secdur5, 17 sp, 18 cond1, 19 sp,
            // 20 codeused4, 24 sp, 25 codedial4, 29 sp, 30 dialed23, 53 sp, 54 clg15, 69 sp,
            // 70 intrk4, 74 sp, 75 incrt4, 79 sp, 80 calling15, 95 sp, 96 outcrt4
            return (
                Take(0, 6),
                Take(7, 4),
                Take(12, 5),
                Take(18, 1),
                Take(20, 4),
                Take(25, 4),
                Take(30, 23),
                Take(54, 15),
                Take(70, 4),
                Take(75, 4),
                Take(80, 15),
                Take(96, 4)
            );
        }
        catch
        {
            return null;
        }
    }

    private static string InferDirection(string cond, string calling, string dialed, string clg)
    {
        var cc = (cond ?? "").Trim().ToUpperInvariant();
        // Standard CM condition codes (most formats)
        if (cc is "9" or "8") return "in";
        if (cc is "7" or "A" or "B") return "out";
        if (cc is "0") return "intra";

        var c = string.IsNullOrEmpty(calling) ? clg : calling;
        c = c.Trim();
        var d = dialed.Trim();
        if (Regex.IsMatch(c, @"^\d{3,6}$") && d.Length >= 7)
            return "out";
        if (d.Length is >= 3 and <= 6 && c.Length >= 7)
            return "in";
        if (c.Length >= 8 && d.Length <= 6)
            return "in";
        if (d.Length >= 8)
            return "out";
        return "";
    }
}

public sealed class CdrFilter
{
    public string? Calling { get; set; }
    public string? Called { get; set; }
    public string? Trunk { get; set; }
    public string? Dir { get; set; }
    public int MinDur { get; set; }

    public bool Matches(CdrRecordDto r)
    {
        if (MinDur > 0 && r.DurationSec < MinDur)
            return false;
        if (!string.IsNullOrWhiteSpace(Dir) &&
            !string.Equals(r.Dir, Dir, StringComparison.OrdinalIgnoreCase))
            return false;
        if (!string.IsNullOrWhiteSpace(Calling))
        {
            var q = Calling.Trim();
            if (!r.CallingNum.Contains(q, StringComparison.OrdinalIgnoreCase) &&
                !r.ClgNum.Contains(q, StringComparison.OrdinalIgnoreCase))
                return false;
        }
        if (!string.IsNullOrWhiteSpace(Called))
        {
            var q = Called.Trim();
            if (!r.DialedNum.Contains(q, StringComparison.OrdinalIgnoreCase))
                return false;
        }
        if (!string.IsNullOrWhiteSpace(Trunk))
        {
            var t = Trunk.Trim().Replace("TG", "", StringComparison.OrdinalIgnoreCase).Trim();
            // match code_used / in_trk / out_crt
            if (!r.CodeUsed.Contains(t, StringComparison.OrdinalIgnoreCase) &&
                !r.InTrk.Contains(t, StringComparison.OrdinalIgnoreCase) &&
                !r.OutCrt.Contains(t, StringComparison.OrdinalIgnoreCase) &&
                !r.InCrt.Contains(t, StringComparison.OrdinalIgnoreCase))
                return false;
        }
        return true;
    }
}

public sealed class CdrRecordDto
{
    public string RecvLocal { get; set; } = "";
    public string Raw { get; set; } = "";
    public string Date { get; set; } = "";
    public string Time { get; set; } = "";
    public int Hour { get; set; } = -1;
    public int DurationSec { get; set; }
    public string Cond { get; set; } = "";
    public string CodeUsed { get; set; } = "";
    public string CodeDial { get; set; } = "";
    public string DialedNum { get; set; } = "";
    public string ClgNum { get; set; } = "";
    public string InTrk { get; set; } = "";
    public string InCrt { get; set; } = "";
    public string CallingNum { get; set; } = "";
    public string OutCrt { get; set; } = "";
    public string Dir { get; set; } = "";
    public bool ParseOk { get; set; }
}

public sealed class CdrDayScanResult
{
    public bool Ok { get; set; }
    public string Date { get; set; } = "";
    public bool FileExists { get; set; }
    public string? FileName { get; set; }
    public int TotalInFile { get; set; }
    public int ParseOk { get; set; }
    public int MatchCount { get; set; }
    public int MatchCountTotal { get; set; }
    public int[] Hourly { get; set; } = new int[24];
    public List<CdrRecordDto> Matches { get; set; } = new();
}
