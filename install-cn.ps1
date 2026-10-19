#Requires -Version 5.1
<#
  install-cn.ps1 —— Hermes Agent 国内加速安装启动器
  官方 install.ps1 一个字节不改。本启动器只做四件事：
    1. 测试各国内镜像站连通性（不通自动回退直连，公共镜像说挂就挂）
    2. 注入进程级环境变量（只影响本窗口，不写注册表）
    3. 写用户级 pip.ini / npmrc（持久，以后 hermes update 也走国内源）
    4. 下载最新官方安装器在本进程执行（环境变量直接被它继承）
  用法：
    powershell -ExecutionPolicy Bypass -File .\install-cn.ps1
  固定默认行为（没有开关，脚本内部自动管理）：
    加速（FastGitHub 策略）  断开 github.com（假代理+白名单直连）→ GitHub 下载数秒内失败 →
                            按原版回退顺序秒切官方镜像 hermes-assets（实测 3.6MB/s）。
                            三道护栏任一命中即自动关闭并打印原因：指定 -Proxy、gh-proxy
                            探测不通、预热 Python 失败。
    无人值守               跳过安装期配置向导，装完用桌面版自带配置流程
                            （需要安装期向导请直接跑官方 install.ps1，见教学文档 §6）。
    Python 本体镜像         按 [1/5] 测试自动选：npmmirror → gh-proxy → 无镜像直连；
                            手动强指定：setx UV_PYTHON_INSTALL_MIRROR <url>（新开窗口重跑）。
  可选参数：
    -Persist                setx 固化镜像变量（新窗口生效，以后 hermes update 也走国内源）
    -Proxy ip:端口           走指定代理，如 -Proxy 66.66.66.1:10808（会自动关闭加速策略）
    -NoDesktop              默认安装桌面图形版；加此参数跳过（只装命令行版）
  示例：
    .\install-cn.ps1                          # 默认：加速 + 无人值守 + 桌面版
    .\install-cn.ps1 -Proxy 66.66.66.1:10808  # 走真代理（自动关加速策略）
    .\install-cn.ps1 -NoDesktop               # 只装命令行版
    .\install-cn.ps1 -Persist                 # 固化镜像变量到用户环境
  断点重跑：任何一步失败直接重跑本脚本，已下完的 git/uv/Python/依赖
  都留在 %LOCALAPPDATA%\hermes 缓存里，不会重下。
#>
[CmdletBinding(PositionalBinding=$false)]
param(
  [switch]$Persist,
  [string]$Proxy = '',
  [switch]$NoDesktop
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- 镜像表：换镜像只改这里（实测日期 2026-10） ----------
$TUNA        = 'https://pypi.tuna.tsinghua.edu.cn/simple'
$ALIYUN      = 'https://mirrors.aliyun.com/pypi/simple/'
$NPM         = 'https://registry.npmmirror.com'
$GHPROXY     = 'https://gh-proxy.com/https://github.com'
$REPO_MIRROR = 'https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git'
$PBS_NPM     = 'https://registry.npmmirror.com/-/binary/python-build-standalone'
$PBS_GHP     = 'https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download'
$UV_ZIP_PROBE = "$GHPROXY/astral-sh/uv/releases/download/0.12.3/uv-x86_64-pc-windows-msvc.zip"
# 原版自带的官方兜底镜像（uv/PortableGit 下载失败时它顶上），第1步会测试它是否可用：
$HERMES_ASSETS = 'https://hermes-assets.nousresearch.com/upstream/sha256/b23350c79e8ad0192b8124af13a0f17e8d4e4549524785e1aef389ae5a06990e'
$INSTALLER_URL = 'https://hermes-agent.nousresearch.com/install.ps1'

# 指定代理时：.NET 的连通性测试/下载 与 子进程 git/curl/uv 都走它（进程级，脚本结束自动还原）
# 写法：-Proxy ip:端口，如 -Proxy 66.66.66.1:10808
$proxyUrl = ''
if ($Proxy) {
  $proxyUrl = if ($Proxy -match '^[a-z]+://') { $Proxy } else { 'http://' + $Proxy }
  if ($proxyUrl -notmatch '^[a-z]+://[^:/\s]+:\d+(/|$)') {
    throw ('代理格式应为 ip:端口，例如 -Proxy 66.66.66.1:10808；实际收到：' + $Proxy)
  }
  [Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy($proxyUrl)
  $env:HTTP_PROXY  = $proxyUrl
  $env:HTTPS_PROXY = $proxyUrl
  $env:ALL_PROXY   = $proxyUrl
  Write-Host ('    代理已启用：' + $proxyUrl) -ForegroundColor Yellow
}

function Test-Mirror([string]$Url, [int]$Sec = 8) {
  try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = 'HEAD'
    $req.Timeout = $Sec * 1000
    $req.AllowAutoRedirect = $true
    $req.UserAgent = 'install-cn-probe'
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return ($code -ge 200 -and $code -lt 400)
  } catch {
    try {
      $req = [Net.HttpWebRequest]::Create($Url)
      $req.Method = 'GET'
      $req.AddRange(0, 0)
      $req.Timeout = $Sec * 1000
      $req.AllowAutoRedirect = $true
      $req.UserAgent = 'install-cn-probe'
      $resp = $req.GetResponse()
      $code = [int]$resp.StatusCode
      $resp.Close()
      return ($code -ge 200 -and $code -lt 400)
    } catch {
      return $false
    }
  }
}

Write-Host '+---------------------------------------------------------' -ForegroundColor Cyan
Write-Host '|  Hermes Agent 国内加速安装（启动器 · 官方脚本零改动）' -ForegroundColor Cyan
Write-Host '+---------------------------------------------------------' -ForegroundColor Cyan

# ---------- 1/5 下载镜像站连通性测试 ----------
Write-Host ''
Write-Host '[1/5] 下载镜像站连通性测试（约 10 秒）' -ForegroundColor Yellow
$probes = [ordered]@{
  'PyPI 清华'              = "$TUNA/"
  'PyPI 阿里（备选）'      = $ALIYUN
  'npm 淘宝'               = "$NPM/"
  'GitHub 代理 gh-proxy'   = $UV_ZIP_PROBE
  'Python PBS npmmirror'   = "$PBS_NPM/"
  '官方兜底 hermes-assets' = $HERMES_ASSETS
  '安装器本体'             = $INSTALLER_URL
}
$up = @{}
foreach ($k in $probes.Keys) {
  $ok = Test-Mirror $probes[$k]
  $up[$k] = $ok
  if ($ok) { Write-Host ('    [OK] ' + $k) -ForegroundColor Green }
  else     { Write-Host ('    [!!] ' + $k + '  不可用，自动回退直连') -ForegroundColor Red }
}
if (-not $up['安装器本体']) {
  throw '官方安装器地址访问不了，检查网络后重跑（本脚本未做任何改动）'
}
if (-not $up['官方兜底 hermes-assets']) {
  Write-Host '    警告：官方兜底镜像也不通，uv/PortableGit 将只能直连 GitHub' -ForegroundColor Yellow
}

# ---------- 2/5 选择加速线路 ----------
Write-Host ''
Write-Host '[2/5] 选择加速线路' -ForegroundColor Yellow
$pypi = $null
if ($up['PyPI 清华']) { $pypi = $TUNA }
elseif ($up['PyPI 阿里（备选）']) { $pypi = $ALIYUN }

$useRepoMirror = $up['GitHub 代理 gh-proxy']

# Python 本体镜像按 [1/5] 测试自动选（手动强指定：setx UV_PYTHON_INSTALL_MIRROR <url> 后新开窗口）
$pyMirrorUrl = $null
if ($up['Python PBS npmmirror']) { $pyMirrorUrl = $PBS_NPM }
elseif ($useRepoMirror) { $pyMirrorUrl = $PBS_GHP }

# 加速策略（FastGitHub）原理：原版下载是"先 GitHub，失败才切 hermes-assets 兜底"，但 GitHub
# 慢而不死时永远不会触发兜底（PortableGit 20 分钟才 24MB 就是这个状态）。
# 本策略给 .NET 和所有子进程指向一个"必然 DNS 解析失败"的 .invalid 假代理，
# 只把需要直连的域名放进白名单 —— github.com 请求数秒内失败，
# 原版 Invoke-VerifiedDownload 和 pm 的 downloader（unresolved → fallback_allowed）
# 都会立刻按原版顺序切到 hermes-assets（本机实测 3.6MB/s）。
# 边界：只掐 GitHub（它是唯一"慢而不死、且有 hermes-assets 兜底"的目标）；
# 没有兜底的源（files.pythonhosted.org、cdn.playwright.dev 等）一律放行直连，掐了就是硬失败。
# 白名单 = 镜像 + 官方兜底 + 依赖源，按 pm/lock.json 域名清单列全；
# 漏一个那个域名就解析失败，测试时看报错补进来即可。
$directHosts = @(
  'hermes-assets.nousresearch.com', 'gh-proxy.com', 'registry.npmmirror.com',
  'pypi.tuna.tsinghua.edu.cn', 'mirrors.aliyun.com', 'nodejs.org', 'unofficial-builds.nodejs.org',
  'cdn.playwright.dev', 'registry.npmjs.org', 'ffmpeg.martin-riedl.de', 'packages.termux.dev',
  'archive.ubuntu.com', 'ports.ubuntu.com', 'hermes-agent.nousresearch.com', 'localhost', '127.0.0.1',
  # 没有镜像兜底的源，掐了就是硬失败，必须放行（2026-10 实测教训）：
  # uv sync --frozen 按 uv.lock 里记死的 files.pythonhosted.org 下载依赖，
  # 清华变量只影响解析/新装，改不了已锁地址——所以依赖走直连（Fastly CDN 实测约 3.6MB/s）
  'files.pythonhosted.org', 'pypi.org', 'npmmirror.com', 'cdn.npmmirror.com'
)
# 加速策略（FastGitHub）默认开启，无参数开关；护栏命中即自动关闭并打印原因
$fastOn = $false
$fastWhy = ''
if ($Proxy) { $fastWhy = '已指定 -Proxy 代理，GitHub 走代理即可，加速策略自动关闭' }
elseif (-not $useRepoMirror) { $fastWhy = 'gh-proxy 镜像 clone 未生效，断 GitHub 会连 clone 一起断，加速策略自动关闭' }
else { $fastOn = $true }

# ---------- 3/5 提前安装 Python 环境（FastGitHub 的必需前置） ----------
# 实测（安装器钉的 uv 0.12.3，2026-10）：安装器下载 Python 用的 uv python install 不认代理白名单 NO_PROXY，
# 只要进程里有代理就会走隧道（tunnel/dns 报错），白名单拦不住；uv pip、Python urllib、git 都认。
# 所以在注入死代理之前，先用"从 install.ps1 源码现读的下载地址+sha256"（与安装器钉的版本
# 永远一致，不写死版本号）取回 uv，再以 npmmirror 直连把 Python 装进 uv 托管目录——
# 安装器随后 Get-BootstrapPython 的 uv python find 直接命中、跳过整个下载阶段。
$installer = Join-Path $env:TEMP 'hermes-install-official.ps1'
$warmState = '未执行（未开 FastGitHub 时安装器自己走镜像下载，无此问题）'
if ($fastOn) {
  Write-Host '[3/5] 提前安装 Python 环境（此阶段不注入代理；装好后安装器会跳过该步）...' -ForegroundColor Yellow
  try {
    if (-not (Test-Path $installer)) {
      Invoke-WebRequest -Uri $INSTALLER_URL -OutFile $installer -UseBasicParsing -TimeoutSec 180
    }
    $body = Get-Content -Raw $installer
    if ($body -notmatch 'Hermes Agent') { throw 'install.ps1 内容异常' }

    $uvArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $m = [regex]::Match($body, '(?s)\{[^{}]*uv-' + $uvArch + '-pc-windows-msvc\.zip[^{}]*\}')
    if (-not $m.Success) { throw '没在 install.ps1 里找到 uv 下载块' }
    $blk  = $m.Value
    $uvSha = ([regex]::Match($blk, '[0-9a-f]{64}')).Value
    $uvUrl = ([regex]::Match($blk, 'MirrorUrl\s*=\s*"([^"]+)"')).Groups[1].Value
    if (-not $uvUrl) { $uvUrl = ([regex]::Match($blk, 'Url\s*=\s*"([^"]+)"')).Groups[1].Value }
    if (-not $uvSha) { throw 'uv 下载块里没解析到 sha256' }

    $uvDir = Join-Path $env:TEMP 'hermes-cn-uv'
    $uvZip = Join-Path $env:TEMP 'hermes-cn-uv.zip'
    New-Item -ItemType Directory -Force -Path $uvDir | Out-Null
    if (-not (Test-Path (Join-Path $uvDir 'uv.exe'))) {
      Write-Host ('    取 uv：' + $uvUrl) -ForegroundColor DarkGray
      Invoke-WebRequest -Uri $uvUrl -OutFile $uvZip -UseBasicParsing -TimeoutSec 300
      $got = (Get-FileHash -Path $uvZip -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($got -ne $uvSha) { throw ('uv sha256 校验失败，预期 ' + $uvSha.Substring(0, 12) + '… 实际 ' + $got.Substring(0, 12) + '…') }
      Expand-Archive -Path $uvZip -DestinationPath $uvDir -Force
      Write-Host '    uv 校验通过' -ForegroundColor Green
    }
    $uvExe = Join-Path $uvDir 'uv.exe'

    # 与安装器同款请求（install.ps1 Get-BootstrapPython）：cpython-3.14-windows-<arch>-none
    $pyReq = 'cpython-3.14-windows-' + $uvArch + '-none'
    $savedPyMirror = [Environment]::GetEnvironmentVariable('UV_PYTHON_INSTALL_MIRROR')
    if ($pyMirrorUrl) { $env:UV_PYTHON_INSTALL_MIRROR = $pyMirrorUrl }   # 用第1步测试通过的镜像；都挂则走直连（此阶段还没注入代理，安全）
    try {
      & $uvExe python install --no-bin --no-registry $pyReq   # stderr 留在屏幕上当进度，不用 2>&1（EAP=Stop 会炸）
      $warmExit = $LASTEXITCODE
    } finally {
      if ($null -eq $savedPyMirror) { Remove-Item Env:UV_PYTHON_INSTALL_MIRROR -ErrorAction SilentlyContinue }
      else { $env:UV_PYTHON_INSTALL_MIRROR = $savedPyMirror }
    }
    if ($warmExit -ne 0) {
      $warmState = '失败：已自动关闭 FastGitHub，改普通直连安装'
      $fastOn = $false
      $fastWhy = '提前安装 Python 失败，已自动关闭 FastGitHub 保证安装能走完（原因见上方 uv 输出）'
      Write-Host '    [!!] Python 环境安装失败 → 已关闭 FastGitHub，改普通直连安装' -ForegroundColor Red
    } else {
      $warmState = '完成：安装器检测到已有 Python，跳过该步下载'
      Write-Host '    [OK] Python 环境已装好，安装器将跳过该步' -ForegroundColor Green
    }
  } catch {
    $warmState = '异常：已自动关闭 FastGitHub，改普通直连安装'
    $fastOn = $false
    $fastWhy = '提前安装 Python 异常，已自动关闭 FastGitHub 保证安装能走完'
    Write-Host ('    [!!] 提前安装 Python 异常：' + $_.Exception.Message + ' → 改普通直连安装') -ForegroundColor Red
  }
}

# ---------- 4/5 写入加速配置（环境变量 + 用户级配置文件） ----------
Write-Host '[4/5] 写入加速配置' -ForegroundColor Yellow
$env:HERMES_INSTALL_CHANNEL = 'stable'   # 钉死 stable：镜像 clone（非官方 origin）时原版会退化成跟 main，显式 stable 绕过（install.ps1:937）
if ($useRepoMirror) { $env:HERMES_REPO_URL = $REPO_MIRROR }
if ($pypi)          { $env:UV_DEFAULT_INDEX = $pypi }        # 影响解析/新装/pip；uv sync --frozen 按锁地址下载，不受它影响（已实测）
if ($pyMirrorUrl)   { $env:UV_PYTHON_INSTALL_MIRROR = $pyMirrorUrl }
# node-pre-gyp 预编译包改道（源码 versioning.js: npm_config_<module_name>_binary_host_mirror，
# module_name=node-get-windows → 只替换首个横杠）。FastGitHub 掐 github 时预编译包改走 gh-proxy，
# 不触发源码编译 → 不需要 VS（gh-proxy 实测 200）
[Environment]::SetEnvironmentVariable('npm_config_node-get-windows_binary_host_mirror', 'https://gh-proxy.com/https://github.com/sindresorhus/get-windows/releases/download/', 'Process')
Write-Host '    HERMES_INSTALL_CHANNEL = stable（钉死，绕过镜像 origin 检查）'
if ($useRepoMirror) { Write-Host '    HERMES_REPO_URL       = gh-proxy 镜像' }
if ($pypi)          { Write-Host ('    UV_DEFAULT_INDEX      = ' + $pypi) }
if ($pyMirrorUrl)   { Write-Host ('    UV_PYTHON_INSTALL_MIRROR = ' + $pyMirrorUrl) }
if (-not $pypi) { Write-Host '    警告：PyPI 镜像全挂，依赖将直连官方源' -ForegroundColor Yellow }
if (-not $pyMirrorUrl) { Write-Host '    提示：Python 本体无镜像（可 setx UV_PYTHON_INSTALL_MIRROR 指定后重跑）' -ForegroundColor Yellow }

# 用户级 pip.ini：你自己 pip 的源，pm 也读它桥接 uv
if ($pypi) {
  $pipDir = Join-Path $env:APPDATA 'pip'
  $pipIni = Join-Path $pipDir 'pip.ini'
  $hasPip = (Test-Path $pipIni) -and (Select-String -Path $pipIni -Pattern 'index-url' -Quiet -ErrorAction SilentlyContinue)
  if ($hasPip) {
    Write-Host '    pip.ini 已有源配置，不覆盖'
  } else {
    New-Item -ItemType Directory -Force -Path $pipDir | Out-Null
    Set-Content -Path $pipIni -Value "global.index-url = $pypi" -Encoding ASCII
    Write-Host ('    已写入 ' + $pipIni)
  }
}
# 用户级 ~/.npmrc —— npm 四层配置里真正的"用户层"。
# 实测（2026-10，npm12 捆绑版）：npm 读 USERPROFILE\.npmrc，不读 %APPDATA%\npm\etc\npmrc
#  （后者是独立 Node 安装的前缀 etc，捆绑 npm 的前缀在 hermes tools 下，写那里没人读）。
$npmRc  = Join-Path $env:USERPROFILE '.npmrc'
$rcWant = @(
  "registry=$NPM/"
  'electron_mirror=https://npmmirror.com/mirrors/electron/'
  'disturl=https://npmmirror.com/mirrors/node/'
)
# 合并策略：这三键以本脚本为准（加速目的），其余行原样保留
$rcKeep = @()
if (Test-Path $npmRc) {
  $rcKeep = Get-Content $npmRc -ErrorAction SilentlyContinue |
    Where-Object { $_ -notmatch '^\s*(registry|electron_mirror|disturl)=' }
}
@($rcKeep + $rcWant) | Set-Content -Path $npmRc -Encoding ASCII
Write-Host ('    已写入/更新 ' + $npmRc + '（registry/electron_mirror/disturl）')
Write-Host '    get-windows 预编译改道不走 npmrc（npm 会吞键里的短横线），用进程环境变量' 
if ($Persist) {
  if ($pypi) { setx UV_DEFAULT_INDEX $pypi | Out-Null }
  if ($pyMirrorUrl) { setx UV_PYTHON_INSTALL_MIRROR $pyMirrorUrl | Out-Null }
  Write-Host '    -Persist：已 setx 固化（新开窗口生效，以后 hermes update 也走国内源）'
}

# ---------- 线路总表 ----------
$cloneDesc   = if ($useRepoMirror) { 'gh-proxy 镜像（HERMES_REPO_URL）' } else { '官方直连 GitHub' }
$pyDesc      = if ($pyMirrorUrl)   { $pyMirrorUrl } else { '官方直连 GitHub（慢/易超时）' }
$pypiDesc    = if ($pypi)          { $pypi } else { '官方 PyPI（镜像全挂）' }
$chanDesc    = 'stable = 最新正式发布版（钉死，绕过镜像 origin 检查）'
Write-Host ''
Write-Host '  本次安装走向：' -ForegroundColor Cyan
Write-Host ('    版本渠道      ' + $chanDesc)
Write-Host ('    源码 clone    ' + $cloneDesc)
Write-Host ('    Python 本体   ' + $pyDesc)
Write-Host ('    Python 依赖   ' + $pypiDesc + '（管解析/新装；已锁包按锁地址直连 pythonhosted，已放行不掐）')
Write-Host '    npm / Electron 用户 npmrc → registry.npmmirror.com（已写入）'
Write-Host '    uv / Git      原版自带官方镜像兜底（hermes-assets，第1步已测试）'
Write-Host ('    GitHub 策略   ' + $(if ($fastOn) { '已断开：GitHub 下载数秒内失败 → 全部秒切 hermes-assets（白名单域名直连）' } else { $fastWhy }))
Write-Host ('    Python 环境   ' + $warmState)
$vsHint = ''
if (-not $NoDesktop) {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $vsOk = (Test-Path $vswhere) -and (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
  if (-not $vsOk) {
    $vsHint = ' （未检测到 VS C++ 构建工具：预编译包已改道 gh-proxy，正常不触发编译，无需处理）'
  }
}
Write-Host ('    桌面图形版    ' + $(if ($NoDesktop) { '跳过（-NoDesktop）' } else { '安装（默认，含 Electron 窗口）' }) + $vsHint)
Write-Host ''
Write-Host '  提示：装完跑 hermes doctor；中途失败直接重跑本脚本，已下完的部分在缓存里不重下。' -ForegroundColor Green
Write-Host ''

# ---------- 5/5 执行官方安装器 ----------
Write-Host '[5/5] 执行官方安装器（未下载过则现拉最新版）...' -ForegroundColor Yellow
$installer = Join-Path $env:TEMP 'hermes-install-official.ps1'
if (-not (Test-Path $installer)) {
  Invoke-WebRequest -Uri $INSTALLER_URL -OutFile $installer -UseBasicParsing -TimeoutSec 180
}
$body = Get-Content -Raw $installer
if ($body -notmatch 'Hermes Agent') { throw ('下载内容异常：' + $installer) }

# 必须用哈希表 splat：PowerShell 5.1 的数组 splat 会把元素当位置参数传，
# 而官方 install.ps1 声明了 PositionalBinding=$false → 数组传参会被拒
# （PositionalParameterNotFound）。哈希表的键才是参数名，已实测可用。
$installerArgs = @{}
if (-not $NoDesktop) { $installerArgs['IncludeDesktop'] = $true }   # 默认安装桌面图形版
$installerArgs['NonInteractive'] = $true   # 固定无人值守：装完用桌面版自带配置（要向导请直接跑官方 install.ps1）

# 代理注入与还原：全部进程级，try/finally 保证正常结束或中途报错都恢复原状；
# 不写注册表、不动 hosts 文件、不改系统代理，只影响本窗口进程。
$deadProxy  = 'http://hermes-cn-off.invalid:8080'   # .invalid 顶级域按 RFC 永不分配 → 必然 DNS 失败
$envKeys    = @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'ALL_PROXY', 'all_proxy', 'NO_PROXY', 'no_proxy', 'ELECTRON_BUILDER_BINARIES_MIRROR', 'ELECTRON_MIRROR')
$savedEnv   = @{}
foreach ($k in $envKeys) { $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k) }
$savedDefaultProxy = [Net.WebRequest]::DefaultWebProxy
$savedEnc = $null
try {
  # 控制台按 UTF-8 解码子进程输出，修官方进度行的乱码（鈫? = UTF-8 被 GBK 解码）；跑完还原
  $savedEnc = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
  # electron-builder 工具组（7zip/icons/winCodeSign/…）与 electron 本体的国内直连：
  #  源码 app-builder-lib/dist/util/electronGet.js 的 getBinariesMirrorUrl() 认
  #  ELECTRON_BUILDER_BINARIES_MIRROR，不设它打包阶段就去 GitHub 下 electron-builder-binaries
  #  → TypeError: fetch failed → products exit 1（2026-10 实测）；npmmirror 有该镜像且已验证200。
  $env:ELECTRON_BUILDER_BINARIES_MIRROR = 'https://registry.npmmirror.com/-/binary/electron-builder-binaries/'
  $env:ELECTRON_MIRROR = 'https://npmmirror.com/mirrors/electron/'
  if ($fastOn) {
    # 层1：Windows PowerShell 5.1 走 .NET Framework，不读环境变量，只认 DefaultWebProxy
    $wp = New-Object Net.WebProxy($deadProxy)
    $wp.BypassList = @($directHosts | ForEach-Object { [regex]::Escape($_) })  # 不加锚点：兼容按 host / 按 URI 两种匹配实现
    [Net.WebRequest]::DefaultWebProxy = $wp
    # 层2（环境变量）——死代理只挂 ALL_PROXY：
    #  python urllib / git / uv 认 all_proxy + no_proxy → pm 的 GitHub 工具包照样秒切官方镜像；
    #  node-pre-gyp 的代理链是 opts.proxy||http_proxy||HTTP_PROXY||npm_config_proxy 四选一、
    #  完全不认 no_proxy（源码实测），npm 又不映射 all_proxy —— 所以 http(s)_proxy 必须留空，
    #  预编译包才会"直连" gh-proxy 改道地址（源码 versioning.js 的 binary_host_mirror 键）。
    $env:NO_PROXY = ($directHosts -join ',')
    $env:no_proxy = $env:NO_PROXY
    foreach ($k in @('ALL_PROXY', 'all_proxy')) { Set-Item -Path ('Env:' + $k) -Value $deadProxy }
    Write-Host '  [-FastGitHub 已注入] ALL_PROXY 死代理：python/git/uv 走镜像回退，node 侧直连改道地址' -ForegroundColor Yellow
  }
  & $installer @installerArgs
  $script:InstallerExit = $LASTEXITCODE
} finally {
  foreach ($k in $envKeys) {
    if ($null -eq $savedEnv[$k]) { Remove-Item -Path ('Env:' + $k) -ErrorAction SilentlyContinue }
    else { Set-Item -Path ('Env:' + $k) -Value $savedEnv[$k] }
  }
  [Net.WebRequest]::DefaultWebProxy = $savedDefaultProxy
  if ($null -ne $savedEnc) { try { [Console]::OutputEncoding = $savedEnc } catch { } }
  if ($fastOn) { Write-Host '  [-FastGitHub 已还原，本窗口代理环境恢复原样]' -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host '  启动器执行完毕。若安装器报错退出，按上面的失败环节排查后重跑本脚本即可（缓存增量）。' -ForegroundColor Cyan
exit $(if ($null -ne $script:InstallerExit) { $script:InstallerExit } else { 1 })   # 退出码回传，远程/CI 判成败用
