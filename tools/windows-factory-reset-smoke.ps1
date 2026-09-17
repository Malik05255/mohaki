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
$quickResumeMarker = Join-Path $dataDir "quickresume.marker"
$creatingData = "$dataDisk.creating"
$previousData = "$dataDisk.pre-standalone"
$atomicPrevious = Join-Path $dataDir "data.previous.qcow2"
$restoreTemporary = Join-Path $dataDir "data.restore.tmp.qcow2"
$compactTemporary = Join-Path $dataDir "data.compact.tmp.qcow2"
$backupDir = Join-Path $dataDir "backups"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null
New-Item $dataDir -ItemType Directory -Force | Out-Null

foreach ($required in @($qemuImg, $template, $pkg)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing reset dependency: $required" }
}

function Stop-QemuProcesses {
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Clear-QuickResume {
    Remove-Item -LiteralPath $quickResumeMarker -Force -ErrorAction SilentlyContinue
}

function Reset-DataState {
    Stop-QemuProcesses
    foreach ($path in @(
        $dataDisk,
        $standaloneMarker,
        $quickResumeMarker,
        $creatingData,
        $previousData,
        $atomicPrevious,
        $restoreTemporary,
        $compactTemporary
    )) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-DataImageInfo {
    param([Parameter(Mandatory = $true)] [string]$Path)
    $json = (& $qemuImg info --output=json $Path) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "qemu-img info failed for $Path." }
    return $json | ConvertFrom-Json
}

function Assert-QcowStandalone {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [switch]$RequireDataMarker
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected QCOW2 image is missing: $Path"
    }
    if ($RequireDataMarker -and -not (Test-Path -LiteralPath $standaloneMarker -PathType Leaf)) {
        throw "Jawal data image is missing the standalone-data marker."
    }

    $info = Get-DataImageInfo -Path $Path
    if ($info.PSObject.Properties.Name -contains 'backing-filename' -and $info.'backing-filename') {
        throw "QCOW2 image still depends on backing file: $($info.'backing-filename')"
    }
    if ($info.PSObject.Properties.Name -contains 'full-backing-filename' -and $info.'full-backing-filename') {
        throw "QCOW2 image still has a full backing path: $($info.'full-backing-filename')"
    }

    & $qemuImg check $Path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "QCOW2 image failed qemu-img check: $Path" }
    return $info
}

function Assert-NoTransitionArtifacts {
    foreach ($path in @($creatingData, $previousData, $atomicPrevious, $restoreTemporary, $compactTemporary)) {
        if (Test-Path -LiteralPath $path) {
            throw "Data lifecycle left temporary artifact behind: $path"
        }
    }
}

function Stop-Jawal($process) {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(15000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    Stop-QemuProcesses
}

function Run-Maintenance {
    param(
        [Parameter(Mandatory = $true)] [string]$Command
    )
    & $pkg $Command $runtime $dataDir
    if ($LASTEXITCODE -ne 0) {
        throw "JawalPkg $Command failed with exit code $LASTEXITCODE."
    }
}

# Recreate the historical Jawal layout: a user-data overlay backed directly by
# the runtime template. Current Jawal must flatten this before Android boots so
# future runtime upgrades cannot invalidate the user's data chain.
Reset-DataState
Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
& $qemuImg create -f qcow2 -F qcow2 -b $template $dataDisk | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dataDisk)) {
    throw "Unable to create legacy Jawal data overlay fixture."
}
$legacyInfo = Get-DataImageInfo -Path $dataDisk
if (-not $legacyInfo.'backing-filename') {
    throw "Legacy migration fixture unexpectedly has no backing file."
}

# 1) Boot the old layout. Jawal must migrate it before exposing Android.
$first = Start-Process -FilePath $jawal -PassThru
try {
    $before = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    $migratedImage = Assert-QcowStandalone -Path $dataDisk -RequireDataMarker
    Assert-NoTransitionArtifacts
    if ($before.smokeInstalled) { throw "Smoke app unexpectedly exists on migrated pristine data disk." }

    & $pkg install $apk
    if ($LASTEXITCODE -ne 0) { throw "Unable to install smoke APK before backup/reset." }
    Start-Sleep -Seconds 1
    $installed = & $probe -TimeoutSeconds 30
    if (-not $installed.smokeInstalled) { throw "Health probe did not observe smoke APK after installation." }
}
finally { Stop-Jawal $first }

$preResetBytes = (Get-Item $dataDisk).Length
Clear-QuickResume

# 2) Exercise the actual C++ backup implementation used by Jawal.exe.
Run-Maintenance -Command "backup-data"
$backup = Get-ChildItem -LiteralPath $backupDir -Filter *.qcow2 -File |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if (-not $backup) { throw "Jawal backup command succeeded without producing a QCOW2 backup." }
$backupImage = Assert-QcowStandalone -Path $backup.FullName
Assert-NoTransitionArtifacts

# 3) Simulate the destructive factory-reset lifecycle. The next Jawal start has
# no data disk and must independently reconstruct a clean standalone image.
Reset-DataState
$second = Start-Process -FilePath $jawal -PassThru
try {
    $afterReset = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    $resetImage = Assert-QcowStandalone -Path $dataDisk -RequireDataMarker
    Assert-NoTransitionArtifacts
    if ($afterReset.smokeInstalled) { throw "Factory reset failed: smoke APK survived on the recreated data disk." }
    $postResetBytes = (Get-Item $dataDisk).Length
}
finally { Stop-Jawal $second }
Clear-QuickResume

# 4) Restore through DeviceMaintenance.cpp. The restored disk must remain fully
# independent and the previously installed app must come back after a cold boot.
Run-Maintenance -Command "restore-data"
$restoredImage = Assert-QcowStandalone -Path $dataDisk -RequireDataMarker
Assert-NoTransitionArtifacts

$third = Start-Process -FilePath $jawal -PassThru
try {
    $afterRestore = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    if (-not $afterRestore.smokeInstalled) {
        throw "Backup restore completed but the installed smoke APK did not return."
    }
}
finally { Stop-Jawal $third }
Clear-QuickResume

# 5) Compact through the same C++ maintenance code and prove the data remains
# bootable, standalone and semantically unchanged afterward.
$preCompactBytes = (Get-Item $dataDisk).Length
Run-Maintenance -Command "compact-data"
$compactedImage = Assert-QcowStandalone -Path $dataDisk -RequireDataMarker
Assert-NoTransitionArtifacts
$postCompactBytes = (Get-Item $dataDisk).Length

$fourth = Start-Process -FilePath $jawal -PassThru
try {
    $afterCompact = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    if (-not $afterCompact.smokeInstalled) {
        throw "Storage compaction lost the restored smoke APK."
    }

    [ordered]@{
        passed = $true
        legacyBackingFixture = [string]$legacyInfo.'backing-filename'
        legacyOverlayMigrated = -not [bool]$migratedImage.'backing-filename'
        backupCreated = $true
        backupStandalone = -not [bool]$backupImage.'backing-filename'
        backupPath = $backup.FullName
        installedBeforeReset = $true
        installedAfterReset = [bool]$afterReset.smokeInstalled
        restoredInstalledApp = [bool]$afterRestore.smokeInstalled
        compactedInstalledApp = [bool]$afterCompact.smokeInstalled
        standaloneAfterMigration = -not [bool]$migratedImage.'backing-filename'
        standaloneAfterReset = -not [bool]$resetImage.'backing-filename'
        standaloneAfterRestore = -not [bool]$restoredImage.'backing-filename'
        standaloneAfterCompact = -not [bool]$compactedImage.'backing-filename'
        preResetDataBytes = $preResetBytes
        postResetDataBytes = $postResetBytes
        preCompactDataBytes = $preCompactBytes
        postCompactDataBytes = $postCompactBytes
        android = $afterCompact
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8
    Write-Host "PASS: migration, backup, reset, restore and compaction preserved standalone Jawal user data."
}
finally {
    Stop-Jawal $fourth
    Clear-QuickResume
}
