param(
    [Parameter(Mandatory = $true)] [string]$Installer,
    [Parameter(Mandatory = $true)] [string]$JawalExe,
    [Parameter(Mandatory = $true)] [string]$RuntimeDir,
    [double]$MaxInstallerMiB = 1200,
    [double]$MaxInstalledMiB = 3072,
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
    "runtime.sha256"
)
foreach ($relative in $requiredRuntimeFiles) {
    $candidate = Join-Path $runtimePath $relative
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Release runtime missing: $relative" }
}

$installerMiB = [Math]::Round((Get-Item $installerPath).Length / 1MB, 1)
$runtimeBytes = (Get-ChildItem $runtimePath -Recurse -File | Measure-Object Length -Sum).Sum
$jawalBytes = (Get-Item $jawalPath).Length
$installedMiB = [Math]::Round(($runtimeBytes + $jawalBytes) / 1MB, 1)

if ($installerMiB -gt $MaxInstallerMiB) {
    throw "Installer budget exceeded: $installerMiB MiB > $MaxInstallerMiB MiB"
}
if ($installedMiB -gt $MaxInstalledMiB) {
    throw "Installed runtime budget exceeded: $installedMiB MiB > $MaxInstalledMiB MiB"
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

$output = [ordered]@{
    passed = $true
    installerMiB = $installerMiB
    installedRuntimeMiB = $installedMiB
    maxInstallerMiB = $MaxInstallerMiB
    maxInstalledMiB = $MaxInstalledMiB
    installerSignature = [string]$installerSignature.Status
    jawalSignature = [string]$jawalSignature.Status
    hashes = $hashes
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
}
$output | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "PASS: release gate"
Write-Host "Installer: $installerMiB MiB / $MaxInstallerMiB MiB"
Write-Host "Installed runtime: $installedMiB MiB / $MaxInstalledMiB MiB"
Write-Host "SHA256 manifest: $shaFile"
