using System.Diagnostics;
using System.Reflection;

var assembly = Assembly.GetExecutingAssembly();
var appPath = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName ?? AppContext.BaseDirectory;
var assemblyFile = new FileInfo(appPath);
var cacheKey = string.Join(
    "-",
    assembly.GetName().Version?.ToString() ?? "0.0.0.0",
    assemblyFile.Exists ? assemblyFile.Length.ToString() : "0",
    assemblyFile.Exists ? assemblyFile.LastWriteTimeUtc.Ticks.ToString() : "0");
var extractRoot = Path.Combine(Path.GetTempPath(), "SouthSideDownloaderExe", cacheKey);
var readyMarkerPath = Path.Combine(extractRoot, ".ready");
var scriptPath = Path.Combine(extractRoot, "download-minecraft-fabric.ps1");
var helpOnly = args.Any(IsHelpArgument);

Directory.CreateDirectory(extractRoot);
if (helpOnly)
{
    await ExtractResourceAsync(assembly, "download-minecraft-fabric.ps1", scriptPath);
}
else if (!File.Exists(readyMarkerPath) || !File.Exists(scriptPath))
{
    foreach (var resourceName in assembly.GetManifestResourceNames())
    {
        var targetPath = Path.Combine(extractRoot, resourceName.Replace('/', Path.DirectorySeparatorChar));
        await ExtractResourceAsync(assembly, resourceName, targetPath);
    }

    File.WriteAllText(readyMarkerPath, cacheKey);
}

var powershellPath = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.System),
    @"WindowsPowerShell\v1.0\powershell.exe");

var forwardedArgs = string.Join(" ", args.Select(QuoteArgument));
var arguments = $"-STA -NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)}";
if (!string.IsNullOrWhiteSpace(forwardedArgs))
{
    arguments += " " + forwardedArgs;
}

var startInfo = new ProcessStartInfo
{
    FileName = powershellPath,
    Arguments = arguments,
    WorkingDirectory = extractRoot,
    UseShellExecute = false
};

int exitCode;
using (var process = Process.Start(startInfo)
    ?? throw new InvalidOperationException("Cannot start installer script"))
{
    process.WaitForExit();
    exitCode = process.ExitCode;
}

TryDeleteDirectory(extractRoot);
TryDeleteEmptyParent(Path.Combine(Path.GetTempPath(), "SouthSideDownloaderExe"));
return exitCode;

static string QuoteArgument(string value)
{
    if (string.IsNullOrEmpty(value))
    {
        return "\"\"";
    }

    return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
}

static bool IsHelpArgument(string value)
{
    return value.Equals("-Help", StringComparison.OrdinalIgnoreCase)
        || value.Equals("--help", StringComparison.OrdinalIgnoreCase)
        || value.Equals("/Help", StringComparison.OrdinalIgnoreCase)
        || value.Equals("/?", StringComparison.OrdinalIgnoreCase);
}

static async Task ExtractResourceAsync(Assembly assembly, string resourceName, string targetPath)
{
    var targetDir = Path.GetDirectoryName(targetPath);
    if (!string.IsNullOrWhiteSpace(targetDir))
    {
        Directory.CreateDirectory(targetDir);
    }

    await using var input = assembly.GetManifestResourceStream(resourceName)
        ?? throw new InvalidOperationException("Cannot read embedded resource: " + resourceName);
    if (File.Exists(targetPath) && new FileInfo(targetPath).Length == input.Length)
    {
        return;
    }

    var tempPath = targetPath + ".tmp-" + Guid.NewGuid().ToString("N");
    await using var output = File.Create(tempPath);
    await input.CopyToAsync(output);
    await output.DisposeAsync();
    File.Move(tempPath, targetPath, true);
}

static void TryDeleteDirectory(string path)
{
    if (!IsSafeTempChildPath(path) || !Directory.Exists(path))
    {
        return;
    }

    for (var attempt = 0; attempt < 3; attempt++)
    {
        try
        {
            Directory.Delete(path, true);
            return;
        }
        catch
        {
            Thread.Sleep(200);
        }
    }
}

static void TryDeleteEmptyParent(string path)
{
    if (!IsSafeTempChildPath(path) || !Directory.Exists(path))
    {
        return;
    }

    try
    {
        Directory.Delete(path, false);
    }
    catch
    {
    }
}

static bool IsSafeTempChildPath(string path)
{
    if (string.IsNullOrWhiteSpace(path))
    {
        return false;
    }

    try
    {
        var tempRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var target = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return target.StartsWith(tempRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            && !target.Equals(tempRoot, StringComparison.OrdinalIgnoreCase);
    }
    catch
    {
        return false;
    }
}
