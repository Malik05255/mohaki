param(
    [Parameter(Mandatory = $true)] [string]$JawalExe,
    [Parameter(Mandatory = $true)] [string]$JawalPkgExe,
    [Parameter(Mandatory = $true)] [string]$SmokeApk,
    [int]$Cycles = 3,
    [int]$TimeoutSeconds = 240,
    [string]$ReportPath = "dist/reports/resilience-smoke.json"
)

$ErrorActionPreference = "Stop"
if ($env:JAWAL_DESTRUCTIVE_TESTS -ne "1") {
    throw "Resilience smoke is destructive. Set JAWAL_DESTRUCTIVE_TESTS=1 only on a dedicated test runner."
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
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null
New-Item $dataDir -ItemType Directory -Force | Out-Null

foreach ($required in @($qemuImg, $template, $pkg)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing resilience dependency: $required" }
}

function Stop-AllJawalProcesses {
    Get-Process Jawal -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 750
}

function Clear-TestDataState {
    Stop-AllJawalProcesses
    foreach ($path in @(
        $dataDisk,
        $standaloneMarker,
        $quickResumeMarker,
        "$dataDisk.creating",
        "$dataDisk.pre-standalone",
        (Join-Path $dataDir "data.previous.qcow2"),
        (Join-Path $dataDir "data.restore.tmp.qcow2"),
        (Join-Path $dataDir "data.compact.tmp.qcow2")
    )) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Clear-QuickResume {
    Remove-Item -LiteralPath $quickResumeMarker -Force -ErrorAction SilentlyContinue
}

function Stop-JawalGracefully($process) {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(15000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Assert-StandaloneData {
    if (-not (Test-Path -LiteralPath $dataDisk -PathType Leaf)) {
        throw "Jawal data.qcow2 is missing."
    }
    if (-not (Test-Path -LiteralPath $standaloneMarker -PathType Leaf)) {
        throw "Jawal standalone-data marker is missing."
    }

    $raw = (& $qemuImg info --output=json $dataDisk) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "qemu-img info failed for data.qcow2." }
    $info = $raw | ConvertFrom-Json
    if (($info.PSObject.Properties.Name -contains 'backing-filename' -and $info.'backing-filename') -or
        ($info.PSObject.Properties.Name -contains 'full-backing-filename' -and $info.'full-backing-filename')) {
        throw "User data regained a backing-file dependency during resilience testing."
    }

    & $qemuImg check $dataDisk | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed for standalone user data." }
    return $info
}

# Stage 9 must not inherit whatever data Stage 8 happened to leave on a reused
# hardware runner. Start from a deterministic clean standalone Jawal device.
Clear-TestDataState
$initial = Start-Process -FilePath $jawal -PassThru
try {
    $initialHealth = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    $null = Assert-StandaloneData
    if ($initialHealth.smokeInstalled) { throw "Smoke app unexpectedly exists in the clean resilience fixture." }

    & $pkg install $apk
    if ($LASTEXITCODE -ne 0) { throw "Unable to install smoke app before resilience cycles." }
    Start-Sleep -Seconds 2
    $installed = & $probe -TimeoutSeconds 30 -RequirePhoneFeatures
    if (-not $installed.smokeInstalled) { throw "Smoke app was not observed before forced-stop cycles." }
}
finally {
    Stop-JawalGracefully $initial
    Clear-QuickResume
}

$cyclesOut = @()
for ($i = 1; $i -le $Cycles; $i++) {
    $process = Start-Process -FilePath $jawal -PassThru
    try {
        $healthBefore = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
        if (-not $healthBefore.smokeInstalled) {
            throw "Installed app state was missing before resilience cycle $i."
        }

        # Give RuntimeWatchdog enough time to observe one successful PING and
        # enter its armed 5-second monitoring loop before simulating QEMU death.
        Start-Sleep -Seconds 7
        $qemuBefore = Get-Process qemu-system-x86_64 -ErrorAction Stop | Select-Object -First 1
        $oldPid = $qemuBefore.Id
        $startedRecovery = [DateTime]::UtcNow
        Stop-Process -Id $oldPid -Force
        $qemuBefore.WaitForExit(10000) | Out-Null

        # Jawal.exe stays alive. The watchdog must cold-recover Android itself.
        $healthRecovered = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
        $recoverySeconds = ([DateTime]::UtcNow - $startedRecovery).TotalSeconds
        if (-not $healthRecovered.smokeInstalled) {
            throw "Installed app state was lost after watchdog recovery in cycle $i."
        }

        $qemuAfter = Get-Process qemu-system-x86_64 -ErrorAction Stop | Select-Object -First 1
        if ($qemuAfter.Id -eq $oldPid) {
            throw "Watchdog recovery did not create a new QEMU process in cycle $i."
        }

        $cyclesOut += [pscustomobject]@{
            cycle = $i
            oldQemuPid = $oldPid
            recoveredQemuPid = $qemuAfter.Id
            watchdogRecoverySeconds = [Math]::Round($recoverySeconds, 2)
            readyAfterRecovery = [bool]$healthRecovered.ready
            smokeInstalledAfterRecovery = [bool]$healthRecovered.smokeInstalled
            dataFreeBytes = [long]$healthRecovered.dataFreeBytes
        }
    }
    finally {
        Stop-JawalGracefully $process
        Clear-QuickResume
    }

    # Integrity checks are intentionally offline so qemu-img never races a
    # watchdog restart or a guest with the data disk open.
    $null = Assert-StandaloneData
}

[ordered]@{
    passed = $true
    cycles = $Cycles
    automaticWatchdogRecovery = $true
    dataRemainedStandalone = $true
    results = $cyclesOut
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "PASS: $Cycles hard-QEMU-crash cycles auto-recovered and preserved standalone user data."
