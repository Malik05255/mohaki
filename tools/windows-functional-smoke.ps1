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
$sessionAuthScript = Join-Path $PSScriptRoot "windows-session-auth-smoke.ps1"
$sessionAuthReportRelative = "dist/reports/session-auth-smoke.json"
$sessionAuthReport = Join-Path $repoRoot $sessionAuthReportRelative

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

    # Before exercising the authorized PackageInstaller path, prove that every
    # host-forwarded localhost bridge rejects clients that do not possess the
    # per-boot 256-bit Jawal session token.
    & $sessionAuthScript -ReportPath $sessionAuthReportRelative
    if (-not (Test-Path -LiteralPath $sessionAuthReport -PathType Leaf)) {
        throw "Session authentication smoke did not produce its evidence report."
    }
    $sessionAuth = Get-Content -LiteralPath $sessionAuthReport -Raw | ConvertFrom-Json
    if (-not $sessionAuth.passed) {
        throw "Session authentication smoke reported passed=false."
    }

    & $installScript -ApkPath $apkPath -TimeoutSeconds $TimeoutSeconds

    # Re-probe after the negative-auth traffic and authorized APK install. This
    # proves rejected clients did not destabilize or poison the live bridge.
    $healthAfter = & $probeScript \
        -TimeoutSeconds 30 \
        -RequireWebView \
        -RequireNetwork \
        -RequireAudio \
        -RequirePhoneFeatures

    $report = [ordered]@{
        passed = $true
        apkInstallPassed = $true
        sessionAuthenticationPassed = $true
        sessionAuthentication = $sessionAuth
        android = $healthAfter
        initialAndroid = $health
        startedAtUtc = $started.ToString("o")
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding UTF8
    Write-Host "PASS: Jawal functional smoke completed, including authenticated bridges and PackageInstaller."
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
