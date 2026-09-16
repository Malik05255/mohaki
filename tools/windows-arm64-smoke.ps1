param(
    [Parameter(Mandatory = $true)] [string]$JawalExe,
    [Parameter(Mandatory = $true)] [string]$JawalPkgExe,
    [Parameter(Mandatory = $true)] [string]$Arm64Apk,
    [int]$TimeoutSeconds = 240,
    [string]$ReportPath = "dist/reports/arm64-smoke.json"
)

$ErrorActionPreference = "Stop"
$jawal = (Resolve-Path $JawalExe).Path
$pkg = (Resolve-Path $JawalPkgExe).Path
$apk = (Resolve-Path $Arm64Apk).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null

$process = Start-Process -FilePath $jawal -PassThru
try {
    $health = & $probe -TimeoutSeconds $TimeoutSeconds -RequireWebView -RequireNetwork -RequirePhoneFeatures
    $nativeBridge = [string]$health.nativeBridge
    if ([string]::IsNullOrWhiteSpace($nativeBridge) -or $nativeBridge -eq "0") {
        throw "ARM64 stage requested but Android reports no active native bridge."
    }

    $started = Get-Date
    & $pkg install $apk
    $code = $LASTEXITCODE
    $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
    if ($code -ne 0) {
        throw "ARM64 APK installation failed with exit code $code."
    }

    [ordered]@{
        passed = $true
        nativeBridge = $nativeBridge
        abis = [string]$health.abis
        apk = (Split-Path -Leaf $apk)
        elapsedMs = $elapsed
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8

    Write-Host "PASS: ARM64 native-bridge smoke passed using $nativeBridge."
}
finally {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(15000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
