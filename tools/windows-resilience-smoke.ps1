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
$dataDisk = Join-Path (Join-Path $env:LOCALAPPDATA "Jawal") "data.qcow2"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null

if (-not (Test-Path -LiteralPath $qemuImg -PathType Leaf)) { throw "qemu-img missing: $qemuImg" }

function Stop-Jawal($process) {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(10000) | Out-Null
    }
}

$cyclesOut = @()
$initial = Start-Process -FilePath $jawal -PassThru
try {
    $null = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    & $pkg install $apk
    if ($LASTEXITCODE -ne 0) { throw "Unable to install smoke app before resilience cycles." }
    Start-Sleep -Seconds 3
    $installed = & $probe -TimeoutSeconds 30
    if (-not $installed.smokeInstalled) { throw "Smoke app was not observed before forced-stop cycles." }
}
finally {
    if ($initial -and -not $initial.HasExited) {
        $null = $initial.CloseMainWindow()
        if (-not $initial.WaitForExit(15000)) { Stop-Process -Id $initial.Id -Force -ErrorAction SilentlyContinue }
    }
}

for ($i = 1; $i -le $Cycles; $i++) {
    $process = Start-Process -FilePath $jawal -PassThru
    try {
        $healthBefore = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
        Start-Sleep -Seconds 2

        $qemu = Get-Process qemu-system-x86_64 -ErrorAction Stop | Select-Object -First 1
        Stop-Process -Id $qemu.Id -Force
        $qemu.WaitForExit(10000) | Out-Null
        Start-Sleep -Milliseconds 750

        & $qemuImg check $dataDisk | Out-Host
        $checkCode = $LASTEXITCODE
        if ($checkCode -ne 0) { throw "qemu-img check failed after forced QEMU stop in cycle $i." }
    }
    finally { Stop-Jawal $process }

    $restart = Start-Process -FilePath $jawal -PassThru
    try {
        $healthAfter = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
        if (-not $healthAfter.smokeInstalled) {
            throw "Installed app state was lost after forced-stop recovery in cycle $i."
        }
        $cyclesOut += [pscustomobject]@{
            cycle = $i
            qcow2CheckExitCode = 0
            readyAfterRestart = [bool]$healthAfter.ready
            smokeInstalledAfterRestart = [bool]$healthAfter.smokeInstalled
            dataFreeBytes = [long]$healthAfter.dataFreeBytes
        }
    }
    finally {
        if ($restart -and -not $restart.HasExited) {
            $null = $restart.CloseMainWindow()
            if (-not $restart.WaitForExit(15000)) { Stop-Process -Id $restart.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}

[ordered]@{
    passed = $true
    cycles = $Cycles
    results = $cyclesOut
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "PASS: $Cycles forced-stop/data-integrity cycles completed successfully."
