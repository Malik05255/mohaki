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

    & $pkg arm64-reset
    if ($LASTEXITCODE -ne 0) { throw "Unable to reset ARM64 execution result channel." }

    $installStarted = Get-Date
    & $pkg install $apk
    $installCode = $LASTEXITCODE
    $installElapsed = [int]((Get-Date) - $installStarted).TotalMilliseconds
    if ($installCode -ne 0) {
        throw "ARM64 APK installation failed with exit code $installCode."
    }

    & $pkg launch com.jawal.arm64smoke
    if ($LASTEXITCODE -ne 0) { throw "ARM64 APK installed but could not be launched." }

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Min(60, $TimeoutSeconds))
    $executionPassed = $false
    do {
        & $pkg arm64-result *> $null
        if ($LASTEXITCODE -eq 0) {
            $executionPassed = $true
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $executionPassed) {
        throw "ARM64 native library installed and launched, but did not execute and return the expected value 42."
    }

    [ordered]@{
        passed = $true
        nativeCodeExecuted = $true
        nativeResult = 42
        nativeBridge = $nativeBridge
        abis = [string]$health.abis
        apk = (Split-Path -Leaf $apk)
        installElapsedMs = $installElapsed
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8

    Write-Host "PASS: ARM64 native code executed through $nativeBridge and returned 42."
}
finally {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(15000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
