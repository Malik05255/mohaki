param(
    [Parameter(Mandatory = $true)]
    [string]$JawalExe,
    [Parameter(Mandatory = $true)]
    [string]$SmokeApk,
    [int]$TimeoutSeconds = 180,
    [string]$ReportPath = "dist/reports/windows-functional-smoke.json"
)

$ErrorActionPreference = "Stop"
$jawalPath = (Resolve-Path $JawalExe).Path
$apkPath = (Resolve-Path $SmokeApk).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probeScript = Join-Path $PSScriptRoot "probe-guest.ps1"
$installScript = Join-Path $PSScriptRoot "install-smoke-apk.ps1"

$reportFile = Join-Path $repoRoot $ReportPath
$reportDir = Split-Path -Parent $reportFile
if ($reportDir) { New-Item $reportDir -ItemType Directory -Force | Out-Null }

$jawal = Start-Process -FilePath $jawalPath -PassThru
$started = [DateTime]::UtcNow
try {
    $health = & $probeScript \
        -TimeoutSeconds $TimeoutSeconds \
        -RequireWebView \
        -RequireNetwork \
        -RequireAudio \
        -RequirePhoneFeatures

    & $installScript -ApkPath $apkPath -TimeoutSeconds $TimeoutSeconds

    $report = [ordered]@{
        passed = $true
        apkInstallPassed = $true
        android = $health
        startedAtUtc = $started.ToString("o")
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding UTF8
    Write-Host "PASS: Jawal functional smoke completed, including PackageInstaller."
    Write-Host "Report: $reportFile"
}
finally {
    if ($jawal -and -not $jawal.HasExited) {
        $null = $jawal.CloseMainWindow()
        if (-not $jawal.WaitForExit(15000)) {
            Stop-Process -Id $jawal.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
