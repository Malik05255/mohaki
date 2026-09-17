param(
    [Parameter(Mandatory = $true)] [string]$JawalExe,
    [Parameter(Mandatory = $true)] [string]$JawalPkgExe,
    [Parameter(Mandatory = $true)] [string]$SmokeApk,
    [int]$TimeoutSeconds = 240,
    [string]$ReportPath = "dist/reports/factory-reset-smoke.json"
)

$ErrorActionPreference = "Stop"
if ($env:JAWAL_DESTRUCTIVE_TESTS -ne "1") {
    throw "Factory-reset smoke is destructive. Set JAWAL_DESTRUCTIVE_TESTS=1 only on a dedicated test runner."
}

$jawal = (Resolve-Path $JawalExe).Path
$pkg = (Resolve-Path $JawalPkgExe).Path
$apk = (Resolve-Path $SmokeApk).Path
$root = Split-Path -Parent $jawal
$runtime = Join-Path $root "runtime"
$qemuImg = Join-Path $runtime "qemu\qemu-img.exe"
$template = Join-Path $runtime "images\jawal-data-template.qcow2"
$dataDir = Join-Path $env:LOCALAPPDATA "Jawal"
$dataDisk = Join-Path $dataDir "data.qcow2"
$standaloneMarker = Join-Path $dataDir "data-independent-v1.marker"
$creatingData = "$dataDisk.creating"
$previousData = "$dataDisk.pre-standalone"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null
New-Item $dataDir -ItemType Directory -Force | Out-Null

foreach ($required in @($qemuImg, $template)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing reset dependency: $required" }
}

function Reset-DataState {
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    foreach ($path in @($dataDisk, $standaloneMarker, $creatingData, $previousData)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-DataImageInfo {
    param([Parameter(Mandatory = $true)] [string]$Path)
    $json = (& $qemuImg info --output=json $Path) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "qemu-img info failed for $Path." }
    return $json | ConvertFrom-Json
}

function Assert-StandaloneDataDisk {
    if (-not (Test-Path -LiteralPath $dataDisk -PathType Leaf)) {
        throw "Jawal did not create data.qcow2."
    }
    if (-not (Test-Path -LiteralPath $standaloneMarker -PathType Leaf)) {
        throw "Jawal data image is missing the standalone-data marker."
    }

    $info = Get-DataImageInfo -Path $dataDisk
    if ($info.PSObject.Properties.Name -contains 'backing-filename' -and $info.'backing-filename') {
        throw "Jawal user data still depends on backing file: $($info.'backing-filename')"
    }
    if ($info.PSObject.Properties.Name -contains 'full-backing-filename' -and $info.'full-backing-filename') {
        throw "Jawal user data still has a full backing path: $($info.'full-backing-filename')"
    }

    & $qemuImg check $dataDisk | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Standalone Jawal data image failed qemu-img check." }
    return $info
}

function Stop-Jawal($process) {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(15000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}

# Recreate the historical Jawal layout: a user-data overlay backed directly by
# the runtime template. Current Jawal must flatten this before Android boots so
# future runtime upgrades cannot invalidate the user's data chain.
Reset-DataState
& $qemuImg create -f qcow2 -F qcow2 -b $template $dataDisk | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dataDisk)) {
    throw "Unable to create legacy Jawal data overlay fixture."
}
$legacyInfo = Get-DataImageInfo -Path $dataDisk
if (-not $legacyInfo.'backing-filename') {
    throw "Legacy migration fixture unexpectedly has no backing file."
}

$first = Start-Process -FilePath $jawal -PassThru
try {
    $before = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    $firstImage = Assert-StandaloneDataDisk
    if ($before.smokeInstalled) { throw "Smoke app unexpectedly exists on migrated pristine data disk." }

    & $pkg install $apk
    if ($LASTEXITCODE -ne 0) { throw "Unable to install smoke APK before factory reset." }
    Start-Sleep -Seconds 1
    $installed = & $probe -TimeoutSeconds 30
    if (-not $installed.smokeInstalled) { throw "Health probe did not observe smoke APK after installation." }
}
finally { Stop-Jawal $first }

$preResetBytes = (Get-Item $dataDisk).Length

# Simulate the destructive data lifecycle used by the factory-reset path. The
# next Jawal start has no data disk and must independently reconstruct a clean
# standalone image from the template.
Reset-DataState
$second = Start-Process -FilePath $jawal -PassThru
try {
    $after = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    $secondImage = Assert-StandaloneDataDisk
    if ($after.smokeInstalled) { throw "Factory reset failed: smoke APK survived on the recreated data disk." }
    $postResetBytes = (Get-Item $dataDisk).Length

    [ordered]@{
        passed = $true
        legacyBackingFixture = [string]$legacyInfo.'backing-filename'
        legacyOverlayMigrated = -not [bool]$firstImage.'backing-filename'
        installedBeforeReset = $true
        installedAfterReset = [bool]$after.smokeInstalled
        standaloneBeforeReset = -not [bool]$firstImage.'backing-filename'
        standaloneAfterReset = -not [bool]$secondImage.'backing-filename'
        preResetDataBytes = $preResetBytes
        postResetDataBytes = $postResetBytes
        android = $after
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8
    Write-Host "PASS: legacy data migrated and factory reset recreated clean standalone Android user data."
}
finally { Stop-Jawal $second }
