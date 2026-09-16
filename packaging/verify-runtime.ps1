param(
    [string]$RuntimeDir = "dist/runtime",
    [int]$MaximumUncompressedMiB = 3200,
    [string]$ReportPath = "dist/reports/runtime-verification.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runtime = (Resolve-Path (Join-Path $repoRoot $RuntimeDir)).Path
$manifest = Join-Path $runtime "runtime.sha256"

$required = @(
    "android\kernel",
    "android\initrd.img",
    "images\jawal-system.qcow2",
    "images\jawal-data-template.qcow2",
    "qemu\qemu-system-x86_64.exe",
    "qemu\qemu-img.exe",
    "runtime.sha256"
)
foreach ($relative in $required) {
    $path = Join-Path $runtime $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Runtime is incomplete: $relative is missing."
    }
}

# runtime.sha256 is generated before the Windows QEMU files are added, so it
# intentionally covers the immutable Android payload only.
$hashResults = @()
Get-Content -LiteralPath $manifest | ForEach-Object {
    if ($_ -notmatch '^([0-9a-fA-F]{64})\s+(.+)$') { return }
    $expected = $Matches[1].ToLowerInvariant()
    $relative = $Matches[2].TrimStart('*').Replace('/', '\')
    $path = Join-Path $runtime $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Integrity manifest references missing file: $relative"
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA-256 mismatch for $relative"
    }
    $hashResults += [ordered]@{ file = $relative; sha256 = $actual; passed = $true }
}

$files = Get-ChildItem -LiteralPath $runtime -Recurse -File
$totalBytes = ($files | Measure-Object Length -Sum).Sum
$totalMiB = [Math]::Round($totalBytes / 1MB, 1)
if ($totalMiB -gt $MaximumUncompressedMiB) {
    throw "Runtime footprint is $totalMiB MiB, above the $MaximumUncompressedMiB MiB production ceiling."
}

$largest = $files | Sort-Object Length -Descending | Select-Object -First 30 | ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($runtime.Length + 1)
        sizeMiB = [Math]::Round($_.Length / 1MB, 2)
    }
}

$report = [ordered]@{
    passed = $true
    runtimeMiB = $totalMiB
    maximumMiB = $MaximumUncompressedMiB
    verifiedAndroidFiles = $hashResults
    largestFiles = $largest
    measuredAtUtc = [DateTime]::UtcNow.ToString("o")
}

$reportFile = Join-Path $repoRoot $ReportPath
$reportDir = Split-Path -Parent $reportFile
if ($reportDir) { New-Item $reportDir -ItemType Directory -Force | Out-Null }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding UTF8
Write-Host "PASS: Jawal runtime verified at $totalMiB MiB."
Write-Host "Report: $reportFile"
