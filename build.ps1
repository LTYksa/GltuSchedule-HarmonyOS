# GltuSchedule HarmonyOS - one-command build script
#
# Usage:
#   .\build.ps1                 # build HAP
#   .\build.ps1 clean           # clean outputs
#
# hvigor needs Node (to run the build) and Java (for the packaging step).
# Both are taken from the DevEco Studio installation, nothing else required.
#
# NOTE: keep this file ASCII-only. Non-ASCII text in a .ps1 breaks the
# PowerShell parser on Windows when the file has no BOM.

param(
    [string]$Task = 'assembleHap',
    [string]$DevEcoHome = 'D:\DevEco Studio'
)

$ErrorActionPreference = 'Continue'

$sdk    = Join-Path $DevEcoHome 'sdk'
$node   = Join-Path $DevEcoHome 'tools\node'
$jbr    = Join-Path $DevEcoHome 'jbr'
$hvigor = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.bat'

foreach ($p in @($sdk, $node, $jbr, $hvigor)) {
    if (-not (Test-Path $p)) {
        Write-Host "[ERROR] missing component: $p" -ForegroundColor Red
        Write-Host "        check DevEco Studio install, or pass -DevEcoHome <path>" -ForegroundColor Red
        exit 1
    }
}

$env:DEVECO_SDK_HOME = $sdk
$env:NODE_HOME       = $node
$env:JAVA_HOME       = $jbr
$env:PATH            = "$jbr\bin;$node;$env:PATH"

$proj = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $proj

Write-Host ''
Write-Host "DevEco : $DevEcoHome" -ForegroundColor Cyan
Write-Host "SDK    : $sdk" -ForegroundColor Cyan
Write-Host "Task   : $Task" -ForegroundColor Cyan
Write-Host ''

& $hvigor $Task --no-daemon
$code = $LASTEXITCODE

Write-Host ''
if ($code -ne 0) {
    Write-Host "BUILD FAILED (exit $code) - see log above" -ForegroundColor Red
    exit $code
}

$hap = Get-ChildItem $proj -Recurse -Filter '*.hap' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($hap) {
    Write-Host "OUTPUT : $($hap.FullName)" -ForegroundColor Green
    Write-Host "SIZE   : $([math]::Round($hap.Length / 1KB, 2)) KB" -ForegroundColor Green
    Write-Host "BUILT  : $($hap.LastWriteTime)" -ForegroundColor Green
} else {
    Write-Host "No .hap found - check build log above." -ForegroundColor Yellow
}
