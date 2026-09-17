param(
    [string]$RuntimeDir = "dist/runtime",
    [int]$MaximumUncompressedMiB = 3200,
    [int]$MaximumQemuMiB = 250,
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
    "firmware\edk2-x86_64-code.fd",
    "runtime.sha256"
)
foreach ($relative in $required) {
    $path = Join-Path $runtime $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Runtime is incomplete: $relative is missing."
    }
}

# The final manifest is regenerated after Android, minimal QEMU DLLs and firmware
# are assembled. Every listed immutable runtime file must verify before release.
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
if ($hashResults.Count -lt 7) {
    throw "Runtime integrity manifest is unexpectedly small ($($hashResults.Count) entries)."
}

$qemuDir = Join-Path $runtime "qemu"
$qemuFiles = @(Get-ChildItem -LiteralPath $qemuDir -File)
$qemuBytes = ($qemuFiles | Measure-Object Length -Sum).Sum
if ($null -eq $qemuBytes) { $qemuBytes = 0 }
$qemuMiB = [Math]::Round($qemuBytes / 1MB, 1)
if ($qemuMiB -gt $MaximumQemuMiB) {
    throw "Minimal QEMU payload is $qemuMiB MiB, above the $MaximumQemuMiB MiB ceiling."
}
$unexpectedQemuExecutables = @(
    $qemuFiles | Where-Object { $_.Name -like 'qemu-system-*.exe' -and $_.Name -ne 'qemu-system-x86_64.exe' }
)
if ($unexpectedQemuExecutables.Count -gt 0) {
    throw "Unrelated QEMU system emulators are present: $($unexpectedQemuExecutables.Name -join ', ')"
}

$dependencyReport = Join-Path $runtime "reports\qemu-dependencies.json"
$dependencyEvidence = $null
if (Test-Path -LiteralPath $dependencyReport -PathType Leaf) {
    $dependencyEvidence = Get-Content -LiteralPath $dependencyReport -Raw | ConvertFrom-Json
    if ($dependencyEvidence.unresolvedNonSystemImports) {
        $props = @($dependencyEvidence.unresolvedNonSystemImports.PSObject.Properties)
        if ($props.Count -gt 0) {
            throw "QEMU dependency report contains unresolved non-system DLL imports."
        }
    }
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
    qemuMiB = $qemuMiB
    maximumQemuMiB = $MaximumQemuMiB
    qemuFileCount = $qemuFiles.Count
    verifiedRuntimeFiles = $hashResults
    dependencyEvidencePresent = [bool]$dependencyEvidence
    largestFiles = $largest
    measuredAtUtc = [DateTime]::UtcNow.ToString("o")
}

$reportFile = Join-Path $repoRoot $ReportPath
$reportDir = Split-Path -Parent $reportFile
if ($reportDir) { New-Item $reportDir -ItemType Directory -Force | Out-Null }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding UTF8
Write-Host "PASS: Jawal runtime verified at $totalMiB MiB; QEMU=$qemuMiB MiB."
Write-Host "Report: $reportFile"
