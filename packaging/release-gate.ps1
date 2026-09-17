param(
    [Parameter(Mandatory = $true)] [string]$Installer,
    [Parameter(Mandatory = $true)] [string]$JawalExe,
    [Parameter(Mandatory = $true)] [string]$RuntimeDir,
    [double]$MaxInstallerMiB = 1200,
    [double]$MaxInstalledMiB = 3072,
    [double]$MaxQemuMiB = 250,
    [double]$TargetInstallerMiB = 900,
    [double]$TargetSystemMiB = 650,
    [double]$TargetQemuMiB = 180,
    [switch]$RequireSignature,
    [string]$ReportPath = "dist/reports/release-gate.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$installerPath = (Resolve-Path $Installer).Path
$jawalPath = (Resolve-Path $JawalExe).Path
$runtimePath = (Resolve-Path $RuntimeDir).Path
$report = Join-Path $repoRoot $ReportPath
New-Item (Split-Path -Parent $report) -ItemType Directory -Force | Out-Null

$requiredRuntimeFiles = @(
    "android\kernel",
    "android\initrd.img",
    "images\jawal-system.qcow2",
    "images\jawal-data-template.qcow2",
    "qemu\qemu-system-x86_64.exe",
    "qemu\qemu-img.exe",
    "firmware\edk2-x86_64-code.fd",
    "runtime.sha256"
)
foreach ($relative in $requiredRuntimeFiles) {
    $candidate = Join-Path $runtimePath $relative
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Release runtime missing: $relative" }
}

function Get-MiB([long]$Bytes) { return [Math]::Round($Bytes / 1MB, 1) }
function Get-TreeBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File | Measure-Object Length -Sum).Sum
    if ($null -eq $sum) { return 0L }
    return [long]$sum
}

$installerMiB = Get-MiB (Get-Item $installerPath).Length
$runtimeBytes = Get-TreeBytes $runtimePath
$jawalBytes = (Get-Item $jawalPath).Length
$installedMiB = Get-MiB ($runtimeBytes + $jawalBytes)

$qemuDir = Join-Path $runtimePath "qemu"
$qemuBytes = Get-TreeBytes $qemuDir
$qemuMiB = Get-MiB $qemuBytes
$qemuFiles = @(Get-ChildItem -LiteralPath $qemuDir -File)
$firmwareDir = Join-Path $runtimePath "firmware"
$firmwareBytes = Get-TreeBytes $firmwareDir
$firmwareMiB = Get-MiB $firmwareBytes
$firmwareFiles = @(Get-ChildItem -LiteralPath $firmwareDir -File)
$systemDisk = Join-Path $runtimePath "images\jawal-system.qcow2"
$dataTemplate = Join-Path $runtimePath "images\jawal-data-template.qcow2"
$kernel = Join-Path $runtimePath "android\kernel"
$initrd = Join-Path $runtimePath "android\initrd.img"
$systemMiB = Get-MiB (Get-Item $systemDisk).Length
$dataTemplateMiB = Get-MiB (Get-Item $dataTemplate).Length
$bootMiB = Get-MiB ((Get-Item $kernel).Length + (Get-Item $initrd).Length)
$jawalMiB = Get-MiB $jawalBytes

if ($installerMiB -gt $MaxInstallerMiB) {
    throw "Installer budget exceeded: $installerMiB MiB > $MaxInstallerMiB MiB"
}
if ($installedMiB -gt $MaxInstalledMiB) {
    throw "Installed runtime budget exceeded: $installedMiB MiB > $MaxInstalledMiB MiB"
}
if ($qemuMiB -gt $MaxQemuMiB) {
    throw "QEMU payload budget exceeded: $qemuMiB MiB > $MaxQemuMiB MiB. Check dependency-driven packaging; do not ship a full QEMU distribution."
}

$targetWarnings = @()
if ($installerMiB -gt $TargetInstallerMiB) {
    $targetWarnings += "Installer is above the $TargetInstallerMiB MiB optimization target: $installerMiB MiB"
}
if ($systemMiB -gt $TargetSystemMiB) {
    $targetWarnings += "Jawal system disk is above the $TargetSystemMiB MiB optimization target: $systemMiB MiB"
}
if ($qemuMiB -gt $TargetQemuMiB) {
    $targetWarnings += "QEMU payload is above the $TargetQemuMiB MiB optimization target: $qemuMiB MiB"
}
foreach ($warning in $targetWarnings) { Write-Warning $warning }

# The minimal runtime must not accidentally contain unrelated QEMU system
# emulators. Jawal executes only x86_64 plus qemu-img.
$unexpectedQemuExecutables = @(
    Get-ChildItem -LiteralPath $qemuDir -Filter "qemu-system-*.exe" -File |
        Where-Object { $_.Name -ne "qemu-system-x86_64.exe" }
)
if ($unexpectedQemuExecutables.Count -gt 0) {
    throw "Unexpected QEMU system emulators packaged: $($unexpectedQemuExecutables.Name -join ', ')"
}

$installerSignature = Get-AuthenticodeSignature -FilePath $installerPath
$jawalSignature = Get-AuthenticodeSignature -FilePath $jawalPath
if ($RequireSignature) {
    if ($installerSignature.Status -ne 'Valid') { throw "JawalSetup.exe is not validly Authenticode-signed." }
    if ($jawalSignature.Status -ne 'Valid') { throw "Jawal.exe is not validly Authenticode-signed." }
}

$hashes = @()
foreach ($path in @($installerPath, $jawalPath)) {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $path
    $hashes += [pscustomobject]@{ file = (Split-Path -Leaf $path); sha256 = $hash.Hash.ToLowerInvariant() }
}

$shaFile = Join-Path (Split-Path -Parent $installerPath) "SHA256SUMS.txt"
$hashes | ForEach-Object { "$($_.sha256)  $($_.file)" } | Set-Content -LiteralPath $shaFile -Encoding ascii

$breakdown = [ordered]@{
    jawalHostMiB = $jawalMiB
    androidBootMiB = $bootMiB
    jawalSystemDiskMiB = $systemMiB
    dataTemplateMiB = $dataTemplateMiB
    qemuMiB = $qemuMiB
    qemuFileCount = $qemuFiles.Count
    firmwareMiB = $firmwareMiB
    firmwareFileCount = $firmwareFiles.Count
}

$output = [ordered]@{
    passed = $true
    installerMiB = $installerMiB
    installedRuntimeMiB = $installedMiB
    maxInstallerMiB = $MaxInstallerMiB
    maxInstalledMiB = $MaxInstalledMiB
    maxQemuMiB = $MaxQemuMiB
    targetInstallerMiB = $TargetInstallerMiB
    targetSystemMiB = $TargetSystemMiB
    targetQemuMiB = $TargetQemuMiB
    targetWarnings = $targetWarnings
    sizeBreakdown = $breakdown
    installerSignature = [string]$installerSignature.Status
    jawalSignature = [string]$jawalSignature.Status
    hashes = $hashes
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
}
$output | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "PASS: release gate"
Write-Host "Installer: $installerMiB MiB / target $TargetInstallerMiB / max $MaxInstallerMiB MiB"
Write-Host "Installed runtime: $installedMiB MiB / max $MaxInstalledMiB MiB"
Write-Host "Breakdown: host=$jawalMiB MiB, boot=$bootMiB MiB, system=$systemMiB MiB, data-template=$dataTemplateMiB MiB, qemu=$qemuMiB MiB ($($qemuFiles.Count) files), firmware=$firmwareMiB MiB"
Write-Host "SHA256 manifest: $shaFile"
