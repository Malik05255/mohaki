param(
    [Parameter(Mandatory = $true)] [string]$JawalExe,
    [int]$TimeoutSeconds = 180,
    [string]$ReportPath = "dist/reports/windows-quick-resume-smoke.json"
)

$ErrorActionPreference = "Stop"
$jawal = (Resolve-Path $JawalExe).Path
$root = Split-Path -Parent $jawal
$runtime = Join-Path $root "runtime"
$qemuImg = Join-Path $runtime "qemu\qemu-img.exe"
$dataDisk = Join-Path (Join-Path $env:LOCALAPPDATA "Jawal") "data.qcow2"
$marker = Join-Path (Join-Path $env:LOCALAPPDATA "Jawal") "quickresume.marker"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null

if (-not (Test-Path -LiteralPath $qemuImg -PathType Leaf)) { throw "qemu-img missing: $qemuImg" }
Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

function Start-And-WaitReady {
    param([string]$Exe, [int]$Timeout)
    $started = [DateTime]::UtcNow
    $process = Start-Process -FilePath $Exe -PassThru
    try {
        $health = & $probe -TimeoutSeconds $Timeout -RequirePhoneFeatures
        $elapsed = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
        return [pscustomobject]@{ Process = $process; Health = $health; ElapsedMs = $elapsed }
    } catch {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Close-Gracefully($process) {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(45000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "Jawal did not exit after saving quick-resume state."
        }
    }
}

$first = Start-And-WaitReady -Exe $jawal -Timeout $TimeoutSeconds
$coldReadyMs = $first.ElapsedMs
Close-Gracefully $first.Process

if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw "Quick-resume marker was not created after graceful close."
}
if (-not (Test-Path -LiteralPath $dataDisk -PathType Leaf)) {
    throw "Jawal data disk missing after first boot."
}

$snapshotOutput = & $qemuImg snapshot -l $dataDisk 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "qemu-img snapshot listing failed." }
if ($snapshotOutput -notmatch 'jawal_quick_resume') {
    throw "Quick-resume VM snapshot is not present in data.qcow2."
}

$second = Start-And-WaitReady -Exe $jawal -Timeout $TimeoutSeconds
$resumeReadyMs = $second.ElapsedMs
Close-Gracefully $second.Process

[ordered]@{
    passed = $true
    snapshotPresent = $true
    markerPresent = (Test-Path -LiteralPath $marker -PathType Leaf)
    coldReadyMs = $coldReadyMs
    resumeReadyMs = $resumeReadyMs
    resumedAndroid = $second.Health
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "PASS: quick-resume snapshot saved and restored."
Write-Host "Cold ready: ${coldReadyMs}ms; resume ready: ${resumeReadyMs}ms"
