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

function Assert-StandaloneDataDisk {
    if (-not (Test-Path -LiteralPath $dataDisk -PathType Leaf)) {
        throw "Jawal did not create data.qcow2."
    }
    if (-not (Test-Path -LiteralPath $standaloneMarker -PathType Leaf)) {
        throw "Jawal data image is missing the standalone-data marker."
    }

    $json = (& $qemuImg info --output=json $dataDisk) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "qemu-img info failed for Jawal user data." }
    $info = $json | ConvertFrom-Json
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

# A fresh start must create independent sparse user data from the runtime
# template; the data image may not keep the runtime template as a backing file.
Reset-DataState
$first = Start-Process -FilePath $jawal -PassThru
try {
    $before = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    $firstImage = Assert-StandaloneDataDisk
    if ($before.smokeInstalled) { throw "Smoke app unexpectedly exists on pristine data disk." }

    & $pkg install $apk
    if ($LASTEXITCODE -ne 0) { throw "Unable to install smoke APK before factory reset." }
    Start-Sleep -Seconds 1
    $installed = & $probe -TimeoutSeconds 30
    if (-not $installed.smokeInstalled) { throw "Health probe did not observe smoke APK after installation." }
}
finally { Stop-Jawal $first }

$preResetBytes = (Get-Item $dataDisk).Length

# Simulate the destructive data lifecycle used by the factory-reset path. The
# next Jawal start must independently reconstruct a clean data image.
Reset-DataState
$second = Start-Process -FilePath $jawal -PassThru
try {
    $after = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    $secondImage = Assert-StandaloneDataDisk
    if ($after.smokeInstalled) { throw "Factory reset failed: smoke APK survived on the recreated data disk." }
    $postResetBytes = (Get-Item $dataDisk).Length

    [ordered]@{
        passed = $true
        installedBeforeReset = $true
        installedAfterReset = [bool]$after.smokeInstalled
        standaloneBeforeReset = -not [bool]$firstImage.'backing-filename'
        standaloneAfterReset = -not [bool]$secondImage.'backing-filename'
        preResetDataBytes = $preResetBytes
        postResetDataBytes = $postResetBytes
        android = $after
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8
    Write-Host "PASS: factory-reset lifecycle recreated clean standalone Android user data."
}
finally { Stop-Jawal $second }
