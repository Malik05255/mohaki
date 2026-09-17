param(
    [Parameter(Mandatory = $true)] [string]$JawalExe,
    [Parameter(Mandatory = $true)] [string]$JawalPkgExe,
    [double]$MinimumSwapsPerSecond = 30.0,
    [int]$TimeoutSeconds = 180,
    [string]$ReportPath = "dist/reports/windows-gpu-smoke.json"
)

$ErrorActionPreference = "Stop"
$jawal = (Resolve-Path $JawalExe).Path
$pkg = (Resolve-Path $JawalPkgExe).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null

$process = Start-Process -FilePath $jawal -PassThru
try {
    $health = & $probe -TimeoutSeconds $TimeoutSeconds -RequirePhoneFeatures
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $gpu = $null
    $last = ""

    do {
        $output = & $pkg gpu-result 2>$null
        $code = $LASTEXITCODE
        $text = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
        $last = $text
        if ($code -eq 0 -and $text.StartsWith("OK ")) {
            $json = $text.Substring(3)
            try {
                $candidate = $json | ConvertFrom-Json
                if ($candidate.ready) {
                    $gpu = $candidate
                    break
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $gpu) { throw "GPU probe did not complete. Last response: $last" }
    if (-not $gpu.passed) { throw "GPU probe reported failure: $($gpu | ConvertTo-Json -Compress)" }
    if ($gpu.softwareRenderer) { throw "Software renderer detected: $($gpu.renderer)" }
    if ([double]$gpu.swapsPerSecond -lt $MinimumSwapsPerSecond) {
        throw "GPU throughput below gate: $($gpu.swapsPerSecond) < $MinimumSwapsPerSecond swaps/s"
    }

    [ordered]@{
        passed = $true
        renderer = [string]$gpu.renderer
        vendor = [string]$gpu.vendor
        glVersion = [string]$gpu.glVersion
        softwareRenderer = [bool]$gpu.softwareRenderer
        frames = [int]$gpu.frames
        swapsPerSecond = [double]$gpu.swapsPerSecond
        minimumSwapsPerSecond = $MinimumSwapsPerSecond
        android = $health
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8

    Write-Host "PASS: accelerated guest GPU probe"
    Write-Host "Renderer: $($gpu.renderer)"
    Write-Host "Throughput: $($gpu.swapsPerSecond) swaps/s"
}
finally {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(15000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
