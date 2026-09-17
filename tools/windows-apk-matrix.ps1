param(
    [Parameter(Mandatory = $true)] [string]$JawalExe,
    [Parameter(Mandatory = $true)] [string]$JawalPkgExe,
    [Parameter(Mandatory = $true)] [string]$ApkDirectory,
    [double]$MinimumPassRate = 0.90,
    [double]$MinimumLaunchRate = 0.85,
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
        $installText = (& $pkg install-json $apk.FullName 2>$null | Out-String).Trim()
        $installExit = $LASTEXITCODE
        $install = $null
        try { $install = $installText | ConvertFrom-Json } catch { }

        $packageName = if ($install -and $install.package) { [string]$install.package } else { "" }
        $installPassed = ($installExit -eq 0 -and $install -and $install.success -eq $true -and $packageName)
        $launchAttempted = $false
        $launchPassed = $false
        $notLaunchable = $false
        $processRunning = $false
        $launchExit = $null
        $launchOutput = ""

        if ($installPassed) {
            $launchAttempted = $true
            $launchOutput = (& $pkg launch $packageName 2>&1 | Out-String).Trim()
            $launchExit = $LASTEXITCODE
            if ($launchExit -eq 0) {
                $launchPassed = $true
                Start-Sleep -Milliseconds 1200
                & $pkg process $packageName *> $null
                $processRunning = ($LASTEXITCODE -eq 0)
            } elseif ($launchExit -eq 8) {
                # Libraries, keyboards, providers and background components can be valid APKs
                # without a launcher activity. Track them separately instead of pretending
                # they failed to install.
                $notLaunchable = $true
            }
        }

        $results += [pscustomobject]@{
            file = $apk.Name
            bytes = $apk.Length
            packageName = $packageName
            installPassed = [bool]$installPassed
            installExitCode = $installExit
            launchAttempted = $launchAttempted
            launchPassed = $launchPassed
            notLaunchable = $notLaunchable
            launchExitCode = $launchExit
            launchOutput = $launchOutput
            processRunningAfterLaunch = $processRunning
            passed = ($installPassed -and ($launchPassed -or $notLaunchable))
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

$total = $results.Count
$installed = @($results | Where-Object installPassed).Count
$installRate = if ($total -gt 0) { $installed / [double]$total } else { 0.0 }
$launchable = @($results | Where-Object { $_.installPassed -and -not $_.notLaunchable }).Count
$launched = @($results | Where-Object launchPassed).Count
$launchRate = if ($launchable -gt 0) { $launched / [double]$launchable } else { 1.0 }
$overallPassed = ($installRate -ge $MinimumPassRate -and $launchRate -ge $MinimumLaunchRate)

$output = [ordered]@{
    passed = $overallPassed
    minimumInstallRate = $MinimumPassRate
    minimumLaunchRate = $MinimumLaunchRate
    installRate = [Math]::Round($installRate, 4)
    launchRate = [Math]::Round($launchRate, 4)
    installedCount = $installed
    launchableCount = $launchable
    launchedCount = $launched
    totalCount = $total
    android = $health
    results = $results
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
}
$output | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "APK install matrix: $installed/$total ($([Math]::Round($installRate * 100, 1))%)."
Write-Host "APK launch matrix: $launched/$launchable ($([Math]::Round($launchRate * 100, 1))%)."
Write-Host "Report: $report"
if (-not $overallPassed) {
    throw "APK compatibility gate failed: install=$installRate (min $MinimumPassRate), launch=$launchRate (min $MinimumLaunchRate)"
}
