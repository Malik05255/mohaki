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
$dataDir = Join-Path $env:LOCALAPPDATA "Jawal"
$dataDisk = Join-Path $dataDir "data.qcow2"
$dataMarker = Join-Path $dataDir "data-independent-v1.marker"
$marker = Join-Path $dataDir "quickresume.marker"
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

function Assert-StandaloneData {
    if (-not (Test-Path -LiteralPath $dataDisk -PathType Leaf)) {
        throw "Jawal data disk is missing."
    }
    if (-not (Test-Path -LiteralPath $dataMarker -PathType Leaf)) {
        throw "Jawal data disk is missing standalone-data marker."
    }
    $raw = (& $qemuImg info --output=json $dataDisk) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "qemu-img info failed for data.qcow2." }
    $info = $raw | ConvertFrom-Json
    if (($info.PSObject.Properties.Name -contains 'backing-filename' -and $info.'backing-filename') -or
        ($info.PSObject.Properties.Name -contains 'full-backing-filename' -and $info.'full-backing-filename')) {
        throw "Quick Resume data disk unexpectedly depends on a backing file."
    }
    return $info
}

$first = Start-And-WaitReady -Exe $jawal -Timeout $TimeoutSeconds
$coldReadyMs = $first.ElapsedMs
Close-Gracefully $first.Process

if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw "Quick-resume marker was not created after graceful close."
}
$null = Assert-StandaloneData

$snapshotOutput = & $qemuImg snapshot -l $dataDisk 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "qemu-img snapshot listing failed." }
if ($snapshotOutput -notmatch 'jawal_quick_resume') {
    throw "Quick-resume VM snapshot is not present in data.qcow2."
}

$markerBeforeResumeUtc = (Get-Item -LiteralPath $marker).LastWriteTimeUtc
$second = Start-And-WaitReady -Exe $jawal -Timeout $TimeoutSeconds
$resumeReadyMs = $second.ElapsedMs
try {
    # VmController deletes this marker only when -loadvm fails and it retries a
    # cold boot. Check it while Android is running, before graceful shutdown can
    # create a fresh marker and accidentally hide a failed resume.
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw "Quick Resume fell back to a cold boot; the resume marker was invalidated during startup."
    }
    $markerDuringResumeUtc = (Get-Item -LiteralPath $marker).LastWriteTimeUtc
    if ($markerDuringResumeUtc -ne $markerBeforeResumeUtc) {
        throw "Quick-resume marker changed during startup; expected the existing snapshot marker to be consumed without replacement."
    }
    $null = Assert-StandaloneData
}
finally {
    Close-Gracefully $second.Process
}

if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw "Quick-resume marker was not refreshed after the resumed session closed."
}
$null = Assert-StandaloneData

$snapshotAfterOutput = & $qemuImg snapshot -l $dataDisk 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $snapshotAfterOutput -notmatch 'jawal_quick_resume') {
    throw "Quick-resume snapshot disappeared after the resumed session was saved again."
}

[ordered]@{
    passed = $true
    snapshotPresentBeforeResume = $true
    resumeUsedWithoutColdFallback = $true
    snapshotPresentAfterResume = $true
    dataRemainedStandalone = $true
    markerPresent = (Test-Path -LiteralPath $marker -PathType Leaf)
    coldReadyMs = $coldReadyMs
    resumeReadyMs = $resumeReadyMs
    resumedAndroid = $second.Health
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "PASS: quick-resume snapshot loaded without cold fallback and user data remained standalone."
Write-Host "Cold ready: ${coldReadyMs}ms; resume ready: ${resumeReadyMs}ms"
