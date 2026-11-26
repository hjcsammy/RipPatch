<#
.SYNOPSIS
    RipPatch 启动器（双击用）。

.DESCRIPTION
    放在仓库根目录。双击本文件（或它同目录的 启动.cmd）即可：

      第一次：自动把程序编译出来（会检查并补装 .NET 10 SDK、拉取依赖）
      以后  ：直接打开界面，不再编译，几秒钟

    编译产物用自包含发布（publish\），所以之后就算换了台没装 .NET 的机器，
    把 publish\RipPatch-win-x64 整个目录拷过去也能直接跑。

    出问题时窗口不会一闪就没 —— 它会把错误留在屏幕上等你看。

.PARAMETER GamePath
    游戏路径。给了它（并给 Output）就走命令行导出，不开界面。

.PARAMETER Output
    导出目录。

.PARAMETER Force
    强制重新编译（代码改过、或者怀疑产物坏了时用）。

.PARAMETER NoBuild
    不编译，只启动。没编译过就直接报错。

.EXAMPLE
    双击运行 → 打开界面

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File 启动.ps1 -GamePath "D:\Game" -Output "D:\Export"
    命令行导出
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$Output,
    [string]$Only,
    [switch]$Force,
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$publishedExe = Join-Path $root 'publish\RipPatch-win-x64\RipPatch.exe'
$builtExe = Join-Path $root 'RipPatch\bin\Release\net10.0\RipPatch.exe'
$arp = Join-Path $root 'tools\arp.ps1'

function Say($text, $color = 'Gray') {
    if ($color -eq 'Gray') { Write-Host $text } else { Write-Host $text -ForegroundColor $color }
}

# ---------------------------------------------------------------- 找可执行文件

function Resolve-Exe {
    # 自包含发布是首选目标：不依赖机器上装了什么，目录也能整个拷走。
    # bin\Release 只在发布缺失时兜底 —— 但它是 framework-dependent 的，
    # 换台没装 .NET 的机器就跑不起来，所以不能当作「已经准备好」。
    if (Test-Path -LiteralPath $publishedExe) { return $publishedExe }
    if (Test-Path -LiteralPath $builtExe) { return $builtExe }
    return $null
}

function Test-Published {
    return (Test-Path -LiteralPath $publishedExe)
}

function Build-IfNeeded {
    if (-not (Test-Path -LiteralPath $arp)) {
        throw "找不到 $arp。启动器必须放在仓库根目录（和 tools\ 同级）。"
    }
    if ($Force) {
        Say '按 -Force 重新发布 ...' 'Cyan'
    } else {
        Say '第一次启动，正在准备程序（自动安装依赖 + 编译，大约几分钟）...' 'Cyan'
        Say '以后再启动就不用等这一步了。' 'DarkGray'
    }
    Say ''

    # 走 arp.ps1 publish：自包含产物，换台机器也能直接跑。
    # 用 -File 起独立进程，输出直接继承，进度条正常显示。
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $arp, 'publish')
    if ($Force) { $argList += '-Force' }
    & powershell @argList
    $code = $LASTEXITCODE

    if ($code -ne 0 -or -not (Test-Path -LiteralPath $publishedExe)) {
        throw "编译失败（退出码 $code）。上面的红色文字就是原因，也可以单独跑 `"$arp doctor`" 看环境。"
    }
    Say ''
    Say '准备完成。' 'Green'
    Say ''
}

function Start-App([string]$exe) {
    $argList = @()
    $mode = '桌面界面'

    if ($GamePath) {
        if (-not $Output) { throw '给了 -GamePath 但没给 -Output。导出需要两个路径。' }
        if (-not (Test-Path -LiteralPath $GamePath)) { throw "找不到游戏路径：$GamePath" }
        $argList += $GamePath, $Output
        $mode = "命令行导出 → $Output"
        if ($Only) { $argList += '--only', $Only }
    } elseif ($Only) {
        throw '-Only 需要配合 -GamePath 和 -Output（命令行导出）使用。'
    }

    Say "启动：$mode" 'Cyan'
    Say "程序：$exe" 'DarkGray'
    Say ''

    # 工作目录设成程序所在目录：设置文件、日志都写在它旁边。
    Push-Location (Split-Path -Parent $exe)
    try {
        & $exe @argList
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($code -ne 0) {
        throw "程序异常退出（退出码 $code）。日志：$(Join-Path (Split-Path -Parent $exe) 'RipPatch.Headless.log')"
    }
}

# ---------------------------------------------------------------- 主流程

try {
    # 触发构建的条件（按优先级）：
    #   -Force      → 无条件重新发布
    #   没有发布产物 → 首次运行，或之前只 build 过
    # 只有 bin\Release 而没有 publish\ 时也要构建：bin 是 framework-dependent 的，
    # 换个没装 .NET 的机器就跑不起来，不能算「准备好了」。
    if ($Force) {
        Build-IfNeeded
    } elseif (-not (Test-Published)) {
        if ($NoBuild) {
            if (-not (Resolve-Exe)) {
                throw "还没有编译过的程序，且指定了 -NoBuild。先双击启动器（或跑 `"$arp publish`"）编译一次。"
            }
            Say '按 -NoBuild 跳过了发布，将使用 bin\Release 里的程序（需要本机装有 .NET 10 运行时）。' 'Yellow'
        } else {
            Build-IfNeeded
        }
    }

    $exe = Resolve-Exe
    if (-not $exe) { throw '编译完了但找不到 exe，请检查 publish\ 目录。' }

    Start-App $exe
}
catch {
    Say ''
    Say '──────────────────────────────────────────────' 'Red'
    Say (' 出错了：' + $_.Exception.Message) 'Red'
    Say '──────────────────────────────────────────────' 'Red'
    Say ''
    Say '这个窗口先别关，把上面所有内容截图或复制发出来即可。' 'Yellow'
    Say ''
    Say '常见情况：' 'Gray'
    Say '  · 没装 .NET 10 SDK      → 重跑一次，启动器会自动装' 'Gray'
    Say '  · 缺 WebView2           → 装 Edge WebView2 运行时，或改用浏览器模式' 'Gray'
    Say '  · 网络访问不了 GitHub   → 检查代理' 'Gray'
    Say ''
    # 双击运行时窗口会立刻关掉，所以停住等用户按一下。
    if ($Host.Name -eq 'ConsoleHost') {
        Read-Host '按 Enter 键关闭'
    }
    exit 1
}
