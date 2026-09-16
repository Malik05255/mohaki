param(
    [Parameter(Mandatory = $true)] [string]$JawalExe,
    [Parameter(Mandatory = $true)] [string]$JawalPkgExe,
    [Parameter(Mandatory = $true)] [string]$ApkDirectory,
    [double]$MinimumPassRate = 0.90,
    [int]$TimeoutSeconds = 240,
    [string]$ReportPath = "dist/reports/apk-matrix.json"
)

$ErrorActionPreference = "Stop"

$jawal = (Resolve-Path $JawalExe).Path
$pkg = (Resolve-Path $JawalPkgExe).Path
$apkRoot = (Resolve-Path $ApkDirectory).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probe = Join-Path $PSScriptRoot "probe-guest.ps1"
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null

$apks = @(Get-ChildItem -LiteralPath $apkRoot -Filter *.apk -File -Recurse | Sort-Object FullName)
if ($apks.Count -eq 0) { throw "No APK files found in $apkRoot" }

$process = Start-Process -FilePath $jawal -PassThru
$results = @()
try {
    $health = & $probe -TimeoutSeconds $TimeoutSeconds -RequireWebView -RequireNetwork -RequirePhoneFeatures

    foreach ($apk in $apks) {
        $started = Get-Date
        & $pkg install $apk.FullName
        $code = $LASTEXITCODE
        $results += [pscustomobject]@{
            file = $apk.Name
            bytes = $apk.Length
            passed = ($code -eq 0)
            exitCode = $code
            elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
        }
    }
}
finally {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(15000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

$passed = @($results | Where-Object passed).Count
$total = $results.Count
$rate = if ($total -gt 0) { $passed / [double]$total } else { 0.0 }

$output = [ordered]@{
    passed = ($rate -ge $MinimumPassRate)
    minimumPassRate = $MinimumPassRate
    passRate = [Math]::Round($rate, 4)
    passedCount = $passed
    totalCount = $total
    android = $health
    results = $results
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
}
$output | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "APK matrix: $passed/$total passed ($([Math]::Round($rate * 100, 1))%)."
Write-Host "Report: $report"
if ($rate -lt $MinimumPassRate) {
    throw "APK compatibility gate failed: pass rate $rate is below $MinimumPassRate"
}
