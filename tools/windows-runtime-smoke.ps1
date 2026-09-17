param(
    [Parameter(Mandatory = $true)]
    [string]$JawalExe,

    [int]$TimeoutSeconds = 180,
    [string]$ReportPath = "dist/reports/windows-runtime-smoke.json"
)

$ErrorActionPreference = "Stop"
$jawalPath = (Resolve-Path $JawalExe).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probeScript = Join-Path $PSScriptRoot "probe-guest.ps1"

$reportDirectory = Split-Path -Parent (Join-Path $repoRoot $ReportPath)
if ($reportDirectory) { New-Item $reportDirectory -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $repoRoot $ReportPath

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$jawal = Start-Process -FilePath $jawalPath -PassThru
$qemu = $null
$health = $null

try {
    $health = & $probeScript \
        -TimeoutSeconds $TimeoutSeconds \
        -RequireWebView \
        -RequireNetwork \
        -RequireAudio \
        -RequirePhoneFeatures

    $stopwatch.Stop()

    # QEMU is launched as a direct child of Jawal.exe. Resolve it by parent PID
    # first so unrelated QEMU instances on the host are never measured or killed.
    $qemuInfo = Get-CimInstance Win32_Process |
        Where-Object { $_.ParentProcessId -eq $jawal.Id -and $_.Name -ieq "qemu-system-x86_64.exe" } |
        Select-Object -First 1
    if ($qemuInfo) {
        $qemu = Get-Process -Id $qemuInfo.ProcessId -ErrorAction SilentlyContinue
    }

    $workingSetMiB = if ($qemu) { [Math]::Round($qemu.WorkingSet64 / 1MB, 1) } else { $null }
    $privateMiB = if ($qemu) { [Math]::Round($qemu.PrivateMemorySize64 / 1MB, 1) } else { $null }

    $report = [ordered]@{
        passed = $true
        bootReadySeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        jawalPid = $jawal.Id
        qemuPid = if ($qemu) { $qemu.Id } else { $null }
        qemuWorkingSetMiB = $workingSetMiB
        qemuPrivateMiB = $privateMiB
        android = $health
        measuredAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding UTF8
    Write-Host "Jawal runtime smoke passed. Android ready in $($report.bootReadySeconds)s"
    if ($qemu) {
        Write-Host "QEMU working set: $workingSetMiB MiB; private: $privateMiB MiB"
    }
    Write-Host "Report: $reportFile"
}
finally {
    if ($jawal -and -not $jawal.HasExited) {
        $null = $jawal.CloseMainWindow()
        if (-not $jawal.WaitForExit(15000)) {
            Stop-Process -Id $jawal.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
