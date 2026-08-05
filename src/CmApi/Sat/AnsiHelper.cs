using System.Text;
using System.Text.RegularExpressions;

namespace CmApi.Sat;

internal static partial class AnsiHelper
{
    [GeneratedRegex(@"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0-9A-B]|\x1b.")]
    private static partial Regex AnsiRegex();

    public static string Strip(string input)
    {
        if (string.IsNullOrEmpty(input)) return "";
        var s = AnsiRegex().Replace(input, "");
        s = s.Replace("\0", "");
        return s;
    }

    public static string VisibleText(string input)
    {
        var s = Strip(input).Replace("\r", "\n");
        var sb = new StringBuilder();
        foreach (var line in s.Split('\n'))
        {
            var t = line.TrimEnd();
            if (t.Length == 0) continue;
            sb.AppendLine(t);
        }
        return sb.ToString();
    }
}
