<#
.SYNOPSIS
    Figma 中文版（桌面端原生汉化）安装脚本。

.DESCRIPTION
    在 Windows 上为 Figma 桌面客户端配置「本地代理 + 中文语言包」，不改系统代理、
    不往证书库写东西、不需要管理员权限。适合通过 `irm <URL> | iex` 直接运行。

    安装内容（全部落在 %USERPROFILE%\.figma-zh-cn 下）：
      python\            自带的 Python 运行环境（embeddable，不影响系统 Python）
      figma_zh.py        mitmproxy 插件：命中 Figma 语言包请求时返回中文包
      figma-zh.ps1       启动器：探测上游 → 拉起 mitm → 带代理参数启动 Figma
      launch-hidden.vbs  无窗口启动包装
      zh.json            中文语言包
      port.txt           本机探测到的 mitm 端口
      mitmconf\          mitmproxy 配置与自签 CA（仅本地使用）
      桌面 + 开始菜单「Figma 中文版」快捷方式

.PARAMETER InstallDir
    安装目录，默认 %USERPROFILE%\.figma-zh-cn。

.PARAMETER Yes
    跳过开头的回车确认（自动化用）。

.PARAMETER NoShortcut
    不创建桌面/开始菜单快捷方式，仅准备文件。

.PARAMETER SkipFigma
    即使没检测到 Figma 也不下载安装。

.PARAMETER Port
    指定 mitm 端口；不指定则自动探测一个未使用的非常用端口。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.figma-zh-cn'),
    [switch]$Yes,
    [switch]$NoShortcut,
    [switch]$SkipFigma,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
# 不生成 __pycache__：保持安装目录干净，也避免字节码里留下本机用户路径
$env:PYTHONDONTWRITEBYTECODE = '1'

# ---------------------------------------------------------------- 编码自愈
# 用 irm 取脚本时，若服务端没有声明 charset，PowerShell 5.1 会把响应按 ISO-8859-1 解码，
# 脚本里的中文会变成乱码（例如 中文版 → ä¸­æ–‡ç‰ˆ）。这里检测一次，命中后在运行时逐段还原：
#   · 连续的单字节字符（≤U+00FF，含 ASCII 与乱码字节）→ 按 Latin-1 取字节后用 UTF-8 解码
#   · 已经是正常中文的字符（>U+00FF）原样保留
# 这样即使一句话里既有乱码标签又有正确中文（例如拼接了路径）也能还原。
$script:ProbeWanted = -join ([char]0x4E2D, [char]0x6587, [char]0x7248)   # 中文版
$script:Mojibake = ($script:ProbeWanted -ne '中文版')

function T([string]$text) {
    if ([string]::IsNullOrEmpty($text) -or -not $script:Mojibake) { return $text }
    $sb = New-Object System.Text.StringBuilder
    $buffer = New-Object System.Collections.Generic.List[byte]
    $utf8 = [System.Text.Encoding]::UTF8
    foreach ($ch in $text.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 256) {
            $buffer.Add([byte]$code)
        } else {
            if ($buffer.Count -gt 0) {
                [void]$sb.Append($utf8.GetString($buffer.ToArray()))
                $buffer.Clear()
            }
            [void]$sb.Append($ch)
        }
    }
    if ($buffer.Count -gt 0) { [void]$sb.Append($utf8.GetString($buffer.ToArray())) }
    return $sb.ToString()
}

function Say([string]$text, [string]$Color = 'Gray') {
    Write-Host (T $text) -ForegroundColor $Color
}

function Write-Title([string]$text) { Say ""; Say "== $text" 'Cyan' }
function Write-Ok([string]$text) { Say "   OK  $text" 'Green' }
function Write-Info([string]$text) { Say "   $text" 'Gray' }
function Write-Warn2([string]$text) { Say "   !   $text" 'Yellow' }

# ---------------------------------------------------------------- 常量
$PyVersion = '3.13.9'
$PyZipUrl = "https://www.python.org/ftp/python/$PyVersion/python-$PyVersion-embed-amd64.zip"
$GetPipUrl = 'https://bootstrap.pypa.io/get-pip.py'
$ZhUrl = 'https://kailous.github.io/figma-zh-CN-localized/lang/zh.json'
$FigmaSetupUrl = 'https://desktop.figma.com/win/FigmaSetup.exe'

$Root = $InstallDir
$PyDir = Join-Path $Root 'python'
$PythonExe = Join-Path $PyDir 'python.exe'
$MitmdumpExe = Join-Path $PyDir 'Scripts\mitmdump.exe'
$AddonPath = Join-Path $Root 'figma_zh.py'
$LauncherPath = Join-Path $Root 'figma-zh.ps1'
$VbsPath = Join-Path $Root 'launch-hidden.vbs'
$ZhPath = Join-Path $Root 'zh.json'
$PortFile = Join-Path $Root 'port.txt'
$ShortcutName = (T 'Figma 中文版') + '.lnk'

function Get-File([string]$url, [string]$dest, [switch]$Progress) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        $cargs = @('-sS', '-L', '--fail', '--retry', '3', '--retry-delay', '2', '-o', $dest, $url)
        if ($Progress) { $cargs = @('-sS', '-L', '--fail', '--retry', '3', '--retry-delay', '2', '--progress-bar', '-o', $dest, $url) }
        # 原生命令的 stderr 在 Stop 模式下会被当成终止性错误，这里临时降级
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($Progress) {
                & $curl @cargs 2>&1 | ForEach-Object { Write-Host $_ }
            } else {
                & $curl @cargs 2>&1 | Out-Null
            }
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldEap
        }
        if ($code -ne 0) { throw "下载失败($code): $url" }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 600
    }
}

function Test-PortFree([int]$p) {
    if ($p -le 0 -or $p -gt 65535) { return $false }
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

# 选一个未使用、且不属于常见服务端口的端口
function Find-FreePort {
    $blocked = @(
        80, 443, 1080, 3000, 3128, 4000, 5000, 5001, 5173, 7001, 8000, 8008, 8080, 8081, 8082, 8088,
        8443, 8888, 9000, 9090, 9200, 10000, 10808, 10809, 11223, 27017, 3306, 5432, 6379
    )
    $blocked += 7890..7900
    $rnd = New-Object System.Random
    for ($i = 0; $i -lt 400; $i++) {
        $candidate = $rnd.Next(20000, 45001)
        if ($blocked -contains $candidate) { continue }
        if (Test-PortFree $candidate) { return $candidate }
    }
    for ($p = 47000; $p -lt 49000; $p++) { if (Test-PortFree $p) { return $p } }
    throw "找不到可用端口"
}

function Test-FigmaInstalled {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Figma\Figma.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Figma\Figma.exe'),
        (Join-Path $env:ProgramFiles 'Figma\Figma.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Figma\Figma.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $uninstallRoots) {
        $entries = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Figma*' -and $_.InstallLocation }
        foreach ($e in $entries) {
            $exe = Join-Path $e.InstallLocation 'Figma.exe'
            if (Test-Path $exe) { return $exe }
        }
    }
    return $null
}

function Clear-FigmaCacheDir {
    # Figma 会把真实英文语言包按 build hash 缓存在 HTTP 缓存；只要它在代理之外跑过一次，
    # 之后即使本地代理返回中文，前端仍可能沿用缓存里的英文。安装时清一次最稳。
    $cacheDir = Join-Path $env:APPDATA 'Figma\DesktopProfile\v44\Cache'
    if (-not (Test-Path $cacheDir)) { return $false }
    try {
        Remove-Item $cacheDir -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function New-Shortcuts {
    $wsh = New-Object -ComObject WScript.Shell
    $targets = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName),
        (Join-Path ([Environment]::GetFolderPath('StartMenu')) ('Programs\' + $ShortcutName))
    )
    $figmaExe = Test-FigmaInstalled
    $iconPath = if ($figmaExe) { "$figmaExe,0" } else { (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',13' }
    foreach ($t in $targets) {
        $needsWrite = $true
        if (Test-Path -LiteralPath $t) {
            $existing = $wsh.CreateShortcut($t)
            $isOurs = ($existing.TargetPath -like '*wscript.exe') -and ($existing.Arguments -like "*$VbsPath*")
            if ($isOurs) { $needsWrite = $false }
        }
        if ($needsWrite) {
            $lnk = $wsh.CreateShortcut($t)
            $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
            $lnk.Arguments = '"' + $VbsPath + '"'
            $lnk.WorkingDirectory = $Root
            $lnk.IconLocation = $iconPath
            $lnk.Description = T 'Figma（中文界面）：通过本地代理加载中文语言包'
            $lnk.Save()
            Write-Ok "快捷方式: $t"
        } else {
            Write-Ok "快捷方式已存在: $t"
        }
    }
}

# ---------------------------------------------------------------- 开场
Say ""
Say "  ┌──────────────────────────────────────────────────────────┐" 'Cyan'
Say "  │            Figma 中文版  ·  Windows 安装脚本             │" 'Cyan'
Say "  └──────────────────────────────────────────────────────────┘" 'Cyan'
Say ""
Say "  这个脚本会为 Figma 桌面客户端配置原生中文界面。它做的事情：" 'White'
Say "    1. 在 $Root 下放一个自带 Python 的独立环境（不影响系统 Python）"
Say "    2. 安装本地代理 mitmproxy，并在本机挑一个未使用的非常用端口供它监听"
Say "    3. 让 Figma 通过这个本地代理启动，从而加载中文语言包"
Say "    4. 在桌面和开始菜单创建「Figma 中文版」快捷方式"
Say ""
Say "  它不会做的事情：" 'White'
Say "    · 不改系统代理，不动 Clash 配置，浏览器和其它程序完全不受影响"
Say "    · 不往 Windows 证书库导入任何证书（Figma 启动时用独立参数跳过校验）"
Say "    · 不需要管理员权限，不写注册表服务项"
Say ""
Say "  网络：需要能访问 python.org / pypi.org / kailous.github.io；缺 Figma 时会去 figma.com 下载。"
if (-not $Yes) {
    Say ""
    Say "  按回车键开始安装；输入其它内容后回车可取消。" 'Yellow'
    $answer = "$(Read-Host (T '  继续'))".Trim()
    if ($answer -ne '') {
        Say "  已取消，未做任何改动。" 'Yellow'
        return
    }
}
Say ""
Say "  开始安装……" 'Green'

# ---------------------------------------------------------------- 1. 目录与既有安装
Write-Title "1/7 准备安装目录"
if (-not (Test-Path $Root)) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Write-Ok "已创建 $Root"
} else {
    Write-Ok "目录已存在 $Root"
}
$isRepair = (Test-Path $PythonExe) -and (Test-Path $LauncherPath) -and (Test-Path $AddonPath)
if ($isRepair) {
    Write-Info "检测到已有安装：本次按「修复/更新」处理（保留语言包与端口设置，补回缺失部分）"
} else {
    Write-Info "未检测到既有安装：按全新安装处理"
}

# ---------------------------------------------------------------- 2. Python 环境
Write-Title "2/7 准备独立 Python 环境"
$needPy = $true
if (Test-Path $MitmdumpExe) {
    try {
        & $MitmdumpExe --version *> $null
        if ($LASTEXITCODE -eq 0) {
            $needPy = $false
            Write-Ok "已存在可用环境: $PyDir"
        }
    } catch { }
}
if ($needPy) {
    $tmpZip = Join-Path $env:TEMP ("python-embed-" + [guid]::NewGuid().ToString('N') + ".zip")
    $tmpPip = Join-Path $env:TEMP ("get-pip-" + [guid]::NewGuid().ToString('N') + ".py")
    try {
        Write-Info "下载 Python $PyVersion 便携版……"
        Get-File -url $PyZipUrl -dest $tmpZip
        if (Test-Path $PyDir) { Remove-Item $PyDir -Recurse -Force }
        New-Item -ItemType Directory -Path $PyDir -Force | Out-Null
        Expand-Archive -Path $tmpZip -DestinationPath $PyDir -Force
        Get-ChildItem $PyDir -Filter '*._pth' | ForEach-Object {
            $content = Get-Content $_.FullName -Raw
            $content = $content -replace '(?m)^#\s*import site\s*$', "import site`r`nLib\site-packages"
            if ($content -notmatch 'Lib\\site-packages') { $content = $content + "`r`nLib\site-packages`r`n" }
            Set-Content -Path $_.FullName -Value $content -Encoding ASCII
        }
        New-Item -ItemType Directory -Path (Join-Path $PyDir 'Lib\site-packages') -Force | Out-Null
        Write-Ok "Python 已解压: $PyDir"

        Write-Info "安装 pip……"
        Get-File -url $GetPipUrl -dest $tmpPip
        & $PythonExe $tmpPip --no-warn-script-location *> $null
        if ($LASTEXITCODE -ne 0) { throw "pip 安装失败" }
        Write-Ok "pip 就绪"

        Write-Info "安装 mitmproxy（约 30-40 MB，需要一点时间）……"
        $pipOut = & $PythonExe -m pip install -q --no-warn-script-location --disable-pip-version-check mitmproxy 2>&1
        if ($LASTEXITCODE -ne 0) {
            ($pipOut | Select-Object -Last 15) | ForEach-Object { Say "     $_" 'DarkGray' }
            throw "mitmproxy 安装失败"
        }
        if (-not (Test-Path $MitmdumpExe)) { throw "mitmdump 未生成: $MitmdumpExe" }
        Write-Ok "mitmproxy 就绪"
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpPip -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- 3. 端口
Write-Title "3/7 选择 mitm 监听端口"
$chosenPort = 0
if ($Port -gt 0) {
    if (-not (Test-PortFree $Port)) { throw "指定的端口 $Port 正被占用" }
    $chosenPort = $Port
    Write-Ok "使用指定端口 $Port"
} elseif (Test-Path $PortFile) {
    $rawPort = (Get-Content $PortFile -Raw).Trim()
    if ($rawPort -match '^\d+$' -and (Test-PortFree ([int]$rawPort))) {
        $chosenPort = [int]$rawPort
        Write-Ok "沿用已安装端口 $chosenPort"
    }
}
if ($chosenPort -eq 0) {
    $chosenPort = Find-FreePort
    Write-Ok "探测到未使用端口 $chosenPort"
}
Set-Content -Path $PortFile -Value $chosenPort -Encoding ASCII

# ---------------------------------------------------------------- 4. 程序文件
Write-Title "4/7 写入程序文件"

$addonCode = @'
"""figma-zh addon：只替换 Figma 的语言包请求，其余流量原样转发。

Figma 126.x 桌面端实际请求的是 <bundle>_app-<hash>.min.en.json(.br)（例如 figma_app-*、
prototype_app-*），不是单一固定路径。命中时直接回本地中文包（200 + JSON），
不产生跨域、不依赖外网可达性。
"""
import os
import re
import threading

from mitmproxy import ctx, http

ZH_PATH = os.environ.get("FIGMA_ZH_PATH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "zh.json"))
LOG_PATH = os.environ.get("FIGMA_ZH_LOG", os.path.join(os.path.dirname(os.path.abspath(__file__)), "locale-requests.log"))

ASSET_PREFIX = "/webpack-artifacts/assets/"
LOCALE_RE = re.compile(
    r"^(?:[a-z0-9_]+_app|auth_iframe|community)-[a-f0-9]{8,64}\.min\.en\.json(?:\.br)?$",
    re.IGNORECASE,
)
SERVE_RE = re.compile(r"^[a-z0-9_]+_app-[a-f0-9]{8,64}\.min\.en\.json(?:\.br)?$", re.IGNORECASE)

_zh_body = None
_lock = threading.Lock()


def _log(line: str) -> None:
    try:
        with _lock, open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_zh() -> None:
    global _zh_body
    with open(ZH_PATH, "rb") as f:
        _zh_body = f.read()


def request(flow: http.HTTPFlow) -> None:
    path = flow.request.path.split("?", 1)[0]
    if ASSET_PREFIX not in path:
        return
    name = path.rsplit("/", 1)[-1]
    if not LOCALE_RE.match(name):
        return

    _log("LOCALE " + flow.request.url)
    if _zh_body is None or not SERVE_RE.match(name):
        _log("PASS " + name)
        return

    flow.response = http.Response.make(
        200,
        _zh_body,
        {
            "Content-Type": "application/json; charset=utf-8",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "Pragma": "no-cache",
        },
    )
    _log("SERVED " + name)


def running() -> None:
    load_zh()
'@
$addonCode = T $addonCode
Set-Content -Path $AddonPath -Value $addonCode -Encoding UTF8
Write-Ok "figma_zh.py"

$launcherCode = @'
# Figma 中文版启动器（由安装脚本生成，请勿手工编辑）
# 只影响 Figma 进程：不动系统代理、不改 Clash 配置。
[CmdletBinding()]
param([switch]$RefreshOnly)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$portFile = Join-Path $root 'port.txt'
$mitm = Join-Path $root 'python\Scripts\mitmdump.exe'
$addon = Join-Path $root 'figma_zh.py'
$zhPath = Join-Path $root 'zh.json'
$zhUrl = 'https://kailous.github.io/figma-zh-CN-localized/lang/zh.json'
$logPath = Join-Path $root 'launcher.log'
$modePath = Join-Path $root 'mitm-mode.txt'
$ClashHost = '127.0.0.1'
$ClashPort = 7897
$SystemProxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Write-Log([string]$msg) {
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
        Add-Content -Path $logPath -Value $line -Encoding utf8
    } catch { }
}

function Test-HostPort([string]$HostName, [int]$PortNumber, [int]$TimeoutMs = 400) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $PortNumber)
        if ($task.Wait($TimeoutMs)) { return $client.Connected }
        return $false
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Test-PortFree([int]$p) {
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

function Find-FreePort {
    for ($p = 47000; $p -lt 49000; $p++) { if (Test-PortFree $p) { return $p } }
    return 47821
}

function Get-Port {
    if (Test-Path $portFile) {
        $raw = (Get-Content $portFile -Raw).Trim()
        if ($raw -match '^\d+$') { return [int]$raw }
    }
    $newPort = Find-FreePort
    Set-Content -Path $portFile -Value $newPort -Encoding ASCII
    return $newPort
}

function Get-SystemProxy {
    try {
        $item = Get-ItemProperty -Path $SystemProxyKey -ErrorAction Stop
    } catch {
        $script:proxyReason = '读不到代理设置'
        return $null
    }
    if ([int]$item.ProxyEnable -ne 1) {
        if ($item.AutoConfigURL) { $script:proxyReason = '系统代理已关闭，只配了 PAC 自动脚本' }
        else { $script:proxyReason = '系统代理已关闭' }
        return $null
    }
    $server = "$($item.ProxyServer)"
    if (-not $server) { $script:proxyReason = 'ProxyEnable 已开但 ProxyServer 为空'; return $null }

    $picked = $null
    foreach ($scheme in @('https', 'http')) {
        $m = [regex]::Match($server, "(?:^|;)\s*$scheme\s*=\s*([^;]+)")
        if ($m.Success) { $picked = $m.Groups[1].Value.Trim(); break }
    }
    if (-not $picked) {
        $first = ($server -split ';')[0]
        if ($first -match '=') { $picked = ($first -split '=', 2)[1].Trim() } else { $picked = $first.Trim() }
    }
    $parsed = [regex]::Match($picked, '^(?<h>\[[^\]]+\]|[^:]+):(?<p>\d{1,5})$')
    if (-not $parsed.Success) { $script:proxyReason = "无法解析 ProxyServer: $picked"; return $null }
    return @{
        Host   = $parsed.Groups['h'].Value.Trim('[', ']')
        Port   = [int]$parsed.Groups['p'].Value
        Source = '系统代理'
    }
}

function Show-UpstreamMissingDialog([string]$Tried) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Figma 中文版'
        $form.ClientSize = New-Object System.Drawing.Size(470, 196)
        $form.StartPosition = 'CenterScreen'
        $form.TopMost = $true
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $label = New-Object System.Windows.Forms.Label
        $label.SetBounds(16, 14, 438, 124)
        $label.Text = "没有可用的上游代理。`r`n$Tried`r`n`r`n直连启动：本地代理改走直连，不走任何上游；界面仍是中文。`r`n停止启动：本次不启动 Figma。"
        $form.Controls.Add($label)
        $btnDirect = New-Object System.Windows.Forms.Button
        $btnDirect.Text = '直连启动'
        $btnDirect.SetBounds(180, 146, 110, 32)
        $btnDirect.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $btnStop = New-Object System.Windows.Forms.Button
        $btnStop.Text = '停止启动'
        $btnStop.SetBounds(304, 146, 110, 32)
        $btnStop.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.AddRange(@($btnDirect, $btnStop))
        $form.AcceptButton = $btnDirect
        $form.CancelButton = $btnStop
        $result = $form.ShowDialog()
        $form.Dispose()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return 'direct' }
        return 'stop'
    } catch {
        Write-Log ("弹窗失败，按停止启动处理: " + $_.Exception.Message)
        return 'stop'
    }
}

function Get-OurMitm {
    Get-CimInstance Win32_Process -Filter "Name='mitmdump.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$addon*" }
}

function Stop-Mitm {
    Get-OurMitm | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        if (-not (Test-HostPort '127.0.0.1' $Port)) { return }
    }
}

function Get-MitmMode {
    if (Test-Path $modePath) { return (Get-Content $modePath -Raw).Trim() }
    return ''
}

function Start-Mitm([string]$Mode, [string]$UpstreamUrl) {
    $mitmArgs = @('-p', "$Port", '-s', $addon, '--set', "confdir=$root\mitmconf", '--set', 'connection_strategy=lazy', '-q')
    if ($Mode -eq 'upstream') {
        $mitmArgs += @('--mode', "upstream:$UpstreamUrl")
        Write-Log "启动本地 mitm（监听 $Port，上游 $UpstreamUrl）"
    } else {
        Write-Log "启动本地 mitm（监听 $Port，直连外网，不走上游）"
    }
    $env:PYTHONDONTWRITEBYTECODE = '1'
    Start-Process -FilePath $mitm -ArgumentList $mitmArgs -WindowStyle Hidden
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 300
        if (Test-HostPort '127.0.0.1' $Port) {
            $record = if ($Mode -eq 'upstream') { "upstream|$UpstreamUrl" } else { 'direct' }
            Set-Content -Path $modePath -Value $record -Encoding ascii
            return $true
        }
    }
    return $false
}

function Test-MitmHealthy {
    # 通过本地代理请求一个固定命中的语言包 URL，确认返回的确实是 zh.json
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl) -or -not (Test-Path $zhPath)) { return $true }
    $tmp = Join-Path $env:TEMP ("figma-zh-probe-" + [guid]::NewGuid().ToString('N') + ".json")
    # 原生命令（curl）出错会往 stderr 写内容，必须先降级 ErrorActionPreference，
    # 否则在 Stop 模式下会被当成终止性错误，导致启动器静默退出。
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $curl -k -sS -x "http://127.0.0.1:$Port" --max-time 8 `
            -o $tmp 'https://www.figma.com/webpack-artifacts/assets/figma_app-0000000000000000.min.en.json.br' 2>&1 | Out-Null
        if (-not (Test-Path $tmp)) { return $false }
        if ((Get-Item $tmp).Length -ne (Get-Item $zhPath).Length) { return $false }
        return ((Get-FileHash $tmp -Algorithm SHA256).Hash -eq (Get-FileHash $zhPath -Algorithm SHA256).Hash)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $oldEap
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Stop-FigmaGracefully {
    # 先正常关闭，关不掉的再强制；taskkill 的 stderr 不能在 Stop 模式下冒泡
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & taskkill.exe /IM Figma.exe 2>&1 | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (@(Get-Process Figma -ErrorAction SilentlyContinue).Count -eq 0) { return $true }
        }
        & taskkill.exe /F /IM Figma.exe 2>&1 | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (@(Get-Process Figma -ErrorAction SilentlyContinue).Count -eq 0) { return $true }
        }
        return $false
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

function Clear-FigmaLocaleCache {
    # Figma 会把真实英文语言包按 build hash 缓存在 HTTP 缓存里；只要它在代理之外跑过一次，
    # 之后即使本地代理返回中文，前端仍可能沿用缓存里的英文。清理缓存目录即可。
    $cacheDir = Join-Path $env:APPDATA 'Figma\DesktopProfile\v44\Cache'
    if (-not (Test-Path $cacheDir)) { return $false }
    try {
        $sizeMb = [math]::Round(((Get-ChildItem $cacheDir -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum).Sum) / 1MB, 1)
        Remove-Item $cacheDir -Recurse -Force -ErrorAction Stop
        Write-Log "已清理 Figma 界面缓存（$sizeMb MB），避免旧英文语言包残留"
        return $true
    } catch {
        Write-Log ("清理 Figma 缓存失败: " + $_.Exception.Message)
        return $false
    }
}

function Show-RestartDialog {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Figma 中文版'
        $form.ClientSize = New-Object System.Drawing.Size(470, 176)
        $form.StartPosition = 'CenterScreen'
        $form.TopMost = $true
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $label = New-Object System.Windows.Forms.Label
        $label.SetBounds(16, 14, 438, 104)
        $label.Text = "Figma 正在运行，但当前这个进程没有走本地代理，所以界面还是英文。`r`n`r`n需要重启 Figma 才能加载中文语言包（不会丢失未保存的内容，Figma 会自动同步）。"
        $form.Controls.Add($label)
        $btnRestart = New-Object System.Windows.Forms.Button
        $btnRestart.Text = '立即重启'
        $btnRestart.SetBounds(180, 128, 110, 32)
        $btnRestart.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = '取消'
        $btnCancel.SetBounds(304, 128, 110, 32)
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.AddRange(@($btnRestart, $btnCancel))
        $form.AcceptButton = $btnRestart
        $form.CancelButton = $btnCancel
        $result = $form.ShowDialog()
        $form.Dispose()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return 'restart' }
        return 'cancel'
    } catch {
        return 'cancel'
    }
}

function Update-ZhPack {
    if (-not (Test-Path $zhPath)) { Write-Log '缺少 zh.json，跳过更新'; return }
    $ageDays = ((Get-Date) - (Get-Item $zhPath).LastWriteTime).TotalDays
    if ($ageDays -lt 7) { return }
    Write-Log '语言包超过 7 天，开始刷新'
    $tmp = "$zhPath.tmp"
    try {
        Invoke-WebRequest -Uri $zhUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 25 | Out-Null
        $ok = & (Join-Path $root 'python\python.exe') -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); sys.exit(0 if isinstance(d,dict) and len(d)>10000 else 1)" $tmp
        if ($LASTEXITCODE -eq 0) {
            Move-Item $tmp $zhPath -Force
            Write-Log '语言包已更新'
        } else {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Write-Log '下载内容校验失败，保留旧包'
        }
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Log ("刷新失败，继续用现有包: " + $_.Exception.Message)
    }
}

Update-ZhPack
if ($RefreshOnly) { return }

$figma = $null
foreach ($c in @(
        (Join-Path $env:LOCALAPPDATA 'Figma\Figma.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Figma\Figma.exe'),
        (Join-Path $env:ProgramFiles 'Figma\Figma.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Figma\Figma.exe')
    )) {
    if ($c -and (Test-Path $c)) { $figma = $c; break }
}
if (-not $figma) {
    Write-Log '未找到 Figma.exe'
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("没有找到 Figma 桌面客户端。`r`n`r`n请先安装 Figma，然后重新运行安装脚本，或双击「Figma 中文版」重试。", 'Figma 中文版', 'OK', 'Warning')
    } catch { }
    return
}

$runningFigma = Get-CimInstance Win32_Process -Filter "Name='Figma.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' }
if ($runningFigma) {
    $viaProxy = @($runningFigma | Where-Object { $_.CommandLine -match '--proxy-server=http://127\.0\.0\.1:' })
    if ($viaProxy.Count -gt 0) {
        Write-Log 'Figma 已在运行且已走本地代理，激活现有窗口'
        Start-Process -FilePath $figma
        return
    }
    Write-Log 'Figma 正在运行但没有走本地代理（界面会是英文），询问是否重启'
    if ((Show-RestartDialog) -ne 'restart') {
        Write-Log '用户选择取消，不重启 Figma'
        return
    }
    Write-Log '按用户选择重启 Figma'
    if (-not (Stop-FigmaGracefully)) {
        Write-Log 'Figma 未能退出，本次不继续启动'
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show("Figma 没有正常退出，请手动关闭 Figma 后再双击「Figma 中文版」。", 'Figma 中文版', 'OK', 'Warning')
        } catch { }
        return
    }
    Write-Log 'Figma 已退出，继续启动中文版'
    # 未走代理的实例很可能已经把英文语言包写进了缓存，这里一并清掉
    [void](Clear-FigmaLocaleCache)
}

$Port = Get-Port
if (Test-HostPort '127.0.0.1' $Port) {
    $ours = Get-OurMitm
    if (-not $ours) {
        $newPort = Find-FreePort
        Write-Log "端口 $Port 被其它程序占用，改用 $newPort"
        $Port = $newPort
        Set-Content -Path $portFile -Value $Port -Encoding ASCII
    }
}

$upstream = $null
$tried = @()
$sys = Get-SystemProxy
if ($sys) {
    if ($sys.Host -in @('127.0.0.1', 'localhost', '::1') -and $sys.Port -eq $Port) {
        $tried += "系统代理指向本启动器自己（$($sys.Host):$($sys.Port)）"
    } elseif (Test-HostPort $sys.Host $sys.Port) {
        $upstream = $sys
    } else {
        $tried += "系统代理 $($sys.Host):$($sys.Port) 不可达"
    }
} else {
    $tried += "系统代理不可用（$script:proxyReason）"
}
if (-not $upstream) {
    if (Test-HostPort $ClashHost $ClashPort) {
        $upstream = @{ Host = $ClashHost; Port = $ClashPort; Source = 'Clash 默认地址' }
    } else {
        $tried += "Clash 默认地址 $ClashHost`:$ClashPort 未监听"
    }
}

if ($upstream) {
    Write-Log "上游代理：$($upstream.Source) $($upstream.Host):$($upstream.Port)"
    $mode = 'upstream'
    $upstreamUrl = "http://$($upstream.Host):$($upstream.Port)"
} else {
    Write-Log ("没有可用的上游代理：" + ($tried -join '；'))
    if ((Show-UpstreamMissingDialog -Tried ($tried -join "`r`n")) -ne 'direct') {
        Write-Log '用户选择停止启动'
        return
    }
    $mode = 'direct'
    $upstreamUrl = ''
    Write-Log '用户选择直连启动'
}

$desiredRecord = if ($mode -eq 'upstream') { "upstream|$upstreamUrl" } else { 'direct' }
if (Test-HostPort '127.0.0.1' $Port) {
    $running = Get-MitmMode
    if ($running -ne $desiredRecord) {
        Write-Log "mitm 当前（$running）与需要（$desiredRecord）不一致，重启"
        Stop-Mitm
    } else {
        Write-Log "mitm 已在运行（$running）"
    }
}
if (-not (Test-HostPort '127.0.0.1' $Port)) {
    if (-not (Start-Mitm -Mode $mode -UpstreamUrl $upstreamUrl)) {
        Write-Log "mitm 未能在 $Port 就绪，本次不启动 Figma"
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show("本地代理未能在端口 $Port 启动，请查看：`r`n$logPath", 'Figma 中文版', 'OK', 'Warning')
        } catch { }
        return
    }
}

# 健康检查：确认本地代理真的在替换语言包（防止"进程在跑但没生效"）
if (-not (Test-MitmHealthy)) {
    Write-Log '健康检查未通过：本地代理返回的不是中文包，重启 mitm 后重试'
    Stop-Mitm
    if (-not (Start-Mitm -Mode $mode -UpstreamUrl $upstreamUrl) -or -not (Test-MitmHealthy)) {
        Write-Log '重启 mitm 后健康检查仍失败，本次不启动 Figma'
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show("本地代理没有生效：语言包没有被替换，Figma 启动后会是英文。`r`n`r`n请查看日志：`r`n$logPath", 'Figma 中文版', 'OK', 'Warning')
        } catch { }
        return
    }
    Write-Log '重启 mitm 后健康检查通过'
} else {
    Write-Log '健康检查通过：语言包由本地代理替换'
}

Write-Log "启动 Figma（代理 127.0.0.1:$Port，$mode）"
Start-Process -FilePath $figma -ArgumentList @(
    "--proxy-server=http://127.0.0.1:$Port",
    '--ignore-certificate-errors'
)
'@
$launcherCode = T $launcherCode
Set-Content -Path $LauncherPath -Value $launcherCode -Encoding UTF8
Write-Ok "figma-zh.ps1"

# VBS 自己定位同目录的启动器：不嵌入路径，避免用户名含中文/空格时的编码问题
$vbsCode = @'
' Figma (Chinese UI) hidden launcher - generated by install.ps1
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
script = fso.GetParentFolderName(WScript.ScriptFullName) & "\figma-zh.ps1"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
'@
Set-Content -Path $VbsPath -Value $vbsCode -Encoding ASCII
Write-Ok "launch-hidden.vbs"

# ---------------------------------------------------------------- 5. 语言包
Write-Title "5/7 准备中文语言包"
$needZh = $true
if (Test-Path $ZhPath) {
    $size = (Get-Item $ZhPath).Length
    if ($isRepair -and $size -gt 500000) { $needZh = $false; Write-Ok "已存在语言包（$([math]::Round($size/1MB,1)) MB），跳过下载" }
}
if ($needZh) {
    Write-Info "下载语言包（约 3.3 MB）……"
    $tmpZh = "$ZhPath.tmp"
    Get-File -url $ZhUrl -dest $tmpZh
    $count = & $PythonExe -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); print(len(d))" $tmpZh
    if ($LASTEXITCODE -ne 0 -or [int]$count -lt 10000) { throw "语言包校验失败（条目数: $count）" }
    Move-Item $tmpZh $ZhPath -Force
    Write-Ok "语言包就绪（$count 条）"
}

# ---------------------------------------------------------------- 6. Figma
Write-Title "6/7 检查 Figma 客户端"
$figmaExe = Test-FigmaInstalled
if ($figmaExe) {
    Write-Ok "已安装: $figmaExe"
    if (@(Get-Process Figma -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Warn2 "Figma 正在运行：请退出 Figma 后重新运行本脚本，或首次启动「Figma 中文版」时按提示重启"
    } elseif (Clear-FigmaCacheDir) {
        Write-Ok "已清理 Figma 界面缓存（避免旧英文语言包残留）"
    }
} elseif ($SkipFigma) {
    Write-Warn2 "未检测到 Figma，按参数要求跳过下载"
} else {
    Write-Warn2 "未检测到 Figma 桌面客户端"
    $doInstall = $true
    if (-not $Yes) {
        $ans = "$(Read-Host (T '  现在下载并安装 Figma 客户端吗？约 160 MB（回车=是，输入 n=跳过）'))".Trim()
        if ($ans -match '^(n|no|否)$') { $doInstall = $false }
    }
    if ($doInstall) {
        $setup = Join-Path $env:TEMP 'FigmaSetup.exe'
        Write-Info "下载 Figma 安装包（约 160 MB）……"
        Get-File -url $FigmaSetupUrl -dest $setup -Progress
        Write-Info "运行安装包……"
        $setupProc = Start-Process -FilePath $setup -ArgumentList '--silent' -PassThru -ErrorAction SilentlyContinue
        if (-not $setupProc) { Start-Process -FilePath $setup }
        for ($i = 0; $i -lt 180; $i++) {
            Start-Sleep -Seconds 2
            $figmaExe = Test-FigmaInstalled
            if ($figmaExe) { break }
        }
        if ($figmaExe) {
            Write-Ok "Figma 已安装: $figmaExe"
        } else {
            Write-Warn2 "尚未检测到 Figma。若安装向导还在等待操作，请完成后再重新运行本脚本。"
        }
        Remove-Item $setup -Force -ErrorAction SilentlyContinue
    } else {
        Write-Warn2 "已跳过 Figma 下载；装好 Figma 后重新运行本脚本即可补上快捷方式。"
    }
}

# ---------------------------------------------------------------- 7. 快捷方式 + 自检
Write-Title "7/7 创建快捷方式并自检"
if ($NoShortcut) {
    Write-Warn2 "按参数要求跳过快捷方式创建"
} else {
    New-Shortcuts
}

Write-Info "自检：读取语言包 + 校验插件规则……"
$selfTest = & $PythonExe -c @"
import importlib.util, json, os, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location('figma_zh', os.path.join(root, 'figma_zh.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
data = json.load(open(os.path.join(root, 'zh.json'), encoding='utf-8'))
ok = (len(data) > 10000
      and mod.SERVE_RE.match('figma_app-6372f0021b0d5c94.min.en.json.br') is not None
      and mod.SERVE_RE.match('prototype_app-2fd57f1b72b1df75.min.en.json') is not None
      and mod.SERVE_RE.match('community-1234abcd.min.en.json') is None)
print('keys=%d rules=%s' % (len(data), 'ok' if ok else 'bad'))
sys.exit(0 if ok else 1)
"@ $Root
if ($LASTEXITCODE -ne 0) { throw "自检失败: $selfTest" }
Write-Ok ("自检通过（" + ($selfTest -join ' ') + "）")

Write-Info "自检：启动 mitm 并验证语言包替换……"
# 自检用独立的临时端口，避免安装端口已被正在运行的 mitm 占用而测到别人
$testPort = Find-FreePort
$testErr = Join-Path $env:TEMP ("figma-zh-selftest-" + [guid]::NewGuid().ToString('N') + ".log")
$probeFile = Join-Path $env:TEMP ("figma-zh-selftest-" + [guid]::NewGuid().ToString('N') + ".json")
$testProc = Start-Process -FilePath $MitmdumpExe -ArgumentList @(
    '-p', "$testPort", '-s', $AddonPath,
    '--set', "confdir=$Root\mitmconf", '--set', 'connection_strategy=lazy', '-q'
) -PassThru -WindowStyle Hidden -RedirectStandardError $testErr
$served = $false
try {
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 300
        if ($testProc.HasExited) { break }
        $probe = New-Object System.Net.Sockets.TcpClient
        try { $probe.Connect('127.0.0.1', $testPort); if ($probe.Connected) { $served = $true } } catch { } finally { $probe.Dispose() }
        if ($served) { break }
    }
    if ($served) {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $probeUrl = 'https://www.figma.com/webpack-artifacts/assets/figma_app-0000000000000000.min.en.json.br'
        & $curl -k -sS -x "http://127.0.0.1:$testPort" --max-time 20 -o $probeFile $probeUrl 2>$null
        $gotLen = if (Test-Path $probeFile) { (Get-Item $probeFile).Length } else { 0 }
        $wantLen = (Get-Item $ZhPath).Length
        $same = $false
        if ($gotLen -eq $wantLen) {
            $same = (Get-FileHash $probeFile -Algorithm SHA256).Hash -eq (Get-FileHash $ZhPath -Algorithm SHA256).Hash
        }
        if ($same) {
            Write-Ok "语言包替换生效（返回 $gotLen 字节，与 zh.json 完全一致）"
        } else {
            Write-Warn2 ("替换自检未通过：got=" + $gotLen + " want=" + $wantLen + "，详见 " + $testErr)
        }
    } else {
        Write-Warn2 ("自检代理未能在临时端口 " + $testPort + " 起来，详见 " + $testErr)
    }
} finally {
    if ($testProc) { Stop-Process -Id $testProc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Remove-Item $testErr -Force -ErrorAction SilentlyContinue
    Remove-Item $probeFile -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 完成
Say ""
Say "  安装完成。" 'Green'
Say ""
Say "  安装目录 : $Root"
Say "  mitm 端口: $chosenPort"
Say "  启动方式 : 桌面 / 开始菜单的「Figma 中文版」"
Say ""
Say "  说明：" 'White'
Say "    · 点原来的 Figma 图标不会被汉化；请用「Figma 中文版」。"
Say "    · 启动时会先探测系统代理，取不到再回退 Clash 127.0.0.1:7897；"
Say "      两者都不可达时会弹窗询问「直连启动 / 停止启动」。"
Say "    · 快捷方式丢失或文件缺失时，重新运行本脚本即可修复。"
Say "    · 卸载：删除 $Root，并删除桌面与开始菜单里的「Figma 中文版」。"
Say ""
