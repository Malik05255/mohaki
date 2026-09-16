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
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null
New-Item $dataDir -ItemType Directory -Force | Out-Null

foreach ($required in @($qemuImg, $template)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing reset dependency: $required" }
}

function New-CleanDataDisk {
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $dataDisk -Force -ErrorAction SilentlyContinue
    & $qemuImg create -f qcow2 -F qcow2 -b $template $dataDisk
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dataDisk)) { throw "Unable to create clean Jawal data overlay." }
}

function Stop-Jawal($process) {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(15000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}

New-CleanDataDisk
$first = Start-Process -FilePath $jawal -PassThru
try {
    $before = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    if ($before.smokeInstalled) { throw "Smoke app unexpectedly exists on pristine data disk." }

    & $pkg install $apk
    if ($LASTEXITCODE -ne 0) { throw "Unable to install smoke APK before factory reset." }
    Start-Sleep -Seconds 1
    $installed = & $probe -TimeoutSeconds 30
    if (-not $installed.smokeInstalled) { throw "Health probe did not observe smoke APK after installation." }
}
finally { Stop-Jawal $first }

$preResetBytes = (Get-Item $dataDisk).Length
New-CleanDataDisk
$postResetBytes = (Get-Item $dataDisk).Length

$second = Start-Process -FilePath $jawal -PassThru
try {
    $after = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    if ($after.smokeInstalled) { throw "Factory reset failed: smoke APK survived on the recreated data disk." }

    [ordered]@{
        passed = $true
        installedBeforeReset = $true
        installedAfterReset = [bool]$after.smokeInstalled
        preResetOverlayBytes = $preResetBytes
        postResetOverlayBytes = $postResetBytes
        android = $after
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8
    Write-Host "PASS: factory-reset lifecycle recreated a clean Android data environment."
}
finally { Stop-Jawal $second }
