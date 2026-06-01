param(
    [string]$MinecraftVersion = "1.21.4",
    [string]$MinecraftDir = (Join-Path $env:APPDATA ".minecraft"),
    [string]$FabricLoaderVersion = "latest",
    [string]$InstallVersionName = "SouthsideNextgen",
    [string]$ProfileName = "SouthsideNextgen",
    [int]$MaxThreads = 16,
    [int]$RetryCount = 3,
    [int]$NoProgressTimeoutSeconds = 15,
    [int]$HedgeAfterSeconds = 5,
    [switch]$NoLauncherProfile,
    [switch]$SkipAssets,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch {
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

$BmclBase = "https://bmclapi2.bangbang93.com"
$PistonMetaBase = "https://piston-meta.mojang.com"
$PistonDataBase = "https://piston-data.mojang.com"
$LaunchMetaBase = "https://launchermeta.mojang.com"
$LauncherBase = "https://launcher.mojang.com"
$LibrariesBase = "https://libraries.minecraft.net"
$AssetsBase = "https://resources.download.minecraft.net"
$FabricMetaBase = "https://meta.fabricmc.net"
$FabricMavenBase = "https://maven.fabricmc.net"

function Show-Help {
    Write-Host "南侧下载器 - 自动下载 Minecraft $MinecraftVersion + Fabric"
    Write-Host ""
    Write-Host "用法："
    Write-Host "  .\SouthSideDownloader.bat"
    Write-Host "  .\SouthSideDownloader.bat -MinecraftDir D:\Games\.minecraft"
    Write-Host "  .\SouthSideDownloader.bat -FabricLoaderVersion 0.16.14"
    Write-Host "  .\SouthSideDownloader.bat -InstallVersionName SouthsideNextgen"
    Write-Host "  .\SouthSideDownloader.bat -MaxThreads 32"
    Write-Host "  .\SouthSideDownloader.bat -RetryCount 3"
    Write-Host "  .\SouthSideDownloader.bat -NoProgressTimeoutSeconds 15"
    Write-Host "  .\SouthSideDownloader.bat -HedgeAfterSeconds 5"
    Write-Host ""
    Write-Host "默认安装目录：$MinecraftDir"
}

if ($Help) {
    Show-Help
    exit 0
}

$MinecraftDirWasProvided = $PSBoundParameters.ContainsKey("MinecraftDir")
$MaxThreadsWasProvided = $PSBoundParameters.ContainsKey("MaxThreads")

function New-Utf8NoBomEncoding {
    return New-Object System.Text.UTF8Encoding($false)
}

function Join-Parts {
    param([string[]]$Parts)

    $result = $Parts[0]
    for ($i = 1; $i -lt $Parts.Count; $i++) {
        $result = Join-Path $result $Parts[$i]
    }
    return $result
}

function Ensure-Directory {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Test-FileMetadataMatches {
    param(
        [string]$Path,
        [Int64]$Length,
        [datetime]$LastWriteTimeUtc = [datetime]::MinValue,
        [int]$TimestampToleranceSeconds = 2
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $file = Get-Item -LiteralPath $Path
    if ([Int64]$file.Length -ne $Length) {
        return $false
    }

    if ($LastWriteTimeUtc -ne [datetime]::MinValue) {
        $seconds = [Math]::Abs(($file.LastWriteTimeUtc - $LastWriteTimeUtc).TotalSeconds)
        if ($seconds -gt $TimestampToleranceSeconds) {
            return $false
        }
    }

    return $true
}

function Set-DownloadNetworkTuning {
    param([int]$ThreadCount)

    $connectionLimit = [Math]::Max(32, [Math]::Min(256, $ThreadCount * 4))
    try {
        [Net.ServicePointManager]::DefaultConnectionLimit = $connectionLimit
        [Net.ServicePointManager]::Expect100Continue = $false
        [Net.ServicePointManager]::UseNagleAlgorithm = $false
    } catch {
    }
    Write-Host "网络并发连接上限：$connectionLimit"
}

function Convert-ToFullPath {
    param([string]$Path)

    $cleanPath = $Path.Trim()
    if (($cleanPath.StartsWith('"') -and $cleanPath.EndsWith('"')) -or ($cleanPath.StartsWith("'") -and $cleanPath.EndsWith("'"))) {
        $cleanPath = $cleanPath.Substring(1, $cleanPath.Length - 2)
    }
    $cleanPath = [Environment]::ExpandEnvironmentVariables($cleanPath)
    return [System.IO.Path]::GetFullPath($cleanPath)
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $true
    )

    if ($DefaultYes) {
        $suffix = "（Y=确定，N=否定，直接回车=确定）"
    } else {
        $suffix = "（Y=确定，N=否定，直接回车=否定）"
    }

    while ($true) {
        $answer = (Read-Host "$Prompt$suffix").Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }
        if (@("y", "yes") -contains $answer) {
            return $true
        }
        if (@("n", "no") -contains $answer) {
            return $false
        }
        Write-Host "请输入 Y 或 N。Y 表示确定，N 表示否定。"
    }
}

function Invoke-WithUserRetry {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    while ($true) {
        try {
            return & $Action
        } catch {
            Write-Host ""
            Write-Host "$Name 出错：$($_.Exception.Message)"
            if (Read-YesNo -Prompt "是否重试 $Name？" -DefaultYes $true) {
                Write-Host "正在重试：$Name"
                continue
            }
            throw
        }
    }
}

function Read-ThreadCount {
    param([int]$DefaultThreads = 16)

    $answer = Read-Host "请输入下载线程数，直接回车默认 $DefaultThreads 线程"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultThreads
    }

    $parsed = 0
    if (-not [int]::TryParse($answer.Trim(), [ref]$parsed)) {
        Write-Host "看不懂这个线程数，使用默认 $DefaultThreads 线程。"
        return $DefaultThreads
    }

    if ($parsed -lt 1) {
        Write-Host "线程数太小，使用默认 $DefaultThreads 线程。"
        return $DefaultThreads
    }

    if ($parsed -gt 64) {
        Write-Host "线程数太大，已限制为 64 线程。"
        return 64
    }

    return $parsed
}

function Convert-ToHtmlText {
    param([string]$Text)

    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Show-InstallTutorial {
    param(
        [string]$InstallVersionName,
        [string]$ProfileName,
        [string]$MinecraftDir,
        [string]$GameDir
    )

    $launcherPath = Join-Path (Split-Path -Parent $MinecraftDir) "Plain Craft Launcher 2.exe"
    $shortcutName = "南方启动器"
    $tutorialDir = Join-Path $env:TEMP "SouthSideDownloader"
    Ensure-Directory $tutorialDir
    $tutorialPath = $null
    $helpZipPath = Join-Parts @($PSScriptRoot, "resources", "help.zip")

    if (Test-Path -LiteralPath $helpZipPath -PathType Leaf) {
        $helpDir = Join-Path $tutorialDir "help"
        if (Test-Path -LiteralPath $helpDir) {
            Remove-Item -LiteralPath $helpDir -Recurse -Force
        }
        Ensure-Directory $helpDir
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($helpZipPath, $helpDir)
        $tutorialPath = Join-Path $helpDir "index.html"
    } else {
        $tutorialPath = Join-Path $tutorialDir "安装后教程.html"

        # TODO: 正式教程还没写好，后面把完整 HTML 内容填到这里。
        $html = @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>安装后教程</title>
  <style>
    body { font-family: "Microsoft YaHei", sans-serif; margin: 32px; line-height: 1.7; color: #1f2328; }
    code { background: #f3f4f6; padding: 2px 6px; border-radius: 4px; }
    .box { border: 1px solid #d0d7de; border-radius: 8px; padding: 16px; margin: 16px 0; }
  </style>
</head>
<body>
  <h1>安装后教程</h1>
  <p>正式教程还没写好，这里先预留 HTML 教程入口。</p>
  <div class="box">
    <p><strong>游戏名称：</strong>$(Convert-ToHtmlText $InstallVersionName)</p>
    <p><strong>启动器配置：</strong>$(Convert-ToHtmlText $ProfileName)</p>
    <p><strong>.minecraft 目录：</strong><code>$(Convert-ToHtmlText $MinecraftDir)</code></p>
    <p><strong>游戏文件夹：</strong><code>$(Convert-ToHtmlText $GameDir)</code></p>
    <p><strong>PCL2 启动器：</strong><code>$(Convert-ToHtmlText $launcherPath)</code></p>
    <p><strong>桌面快捷方式：</strong>$(Convert-ToHtmlText $shortcutName)</p>
  </div>
  <h2>临时说明</h2>
  <ol>
    <li>你需要打开你的启动器，本安装器已经在桌面上生成快捷方式。</li>
    <li>如果 PCL2 询问游戏目录，请选择上面显示的 .minecraft 目录。</li>
    <li>选择启动配置：$(Convert-ToHtmlText $ProfileName)。</li>
    <li>确认 Java 使用 Java 21。</li>
    <li>内置模组已经放在：<code>$(Convert-ToHtmlText (Join-Path $GameDir "mods"))</code></li>
    <li>首次使用无需兑换/充值这一步。</li>
    <li>进入世界后，按下 <code>0</code> 打开云参，按下 <code>右 Shift</code> 打开南方 ClickGUI。</li>
  </ol>
</body>
</html>
"@

        [System.IO.File]::WriteAllText($tutorialPath, $html, (New-Utf8NoBomEncoding))
    }

    $browserPaths = New-Object System.Collections.Generic.List[string]
    foreach ($registryPath in @(
        "HKCU:\Software\Classes\ChromeHTML.LPVXVUOBNCCOOZ3FN37CPWECGY\shell\open\command",
        "HKCU:\Software\Classes\ChromeHTML\shell\open\command",
        "HKCU:\Software\Classes\MSEdgeHTM\shell\open\command",
        "HKLM:\Software\Classes\ChromeHTML\shell\open\command",
        "HKLM:\Software\Classes\MSEdgeHTM\shell\open\command"
    )) {
        $command = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue)."(default)"
        if ([string]::IsNullOrWhiteSpace($command)) {
            continue
        }
        if ($command -match '^"([^"]+)"') {
            [void]$browserPaths.Add($matches[1])
        }
    }
    foreach ($knownBrowserPath in @(
        "$env:LocalAppData\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )) {
        [void]$browserPaths.Add($knownBrowserPath)
    }

    $openedTutorial = $false
    foreach ($browserPath in ($browserPaths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $browserPath -PathType Leaf)) {
            continue
        }
        try {
            Start-Process -FilePath $browserPath -ArgumentList @("--new-window", $tutorialPath) | Out-Null
            $openedTutorial = $true
            break
        } catch {
        }
    }

    if (-not $openedTutorial) {
        Write-Host "教程 HTML 自动打开失败，请手动打开：$tutorialPath"
    }

    Write-Host ""
    Write-Host "请阅读已经弹出的教程 HTML。"
    Write-Host "教程 HTML 位置：$tutorialPath"
    Write-Host ""
}

function Wait-TutorialReadConfirmation {
    $expected = "我已经阅读了教程"
    try {
        while ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
        }
    } catch {
    }

    while ($true) {
        Write-Host "请输入“$expected”后按回车退出安装"
        $answer = [Console]::ReadLine()
        if ($answer -eq $null) {
            Start-Sleep -Milliseconds 200
            continue
        }
        if ([string]::IsNullOrWhiteSpace($answer)) {
            continue
        }
        if ($answer.Trim() -eq $expected) {
            return
        }
        Write-Host "输入不正确，请完整输入：$expected"
    }
}

function Install-BundledMods {
    param([string]$GameDir)

    $modsZipPath = Join-Parts @($PSScriptRoot, "resources", "mods.zip")
    if (-not (Test-Path -LiteralPath $modsZipPath -PathType Leaf)) {
        Write-Host "未找到内置模组包，跳过模组导入：$modsZipPath"
        return
    }

    $modsDir = Join-Path $GameDir "mods"
    Ensure-Directory $modsDir

    Write-Host "正在导入内置模组到：$modsDir"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($modsZipPath)
        $extractedCount = 0
        $skippedCount = 0
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                continue
            }

            $entryName = $entry.Name
            $targetPath = Join-Path $modsDir $entryName
            if (Test-FileMetadataMatches -Path $targetPath -Length $entry.Length -LastWriteTimeUtc $entry.LastWriteTime.UtcDateTime) {
                $skippedCount++
                continue
            }

            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
            [System.IO.File]::SetLastWriteTimeUtc($targetPath, $entry.LastWriteTime.UtcDateTime)
            $extractedCount++
        }
    } finally {
        if ($archive -ne $null) {
            $archive.Dispose()
        }
    }

    if ($extractedCount -eq 0 -and $skippedCount -gt 0) {
        Write-Host "内置模组已是最新，跳过重复导入"
    } else {
        Write-Host "内置模组导入完成：更新 $extractedCount 个，跳过 $skippedCount 个"
    }
}

function Install-BundledLauncher {
    param([string]$MinecraftDir)

    $launcherSourcePath = Join-Parts @($PSScriptRoot, "resources", "Plain Craft Launcher 2.exe")
    if (-not (Test-Path -LiteralPath $launcherSourcePath -PathType Leaf)) {
        Write-Host "未找到内置 PCL2 启动器，跳过启动器释放：$launcherSourcePath"
        return
    }

    $parentDir = Split-Path -Parent $MinecraftDir
    if ([string]::IsNullOrWhiteSpace($parentDir)) {
        $parentDir = $MinecraftDir
    }
    Ensure-Directory $parentDir

    $launcherTargetPath = Join-Path $parentDir "Plain Craft Launcher 2.exe"
    $sourceFile = Get-Item -LiteralPath $launcherSourcePath
    if (Test-FileMetadataMatches -Path $launcherTargetPath -Length $sourceFile.Length -LastWriteTimeUtc $sourceFile.LastWriteTimeUtc) {
        Write-Host "PCL2 启动器已是最新，跳过重复释放：$launcherTargetPath"
    } else {
        Copy-Item -LiteralPath $launcherSourcePath -Destination $launcherTargetPath -Force
        [System.IO.File]::SetLastWriteTimeUtc($launcherTargetPath, $sourceFile.LastWriteTimeUtc)
        Write-Host "PCL2 启动器已释放到：$launcherTargetPath"
    }

    try {
        $desktopDir = [Environment]::GetFolderPath("Desktop")
        $shortcutPath = Join-Path $desktopDir "南方启动器.lnk"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        if ($shortcut.TargetPath -ieq $launcherTargetPath -and
            $shortcut.WorkingDirectory -ieq $parentDir -and
            $shortcut.Description -eq "南方启动器" -and
            $shortcut.IconLocation -ieq $launcherTargetPath) {
            Write-Host "桌面快捷方式已是最新，跳过重复创建：$shortcutPath"
        } else {
            $shortcut.TargetPath = $launcherTargetPath
            $shortcut.WorkingDirectory = $parentDir
            $shortcut.Description = "南方启动器"
            $shortcut.IconLocation = $launcherTargetPath
            $shortcut.Save()
            Write-Host "桌面快捷方式已创建：$shortcutPath"
        }
    } catch {
        Write-Host "桌面快捷方式创建失败：$($_.Exception.Message)"
    }
}

function Select-FolderByDialog {
    param(
        [string]$Description,
        [string]$DefaultPath,
        [bool]$AllowCreate = $true
    )

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $AllowCreate

    if (-not [string]::IsNullOrWhiteSpace($DefaultPath)) {
        $expandedDefaultPath = Convert-ToFullPath $DefaultPath
        if (Test-Path -LiteralPath $expandedDefaultPath -PathType Container) {
            $dialog.SelectedPath = $expandedDefaultPath
        }
    }

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or [string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
        throw "玩家取消了文件夹选择"
    }

    return Convert-ToFullPath $dialog.SelectedPath
}

function Get-InteractiveMinecraftDir {
    param([string]$DefaultMinecraftDir)

    Write-Host "安装位置设置"
    Write-Host "本工具需要一个 .minecraft 文件夹。"
    Write-Host ""

    $hasMinecraftFolder = Read-YesNo -Prompt "你已经有 .minecraft 文件夹吗？" -DefaultYes (Test-Path -LiteralPath $DefaultMinecraftDir -PathType Container)

    if ($hasMinecraftFolder) {
        while ($true) {
            Write-Host "请在弹出的窗口中选择已有的 .minecraft 文件夹。"
            $existingPath = Select-FolderByDialog -Description "请选择已有的 .minecraft 文件夹" -DefaultPath $DefaultMinecraftDir -AllowCreate $false
            if (Test-Path -LiteralPath $existingPath -PathType Container) {
                return $existingPath
            }

            Write-Host "没有找到文件夹：$existingPath"
        }
    }

    while ($true) {
        Write-Host "请在弹出的窗口中选择安装位置，程序会在里面新建 .minecraft 文件夹。"
        $installRoot = Select-FolderByDialog -Description "请选择安装位置，程序会在里面新建 .minecraft 文件夹" -DefaultPath (Join-Path $env:APPDATA "SouthSideDownloader") -AllowCreate $true
        $targetDir = Join-Path $installRoot ".minecraft"

        Write-Host "将使用这个 .minecraft 文件夹：$targetDir"
        if (Read-YesNo -Prompt "确定使用这个位置吗？" -DefaultYes $true) {
            Ensure-Directory $targetDir
            return $targetDir
        }
    }
}

function Save-Utf8Json {
    param(
        [string]$Path,
        [object]$Object
    )

    Ensure-Directory (Split-Path -Parent $Path)
    $json = $Object | ConvertTo-Json -Depth 100
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) -eq $json)) {
        return
    }

    [System.IO.File]::WriteAllText($Path, $json, (New-Utf8NoBomEncoding))
}

function Read-Utf8JsonFile {
    param([string]$Path)

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json
}

function Get-Sha1 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant()
}

$script:FileValidationCachePath = ""
$script:FileValidationCache = @{}
$script:FileValidationCacheDirty = $false
$script:JsonCacheDir = ""
$script:JsonCachePathByUrl = @{}

function Get-FileValidationCacheKey {
    param([string]$Path)

    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd("\").ToLowerInvariant()
    } catch {
        return ([string]$Path).ToLowerInvariant()
    }
}

function Initialize-FileValidationCache {
    param([string]$MinecraftDir)

    $script:FileValidationCachePath = Join-Path $MinecraftDir ".southside-downloader-cache.json"
    $script:FileValidationCache = @{}
    $script:FileValidationCacheDirty = $false

    if (-not (Test-Path -LiteralPath $script:FileValidationCachePath -PathType Leaf)) {
        return
    }

    try {
        $cacheRoot = Read-Utf8JsonFile $script:FileValidationCachePath
        if ($cacheRoot -eq $null -or $cacheRoot.version -ne 1 -or $cacheRoot.entries -eq $null) {
            return
        }

        foreach ($entry in @($cacheRoot.entries)) {
            if ($entry -eq $null -or [string]::IsNullOrWhiteSpace([string]$entry.key)) {
                continue
            }
            $script:FileValidationCache[[string]$entry.key] = [pscustomobject]@{
                length = [Int64]$entry.length
                lastWriteUtcTicks = [Int64]$entry.lastWriteUtcTicks
                sha1 = ([string]$entry.sha1).ToLowerInvariant()
            }
        }
    } catch {
        $script:FileValidationCache = @{}
    }
}

function Set-FileValidationCacheEntry {
    param(
        [string]$Path,
        [string]$Sha1,
        [object]$File = $null
    )

    if ([string]::IsNullOrWhiteSpace($script:FileValidationCachePath) -or [string]::IsNullOrWhiteSpace($Sha1)) {
        return
    }

    try {
        if ($File -eq $null) {
            $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        } else {
            $file = $File
        }
        $key = Get-FileValidationCacheKey $Path
        if ($script:FileValidationCache.ContainsKey($key)) {
            $cached = $script:FileValidationCache[$key]
            if ([Int64]$cached.length -eq [Int64]$file.Length -and
                [Int64]$cached.lastWriteUtcTicks -eq [Int64]$file.LastWriteTimeUtc.Ticks -and
                [string]$cached.sha1 -eq $Sha1.ToLowerInvariant()) {
                return
            }
        }

        $script:FileValidationCache[$key] = [pscustomobject]@{
            length = [Int64]$file.Length
            lastWriteUtcTicks = [Int64]$file.LastWriteTimeUtc.Ticks
            sha1 = $Sha1.ToLowerInvariant()
        }
        $script:FileValidationCacheDirty = $true
    } catch {
    }
}

function Save-FileValidationCache {
    if (-not $script:FileValidationCacheDirty -or [string]::IsNullOrWhiteSpace($script:FileValidationCachePath)) {
        return
    }

    try {
        Ensure-Directory (Split-Path -Parent $script:FileValidationCachePath)
        $entries = New-Object System.Collections.ArrayList
        foreach ($key in $script:FileValidationCache.Keys) {
            $entry = $script:FileValidationCache[$key]
            [void]$entries.Add([pscustomobject]@{
                key = $key
                length = [Int64]$entry.length
                lastWriteUtcTicks = [Int64]$entry.lastWriteUtcTicks
                sha1 = [string]$entry.sha1
            })
        }

        Save-Utf8Json -Path $script:FileValidationCachePath -Object ([pscustomobject]@{
            version = 1
            entries = $entries.ToArray()
        })
        $script:FileValidationCacheDirty = $false
    } catch {
        Write-Host "校验缓存保存失败，已跳过：$($_.Exception.Message)"
    }
}

function Get-TextSha1 {
    param([string]$Text)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha1.ComputeHash($bytes)
        return ([BitConverter]::ToString($hashBytes) -replace "-", "").ToLowerInvariant()
    } finally {
        $sha1.Dispose()
    }
}

function Initialize-JsonCache {
    param([string]$MinecraftDir)

    $script:JsonCacheDir = Join-Path $MinecraftDir ".southside-downloader-json-cache"
    $script:JsonCachePathByUrl = @{}
    Ensure-Directory $script:JsonCacheDir
}

function Get-JsonCachePath {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($script:JsonCacheDir) -or [string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }
    if ($script:JsonCachePathByUrl.ContainsKey($Url)) {
        return $script:JsonCachePathByUrl[$Url]
    }

    $cachePath = Join-Path $script:JsonCacheDir "$(Get-TextSha1 $Url).json"
    $script:JsonCachePathByUrl[$Url] = $cachePath
    return $cachePath
}

function Read-JsonCacheEntry {
    param(
        [string]$Url,
        [string]$Name,
        [int]$MaxAgeMinutes = 360,
        [bool]$AllowStale = $false
    )

    $cachePath = Get-JsonCachePath $Url
    if ([string]::IsNullOrWhiteSpace($cachePath) -or -not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        return [pscustomobject]@{ Hit = $false; Value = $null }
    }

    try {
        $file = Get-Item -LiteralPath $cachePath -ErrorAction Stop
        $ageMinutes = ((Get-Date).ToUniversalTime() - $file.LastWriteTimeUtc).TotalMinutes
        if (-not $AllowStale -and $ageMinutes -gt $MaxAgeMinutes) {
            return [pscustomobject]@{ Hit = $false; Value = $null }
        }

        $raw = [System.IO.File]::ReadAllText($cachePath, [System.Text.Encoding]::UTF8)
        $value = $raw | ConvertFrom-Json
        if ($AllowStale) {
            Write-Host "使用旧缓存读取${Name}：$Url"
        } else {
            Write-Host "使用缓存读取${Name}：$Url"
        }
        return [pscustomobject]@{ Hit = $true; Value = $value }
    } catch {
        return [pscustomobject]@{ Hit = $false; Value = $null }
    }
}

function Write-JsonCacheEntry {
    param(
        [string]$Url,
        [string]$Content
    )

    $cachePath = Get-JsonCachePath $Url
    if ([string]::IsNullOrWhiteSpace($cachePath) -or [string]::IsNullOrWhiteSpace($Content)) {
        return
    }

    try {
        Ensure-Directory (Split-Path -Parent $cachePath)
        if ((Test-Path -LiteralPath $cachePath -PathType Leaf) -and ([System.IO.File]::ReadAllText($cachePath, [System.Text.Encoding]::UTF8) -eq $Content)) {
            [System.IO.File]::SetLastWriteTimeUtc($cachePath, (Get-Date).ToUniversalTime())
            return
        }

        [System.IO.File]::WriteAllText($cachePath, $Content, (New-Utf8NoBomEncoding))
    } catch {
    }
}

function Test-FileMatches {
    param(
        [string]$Path,
        [string]$Sha1,
        [Nullable[Int64]]$Size
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $file = Get-Item -LiteralPath $Path
    if ($Size -ne $null -and $Size -gt 0 -and $file.Length -ne $Size) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($Sha1)) {
        $expectedSha1 = $Sha1.ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($script:FileValidationCachePath)) {
            $key = Get-FileValidationCacheKey $Path
            if ($script:FileValidationCache.ContainsKey($key)) {
                $cached = $script:FileValidationCache[$key]
                if ([Int64]$cached.length -eq [Int64]$file.Length -and
                    [Int64]$cached.lastWriteUtcTicks -eq [Int64]$file.LastWriteTimeUtc.Ticks -and
                    [string]$cached.sha1 -eq $expectedSha1) {
                    return $true
                }
            }
        }

        if ((Get-Sha1 $Path) -ne $expectedSha1) {
            return $false
        }
        Set-FileValidationCacheEntry -Path $Path -Sha1 $expectedSha1 -File $file
    }

    return $true
}

function Format-FileSize {
    param([double]$Bytes)

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }
    if ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }
    return "{0:N0} B" -f $Bytes
}

function Show-TextProgressBar {
    param(
        [string]$Title,
        [int]$Done,
        [int]$Total,
        [string]$Extra = "",
        [switch]$Complete
    )

    $safeTotal = [Math]::Max($Total, 1)
    $percent = [Math]::Min(100, [Math]::Max(0, [int](($Done / $safeTotal) * 100)))
    $width = 30
    $filled = [Math]::Min($width, [Math]::Max(0, [int](($percent / 100) * $width)))
    $empty = $width - $filled
    $bar = ("#" * $filled) + ("-" * $empty)
    $line = "`r$Title [$bar] $percent%  $Done/$Total"
    if (-not [string]::IsNullOrWhiteSpace($Extra)) {
        $line = "$line  $Extra"
    }

    Write-Host $line -NoNewline
    if ($Complete) {
        Write-Host ""
    }
}

function Show-ByteProgressBar {
    param(
        [string]$Title,
        [Int64]$DoneBytes,
        [Int64]$TotalBytes,
        [switch]$Complete
    )

    if ($TotalBytes -le 0) {
        $line = "`r$Title [未知大小] 已下载 $(Format-FileSize $DoneBytes)"
        Write-Host $line -NoNewline
        if ($Complete) {
            Write-Host ""
        }
        return
    }

    $extra = "$(Format-FileSize $DoneBytes) / $(Format-FileSize $TotalBytes)"
    Show-TextProgressBar -Title $Title -Done ([int][Math]::Min($DoneBytes, $TotalBytes)) -Total ([int]$TotalBytes) -Extra $extra -Complete:$Complete
}

function Get-ShortProgressName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "未知文件"
    }
    $leafName = Split-Path -Leaf $Name
    if ([string]::IsNullOrWhiteSpace($leafName)) {
        $leafName = $Name
    }
    if ($leafName.Length -le 18) {
        return $leafName
    }
    return $leafName.Substring(0, 7) + "..." + $leafName.Substring($leafName.Length - 8)
}

function Limit-ConsoleText {
    param(
        [string]$Text,
        [int]$MaxLength
    )

    if ([string]::IsNullOrEmpty($Text) -or $Text.Length -le $MaxLength) {
        return $Text
    }

    if ($MaxLength -le 3) {
        return $Text.Substring(0, $MaxLength)
    }

    return $Text.Substring(0, $MaxLength - 3) + "..."
}

function Clear-CurrentConsoleLine {
    param([int]$Width)

    try {
        [Console]::Write("`r" + (" " * [Math]::Max(1, $Width - 1)) + "`r")
    } catch {
        [Console]::Write("`r")
    }
}

function Get-ConsoleLineWidth {
    try {
        $width = [Console]::WindowWidth
        if ($width -le 0) {
            $width = [Console]::BufferWidth
        }
    } catch {
        $width = 100
    }

    if ($width -lt 50) {
        return 50
    }
    return [Math]::Min($width, 120)
}
function Show-FileProgressItem {
    param(
        [int]$Id,
        [string]$Name,
        [Int64]$DoneBytes,
        [Int64]$TotalBytes,
        [string]$Status
    )

    $shortName = Get-ShortProgressName $Name
    if ($TotalBytes -gt 0) {
        $percent = [Math]::Min(100, [Math]::Max(0, [int](($DoneBytes / $TotalBytes) * 100)))
        $statusText = "$Status  $(Format-FileSize $DoneBytes) / $(Format-FileSize $TotalBytes)"
    } else {
        $percent = 0
        $statusText = "$Status  $(Format-FileSize $DoneBytes)"
    }

    Write-Progress -Id $Id -Activity "下载文件：$shortName" -Status $statusText -PercentComplete $percent
}

function Get-ProgressBarText {
    param(
        [int]$Percent,
        [int]$Width = 30
    )

    $safePercent = [Math]::Min(100, [Math]::Max(0, $Percent))
    $filled = [Math]::Min($Width, [Math]::Max(0, [int](($safePercent / 100) * $Width)))
    $empty = $Width - $filled
    return ("#" * $filled) + ("-" * $empty)
}

function Write-FixedProgressLines {
    param(
        [string]$Title,
        [int]$Done,
        [int]$Total,
        [int]$ThreadCount,
        [string]$FileName = "",
        [Int64]$FileDoneBytes = 0,
        [Int64]$FileTotalBytes = 0,
        [switch]$Initialize,
        [switch]$Complete
    )

    $width = Get-ConsoleLineWidth
    $maxLineLength = [Math]::Max(45, [Math]::Min(88, [int](($width - 4) * 0.58)))

    $safeTotal = [Math]::Max($Total, 1)
    $totalPercent = [Math]::Min(100, [Math]::Max(0, [int](($Done / $safeTotal) * 100)))
    $totalBar = Get-ProgressBarText -Percent $totalPercent -Width 12

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        $filePart = "文件:等待"
    } else {
        $shortName = Get-ShortProgressName $FileName
        if ($FileTotalBytes -gt 0) {
            $filePercent = [Math]::Min(100, [Math]::Max(0, [int](($FileDoneBytes / $FileTotalBytes) * 100)))
            $fileBar = Get-ProgressBarText -Percent $filePercent -Width 6
            $filePart = "文件:$filePercent% [$fileBar] $shortName"
        } else {
            $filePart = "文件[未知] $shortName"
        }
    }

    $line = "$Title [$totalBar] $totalPercent% $Done/$Total  线程:$ThreadCount  $filePart"
    $line = Limit-ConsoleText -Text $line -MaxLength $maxLineLength

    Clear-CurrentConsoleLine -Width $width
    [Console]::Write("`r$line")

    if ($Complete) {
        [Console]::WriteLine()
    }
}

function Invoke-DownloadFileWithProgress {
    param(
        [string]$Url,
        [string]$Path,
        [string]$Name,
        [int]$NoProgressTimeoutSeconds = 15
    )

    $response = $null
    $inputStream = $null
    $outputStream = $null

    try {
        $existingBytes = [Int64]0
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $existingBytes = (Get-Item -LiteralPath $Path).Length
        }

        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Timeout = 120000
        $request.ReadWriteTimeout = [Math]::Max(5, $NoProgressTimeoutSeconds) * 1000
        if ($existingBytes -gt 0) {
            $request.AddRange($existingBytes)
        }

        $response = $request.GetResponse()
        $inputStream = $response.GetResponseStream()

        $resumeAccepted = $existingBytes -gt 0 -and $response.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent
        if ($resumeAccepted) {
            $outputStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $doneBytes = $existingBytes
            if ($response.ContentLength -gt 0) {
                $totalBytes = $existingBytes + [Int64]$response.ContentLength
            } else {
                $totalBytes = [Int64]0
            }
        } else {
            $outputStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $doneBytes = [Int64]0
            $totalBytes = [Int64]$response.ContentLength
        }

        $buffer = New-Object byte[] 131072
        $lastUpdate = Get-Date
        Show-ByteProgressBar -Title "下载${Name}" -DoneBytes 0 -TotalBytes $totalBytes

        while ($true) {
            $read = $inputStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }

            $outputStream.Write($buffer, 0, $read)
            $doneBytes += $read
            $now = Get-Date
            if (($now - $lastUpdate).TotalMilliseconds -ge 200) {
                Show-ByteProgressBar -Title "下载${Name}" -DoneBytes $doneBytes -TotalBytes $totalBytes
                $lastUpdate = $now
            }
        }

        Show-ByteProgressBar -Title "下载${Name}" -DoneBytes $doneBytes -TotalBytes $totalBytes -Complete
    } finally {
        if ($outputStream -ne $null) {
            $outputStream.Dispose()
        }
        if ($inputStream -ne $null) {
            $inputStream.Dispose()
        }
        if ($response -ne $null) {
            $response.Dispose()
        }
    }
}

function Get-UniqueUrls {
    param([string[]]$Urls)

    $seen = @{}
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($url in $Urls) {
        if ([string]::IsNullOrWhiteSpace($url)) {
            continue
        }
        if (-not $seen.ContainsKey($url)) {
            $seen[$url] = $true
            $result.Add($url)
        }
    }
    return $result.ToArray()
}

function Get-MetaUrls {
    param([string]$Original)

    if ([string]::IsNullOrWhiteSpace($Original)) {
        throw "缺少版本信息下载地址"
    }

    $mirror = $Original.
        Replace($PistonDataBase, $BmclBase).
        Replace($PistonMetaBase, $BmclBase).
        Replace($LauncherBase, $BmclBase).
        Replace($LaunchMetaBase, $BmclBase)

    return Get-UniqueUrls @($mirror, $Original)
}

function Get-LibraryUrls {
    param([string]$Original)

    if ([string]::IsNullOrWhiteSpace($Original)) {
        throw "缺少依赖库下载地址"
    }

    $mirrorMaven = $Original.
        Replace($PistonDataBase, "$BmclBase/maven").
        Replace($PistonMetaBase, "$BmclBase/maven").
        Replace($LibrariesBase, "$BmclBase/maven").
        Replace($FabricMavenBase, "$BmclBase/maven")

    $mirrorLibraries = $Original.
        Replace($PistonDataBase, "$BmclBase/libraries").
        Replace($PistonMetaBase, "$BmclBase/libraries").
        Replace($LibrariesBase, "$BmclBase/libraries").
        Replace($FabricMavenBase, "$BmclBase/maven")

    return Get-UniqueUrls @($mirrorMaven, $mirrorLibraries, $Original)
}

function Get-AssetUrls {
    param([string]$Hash)

    $prefix = $Hash.Substring(0, 2)
    return Get-UniqueUrls @(
        "$BmclBase/assets/$prefix/$Hash",
        "$AssetsBase/$prefix/$Hash"
    )
}

function Invoke-JsonWithFallback {
    param(
        [string[]]$Urls,
        [string]$Name,
        [int]$CacheMinutes = 360
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $uniqueUrls = Get-UniqueUrls $Urls

    foreach ($url in $uniqueUrls) {
        $cached = Read-JsonCacheEntry -Url $url -Name $Name -MaxAgeMinutes $CacheMinutes
        if ($cached.Hit) {
            return $cached.Value
        }
    }

    foreach ($url in $uniqueUrls) {
        try {
            Write-Host "读取${Name}：$url"
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 45
            Write-JsonCacheEntry -Url $url -Content $response.Content
            return ($response.Content | ConvertFrom-Json)
        } catch {
            $errors.Add("$url -> $($_.Exception.Message)")
        }
    }

    foreach ($url in $uniqueUrls) {
        $cached = Read-JsonCacheEntry -Url $url -Name $Name -MaxAgeMinutes $CacheMinutes -AllowStale $true
        if ($cached.Hit) {
            return $cached.Value
        }
    }

    throw "读取${Name}失败。`n$($errors -join "`n")"
}

function Get-MinecraftVersionEntry {
    param(
        [string[]]$ManifestUrls,
        [string]$VersionId
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($url in (Get-UniqueUrls $ManifestUrls)) {
        try {
            $manifest = Invoke-JsonWithFallback -Urls @($url) -Name "Minecraft 版本列表"
            $entry = $manifest.versions | Where-Object { $_.id -eq $VersionId } | Select-Object -First 1
            if ($entry -ne $null) {
                return [pscustomobject]@{
                    Manifest = $manifest
                    Entry = $entry
                }
            }
            $errors.Add("$url -> 版本列表中没有 $VersionId")
        } catch {
            $errors.Add("$url -> $($_.Exception.Message)")
        }
    }

    throw "找不到 Minecraft 版本：$VersionId。`n$($errors -join "`n")"
}

function Invoke-DownloadWithFallback {
    param(
        [string[]]$Urls,
        [string]$Path,
        [string]$Sha1,
        [Nullable[Int64]]$Size,
        [string]$Name,
        [int]$RetryCount = 3,
        [int]$NoProgressTimeoutSeconds = 15,
        [string]$TempPath = ""
    )

    if (Test-FileMatches -Path $Path -Sha1 $Sha1 -Size $Size) {
        Write-Host "跳过${Name}：文件已存在且校验通过"
        return
    }

    Ensure-Directory (Split-Path -Parent $Path)
    if ([string]::IsNullOrWhiteSpace($TempPath)) {
        $tempPath = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    } else {
        $tempPath = $TempPath
    }
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($url in (Get-UniqueUrls $Urls)) {
        try {
            for ($attempt = 1; $attempt -le [Math]::Max(1, $RetryCount); $attempt++) {
                try {
                    Write-Host "下载${Name}：$url（第 $attempt 次）"
                    Invoke-DownloadFileWithProgress -Url $url -Path $tempPath -Name $Name -NoProgressTimeoutSeconds $NoProgressTimeoutSeconds
                    break
                } catch {
                    if ($attempt -ge [Math]::Max(1, $RetryCount)) {
                        throw
                    }
                    Write-Host "连接中断，正在自动重连：$Name"
                    Start-Sleep -Milliseconds (300 * $attempt)
                }
            }

            if (-not (Test-FileMatches -Path $tempPath -Sha1 $Sha1 -Size $Size)) {
                throw "下载完成，但文件校验失败"
            }

            Move-Item -LiteralPath $tempPath -Destination $Path -Force
            Set-FileValidationCacheEntry -Path $Path -Sha1 $Sha1
            return
        } catch {
            $errors.Add("$url -> $($_.Exception.Message)")
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force
            }
        }
    }

    throw "下载${Name}失败。`n$($errors -join "`n")"
}

function Invoke-DownloadWorker {
    param(
        [string[]]$Urls,
        [string]$Path,
        [string]$Sha1,
        [Nullable[Int64]]$Size,
        [string]$Name,
        [int]$RetryCount = 3,
        [int]$NoProgressTimeoutSeconds = 15,
        [string]$TempPath = ""
    )

    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"
    try {
        [Net.ServicePointManager]::DefaultConnectionLimit = 256
        [Net.ServicePointManager]::Expect100Continue = $false
        [Net.ServicePointManager]::UseNagleAlgorithm = $false
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
    }

    function Ensure-WorkerDirectory {
        param([string]$WorkerPath)
        if (-not [string]::IsNullOrWhiteSpace($WorkerPath) -and -not (Test-Path -LiteralPath $WorkerPath)) {
            New-Item -ItemType Directory -Path $WorkerPath -Force | Out-Null
        }
    }

    function Get-WorkerSha1 {
        param([string]$WorkerPath)
        return (Get-FileHash -LiteralPath $WorkerPath -Algorithm SHA1).Hash.ToLowerInvariant()
    }

    function Test-WorkerFileMatches {
        param(
            [string]$WorkerPath,
            [string]$WorkerSha1,
            [Nullable[Int64]]$WorkerSize
        )

        if (-not (Test-Path -LiteralPath $WorkerPath -PathType Leaf)) {
            return $false
        }

        $file = Get-Item -LiteralPath $WorkerPath
        if ($WorkerSize -ne $null -and $WorkerSize -gt 0 -and $file.Length -ne $WorkerSize) {
            return $false
        }

        if (-not [string]::IsNullOrWhiteSpace($WorkerSha1) -and (Get-WorkerSha1 $WorkerPath) -ne $WorkerSha1.ToLowerInvariant()) {
            return $false
        }

        return $true
    }

    function Invoke-WorkerDownloadFile {
        param(
            [string]$WorkerUrl,
            [string]$WorkerPath,
            [int]$WorkerNoProgressTimeoutSeconds = 15
        )

        $response = $null
        $inputStream = $null
        $outputStream = $null

        try {
            $existingBytes = [Int64]0
            if (Test-Path -LiteralPath $WorkerPath -PathType Leaf) {
                $existingBytes = (Get-Item -LiteralPath $WorkerPath).Length
            }

            $request = [System.Net.HttpWebRequest]::Create($WorkerUrl)
            $request.Timeout = 120000
            $request.ReadWriteTimeout = [Math]::Max(5, $WorkerNoProgressTimeoutSeconds) * 1000
            if ($existingBytes -gt 0) {
                $request.AddRange($existingBytes)
            }

            $response = $request.GetResponse()
            $inputStream = $response.GetResponseStream()

            $resumeAccepted = $existingBytes -gt 0 -and $response.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent
            if ($resumeAccepted) {
                $outputStream = [System.IO.File]::Open($WorkerPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            } else {
                $outputStream = [System.IO.File]::Open($WorkerPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            }

            $buffer = New-Object byte[] 131072

            while ($true) {
                $read = $inputStream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) {
                    break
                }
                $outputStream.Write($buffer, 0, $read)
            }
        } finally {
            if ($outputStream -ne $null) {
                $outputStream.Dispose()
            }
            if ($inputStream -ne $null) {
                $inputStream.Dispose()
            }
            if ($response -ne $null) {
                $response.Dispose()
            }
        }
    }

    $result = [ordered]@{
        Name = $Name
        Path = $Path
        Status = ""
        Message = ""
    }

    if (Test-WorkerFileMatches -WorkerPath $Path -WorkerSha1 $Sha1 -WorkerSize $Size) {
        $result.Status = "跳过"
        $result.Message = "文件已存在且校验通过"
        return [pscustomobject]$result
    }

    Ensure-WorkerDirectory (Split-Path -Parent $Path)
    if ([string]::IsNullOrWhiteSpace($TempPath)) {
        $tempPath = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    } else {
        $tempPath = $TempPath
    }
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($url in $Urls) {
        try {
            for ($attempt = 1; $attempt -le [Math]::Max(1, $RetryCount); $attempt++) {
                try {
                    Invoke-WorkerDownloadFile -WorkerUrl $url -WorkerPath $tempPath -WorkerNoProgressTimeoutSeconds $NoProgressTimeoutSeconds
                    break
                } catch {
                    if ($attempt -ge [Math]::Max(1, $RetryCount)) {
                        throw
                    }
                    Start-Sleep -Milliseconds (300 * $attempt)
                }
            }

            if (-not (Test-WorkerFileMatches -WorkerPath $tempPath -WorkerSha1 $Sha1 -WorkerSize $Size)) {
                throw "下载完成，但文件校验失败"
            }

            if (Test-WorkerFileMatches -WorkerPath $Path -WorkerSha1 $Sha1 -WorkerSize $Size) {
                if (Test-Path -LiteralPath $tempPath) {
                    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                }
                $result.Status = "跳过"
                $result.Message = "已有其他源完成"
                return [pscustomobject]$result
            }

            Move-Item -LiteralPath $tempPath -Destination $Path -Force
            $result.Status = "完成"
            $result.Message = $url
            return [pscustomobject]$result
        } catch {
            $errors.Add("$url -> $($_.Exception.Message)")
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $result.Status = "失败"
    $result.Message = $errors -join "`n"
    return [pscustomobject]$result
}

function Test-RuleMatchesWindows {
    param([object]$Rule)

    $osProperty = $Rule.PSObject.Properties["os"]
    if ($osProperty -eq $null -or $osProperty.Value -eq $null) {
        return $true
    }

    $os = $osProperty.Value
    $nameProperty = $os.PSObject.Properties["name"]
    if ($nameProperty -ne $null -and -not [string]::IsNullOrWhiteSpace($nameProperty.Value)) {
        if ($nameProperty.Value -ne "windows") {
            return $false
        }
    }

    $archProperty = $os.PSObject.Properties["arch"]
    if ($archProperty -ne $null -and -not [string]::IsNullOrWhiteSpace($archProperty.Value)) {
        $is64 = [Environment]::Is64BitOperatingSystem
        if ($archProperty.Value -eq "x64" -and -not $is64) {
            return $false
        }
        if ($archProperty.Value -eq "x86" -and $is64) {
            return $false
        }
    }

    return $true
}

function Test-LibraryAllowed {
    param([object]$Library)

    $rulesProperty = $Library.PSObject.Properties["rules"]
    if ($rulesProperty -eq $null -or $rulesProperty.Value -eq $null) {
        return $true
    }

    $allowed = $false
    foreach ($rule in $rulesProperty.Value) {
        if (Test-RuleMatchesWindows $rule) {
            $allowed = ($rule.action -eq "allow")
        }
    }
    if (-not $allowed) {
        return $false
    }

    $name = [string]$Library.name
    $arch = Get-WindowsArchitectureTag
    if ($name.EndsWith(":natives-windows-arm64")) {
        return $arch -eq "arm64"
    }
    if ($name.EndsWith(":natives-windows-x86")) {
        return $arch -eq "x86"
    }
    if ($name.EndsWith(":natives-windows")) {
        return $arch -eq "x64"
    }

    return $true
}

function Get-WindowsArchitectureTag {
    $arch = [string]$env:PROCESSOR_ARCHITECTURE
    if ($arch -match "ARM64") {
        return "arm64"
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        return "x86"
    }
    return "x64"
}

function Convert-MavenNameToPath {
    param([string]$Name)

    $parts = $Name.Split(":")
    if ($parts.Count -lt 3) {
        throw "无法解析依赖坐标：$Name"
    }

    $groupPath = $parts[0].Replace(".", "/")
    $artifact = $parts[1]
    $version = $parts[2]
    $classifier = ""
    if ($parts.Count -ge 4 -and -not [string]::IsNullOrWhiteSpace($parts[3])) {
        $classifier = "-$($parts[3])"
    }

    return "$groupPath/$artifact/$version/$artifact-$version$classifier.jar"
}

function Complete-LibraryDownloadMetadata {
    param([object]$Library)

    if ($Library -eq $null -or [string]::IsNullOrWhiteSpace($Library.name)) {
        return $Library
    }

    $downloadsProperty = $Library.PSObject.Properties["downloads"]
    if ($downloadsProperty -ne $null -and $downloadsProperty.Value -ne $null) {
        $artifactProperty = $downloadsProperty.Value.PSObject.Properties["artifact"]
        if ($artifactProperty -ne $null -and $artifactProperty.Value -ne $null) {
            return $Library
        }
    }

    $baseUrl = $LibrariesBase
    $urlProperty = $Library.PSObject.Properties["url"]
    if ($urlProperty -ne $null -and -not [string]::IsNullOrWhiteSpace($urlProperty.Value)) {
        $baseUrl = ([string]$urlProperty.Value).TrimEnd("/")
    }

    $path = Convert-MavenNameToPath $Library.name
    $artifact = [ordered]@{
        path = $path
        url = "$baseUrl/$path"
    }

    foreach ($hashName in @("sha1", "sha256", "sha512", "md5")) {
        $hashProperty = $Library.PSObject.Properties[$hashName]
        if ($hashProperty -ne $null -and -not [string]::IsNullOrWhiteSpace([string]$hashProperty.Value)) {
            $artifact[$hashName] = $hashProperty.Value
        }
    }

    $sizeProperty = $Library.PSObject.Properties["size"]
    if ($sizeProperty -ne $null -and $sizeProperty.Value -ne $null) {
        $artifact["size"] = $sizeProperty.Value
    }

    $Library | Add-Member -NotePropertyName "downloads" -NotePropertyValue ([pscustomobject]@{
        artifact = [pscustomobject]$artifact
    }) -Force

    return $Library
}

function Merge-FabricArguments {
    param(
        [object]$BaseArguments,
        [object]$FabricArguments
    )

    if ($BaseArguments -eq $null) {
        $BaseArguments = [pscustomobject]@{}
    }
    if ($BaseArguments.PSObject.Properties["game"] -eq $null) {
        $BaseArguments | Add-Member -NotePropertyName "game" -NotePropertyValue @() -Force
    }
    if ($BaseArguments.PSObject.Properties["jvm"] -eq $null) {
        $BaseArguments | Add-Member -NotePropertyName "jvm" -NotePropertyValue @() -Force
    }

    if ($FabricArguments -eq $null) {
        return $BaseArguments
    }

    foreach ($section in @("game", "jvm")) {
        $fabricProperty = $FabricArguments.PSObject.Properties[$section]
        if ($fabricProperty -eq $null -or $fabricProperty.Value -eq $null) {
            continue
        }

        $merged = New-Object System.Collections.ArrayList
        $baseProperty = $BaseArguments.PSObject.Properties[$section]
        if ($baseProperty -ne $null -and $baseProperty.Value -ne $null) {
            foreach ($argument in @($baseProperty.Value)) {
                [void]$merged.Add($argument)
            }
        }
        foreach ($argument in @($fabricProperty.Value)) {
            [void]$merged.Add($argument)
        }
        $BaseArguments | Add-Member -NotePropertyName $section -NotePropertyValue $merged.ToArray() -Force
    }

    return $BaseArguments
}

function Add-DownloadItem {
    param(
        [System.Collections.ArrayList]$List,
        [string[]]$Urls,
        [string]$Path,
        [string]$Sha1,
        [Nullable[Int64]]$Size,
        [string]$Name
    )

    [void]$List.Add([pscustomobject]@{
        Urls = $Urls
        Path = $Path
        Sha1 = $Sha1
        Size = $Size
        Name = $Name
    })
}

function Add-LibraryDownloadItems {
    param(
        [System.Collections.ArrayList]$List,
        [object]$Library,
        [string]$LibrariesDir
    )

    if (-not (Test-LibraryAllowed $Library)) {
        return
    }

    $downloadsProperty = $Library.PSObject.Properties["downloads"]
    if ($downloadsProperty -ne $null -and $downloadsProperty.Value -ne $null) {
        $downloads = $downloadsProperty.Value
        $artifactProperty = $downloads.PSObject.Properties["artifact"]
        if ($artifactProperty -ne $null -and $artifactProperty.Value -ne $null) {
            $artifact = $artifactProperty.Value
            $localPath = Join-Parts @($LibrariesDir, ($artifact.path -replace "/", "\"))
            Add-DownloadItem -List $List -Urls (Get-LibraryUrls $artifact.url) -Path $localPath -Sha1 $artifact.sha1 -Size $artifact.size -Name $Library.name
        }

        $nativesProperty = $Library.PSObject.Properties["natives"]
        $classifiersProperty = $downloads.PSObject.Properties["classifiers"]
        if ($nativesProperty -ne $null -and $nativesProperty.Value -ne $null -and $classifiersProperty -ne $null) {
            $windowsNative = $nativesProperty.Value.PSObject.Properties["windows"]
            if ($windowsNative -ne $null) {
                $nativeKey = $windowsNative.Value.Replace('${arch}', "64")
                $classifier = $classifiersProperty.Value.PSObject.Properties[$nativeKey]
                if ($classifier -ne $null -and $classifier.Value -ne $null) {
                    $native = $classifier.Value
                    $nativePath = Join-Parts @($LibrariesDir, ($native.path -replace "/", "\"))
                    Add-DownloadItem -List $List -Urls (Get-LibraryUrls $native.url) -Path $nativePath -Sha1 $native.sha1 -Size $native.size -Name "$($Library.name) [$nativeKey]"
                }
            }
        }
        return
    }

    $path = Convert-MavenNameToPath $Library.name
    $baseUrl = $LibrariesBase
    $urlProperty = $Library.PSObject.Properties["url"]
    if ($urlProperty -ne $null -and -not [string]::IsNullOrWhiteSpace($urlProperty.Value)) {
        $baseUrl = $urlProperty.Value.TrimEnd("/")
    }

    $officialUrl = "$baseUrl/$path"
    $localFallbackPath = Join-Parts @($LibrariesDir, ($path -replace "/", "\"))
    Add-DownloadItem -List $List -Urls (Get-LibraryUrls $officialUrl) -Path $localFallbackPath -Sha1 $Library.sha1 -Size $Library.size -Name $Library.name
}

function Download-Items {
    param(
        [System.Collections.ArrayList]$Items,
        [string]$Title,
        [int]$ThreadCount = 16,
        [int]$RetryCount = 3,
        [int]$NoProgressTimeoutSeconds = 15,
        [int]$HedgeAfterSeconds = 5
    )

    $pendingDownloadItems = New-Object System.Collections.ArrayList
    $seenPaths = @{}
    $total = 0
    $alreadyValidCount = 0
    foreach ($item in $Items) {
        $key = ([string]$item.Path).ToLowerInvariant()
        if (-not $seenPaths.ContainsKey($key)) {
            $seenPaths[$key] = $true
            $total++
            if (Test-FileMatches -Path $item.Path -Sha1 $item.Sha1 -Size $item.Size) {
                $alreadyValidCount++
                continue
            }
            [void]$pendingDownloadItems.Add($item)
        }
    }

    if ($total -eq 0) {
        return
    }
    if ($pendingDownloadItems.Count -eq 0) {
        Write-FixedProgressLines -Title $Title -Done $total -Total $total -ThreadCount 0 -FileName "全部已存在" -FileDoneBytes 1 -FileTotalBytes 1 -Complete
        Write-Host "$Title：全部文件已存在且校验通过"
        return
    }

    $Items = $pendingDownloadItems
    $threadLimit = [Math]::Max(1, [Math]::Min($ThreadCount, $Items.Count))
    $runspaceLimit = $threadLimit
    if ($HedgeAfterSeconds -gt 0) {
        $runspaceLimit = [Math]::Min(256, [Math]::Max($threadLimit, $threadLimit * 2))
    }
    Write-Host "$Title：共 $total 个文件，需下载 $($Items.Count) 个，已跳过 $alreadyValidCount 个，使用 $threadLimit 个主线程"

    $pool = [RunspaceFactory]::CreateRunspacePool(1, $runspaceLimit)
    $pool.Open()
    $jobs = New-Object System.Collections.ArrayList
    $scriptBlock = ${function:Invoke-DownloadWorker}

    try {
        function Start-QueuedDownload {
            param(
                [object]$Item,
                [string[]]$Urls,
                [string]$DisplayName,
                [int]$ProgressId,
                [bool]$Primary
            )

            $tempKind = "hedge"
            if ($Primary) {
                $tempKind = "primary"
            }
            $tempPath = "$($Item.Path).tmp-$tempKind-$([Guid]::NewGuid().ToString('N'))"

            $powershell = [PowerShell]::Create()
            $powershell.RunspacePool = $pool
            [void]$powershell.AddScript($scriptBlock)
            [void]$powershell.AddArgument([string[]]$Urls)
            [void]$powershell.AddArgument($Item.Path)
            [void]$powershell.AddArgument($Item.Sha1)
            [void]$powershell.AddArgument($Item.Size)
            [void]$powershell.AddArgument($DisplayName)
            [void]$powershell.AddArgument($RetryCount)
            [void]$powershell.AddArgument($NoProgressTimeoutSeconds)
            [void]$powershell.AddArgument($tempPath)

            [void]$jobs.Add([pscustomobject]@{
                PowerShell = $powershell
                Handle = $powershell.BeginInvoke()
                Name = $DisplayName
                Path = $Item.Path
                Sha1 = $Item.Sha1
                Size = $Item.Size
                ProgressId = $ProgressId
                Primary = $Primary
                Key = ([string]$Item.Path).ToLowerInvariant()
                TempPath = $tempPath
            })
        }

        $pendingItems = New-Object System.Collections.ArrayList
        $nextPendingItemIndex = 0
        $pendingHedgeJobs = New-Object System.Collections.ArrayList
        $nextProgressId = 100
        foreach ($item in $Items) {
            $urls = Get-UniqueUrls $item.Urls
            if ($urls.Count -eq 0) {
                continue
            }

            $hedgeUrls = @()
            if ($urls.Count -gt 1) {
                $hedgeUrls = @($urls[1..($urls.Count - 1)])
            }

            [void]$pendingItems.Add([pscustomobject]@{
                Item = $item
                PrimaryUrls = @($urls[0])
                HedgeUrls = $hedgeUrls
                ProgressId = $nextProgressId
            })
            $nextProgressId++
        }

        $done = $alreadyValidCount
        $failureMessages = @{}
        $completedKeys = @{}
        $validatedKeys = @{}
        $lastProgressUpdate = [datetime]::MinValue
        Write-FixedProgressLines -Title $Title -Done 0 -Total $total -ThreadCount $threadLimit -Initialize

        while ($jobs.Count -gt 0 -or $nextPendingItemIndex -lt $pendingItems.Count -or $pendingHedgeJobs.Count -gt 0) {
            while ($nextPendingItemIndex -lt $pendingItems.Count -and $jobs.Count -lt $threadLimit) {
                $queued = $pendingItems[$nextPendingItemIndex]
                $nextPendingItemIndex++
                $item = $queued.Item
                $key = ([string]$item.Path).ToLowerInvariant()
                if (Test-FileMatches -Path $item.Path -Sha1 $item.Sha1 -Size $item.Size) {
                    if (-not $completedKeys.ContainsKey($key)) {
                        $completedKeys[$key] = $true
                        $validatedKeys[$key] = $true
                        $done++
                    }
                    continue
                }

                Start-QueuedDownload -Item $item -Urls $queued.PrimaryUrls -DisplayName $item.Name -ProgressId $queued.ProgressId -Primary $true
                if ($queued.HedgeUrls.Count -gt 0 -and $HedgeAfterSeconds -gt 0) {
                    [void]$pendingHedgeJobs.Add([pscustomobject]@{
                        Item = $item
                        Urls = $queued.HedgeUrls
                        StartAt = (Get-Date).AddSeconds($HedgeAfterSeconds)
                        ProgressId = $queued.ProgressId
                    })
                }
            }

            $now = Get-Date
            for ($h = $pendingHedgeJobs.Count - 1; $h -ge 0; $h--) {
                $hedge = $pendingHedgeJobs[$h]
                if ($now -lt $hedge.StartAt) {
                    continue
                }

                $item = $hedge.Item
                $key = ([string]$item.Path).ToLowerInvariant()
                if ($completedKeys.ContainsKey($key)) {
                    $pendingHedgeJobs.RemoveAt($h)
                    continue
                }

                if (Test-FileMatches -Path $item.Path -Sha1 $item.Sha1 -Size $item.Size) {
                    if (-not $completedKeys.ContainsKey($key)) {
                        $completedKeys[$key] = $true
                        $validatedKeys[$key] = $true
                        $done++
                    }
                    $pendingHedgeJobs.RemoveAt($h)
                    continue
                }

                if ($jobs.Count -lt $runspaceLimit) {
                    Start-QueuedDownload -Item $item -Urls $hedge.Urls -DisplayName "$($item.Name)（备用源）" -ProgressId $hedge.ProgressId -Primary $false
                    $pendingHedgeJobs.RemoveAt($h)
                }
            }

            for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
                $job = $jobs[$i]
                if (-not $job.Handle.IsCompleted) {
                    continue
                }

                $outputs = $job.PowerShell.EndInvoke($job.Handle)
                $jobSucceeded = $false
                foreach ($output in $outputs) {
                    if ($output.Status -eq "失败") {
                        if (-not (Test-FileMatches -Path $job.Path -Sha1 $job.Sha1 -Size $job.Size)) {
                            if (-not $failureMessages.ContainsKey($job.Key)) {
                                $failureMessages[$job.Key] = New-Object System.Collections.Generic.List[string]
                            }
                            $failureMessages[$job.Key].Add("$($output.Name)：$($output.Message)")
                            Write-Host "失败：$($output.Name)"
                        }
                    } elseif ($output.Status -eq "完成" -or $output.Status -eq "跳过") {
                        $jobSucceeded = $true
                    }
                }

                $job.PowerShell.Dispose()
                $jobs.RemoveAt($i)
                if ($jobSucceeded -and -not $completedKeys.ContainsKey($job.Key)) {
                    $completedKeys[$job.Key] = $true
                    $validatedKeys[$job.Key] = $true
                    Set-FileValidationCacheEntry -Path $job.Path -Sha1 $job.Sha1
                    $done++
                    if ($done -gt $total) {
                        $done = $total
                    }

                    for ($h = $pendingHedgeJobs.Count - 1; $h -ge 0; $h--) {
                        if ((([string]$pendingHedgeJobs[$h].Item.Path).ToLowerInvariant()) -eq $job.Key) {
                            $pendingHedgeJobs.RemoveAt($h)
                        }
                    }
                } elseif ((Test-FileMatches -Path $job.Path -Sha1 $job.Sha1 -Size $job.Size) -and -not $completedKeys.ContainsKey($job.Key)) {
                    $completedKeys[$job.Key] = $true
                    $validatedKeys[$job.Key] = $true
                    Set-FileValidationCacheEntry -Path $job.Path -Sha1 $job.Sha1
                    $done++
                    if ($done -gt $total) {
                        $done = $total
                    }

                    for ($h = $pendingHedgeJobs.Count - 1; $h -ge 0; $h--) {
                        if ((([string]$pendingHedgeJobs[$h].Item.Path).ToLowerInvariant()) -eq $job.Key) {
                            $pendingHedgeJobs.RemoveAt($h)
                        }
                    }
                }
            }

            $progressNow = Get-Date
            if (($progressNow - $lastProgressUpdate).TotalMilliseconds -ge 250) {
                $currentName = ""
                $currentDoneBytes = [Int64]0
                $currentTotalBytes = [Int64]0
                foreach ($job in $jobs) {
                    $tempPath = $job.TempPath
                    if (-not (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
                        continue
                    }

                    $tempLength = $null
                    try {
                        $tempLength = (Get-Item -LiteralPath $tempPath -ErrorAction Stop).Length
                    } catch {
                        continue
                    }

                    $currentName = $job.Name
                    $currentDoneBytes = [Int64]$tempLength
                    if ($job.Size -ne $null) {
                        $currentTotalBytes = [Int64]$job.Size
                    }
                    break
                }

                Write-FixedProgressLines -Title $Title -Done $done -Total $total -ThreadCount $threadLimit -FileName $currentName -FileDoneBytes $currentDoneBytes -FileTotalBytes $currentTotalBytes
                $lastProgressUpdate = $progressNow
            }
            Start-Sleep -Milliseconds 100
        }

        $failed = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Items) {
            $key = ([string]$item.Path).ToLowerInvariant()
            if ($completedKeys.ContainsKey($key) -and $validatedKeys.ContainsKey($key)) {
                continue
            }
            if (Test-FileMatches -Path $item.Path -Sha1 $item.Sha1 -Size $item.Size) {
                continue
            }
            if ($failureMessages.ContainsKey($key)) {
                $failed.Add(($failureMessages[$key] -join "`n"))
            } else {
                $failed.Add("$($item.Name)：文件未下载完成")
            }
        }
        if ($failed.Count -gt 0) {
            Write-FixedProgressLines -Title $Title -Done $done -Total $total -ThreadCount $threadLimit -FileName "下载失败" -FileDoneBytes 0 -FileTotalBytes 1 -Complete
            throw "$Title 有 $($failed.Count) 个文件下载失败。`n$($failed -join "`n")"
        }
        Write-FixedProgressLines -Title $Title -Done $total -Total $total -ThreadCount $threadLimit -FileName "全部完成" -FileDoneBytes 1 -FileTotalBytes 1 -Complete
        Write-Host "$Title：全部完成"
    } finally {
        foreach ($job in $jobs) {
            try {
                $job.PowerShell.Stop()
                $job.PowerShell.Dispose()
            } catch {
            }
        }
        $pool.Close()
        $pool.Dispose()
    }
}

function Get-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
}

function Update-LauncherProfile {
    param(
        [string]$LauncherProfilesPath,
        [string]$Name,
        [string]$VersionId,
        [string]$GameDir
    )

    Ensure-Directory (Split-Path -Parent $LauncherProfilesPath)
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $defaultMinecraftDir = Join-Path $env:APPDATA ".minecraft"
    $targetGameDir = $null
    if ((Get-FullPath $GameDir) -ne (Get-FullPath $defaultMinecraftDir)) {
        $targetGameDir = $GameDir
    }

    function New-LauncherProfileObject {
        param(
            [string]$ProfileName,
            [string]$ProfileVersionId,
            [string]$ProfileGameDir,
            [string]$Timestamp
        )

        $profile = [ordered]@{
            name = $ProfileName
            type = "custom"
            created = $Timestamp
            lastUsed = $Timestamp
            lastVersionId = $ProfileVersionId
        }
        if (-not [string]::IsNullOrWhiteSpace($ProfileGameDir)) {
            $profile["gameDir"] = $ProfileGameDir
        }
        return [pscustomobject]$profile
    }

    if (Test-Path -LiteralPath $LauncherProfilesPath) {
        $root = Read-Utf8JsonFile $LauncherProfilesPath
    } else {
        $root = [pscustomobject]@{
            profiles = [pscustomobject]@{}
            selectedProfile = $Name
        }
    }

    if ($root.PSObject.Properties["profiles"] -eq $null -or $root.profiles -eq $null) {
        $root | Add-Member -NotePropertyName "profiles" -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $desiredProfile = New-LauncherProfileObject -ProfileName $Name -ProfileVersionId $VersionId -ProfileGameDir $targetGameDir -Timestamp $now
    $existingProfile = $null
    if ($root.profiles.PSObject.Properties[$Name] -ne $null) {
        $existingProfile = $root.profiles.$Name
    }

    $alreadyMatches = $false
    if ($existingProfile -ne $null -and $root.selectedProfile -eq $Name) {
        $alreadyMatches = $existingProfile.name -eq $desiredProfile.name -and
            $existingProfile.type -eq $desiredProfile.type -and
            $existingProfile.lastVersionId -eq $desiredProfile.lastVersionId -and
            $existingProfile.gameDir -eq $desiredProfile.gameDir
    }

    if ($alreadyMatches) {
        Write-Host "启动器配置已是最新，跳过重复更新：$LauncherProfilesPath"
        return
    }

    if (Test-Path -LiteralPath $LauncherProfilesPath) {
        $backup = "$LauncherProfilesPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item -LiteralPath $LauncherProfilesPath -Destination $backup -Force
    }

    $root.profiles | Add-Member -NotePropertyName $Name -NotePropertyValue $desiredProfile -Force
    $root | Add-Member -NotePropertyName "selectedProfile" -NotePropertyValue $Name -Force

    Save-Utf8Json -Path $LauncherProfilesPath -Object $root
}

try {
    if (-not $MinecraftDirWasProvided) {
        $MinecraftDir = Get-InteractiveMinecraftDir -DefaultMinecraftDir $MinecraftDir
        Write-Host ""
    } else {
        $MinecraftDir = Convert-ToFullPath $MinecraftDir
    }

    if (-not $MaxThreadsWasProvided) {
        $MaxThreads = Read-ThreadCount -DefaultThreads 16
        Write-Host ""
    }

    Write-Host "由 bsk 和 Ezplus 制作"
    Write-Host "南侧下载器已启动"
    Write-Host "Minecraft 版本：$MinecraftVersion"
    Write-Host "安装后的游戏名称：$InstallVersionName"
    if ($FabricLoaderVersion -eq "latest") {
        Write-Host "Fabric 加载器：最新版"
    } else {
        Write-Host "Fabric 加载器：$FabricLoaderVersion"
    }
    Write-Host "安装目录：$MinecraftDir"
    Write-Host "下载线程：$MaxThreads"
    Write-Host "失败重试：$RetryCount 次"
    Write-Host "无进度重连：$NoProgressTimeoutSeconds 秒"
    Write-Host "竞速下载延迟：$HedgeAfterSeconds 秒"
    Write-Host "下载源策略：优先使用国内源，难下载时自动与官方源竞速"
    Write-Host ""

    Set-DownloadNetworkTuning -ThreadCount $MaxThreads

    Ensure-Directory $MinecraftDir
    Initialize-FileValidationCache -MinecraftDir $MinecraftDir
    Initialize-JsonCache -MinecraftDir $MinecraftDir

    $versionsDir = Join-Parts @($MinecraftDir, "versions")
    $librariesDir = Join-Parts @($MinecraftDir, "libraries")
    $assetsDir = Join-Parts @($MinecraftDir, "assets")
    Ensure-Directory $versionsDir
    Ensure-Directory $librariesDir
    Ensure-Directory $assetsDir

    $versionLookup = Invoke-WithUserRetry -Name "获取 Minecraft 版本信息" -Action {
        Get-MinecraftVersionEntry -ManifestUrls @(
            "$BmclBase/mc/game/version_manifest_v2.json",
            "$PistonMetaBase/mc/game/version_manifest_v2.json"
        ) -VersionId $MinecraftVersion
    }

    $versionEntry = $versionLookup.Entry

    $installVersionDir = Join-Parts @($versionsDir, $InstallVersionName)
    $gameDir = $installVersionDir
    $vanillaJsonPath = Join-Parts @($installVersionDir, "$InstallVersionName.vanilla.json")
    $installJarPath = Join-Parts @($installVersionDir, "$InstallVersionName.jar")

    Invoke-WithUserRetry -Name "下载 Minecraft $MinecraftVersion 版本配置" -Action {
        Invoke-DownloadWithFallback -Urls (Get-MetaUrls $versionEntry.url) -Path $vanillaJsonPath -Sha1 $versionEntry.sha1 -Size $versionEntry.size -Name "Minecraft $MinecraftVersion 版本配置" -RetryCount $RetryCount -NoProgressTimeoutSeconds $NoProgressTimeoutSeconds
    }
    $versionJson = Read-Utf8JsonFile $vanillaJsonPath

    $client = $versionJson.downloads.client
    Invoke-WithUserRetry -Name "下载 Minecraft 客户端文件" -Action {
        Invoke-DownloadWithFallback -Urls (Get-MetaUrls $client.url) -Path $installJarPath -Sha1 $client.sha1 -Size $client.size -Name "Minecraft 客户端文件" -RetryCount $RetryCount -NoProgressTimeoutSeconds $NoProgressTimeoutSeconds
    }

    $libraryItems = New-Object System.Collections.ArrayList
    foreach ($library in $versionJson.libraries) {
        Add-LibraryDownloadItems -List $libraryItems -Library $library -LibrariesDir $librariesDir
    }
    Invoke-WithUserRetry -Name "下载 Minecraft 依赖库" -Action {
        Download-Items -Items $libraryItems -Title "下载 Minecraft 依赖库" -ThreadCount $MaxThreads -RetryCount $RetryCount -NoProgressTimeoutSeconds $NoProgressTimeoutSeconds -HedgeAfterSeconds $HedgeAfterSeconds
    }

    if (-not $SkipAssets) {
        $assetIndex = $versionJson.assetIndex
        $assetIndexPath = Join-Parts @($assetsDir, "indexes", "$($assetIndex.id).json")
        Invoke-WithUserRetry -Name "下载 Minecraft 资源索引" -Action {
            Invoke-DownloadWithFallback -Urls (Get-MetaUrls $assetIndex.url) -Path $assetIndexPath -Sha1 $assetIndex.sha1 -Size $assetIndex.size -Name "Minecraft 资源索引" -RetryCount $RetryCount -NoProgressTimeoutSeconds $NoProgressTimeoutSeconds
        }

        $assetIndexJson = Read-Utf8JsonFile $assetIndexPath
        $assetItems = New-Object System.Collections.ArrayList
        $assetTotalCount = 0
        $assetAlreadyValidCount = 0
        foreach ($property in $assetIndexJson.objects.PSObject.Properties) {
            $asset = $property.Value
            $hash = $asset.hash
            $assetPath = Join-Parts @($assetsDir, "objects", $hash.Substring(0, 2), $hash)
            $assetTotalCount++
            if (Test-FileMatches -Path $assetPath -Sha1 $hash -Size $asset.size) {
                $assetAlreadyValidCount++
                continue
            }
            Add-DownloadItem -List $assetItems -Urls (Get-AssetUrls $hash) -Path $assetPath -Sha1 $hash -Size $asset.size -Name $property.Name
        }
        if ($assetItems.Count -eq 0) {
            Write-FixedProgressLines -Title "下载 Minecraft 资源文件" -Done $assetTotalCount -Total $assetTotalCount -ThreadCount 0 -FileName "全部已存在" -FileDoneBytes 1 -FileTotalBytes 1 -Complete
            Write-Host "下载 Minecraft 资源文件：全部文件已存在且校验通过"
        } else {
            Write-Host "下载 Minecraft 资源文件：共 $assetTotalCount 个文件，构建下载队列 $($assetItems.Count) 个，已提前跳过 $assetAlreadyValidCount 个"
            Invoke-WithUserRetry -Name "下载 Minecraft 资源文件" -Action {
                Download-Items -Items $assetItems -Title "下载 Minecraft 资源文件" -ThreadCount $MaxThreads -RetryCount $RetryCount -NoProgressTimeoutSeconds $NoProgressTimeoutSeconds -HedgeAfterSeconds $HedgeAfterSeconds
            }
        }
    } else {
        Write-Host "已按参数跳过资源文件下载"
    }

    $encodedMinecraftVersion = [Uri]::EscapeDataString($MinecraftVersion)
    $loaderList = Invoke-WithUserRetry -Name "读取 Fabric 加载器列表" -Action {
        Invoke-JsonWithFallback -Urls @(
            "$BmclBase/fabric-meta/v2/versions/loader/$encodedMinecraftVersion",
            "$FabricMetaBase/v2/versions/loader/$encodedMinecraftVersion"
        ) -Name "Fabric 加载器列表"
    }

    if ($FabricLoaderVersion -eq "latest") {
        $loaderEntry = $loaderList | Where-Object { $_.loader.stable -eq $true } | Select-Object -First 1
        if ($loaderEntry -eq $null) {
            $loaderEntry = $loaderList | Select-Object -First 1
        }
    } else {
        $loaderEntry = $loaderList | Where-Object { $_.loader.version -eq $FabricLoaderVersion } | Select-Object -First 1
    }

    if ($loaderEntry -eq $null) {
        throw "找不到适用于 Minecraft ${MinecraftVersion} 的 Fabric 加载器：$FabricLoaderVersion"
    }

    $resolvedLoaderVersion = $loaderEntry.loader.version
    $encodedLoaderVersion = [Uri]::EscapeDataString($resolvedLoaderVersion)
    $fabricProfile = Invoke-WithUserRetry -Name "读取 Fabric 版本配置" -Action {
        Invoke-JsonWithFallback -Urls @(
            "$BmclBase/fabric-meta/v2/versions/loader/$encodedMinecraftVersion/$encodedLoaderVersion/profile/json",
            "$FabricMetaBase/v2/versions/loader/$encodedMinecraftVersion/$encodedLoaderVersion/profile/json"
        ) -Name "Fabric 版本配置"
    }

    $fabricVersionId = $InstallVersionName
    $fabricJsonPath = Join-Parts @($installVersionDir, "$InstallVersionName.json")

    $finalVersionJson = $versionJson
    $finalVersionJson | Add-Member -NotePropertyName "id" -NotePropertyValue $InstallVersionName -Force
    $finalVersionJson | Add-Member -NotePropertyName "type" -NotePropertyValue "release" -Force

    if ($finalVersionJson.PSObject.Properties["inheritsFrom"] -ne $null) {
        $finalVersionJson.PSObject.Properties.Remove("inheritsFrom")
    }
    if ($finalVersionJson.PSObject.Properties["jar"] -ne $null) {
        $finalVersionJson.PSObject.Properties.Remove("jar")
    }

    if ($fabricProfile.PSObject.Properties["mainClass"] -ne $null) {
        $finalVersionJson | Add-Member -NotePropertyName "mainClass" -NotePropertyValue $fabricProfile.mainClass -Force
    }
    if ($fabricProfile.PSObject.Properties["arguments"] -ne $null) {
        $mergedArguments = Merge-FabricArguments -BaseArguments $finalVersionJson.arguments -FabricArguments $fabricProfile.arguments
        $finalVersionJson | Add-Member -NotePropertyName "arguments" -NotePropertyValue $mergedArguments -Force
    }
    if ($fabricProfile.PSObject.Properties["minecraftArguments"] -ne $null) {
        $finalVersionJson | Add-Member -NotePropertyName "minecraftArguments" -NotePropertyValue $fabricProfile.minecraftArguments -Force
    }

    $mergedLibraries = New-Object System.Collections.ArrayList
    foreach ($library in $versionJson.libraries) {
        [void]$mergedLibraries.Add($library)
    }
    foreach ($library in $fabricProfile.libraries) {
        [void]$mergedLibraries.Add((Complete-LibraryDownloadMetadata $library))
    }
    $finalVersionJson | Add-Member -NotePropertyName "libraries" -NotePropertyValue $mergedLibraries.ToArray() -Force

    Save-Utf8Json -Path $fabricJsonPath -Object $finalVersionJson

    $fabricLibraryItems = New-Object System.Collections.ArrayList
    foreach ($library in $fabricProfile.libraries) {
        Add-LibraryDownloadItems -List $fabricLibraryItems -Library $library -LibrariesDir $librariesDir
    }
    Invoke-WithUserRetry -Name "下载 Fabric 依赖库" -Action {
        Download-Items -Items $fabricLibraryItems -Title "下载 Fabric 依赖库" -ThreadCount $MaxThreads -RetryCount $RetryCount -NoProgressTimeoutSeconds $NoProgressTimeoutSeconds -HedgeAfterSeconds $HedgeAfterSeconds
    }

    if (-not $NoLauncherProfile) {
        $launcherProfilesPath = Join-Parts @($MinecraftDir, "launcher_profiles.json")
        Update-LauncherProfile -LauncherProfilesPath $launcherProfilesPath -Name $ProfileName -VersionId $fabricVersionId -GameDir $gameDir
        Write-Host "启动器配置已更新：$ProfileName -> $fabricVersionId"
    }

    Install-BundledMods -GameDir $gameDir
    Install-BundledLauncher -MinecraftDir $MinecraftDir

    Write-Host ""
    Write-Host "完成：$InstallVersionName 已下载到 $MinecraftDir"
    Save-FileValidationCache
    Write-Host "启动器中请选择游戏：$ProfileName"
    if (-not $MinecraftDirWasProvided) {
        Show-InstallTutorial -InstallVersionName $InstallVersionName -ProfileName $ProfileName -MinecraftDir $MinecraftDir -GameDir $gameDir
        Wait-TutorialReadConfirmation
    }
    exit 0
} catch {
    Save-FileValidationCache
    Write-Host ""
    Write-Host "失败：$($_.Exception.Message)"
    if (-not $MinecraftDirWasProvided) {
        Write-Host ""
        Read-Host "按回车键退出"
    }
    exit 1
}
