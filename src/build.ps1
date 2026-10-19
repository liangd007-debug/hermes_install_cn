# build.ps1 —— hermes_install_cn 统一编译脚本（系统自带 csc，零工具链）
# 用法：
#   .\src\build.ps1            # 全部
#   .\src\build.ps1 -Only cli  # 只编命令行版
#   .\src\build.ps1 -Only gui  # 只编图形版
param([ValidateSet('all','cli','gui')][string]$Only = 'all')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot          # 项目根
$csc  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw ('找不到 csc.exe：' + $csc) }
$ps1  = Join-Path $root 'install-cn.ps1'          # 内嵌的安装脚本（唯一母本）
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (-not (Test-Path $ps1)) { throw ('缺少 install-cn.ps1：' + $ps1) }

if ($Only -in @('all','cli')) {
    & $csc /nologo /target:exe /platform:anycpu /optimize+ `
        /out:"$dist\hermes-install-cn.exe" `
        /resource:"$ps1",hermes_install_cn.installer.ps1 `
        (Join-Path $root 'src\cli\Program.cs')
    if ($LASTEXITCODE -ne 0) { throw 'CLI 编译失败' }
    Write-Host ("  [OK] CLI  → " + (Join-Path $dist 'hermes-install-cn.exe')) -ForegroundColor Green
}

if ($Only -in @('all','gui')) {
    & $csc /nologo /target:winexe /platform:anycpu /optimize+ `
        /r:System.Windows.Forms.dll /r:System.Drawing.dll `
        /out:"$dist\hermes-install-cn-gui.exe" `
        /resource:"$ps1",hermes_install_cn.installer.ps1 `
        (Join-Path $root 'src\gui\Program.cs')
    if ($LASTEXITCODE -ne 0) { throw 'GUI 编译失败' }
    Write-Host ("  [OK] GUI  → " + (Join-Path $dist 'hermes-install-cn-gui.exe')) -ForegroundColor Green
}

Get-ChildItem $dist -Filter '*.exe' | ForEach-Object {
    Write-Host ('  ' + $_.Name + '  ' + $_.Length + ' bytes  ' + $_.LastWriteTime.ToString('HH:mm:ss'))
}
