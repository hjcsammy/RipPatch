<#
.SYNOPSIS
    一站式工具：把 RipPatch 从「刚下载的压缩包」推到「能跑」。

.DESCRIPTION
    一个脚本覆盖从零到可用的全部步骤，每一步都自己判断要不要做，
    所以可以反复执行（幂等）：

      环境检查    .NET 10 SDK / WebView2 / 磁盘空间
      拉取依赖    AssetRipper 2.0.0、ShaderRipper v1.2.5 两个子模块
      构建        dotnet restore + build
      发布        dotnet publish（自包含，可挪到别的机器）
      运行        桌面界面 / 命令行导出

    不依赖 git：压缩包下载（没有 .git）的情况下直接用 GitHub 的源码压缩包
    按固定版本铺到子模块目录。

.PARAMETER Command
    setup    检查环境 + 拉子模块 + 构建（默认）
    build    只构建
    restore  只拉子模块 / 还原 NuGet
    publish  发布到 publish\ 目录
    run      构建后启动桌面界面（或命令行导出，取决于是否给了 Input/Output）
    doctor   只做检查，报告缺什么、怎么补，不修改任何东西
    clean    删除 bin/obj/publish 构建产物

.PARAMETER Input
    游戏路径。给了 Input + Output 就走命令行导出，不开界面。

.PARAMETER Output
    导出目录。命令行导出时会先清空，脚本不会替你创建父目录以外的任何删除动作。

.PARAMETER Only
    只导出指定类型（逗号分隔，支持 * 通配），对应 --only。

.EXAMPLE
    .\tools\arp.ps1
    零参数：检查环境、拉依赖、构建，然后启动桌面界面。

.EXAMPLE
    .\tools\arp.ps1 run "D:\Games\MyGame" "D:\Exports\MyGame"
    命令行导出，应用全部补丁。

.EXAMPLE
    .\tools\arp.ps1 publish
    产出可分发目录 publish\RipPatch-win-x64\。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'build', 'restore', 'publish', 'package', 'run', 'doctor', 'clean', 'help')]
    [string]$Command = 'setup',

    [Parameter(Position = 1)]
    [string]$Input,

    [Parameter(Position = 2)]
    [string]$Output,

    [string]$Only,

    # 子模块 pin 的版本，和 README 保持一致；改这里之前先改 README。
    #
    # <para><b>ShaderRipper 必须是 v1.2.5+。</b>补丁的 shader 代码调用
    # `ShaderDecompiler.Translate(model, includeDxbc)` 并用 `ShaderResult.DxbcPrograms`，
    # 这两个都是 v1.2.5 才有的；v1.2.4 上会报 CS1061/CS1501。
    # 注意 ShaderRipper 的 csproj 在 v1.2.5 里仍写 &lt;Version&gt;1.2.4&lt;/Version&gt;，
    # 所以只能按 tag 判断，别去看程序集版本。</para>
    [string]$AssetRipperRef = '2.0.0',
    [string]$ShaderRipperRef = 'v1.2.5',

    [string]$Configuration = 'Release',
    [string]$Runtime = 'win-x64',

    # 发布产物目录（相对仓库根）。
    [string]$PublishDir = 'publish',

    # 跳过的环节，逗号分隔：submodules,sdk,webview2
    [string[]]$Skip,
    [switch]$Force,
    [switch]$NoRestore,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 常量与基础工具

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:PatcherProject = Join-Path $script:RepoRoot 'RipPatch\RipPatch.csproj'
$script:Slnx = Join-Path $script:RepoRoot 'RipPatch.slnx'

$script:StepCount = 0
$script:StepName = ''
$script:Dotnet = $null

function Test-IsWindows {
    # $PSVersionTable.Platform 只在 PowerShell 6+ 才有；5.1 里访问会触发 StrictMode 异常。
    if ($PSVersionTable.ContainsKey('Platform')) {
        return ($PSVersionTable.Platform -eq 'Win32NT')
    }
    return $true   # 5.1 只有 Windows 版
}

# 子模块：目录名 → { 仓库地址; 版本; 探测文件 }
$script:Submodules = [ordered]@{
    'AssetRipper'  = @{
        Url = 'https://github.com/AssetRipper/AssetRipper'
        Ref = $AssetRipperRef
        # Probe：用来判断目录是不是已经铺好了，不需要每次下载。
        Probe = 'Source\AssetRipper.GUI.Web\AssetRipper.GUI.Web.csproj'
    }
    'ShaderRipper' = @{
        Url = 'https://github.com/StArraySharp/ShaderRipper'
        Ref = $ShaderRipperRef
        Probe = 'src\ShaderRipper\ShaderRipper.csproj'
        # 版本哨兵：文件里有它才说明目录是这个版本。
        # ShaderRipper 各 tag 的 <Version> 都写着 1.2.4（连 v1.2.5 也是），
        # 靠 csproj 的版本号分辨不出新旧，只能认 v1.2.5 才引入的符号。
        Sentinel = 'includeDxbc'
    }
}

# 铺好子模块后写一个版本戳。目录里另有 .git（真正的 git 克隆）时不写不读，
# 免得往别人的仓库里塞文件。
$script:StampName = '.arp-source-stamp.json'

function Write-Banner([string]$Text) {
    if ($Quiet) { return }
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Write-Step([string]$Text) {
    $script:StepCount++
    $script:StepName = $Text
    if ($Quiet) { return }
    Write-Host ''
    Write-Host ("[{0}] {1}" -f $script:StepCount, $Text) -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    if ($Quiet) { return }
    Write-Host "   OK   $Text" -ForegroundColor Green
}

function Write-Info([string]$Text) {
    if ($Quiet) { return }
    Write-Host "        $Text" -ForegroundColor Gray
}

function Write-Warn([string]$Text) {
    Write-Host "   WARN $Text" -ForegroundColor Yellow
}

function Write-Fail([string]$Text) {
    Write-Host "   FAIL $Text" -ForegroundColor Red
}

function Test-Skipped([string]$Name) {
    if (-not $Skip) { return $false }
    return $Skip -contains $Name
}

# ---------------------------------------------------------------- 环境探测

# 所有可能装 dotnet 的位置，按「优先级」排列：用户态安装在前。
# <para>顺序很重要：PATH 上的 dotnet 可能是机器级的旧版（8.0），而新装的 10.0
# 在用户目录。.NET 主机只会用「与自身同目录」的 SDK，所以拿错 exe 会直接报
# MSB4068「无法识别元素 \<Solution\>」（.slnx 需要 9.0+）。</para>
function Get-DotnetCandidates {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
            (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe')
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $list.Add($candidate) }
    }
    $onPath = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($onPath) { $list.Add($onPath.Source) }
    $machine = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $machine) { $list.Add($machine) }

    return ($list | Select-Object -Unique)
}

function Get-DotnetCommand {
    <#
        挑一个带 .NET 10 SDK 的 dotnet.exe；都没有就返回 PATH 上那个（或 null），
        让调用方去走安装流程 / 报错。
    #>
    $fallback = $null
    foreach ($candidate in Get-DotnetCandidates) {
        if (-not $fallback) { $fallback = $candidate }
        $info = Get-DotnetInfo $candidate
        if ($info.HasNet10Sdk) { return $candidate }
    }
    return $fallback
}

function Get-DotnetInfo([string]$DotnetPath) {
    $result = [ordered]@{
        Path          = $DotnetPath
        Sdks          = @()
        HasNet10Sdk   = $false
        Net10SdkVer   = $null
        Runtimes      = @()
        HasNet10Ts    = $false
        RuntimeInstalled = $false
    }
    if (-not $DotnetPath) { return [pscustomobject]$result }

    try {
        $result.Sdks = @(& $DotnetPath --list-sdks 2>$null | ForEach-Object { ($_ -split '\s+')[0] })
        $ten = $result.Sdks | Where-Object { $_ -match '^10\.' } | Sort-Object -Descending | Select-Object -First 1
        if ($ten) { $result.HasNet10Sdk = $true; $result.Net10SdkVer = $ten }
    } catch { }
    try {
        $result.Runtimes = @(& $DotnetPath --list-runtimes 2>$null | ForEach-Object { ($_ -split '\s+')[1] })
        $result.HasNet10Ts = [bool]($result.Runtimes | Where-Object { $_ -match '^10\.' })
    } catch { }
    try {
        $idx = Join-Path $env:USERPROFILE '.dotnet\sdk'
        $machine = Join-Path $env:ProgramFiles 'dotnet\sdk'
        $dirs = @($idx, $machine) | Where-Object { Test-Path -LiteralPath $_ } |
            ForEach-Object { Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue }
        $tenDir = $dirs | Where-Object { $_.Name -match '^10\.' } | Sort-Object Name -Descending | Select-Object -First 1
        if ($tenDir) {
            $result.HasNet10Sdk = $true
            # 刚装完、还没重启终端时 `dotnet --list-sdks` 可能读不到（PATH 还是旧的），
            # 用目录名兜底，别让版本号显示成空白。
            if (-not $result.Net10SdkVer) { $result.Net10SdkVer = $tenDir.Name }
        }
    } catch { }
    return [pscustomobject]$result
}

function Get-WebView2Version {
    # 三条路径都查：机器级、当前用户级、非管理员安装的 Enterprise 位置。
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach ($key in $keys) {
        try {
            $value = (Get-ItemProperty -Path $key -ErrorAction Stop).pv
            if ($value -and $value -ne '0.0.0.0') { return $value }
        } catch { }
    }
    return $null
}

function Get-DiskFreeGb([string]$Path) {
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($full)
        $drive = New-Object System.IO.DriveInfo($root)
        return [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    } catch { return $null }
}

# ---------------------------------------------------------------- dotnet 调用

function Invoke-Dotnet {
    <#
        跑 dotnet 并把输出原样透传，只返回退出码。

        <para><b>必须用 Out-Host。</b>直接把原生命令的输出留在函数里会进「成功输出流」，
        和下面的 `return $code` 混起来，调用方收到的是 Object[] 而不是 int，
        于是 `Assert-DotnetOk $code` 报「无法把 Object[] 转成 Int32」。
        Out-Host 让 dotnet 的输出直接进控制台，函数里只剩退出码一个返回值。</para>
    #>
    param(
        [Parameter(Mandatory)] [string[]]$Arguments,
        [string]$WorkingDirectory = $script:RepoRoot,
        [string]$Description
    )

    if ($Description -and -not $Quiet) { Write-Info $Description }
    if (-not $script:Dotnet) {
        throw '找不到 dotnet。先运行 `arp.ps1 setup` 安装 .NET 10 SDK。'
    }

    Push-Location $WorkingDirectory
    try {
        # 关掉遥测和首次运行提示：前者拖慢启动，后者在 CI 里会阻塞等输入。
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
        $env:DOTNET_NOLOGO = '1'
        $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
        & $script:Dotnet @Arguments 2>&1 | Out-Host
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return [int]$code
}

function Assert-DotnetOk([int]$Code, [string]$What) {
    if ($Code -ne 0) {
        throw "$What 失败（dotnet 退出码 $Code）。把上面的输出发出来，或者用 -Verbose 重跑定位。"
    }
}

# ---------------------------------------------------------------- 子模块

function Test-SubmoduleReady([string]$Name) {
    <#
        目录是否「已经是要的那个版本」。只有 Probe 存在还不够：
        版本 pin 变了以后，旧目录一样存在，但编译会因为 API 不匹配而失败
        （ShaderRipper v1.2.4 vs v1.2.5 就是这样）。所以再加两道检查：
        版本戳里记的 Ref、以及 Sentinel 符号是否真的在新源码里。
    #>
    $meta = $script:Submodules[$Name]
    $dir = Join-Path $script:RepoRoot $Name
    if (-not (Test-Path -LiteralPath (Join-Path $dir $meta.Probe))) { return $false }

    $hasGit = Test-Path -LiteralPath (Join-Path $dir '.git')
    $stampPath = Join-Path $dir $script:StampName

    if ($hasGit) {
        # 真正的 git 子模块：交给 git 管版本，脚本不置喙。
        return $true
    }

    if (Test-Path -LiteralPath $stampPath) {
        try {
            $stamp = Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json
            if ($stamp.ref -ne $meta.Ref) {
                Write-Info "$Name 版本不符（目录里是 $($stamp.ref)，需要 $($meta.Ref)）"
                return $false
            }
        } catch {
            return $false
        }
    }

    if ($meta.ContainsKey('Sentinel')) {
        $probeFile = Join-Path $dir $meta.Probe
        $content = Get-Content -LiteralPath $probeFile -Raw -ErrorAction SilentlyContinue
        if ($content -notmatch [regex]::Escape($meta.Sentinel)) {
            # csproj 里没有哨兵，再看源码：v1.2.5 把 includeDxbc 加在 ShaderDecompiler 里。
            $src = Join-Path $dir 'src\ShaderRipper\ShaderDecompiler.cs'
            if (-not (Test-Path -LiteralPath $src)) { return $false }
            $text = Get-Content -LiteralPath $src -Raw -ErrorAction SilentlyContinue
            if ($text -notmatch [regex]::Escape($meta.Sentinel)) {
                Write-Info "$Name 源码里没有 $($meta.Sentinel)（是 $($meta.Ref) 之前的版本）"
                return $false
            }
        }
    }
    return $true
}

function Write-SubmoduleStamp([string]$Name, [string]$Ref) {
    $dir = Join-Path $script:RepoRoot $Name
    if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return }
    $stamp = [ordered]@{
        source = 'tools/arp.ps1'
        ref    = $Ref
        note   = '由 arp.ps1 铺的源码快照；目录必须是这个版本才能编译。删掉本文件会让脚本重新校验。'
    }
    $stamp | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir $script:StampName) -Encoding UTF8
}

function Get-ArchiveUrl([string]$Url, [string]$Ref) {
    # GitHub 的 /archive/ 地址支持 tag / 分支 / commit，压缩包解出来是 <repo>-<ref> 一个目录。
    return "$Url/archive/refs/tags/$Ref.zip"
}

function Expand-SubmoduleArchive {
    <#
        下载 ref 的源码压缩包并铺到目标目录。

        为什么不用 git：用户拿到的往往是 GitHub 的 "Download ZIP"，
        里面没有 .git，`git submodule update` 直接报 "not a git repository"。
        压缩包方案对「有 git」和「没 git」两种情况都成立，且版本由 -Ref 固定，
        和 README 里写的 pin 一致。
    #>
    param([string]$Name, [string]$Url, [string]$Ref)

    $target = Join-Path $script:RepoRoot $Name
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("arp-submodule-" + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $tempRoot 'src.zip'
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    # codeload 直连比 /archive/ 少一次跳转；两个都给，前一个不通自动换。
    $urls = @(
        "$Url/archive/refs/tags/$Ref.zip",
        "$Url/archive/refs/heads/$Ref.zip",
        "https://codeload.github.com/$(([uri]$Url).AbsolutePath.Trim('/'))/zip/refs/tags/$Ref"
    ) | Select-Object -Unique

    try {
        try {
            Get-FileWithProgress -Urls $urls -Destination $zipPath -Label "下载 $Name"
        } catch {
            throw @"
下载依赖 $Name 失败：
  $($_.Exception.Message)
  检查：1) 网络/代理能否访问 github.com；2) $Ref 是否是有效 tag。
  也可以手动下载 $Url/archive/refs/tags/$Ref.zip，解压后把里面的内容
  放到 $target（目录里应能看到 $($script:Submodules[$Name].Probe)）。
"@
        }

        $size = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
        Write-Info "已下载 $size MB，解压中 ..."

        $extract = Join-Path $tempRoot 'x'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extract)

        # 压缩包里只有一个顶层目录。
        $top = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
        if (-not $top) { throw "压缩包结构异常：$Url@$Ref" }

        if (Test-Path -LiteralPath $target) {
            $existing = Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue
            # 什么时候可以直接替换而不要求 -Force：
            #   - 有我们写的版本戳（自己铺的快照），或
            #   - 目录「长得就像」这个仓库的源码（有 .gitmodules / Probe 指定的工程文件），
            #     说明它是子模块目录，只是版本旧或没写过戳。
            # 其它情况（用户往里放了别的东西）必须显式 -Force，避免误删。
            $hasStamp = Test-Path -LiteralPath (Join-Path $target $script:StampName)
            $hasGit = Test-Path -LiteralPath (Join-Path $target '.git')
            $looksLikeSource = (Test-Path -LiteralPath (Join-Path $target $script:Submodules[$Name].Probe)) -or
                               (Test-Path -LiteralPath (Join-Path $target '.gitmodules'))
            $isOwnCopy = -not $hasGit -and ($hasStamp -or $looksLikeSource)
            if ($existing -and -not $Force -and -not $isOwnCopy) {
                throw "目录 $target 已存在且非空。确实要覆盖请加 -Force。"
            }
            Remove-Item -LiteralPath $target -Recurse -Force
        }

        Move-Item -LiteralPath $top.FullName -Destination $target
        Write-SubmoduleStamp -Name $Name -Ref $Ref
        Write-Ok "$Name → $Ref"
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Submodules {
    Write-Step '依赖源码（AssetRipper / ShaderRipper）'

    $missing = @()
    foreach ($name in $script:Submodules.Keys) {
        if (Test-SubmoduleReady $name) {
            $meta = $script:Submodules[$name]
            Write-Ok "$name 已就位（期望 $($meta.Ref)）"
        } else {
            Write-Warn "$name 缺失或版本不对（需要 $($script:Submodules[$name].Ref)）"
            $missing += $name
        }
    }

    if ($missing.Count -eq 0) { return }

    if (Test-Skipped 'submodules') {
        throw "缺少子模块 $($missing -join ', ')，但指定了 -Skip submodules。"
    }

    if (-not (Get-Command Expand-Archive -ErrorAction SilentlyContinue)) {
        throw '需要 PowerShell 5.1+（脚本用了 .NET 的 System.IO.Compression API）。'
    }

    foreach ($name in $missing) {
        $meta = $script:Submodules[$name]
        Expand-SubmoduleArchive -Name $name -Url $meta.Url -Ref $meta.Ref
    }

    # 铺完再验一次，防止「下载成功但结构/版本不对」拖到编译阶段才暴露。
    foreach ($name in $script:Submodules.Keys) {
        if (-not (Test-SubmoduleReady $name)) {
            throw "$name 铺好后仍不是 $($script:Submodules[$name].Ref)（找不到 $($script:Submodules[$name].Probe) 或版本标记不符）。"
        }
    }
}

# ---------------------------------------------------------------- .NET SDK

function Get-DotnetSdkDownloadUrl {
    <#
        从官方 channel 清单里挑一个 x64 SDK 的真实下载地址。

        <para>为什么不用 dotnet-install.ps1：那条路在慢网络上会长时间零输出，
        用户以为卡死了。自己下 zip 就能报进度、失败也能说清楚是哪一步。</para>
    #>
    param([string]$Channel = '10.0')

    try {
        $indexUrl = "https://dotnetcli.blob.core.windows.net/dotnet/Sdk/$Channel/latest.version"
        $latest = (Invoke-WebRequest -Uri $indexUrl -UseBasicParsing -TimeoutSec 60).Content.Trim()
        if ($latest -match '^\d+\.\d+\.\d+') {
            return @{
                Version = $latest
                # 两个官方 CDN 都给出来：同一份文件，国内网络下速度能差 3 倍，
                # 一个连不上自动换下一个。
                Urls    = @(
                    "https://builds.dotnet.microsoft.com/dotnet/Sdk/$latest/dotnet-sdk-$latest-win-x64.zip",
                    "https://dotnetcli.azureedge.net/dotnet/Sdk/$latest/dotnet-sdk-$latest-win-x64.zip"
                )
            }
        }
    } catch { }

    # 退路：解析 releases.json（字段名随版本变动，做宽松匹配）。
    $index = (Invoke-WebRequest -Uri "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/$Channel/releases.json" -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json
    $release = $index.releases | Select-Object -First 1
    if (-not $release) { throw "取不到 .NET $Channel 的发布信息，请手动安装：https://dotnet.microsoft.com/download/dotnet/10.0" }
    $sdk = $release.sdk
    $file = $sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -like 'dotnet-sdk-*win-x64.zip' } | Select-Object -First 1
    if (-not $file) { throw "取不到 win-x64 SDK 的下载地址，请手动安装：https://dotnet.microsoft.com/download/dotnet/10.0" }
    return @{ Version = $sdk.version; Urls = @($file.url) }
}

function Get-FileWithProgress {
    <#
        下载并显示进度，支持断点续传（.partial 文件）和多个镜像依次尝试。

        <para>为什么不用 Invoke-WebRequest：它没有可靠的进度回调，
        慢网络上几百 MB 的下载会显得像卡死；而且失败后要整份重下。</para>
    #>
    param(
        [Parameter(Mandatory)] [string[]]$Urls,
        [Parameter(Mandatory)] [string]$Destination,
        [string]$Label = '下载'
    )

    $partial = "$Destination.partial"
    $lastError = $null

    foreach ($url in $Urls) {
        $attempt = 0
        while ($attempt -lt 2) {
            $attempt++
            try {
                $existing = 0
                if (Test-Path -LiteralPath $partial) { $existing = (Get-Item -LiteralPath $partial).Length }

                $request = [System.Net.HttpWebRequest]::Create($url)
                $request.Timeout = 30000
                $request.ReadWriteTimeout = 120000    # 慢线路下别轻易判死
                $request.UserAgent = 'RipPatch-setup'
                if ($existing -gt 0) { $request.AddRange([long]$existing) }

                $response = $request.GetResponse()
                $totalLength = $response.ContentLength
                if ($existing -gt 0 -and $response.StatusCode -ne [System.Net.HttpStatusCode]::PartialContent) {
                    # 服务器不支持 Range：只能从头来
                    $existing = 0
                }
                if ($totalLength -le 0) { $totalLength = -1 }
                else { $totalLength += $existing }

                $mode = if ($existing -gt 0 -and $response.ContentLength -eq -1) { 'Create' } else { 'Create' }
                $fileStream = [System.IO.File]::Open($partial, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
                try {
                    $stream = $response.GetResponseStream()
                    $buffer = New-Object byte[] 262144
                    $received = $existing
                    $nextReport = 0
                    $stalled = 0
                    while ($true) {
                        try {
                            $read = $stream.Read($buffer, 0, $buffer.Length)
                        } catch {
                            # 已收到 90% 以上就当作完成（有些 CDN 长度不精确）；否则留给下一轮续传
                            if ($totalLength -gt 0 -and $received -ge $totalLength * 0.9) { break }
                            throw
                        }
                        if ($read -le 0) { break }
                        $fileStream.Write($buffer, 0, $read)
                        $received += $read
                        $stalled = 0
                        if (-not $Quiet -and $received -ge $nextReport) {
                            if ($totalLength -gt 0) {
                                $pct = [int]($received * 100 / $totalLength)
                                if ($pct -gt 100) { $pct = 100 }
                                Write-Host ("        {0} {1,3}%  ({2}/{3} MB)" -f $Label, $pct,
                                    [math]::Round($received / 1MB), [math]::Round($totalLength / 1MB)) -ForegroundColor Gray
                            } else {
                                Write-Host ("        {0}  {1} MB" -f $Label, [math]::Round($received / 1MB)) -ForegroundColor Gray
                            }
                            $nextReport = $received + 5MB
                        }
                    }
                } finally {
                    $fileStream.Dispose()
                    $response.Close()
                }

                $finalSize = (Get-Item -LiteralPath $partial).Length
                if ($totalLength -gt 0 -and $finalSize -lt $totalLength) {
                    throw "下载不完整（$([math]::Round($finalSize/1MB))/$([math]::Round($totalLength/1MB)) MB）"
                }
                Move-Item -LiteralPath $partial -Destination $Destination -Force
                return
            } catch {
                $lastError = $_.Exception.Message
                if ($attempt -lt 2) {
                    Write-Info "本轮失败（$lastError），尝试续传 ..."
                    Start-Sleep -Seconds 2
                } else {
                    Write-Info "该镜像失败：$lastError"
                }
            }
        }
    }

    throw "全部下载地址都失败。最后一个错误：$lastError`n  手动方案：浏览器直接下载 $($Urls[0])"
}

function Install-DotnetSdk {
    <#
        .NET 10 SDK 装到用户目录（%USERPROFILE%\.dotnet），不需要管理员权限。
        走 zip 解压而不是官方 dotnet-install.ps1：能报进度、能续传、出错能定位。
    #>
    param([string]$Channel = '10.0')

    $installDir = Join-Path $env:USERPROFILE '.dotnet'
    Write-Info "查询 .NET SDK $Channel 的最新版本 ..."
    $dl = Get-DotnetSdkDownloadUrl -Channel $Channel
    Write-Info "将安装 SDK $($dl.Version)（约 300 MB；网络慢时可先去泡杯茶）"

    # 下载缓存放在固定位置：中途 Ctrl+C 后再跑，会从 .partial 续传，不用从头下。
    $cache = Join-Path $script:RepoRoot '.cache\dotnet-sdk'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $zip = Join-Path $cache "dotnet-sdk-$($dl.Version)-win-x64.zip"

    if (-not (Test-Path -LiteralPath $zip)) {
        Get-FileWithProgress -Urls $dl.Urls -Destination $zip -Label '下载 SDK'
    } else {
        Write-Info "复用已下载的 $([System.IO.Path]::GetFileName($zip))"
    }

    $size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
    Write-Info "解压（$size MB）到 $installDir ..."

    $extract = Join-Path $cache 'extract'
    try {
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)

        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        # SDK zip 的根目录内容直接对应 dotnet 安装根（dotnet.exe / sdk / shared / host ...）。
        Get-ChildItem -LiteralPath $extract -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $installDir -Recurse -Force
        }
    } catch {
        throw @"
安装 .NET SDK 失败：$($_.Exception.Message)
  手动方案：从 https://dotnet.microsoft.com/download/dotnet/10.0 下载
            「SDK 10.x · Windows x64 · Installer」，双击安装即可。
"@
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }

    $exe = Join-Path $installDir 'dotnet.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "安装后找不到 $exe。" }

    # 当前进程能直接用；同时让之后新开的终端也能直接用。
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable('Path', "$installDir;$userPath", 'User')
        Write-Info "已把 $installDir 加入用户 PATH（新开的终端生效）。"
    }
    return $exe
}

# ---------------------------------------------------------------- 各命令

function Invoke-Doctor {
    Write-Banner '环境检查'

    $ok = $true

    # 1. PowerShell
    Write-Step "PowerShell $($PSVersionTable.PSVersion)"
    if ($PSVersionTable.PSVersion.Major -ge 5) {
        Write-Ok '版本满足要求（>= 5.1）'
    } else {
        Write-Fail 'PowerShell 版本过低，需要 5.1+'
        $ok = $false
    }

    # 2. 系统
    Write-Step '操作系统'
    if (-not (Test-IsWindows)) {
        Write-Fail "本工程目前只支持 Windows（当前 $($PSVersionTable.OS)）"
        $ok = $false
    } else {
        Write-Ok "$([Environment]::OSVersion.VersionString) / $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
        if ([Environment]::OSVersion.Version.Major -lt 10) {
            Write-Fail '需要 Windows 10 1703 及以上（.NET 10 的下限）'
            $ok = $false
        }
    }

    # 3. .NET SDK
    Write-Step '.NET SDK'
    $dotnetPath = Get-DotnetCommand
    if (-not $dotnetPath) {
        Write-Fail '没找到 dotnet。运行 `arp.ps1 setup` 自动安装，或手动装 .NET 10 SDK。'
        $ok = $false
        $script:Dotnet = $null
    } else {
        $info = Get-DotnetInfo $dotnetPath
        Write-Info $dotnetPath
        if ($info.HasNet10Sdk) {
            Write-Ok "SDK $($info.Net10SdkVer)（满足 net10.0）"
            # 特意提醒：PATH 上的旧版 dotnet 会让 .slnx 报 MSB4068，是最容易踩的坑。
            $onPath = Get-Command dotnet -ErrorAction SilentlyContinue
            if ($onPath -and $onPath.Source -ne $dotnetPath) {
                Write-Info "注意：PATH 上的 dotnet 是 $($onPath.Source)，它是旧版；脚本会用上面这个 10.0 来构建。"
            }
        } else {
            $list = if ($info.Sdks.Count) { $info.Sdks -join ', ' } else { '无' }
            Write-Fail "没有 .NET 10 SDK（已装：$list）。`arp.ps1 setup` 可以自动补装。"
            $ok = $false
        }
        $script:Dotnet = $dotnetPath
    }

    # 4. 子模块
    Write-Step '依赖源码'
    foreach ($name in $script:Submodules.Keys) {
        $meta = $script:Submodules[$name]
        if (Test-SubmoduleReady $name) {
            Write-Ok "$name（期望 $($meta.Ref)）"
        } else {
            Write-Fail "$name 缺失。`arp.ps1 restore` 会按 $($meta.Ref) 拉取。"
            $ok = $false
        }
    }

    # 5. WebView2（只有桌面界面需要；--web 可以绕过）
    Write-Step 'WebView2 运行时（桌面界面用）'
    $wv2 = Get-WebView2Version
    if ($wv2) {
        Write-Ok "已安装 $wv2"
    } else {
        Write-Warn '未检测到。桌面窗口会自动降级到浏览器模式，也可以用 --web。'
        Write-Info '安装：https://go.microsoft.com/fwlink/p/?LinkId=2124703'
    }

    # 6. 磁盘
    Write-Step '磁盘空间'
    foreach ($dir in @($script:RepoRoot, $env:USERPROFILE)) {
        $free = Get-DiskFreeGb $dir
        if ($null -eq $free) { continue }
        if ($free -lt 3) {
            Write-Fail "$dir 剩余 $free GB，构建至少需要 3 GB"
            $ok = $false
        } else {
            Write-Ok "$dir 剩余 $free GB"
        }
    }

    # 7. 已有产物
    Write-Step '已有产物'
    $pub = Join-Path (Join-Path $script:PublishDir 'RipPatch-win-x64') 'RipPatch.exe'
    if (Test-Path -LiteralPath (Join-Path $script:RepoRoot $pub)) {
        Write-Ok "已发布：$pub"
    } else {
        Write-Info "$pub 尚未生成；用 'arp.ps1 publish' 生成。"
    }

    Write-Banner $(if ($ok) { '检查通过，可以开始构建' } else { '有阻塞项，见上面的 FAIL' })
    return $ok
}

function Invoke-Restore {
    Ensure-DotnetForBuild
    Invoke-Submodules

    Write-Step '还原 NuGet 包'
    $code = Invoke-Dotnet -Arguments @('restore', $script:Slnx) -Description "dotnet restore $([System.IO.Path]::GetFileName($script:Slnx))"
    Assert-DotnetOk $code 'dotnet restore'
    Write-Ok '还原完成'
}

function Ensure-DotnetForBuild {
    # 每次都重新探测：用户可能刚装了 10.0，而缓存里还是旧路径。
    $script:Dotnet = Get-DotnetCommand
    if ($script:Dotnet) {
        $info = Get-DotnetInfo $script:Dotnet
        if ($info.HasNet10Sdk) { return }
    }

    if (Test-Skipped 'sdk') {
        throw '缺少 .NET 10 SDK，且指定了 -Skip sdk。请手动安装：https://dotnet.microsoft.com/download/dotnet/10.0'
    }

    Write-Step '.NET 10 SDK 缺失，自动安装'
    $script:Dotnet = Install-DotnetSdk
    $info = Get-DotnetInfo $script:Dotnet
    if (-not $info.HasNet10Sdk) {
        throw "安装后仍未发现 .NET 10 SDK（$($script:Dotnet)）。"
    }
    Write-Ok "SDK $($info.Net10SdkVer) 就绪"
}

function Invoke-Build {
    Ensure-DotnetForBuild
    Invoke-Submodules

    if (-not $NoRestore) {
        Write-Step '还原 NuGet 包'
        $code = Invoke-Dotnet -Arguments @('restore', $script:Slnx) -Description 'dotnet restore'
        Assert-DotnetOk $code 'dotnet restore'
        Write-Ok '还原完成'
    }

    Write-Step "构建（$Configuration）"
    $buildArgs = @('build', $script:Slnx, '-c', $Configuration, '--nologo')
    if (-not $NoRestore) { $buildArgs += '--no-restore' }
    Write-Info '首次构建要编译 AssetRipper 的 20+ 个工程，大约 2-5 分钟。'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-Dotnet -Arguments $buildArgs
    $sw.Stop()
    Assert-DotnetOk $code 'dotnet build'

    $exe = Join-Path $script:RepoRoot "RipPatch\bin\$Configuration\net10.0\RipPatch.exe"
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "构建成功但找不到产物：$exe"
    }
    $mb = [math]::Round((Get-Item -LiteralPath $exe).Length / 1MB, 1)
    Write-Ok ("$exe（{0:N0}s）" -f $sw.Elapsed.TotalSeconds)
    $script:BuiltExe = $exe
}

function Invoke-Publish {
    Ensure-DotnetForBuild
    Invoke-Submodules

    Write-Step "发布（$Runtime，自包含）"
    Write-Info '自包含发布：目标机器不需要装 .NET 运行时。首次需要下载 win-x64 运行时包。'

    $outDir = Join-Path $script:RepoRoot (Join-Path $script:PublishDir 'RipPatch-win-x64')
    $publishArgs = @(
        'publish', $script:PatcherProject,
        '-c', $Configuration,
        '-r', $Runtime,
        '--self-contained', 'true',
        '-o', $outDir,
        '--nologo'
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-Dotnet -Arguments $publishArgs
    $sw.Stop()
    Assert-DotnetOk $code 'dotnet publish'

    $exe = Join-Path $outDir 'RipPatch.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "发布成功但找不到 $exe" }

    # 清掉不该进分发包的东西（运行残留的 temp\、调试符号）
    Clear-PublishDirectory -Directory $outDir

    $totalMb = [math]::Round(((Get-ChildItem -LiteralPath $outDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
    Write-Ok ("$outDir（{0:N0}s，{1} MB）" -f $sw.Elapsed.TotalSeconds, $totalMb)
    Write-Info '整个目录可以拷到别的机器直接用，别只拷 exe。'
    $script:PublishedExe = $exe
}

function Clear-PublishDirectory {
    <#
        清理发布目录里不该进分发包的东西。

        <para><b>为什么不把 DLL 收进 bin\ 让 exe 单独一层。</b>试过，做不到。
        .NET host 在自包含应用里严格按 deps.json 的条目找文件，不认子目录：
        把 deps 里 400 多个路径全改写成 bin/Xxx.dll 后，即便文件确实在 bin\ 里，
        host 仍然报 "assembly ... was not found"；additionalProbingPaths 对
        运行时包内的程序集也不生效。所以 exe 必须和这些 DLL 平铺在同一层，
        这是 .NET 的硬性约束，不是配置问题。</para>

        <para>能做的是去掉不该来的东西：运行残留的 temp\（实测可达 565 MB）、
        调试符号、运行时生成的设置文件。</para>
    #>
    param([Parameter(Mandatory)] [string]$Directory)

    Write-Step '清理发布目录'

    $tempDir = Join-Path $Directory 'temp'
    if (Test-Path -LiteralPath $tempDir) {
        $tempMb = [math]::Round(((Get-ChildItem -LiteralPath $tempDir -Recurse -File -EA SilentlyContinue |
            Measure-Object Length -Sum).Sum / 1MB), 1)
        Remove-Item -LiteralPath $tempDir -Recurse -Force -EA SilentlyContinue
        Write-Info "已清理运行残留 temp\（$tempMb MB）"
    }

    $pdbFiles = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter '*.pdb' -EA SilentlyContinue)
    if ($pdbFiles.Count -gt 0) {
        $pdbMb = [math]::Round(($pdbFiles | Measure-Object Length -Sum).Sum / 1MB, 1)
        $pdbFiles | Remove-Item -Force -EA SilentlyContinue
        Write-Info "已移除 $($pdbFiles.Count) 个调试符号（$pdbMb MB）"
    }

    # 运行时生成的用户设置，带进包会把开发机的配置泄漏出去
    $settings = Join-Path $Directory 'AssetRipper.Settings.json'
    if (Test-Path -LiteralPath $settings) {
        Remove-Item -LiteralPath $settings -Force -EA SilentlyContinue
    }

    $count = (Get-ChildItem -LiteralPath $Directory -File -EA SilentlyContinue | Measure-Object).Count
    Write-Info "根目录 $count 个文件"
}

function Invoke-Package {
    <#
        打成可分发的 zip。

        <para><b>为什么不打单文件 exe。</b>实测 Harmony 2.4.2 在 .NET 10 单文件模式下
        启动即崩溃（PlatformNotSupportedException: Could not locate clrjit library），
        手动把 clrjit.dll / coreclr.dll 放到 exe 旁边也无效。所以改为
        「自包含目录 + zip」：解压即用，不需要装 .NET。</para>
    #>
    param([switch]$SkipPublish)

    if (-not $SkipPublish) {
        Invoke-Publish
    }

    Write-Step '打包 zip'
    $srcDir = Join-Path $script:RepoRoot (Join-Path $script:PublishDir 'RipPatch-win-x64')
    if (-not (Test-Path -LiteralPath $srcDir)) {
        throw "找不到发布目录 $srcDir，先跑 `arp.ps1 publish`。"
    }

    # pdb 对使用者没用，还占几十 MB，不进分发包。
    $pdbFiles = Get-ChildItem -LiteralPath $srcDir -Recurse -File -Filter '*.pdb' -ErrorAction SilentlyContinue
    $pdbMb = 0
    if ($pdbFiles) {
        $pdbMb = [math]::Round(($pdbFiles | Measure-Object Length -Sum).Sum / 1MB, 1)
        Write-Info "先从包内容里排除 $($pdbFiles.Count) 个 pdb（$pdbMb MB）"
    }

    $version = (Get-Item -LiteralPath (Join-Path $srcDir 'RipPatch.exe')).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) { $version = 'dev' }
    $zipName = "RipPatch-$version-win-x64.zip"
    $zipPath = Join-Path $script:RepoRoot $zipName
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    # 用 Compress-Archive 会把 pdb 也塞进去，所以先复制一份干净目录再压。
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("rippatch-pack-" + [guid]::NewGuid().ToString('N'))
    try {
        # 分两层：
        #   RipPatch-<版本>-win-x64\       ← 解压出来的这一层
        #     RipPatch.cmd                 ← 双击这个就启动，不用找 exe
        #     RipPatch\                    ← 程序本体（420 个文件）
        #       RipPatch.exe
        # 程序本体必须保持平铺（.NET host 要求），所以只能靠外层放个入口脚本
        # 来避免用户在几百个文件里翻找 exe。
        $outer = Join-Path $staging "RipPatch-$version-win-x64"
        $dest = Join-Path $outer 'RipPatch'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        # 这里必须用 -Path 而不是 -LiteralPath：要的是通配符展开。
        # 用 -LiteralPath 会把 "*" 当成字面文件名，一个文件都拷不过去。
        Copy-Item -Path (Join-Path $srcDir '*') -Destination $dest -Recurse -Force
        $copied = (Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($copied -eq 0) {
            throw "暂存目录里没有任何文件（源：$srcDir）。"
        }
        Get-ChildItem -LiteralPath $dest -Recurse -File -Filter '*.pdb' | Remove-Item -Force -ErrorAction SilentlyContinue

        # 外层放启动脚本和说明
        $launcherSource = Join-Path $script:RepoRoot 'tools\dist-launcher.cmd'
        if (Test-Path -LiteralPath $launcherSource) {
            Copy-Item -LiteralPath $launcherSource -Destination (Join-Path $outer 'RipPatch.cmd') -Force
        } else {
            Write-Warn "找不到 tools\dist-launcher.cmd，包里不会有快捷启动脚本"
        }

        $readmeSource = Join-Path $script:RepoRoot 'tools\dist-readme.txt'
        if (Test-Path -LiteralPath $readmeSource) {
            Copy-Item -LiteralPath $readmeSource -Destination (Join-Path $outer '使用说明.txt') -Force
        }

        # 注意：CreateFromDirectory 会把 staging 的「目录名」也写进条目，
        # 于是解压出来是 rippatch-pack-xxx\RipPatch\...，路径又长又随机。
        # 这里逐条手动写入，让 zip 顶层就是 RipPatch-<版本>-win-x64\。
        #
        # PowerShell 5.1 上 Add-Type 只加 FileSystem 时，ZipArchiveMode 这个枚举
        # 仍然找不到（它在 System.IO.Compression 里），所以两个都要加载。
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $mode = [System.IO.Compression.ZipArchiveMode]::Create
        $level = [System.IO.Compression.CompressionLevel]::Optimal
        $archive = [System.IO.Compression.ZipFile]::Open($zipPath, $mode)
        try {
            $baseFull = (Resolve-Path -LiteralPath $staging).Path.TrimEnd('\') + '\'
            foreach ($file in Get-ChildItem -LiteralPath $staging -Recurse -File) {
                $entryName = $file.FullName.Substring($baseFull.Length).Replace('\', '/')
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive, $file.FullName, $entryName, $level)
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    $zipMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
    Write-Ok "$zipName（$zipMb MB）"
    Write-Info '解压后双击 RipPatch.cmd 即可启动，不需要在几百个文件里找 exe。'
    Write-Info '整个文件夹要一起分发，不要只给 exe。'
    $script:PackagedZip = $zipPath
}

function Invoke-Run {
    $exe = Join-Path $script:RepoRoot "RipPatch\bin\$Configuration\net10.0\RipPatch.exe"
    if (-not (Test-Path -LiteralPath $exe) -or $Force) {
        Write-Info $(if ($Force) { '-Force：重新构建' } else { '尚未构建，先构建一次' })
        Invoke-Build | Out-Null
    }

    if (-not (Test-Path -LiteralPath $exe)) {
        throw "找不到可执行文件：$exe。先跑 `arp.ps1 build`。"
    }

    $argList = @()
    $mode = '桌面界面'
    if ($Input) {
        if (-not $Output) {
            throw '给了游戏路径但没给输出路径。用法：arp.ps1 run <游戏> <输出>'
        }
        $argList += $Input, $Output
        $mode = "命令行导出 → $Output"
        if ($Only) { $argList += '--only', $Only }
    } elseif ($Only) {
        throw '-Only 会和 0 个输入路径冲突：--only 只用于命令行导出，需要同时给 <游戏> <输出>。'
    }

    if (-not $Input -and -not (Get-WebView2Version)) {
        Write-Warn '没有 WebView2，窗口会降级到浏览器。'
    }

    Write-Banner "启动 RipPatch（$mode）"
    Write-Info "exe  : $exe"
    if ($argList.Count) { Write-Info ("参数 : " + ($argList -join ' ')) }
    Write-Host ''

    Push-Location (Split-Path -Parent $exe)
    try {
        & $exe @argList
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($code -ne 0) {
        throw "RipPatch 退出码 $code（导出失败）。日志：$(Join-Path (Split-Path -Parent $exe) 'RipPatch.Headless.log')"
    }
}

function Invoke-Clean {
    Write-Step '清理构建产物'
    $targets = @()
    foreach ($dir in @('RipPatch', 'RipPatch.Tests', 'RipPatch.Tools', 'tools\UnityPackageHarvester')) {
        foreach ($sub in @('bin', 'obj')) {
            $p = Join-Path $script:RepoRoot (Join-Path $dir $sub)
            if (Test-Path -LiteralPath $p) { $targets += $p }
        }
    }
    $pubRoot = Join-Path $script:RepoRoot $PublishDir
    if (Test-Path -LiteralPath $pubRoot) { $targets += $pubRoot }

    if ($targets.Count -eq 0) { Write-Ok '没有需要清理的'; return }
    foreach ($p in $targets) {
        Write-Info "删除 $($p.Replace($script:RepoRoot + '\', ''))"
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "清理完成（共 $($targets.Count) 项）。子模块源码保留。"
}

function Invoke-Setup {
    Write-Banner ("RipPatch 一键构建  ·  .NET 10 / {0}" -f [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)
    Write-Info "仓库: $script:RepoRoot"

    Write-Step '环境检查'
    $dotnetPath = Get-DotnetCommand
    if ($dotnetPath) { $script:Dotnet = $dotnetPath }
    $hasSdk = $false
    if ($dotnetPath) {
        $info = Get-DotnetInfo $dotnetPath
        $hasSdk = $info.HasNet10Sdk
        if ($hasSdk) { Write-Ok ".NET SDK $($info.Net10SdkVer)" }
    }
    if (-not $hasSdk) { Write-Warn '.NET 10 SDK 未安装，稍后自动补装' }
    $wv2 = Get-WebView2Version
    if ($wv2) { Write-Ok "WebView2 $wv2" } else { Write-Warn 'WebView2 未安装，桌面窗口将降级到浏览器（不影响命令行导出）' }

    $free = Get-DiskFreeGb $script:RepoRoot
    if ($null -ne $free -and $free -lt 3) {
        throw "磁盘剩余 $free GB，构建至少需要 3 GB。"
    }

    Ensure-DotnetForBuild
    Invoke-Submodules

    Write-Step '还原 NuGet 包'
    $code = Invoke-Dotnet -Arguments @('restore', $script:Slnx) -Description 'dotnet restore'
    Assert-DotnetOk $code 'dotnet restore'
    Write-Ok '还原完成'

    Write-Step "构建（$Configuration）"
    Write-Info '首次构建要编译 AssetRipper 的 20+ 个工程，大约 2-5 分钟。'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-Dotnet -Arguments @('build', $script:Slnx, '-c', $Configuration, '--nologo', '--no-restore')
    $sw.Stop()
    Assert-DotnetOk $code 'dotnet build'

    $exe = Join-Path $script:RepoRoot "RipPatch\bin\$Configuration\net10.0\RipPatch.exe"
    if (-not (Test-Path -LiteralPath $exe)) { throw "找不到产物 $exe" }
    $script:BuiltExe = $exe
    Write-Ok ("{0}（{1:N0}s）" -f $exe, $sw.Elapsed.TotalSeconds)

    Write-Banner '完成'
    Write-Host @"
  桌面界面    .\tools\arp.ps1 run
             或直接双击（保持下面目录里的相对结构）：
             $("RipPatch\bin\$Configuration\net10.0\RipPatch.exe")

  命令行导出  .\tools\arp.ps1 run "D:\Game" "D:\Export"
  可分发发布  .\tools\arp.ps1 publish     →  publish\RipPatch-win-x64\

  提示        设置文件写在 exe 旁边：AssetRipper.Settings.json（首次运行自动生成）
"@
}

function Show-Help {
    Write-Host @'
RipPatch 一键工具

常用：
  .\tools\arp.ps1                        检查 + 拉依赖 + 构建，然后启动界面
  .\tools\arp.ps1 setup                  同上，但只构建不启动
  .\tools\arp.ps1 doctor                 只检查，不修改任何东西
  .\tools\arp.ps1 run "D:\Game" "D:\Out" 命令行导出

命令：
  setup     环境检查 + 拉子模块 + 构建（默认）
  build     只构建（自动补装 .NET 10 SDK、拉子模块）
  restore   只拉子模块 + NuGet 还原
  publish   发布自包含目录到 publish\RipPatch-win-x64\
  package   发布并打成可分发的 zip（解压即用）
  run       构建后启动：不给输入 = 桌面界面；给 <输入> <输出> = 命令行导出
  doctor    环境体检
  clean     删除 bin/obj/publish

运行参数：
  -Only "Sprite,Texture2D"   命令行导出时只导出指定类型（run 用）
  -Configuration Release     Debug / Release，默认 Release
  -Skip submodules,sdk       跳过某一步（sdk 表示不自动装 .NET）
  -Force                     子模块目录非空时也强制覆盖 / run 时强制重建
  -NoRestore                 跳过 NuGet 还原（已经还原过时可节省时间）

更多说明见 docs\USAGE.md。
'@
}

# ---------------------------------------------------------------- 入口

try {
    switch ($Command) {
        'help' { Show-Help; exit 0 }
        'doctor' { $ok = Invoke-Doctor; exit $(if ($ok) { 0 } else { 1 }) }
        'setup' {
            Invoke-Setup
            # setup 之后顺手打开界面：用户的直觉是「跑一下就能用」。
            if (-not $Input) { Invoke-Run }
            exit 0
        }
        'build' { Invoke-Build; exit 0 }
        'restore' { Invoke-Restore; exit 0 }
        'publish' { Invoke-Publish; exit 0 }
        'package' { Invoke-Package; exit 0 }
        'run' { Invoke-Run; exit 0 }
        'clean' { Invoke-Clean; exit 0 }
    }
} catch {
    Write-Host ''
    Write-Host ' ────────────────────────────────────────────' -ForegroundColor Red
    Write-Fail $_.Exception.Message
    Write-Host ' ────────────────────────────────────────────' -ForegroundColor Red
    Write-Host ''
    Write-Host ' 排查建议：' -ForegroundColor Gray
    Write-Host '   1. .\tools\arp.ps1 doctor      看哪一步不满足' -ForegroundColor Gray
    Write-Host '   2. 确认网络能访问 github.com / api.nuget.org' -ForegroundColor Gray
    Write-Host '   3. 完整说明见 docs\USAGE.md' -ForegroundColor Gray
    exit 1
}
