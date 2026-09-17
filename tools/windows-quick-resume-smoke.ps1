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
$sessionTokenPath = Join-Path $dataDir "session.token"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null

if (-not (Test-Path -LiteralPath $qemuImg -PathType Leaf)) { throw "qemu-img missing: $qemuImg" }
Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $sessionTokenPath -Force -ErrorAction SilentlyContinue

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

function Assert-V3Marker {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw "Quick-resume marker is missing."
    }
    $lines = @(Get-Content -LiteralPath $marker)
    if ($lines.Count -lt 3 -or $lines[0] -ne 'jawal_quick_resume_v3' -or
        $lines[1] -notmatch '^runtime=[0-9a-f]{64}$' -or
        $lines[2] -notmatch '^session=[0-9a-f]{64}$') {
        throw "Quick-resume marker is not bound to runtime and authenticated session fingerprints."
    }
    return [pscustomobject]@{
        Runtime = $lines[1].Substring('runtime='.Length)
        Session = $lines[2].Substring('session='.Length)
    }
}

function Assert-LiveSessionToken([string]$Expected) {
    if (-not (Test-Path -LiteralPath $sessionTokenPath -PathType Leaf)) {
        throw "Live authenticated session token is missing while Jawal is running."
    }
    $actual = (Get-Content -LiteralPath $sessionTokenPath -Raw).Trim()
    if ($actual -notmatch '^[0-9a-f]{64}$') { throw "Live session token is malformed." }
    if ($Expected -and $actual -ne $Expected) {
        throw "Live session token does not match the Quick Resume snapshot session."
    }
    return $actual
}

$first = Start-And-WaitReady -Exe $jawal -Timeout $TimeoutSeconds
$coldReadyMs = $first.ElapsedMs
$firstLiveSession = Assert-LiveSessionToken ""
Close-Gracefully $first.Process

$firstMarker = Assert-V3Marker
if ($firstMarker.Session -ne $firstLiveSession) {
    throw "Saved Quick Resume marker did not preserve the cold-boot authenticated session token."
}
if (Test-Path -LiteralPath $sessionTokenPath -PathType Leaf) {
    throw "Session token file survived after Jawal/QEMU shutdown."
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
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw "Quick Resume fell back to a cold boot; the resume marker was invalidated during startup."
    }
    $markerDuringResumeUtc = (Get-Item -LiteralPath $marker).LastWriteTimeUtc
    if ($markerDuringResumeUtc -ne $markerBeforeResumeUtc) {
        throw "Quick-resume marker changed during startup; expected the existing snapshot marker to remain unchanged."
    }
    $resumedLiveSession = Assert-LiveSessionToken $firstMarker.Session
    $null = Assert-StandaloneData
}
finally {
    Close-Gracefully $second.Process
}

$secondMarker = Assert-V3Marker
if ($secondMarker.Runtime -ne $firstMarker.Runtime -or $secondMarker.Session -ne $firstMarker.Session) {
    throw "Quick Resume did not preserve its runtime/session identity across the resumed session."
}
if (Test-Path -LiteralPath $sessionTokenPath -PathType Leaf) {
    throw "Session token file survived after resumed Jawal shutdown."
}
$null = Assert-StandaloneData

$snapshotAfterOutput = & $qemuImg snapshot -l $dataDisk 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $snapshotAfterOutput -notmatch 'jawal_quick_resume') {
    throw "Quick-resume snapshot disappeared after the resumed session was saved again."
}

# Corrupt only the runtime authorization fingerprint while retaining the old
# session token. Jawal must reject the whole snapshot and generate a fresh cold-
# boot session rather than trusting the stale in-memory Android state.
@(
    'jawal_quick_resume_v3',
    ('runtime=' + ('0' * 64)),
    ('session=' + $secondMarker.Session)
) | Set-Content -LiteralPath $marker -Encoding ascii

$third = Start-And-WaitReady -Exe $jawal -Timeout $TimeoutSeconds
$runtimeMismatchColdReadyMs = $third.ElapsedMs
try {
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        throw "Jawal did not invalidate a quick-resume marker from a different runtime fingerprint."
    }
    $freshColdSession = Assert-LiveSessionToken ""
    if ($freshColdSession -eq $secondMarker.Session) {
        throw "Cold boot after stale snapshot rejection reused the old authenticated session token."
    }
    $null = Assert-StandaloneData
}
finally {
    Close-Gracefully $third.Process
}

$recoveredMarker = Assert-V3Marker
if ($recoveredMarker.Runtime -ne $firstMarker.Runtime) {
    throw "Cold boot after runtime mismatch did not write the current runtime fingerprint."
}
if ($recoveredMarker.Session -eq $secondMarker.Session) {
    throw "Cold boot after runtime mismatch did not rotate the authenticated session token."
}
if (Test-Path -LiteralPath $sessionTokenPath -PathType Leaf) {
    throw "Session token file survived after final Jawal shutdown."
}

[ordered]@{
    passed = $true
    snapshotPresentBeforeResume = $true
    resumeUsedWithoutColdFallback = $true
    snapshotPresentAfterResume = $true
    runtimeFingerprintBoundMarker = $true
    sessionTokenBoundMarker = $true
    sessionTokenReusedOnlyForResume = $true
    sessionTokenRemovedOnShutdown = $true
    mismatchedRuntimeMarkerRejected = $true
    freshSessionAfterColdFallback = $true
    freshMarkerWrittenAfterColdFallback = $true
    dataRemainedStandalone = $true
    markerPresent = (Test-Path -LiteralPath $marker -PathType Leaf)
    runtimeFingerprint = $recoveredMarker.Runtime
    coldReadyMs = $coldReadyMs
    resumeReadyMs = $resumeReadyMs
    runtimeMismatchColdReadyMs = $runtimeMismatchColdReadyMs
    resumedAndroid = $second.Health
    coldAfterMismatchAndroid = $third.Health
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "PASS: Quick Resume is runtime-bound, session-authenticated and rotates credentials after cold fallback."
Write-Host "Cold: ${coldReadyMs}ms; resume: ${resumeReadyMs}ms; mismatch cold boot: ${runtimeMismatchColdReadyMs}ms"
