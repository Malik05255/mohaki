param(
    [Parameter(Mandatory = $true)]
    [string]$QemuDir,

    [string]$AndroidRuntimeDir = "dist/android-runtime",
    [string]$OutputDir = "dist/runtime"
)

$ErrorActionPreference = "Stop"

function Require-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing: $Path"
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$qemuRoot = (Resolve-Path $QemuDir).Path
$androidRoot = (Resolve-Path (Join-Path $repoRoot $AndroidRuntimeDir)).Path
$output = Join-Path $repoRoot $OutputDir

$qemuExe = Join-Path $qemuRoot "qemu-system-x86_64.exe"
$qemuImg = Join-Path $qemuRoot "qemu-img.exe"
Require-File $qemuExe "QEMU x86_64 executable"
Require-File $qemuImg "qemu-img"
Require-File (Join-Path $androidRoot "android\kernel") "Jawal Android kernel"
Require-File (Join-Path $androidRoot "android\initrd.img") "Jawal Android initrd"
Require-File (Join-Path $androidRoot "images\jawal-system.qcow2") "Jawal system disk"
Require-File (Join-Path $androidRoot "images\jawal-data-template.qcow2") "Jawal data template"

if (Test-Path $output) {
    Remove-Item $output -Recurse -Force
}
New-Item $output -ItemType Directory | Out-Null
New-Item (Join-Path $output "qemu") -ItemType Directory | Out-Null
New-Item (Join-Path $output "firmware") -ItemType Directory | Out-Null
New-Item (Join-Path $output "reports") -ItemType Directory | Out-Null

Copy-Item (Join-Path $androidRoot "android") $output -Recurse
Copy-Item (Join-Path $androidRoot "images") $output -Recurse
if (Test-Path (Join-Path $androidRoot "reports")) {
    Copy-Item (Join-Path $androidRoot "reports\*") (Join-Path $output "reports") -Force
}

# Copy only the two QEMU tools Jawal actually executes.
Copy-Item $qemuExe (Join-Path $output "qemu\qemu-system-x86_64.exe") -Force
Copy-Item $qemuImg (Join-Path $output "qemu\qemu-img.exe") -Force

# Do not ship every DLL from a full QEMU distribution. Compute the recursive PE
# import closure for qemu-system-x86_64.exe + qemu-img.exe and copy only local
# dependencies that those binaries really reference. This keeps the runtime
# portable across QEMU builds without hard-coding a brittle DLL allowlist.
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $python) {
    throw "Python is required to compute the minimal QEMU DLL dependency closure."
}
$scanner = Join-Path $repoRoot "tools\pe-dependency-closure.py"
Require-File $scanner "QEMU PE dependency scanner"
$depReport = Join-Path $output "reports\qemu-dependencies.json"
$dllNames = & $python.Source $scanner $qemuRoot `
    "qemu-system-x86_64.exe" "qemu-img.exe" --json $depReport
if ($LASTEXITCODE -ne 0) {
    throw "Failed to compute QEMU DLL dependency closure."
}
foreach ($dllName in ($dllNames | Where-Object { $_ -and $_.Trim() } | Sort-Object -Unique)) {
    $source = Join-Path $qemuRoot $dllName.Trim()
    Require-File $source "QEMU dependency"
    Copy-Item $source (Join-Path $output "qemu\$($dllName.Trim())") -Force
}

# The minimized QEMU bundle must still contain deterministic PC firmware.
# Do not rely on a machine-wide QEMU installation at runtime.
$firmwareCandidates = @(
    (Join-Path $qemuRoot "share\edk2-x86_64-code.fd"),
    (Join-Path $qemuRoot "share\qemu\edk2-x86_64-code.fd"),
    (Join-Path $qemuRoot "edk2-x86_64-code.fd")
)
$firmware = $firmwareCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $firmware) {
    throw "QEMU x86_64 firmware edk2-x86_64-code.fd was not found. A minimal Jawal runtime must bundle its own firmware."
}
Copy-Item $firmware (Join-Path $output "firmware\edk2-x86_64-code.fd") -Force

# Some QEMU distributions keep the virtio VGA option ROM as an external file.
# It is tiny; include it when available rather than shipping the entire share tree.
$virtioVgaCandidates = @(
    (Join-Path $qemuRoot "share\vgabios-virtio.bin"),
    (Join-Path $qemuRoot "share\qemu\vgabios-virtio.bin"),
    (Join-Path $qemuRoot "vgabios-virtio.bin")
)
$virtioVgaRom = $virtioVgaCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($virtioVgaRom) {
    Copy-Item $virtioVgaRom (Join-Path $output "firmware\vgabios-virtio.bin") -Force
}

# Keep QEMU license material with the runtime when the binary distribution ships it.
$licenseCandidates = @("COPYING", "COPYING.LIB", "LICENSE", "LICENSE.txt")
$licenseDir = Join-Path $output "licenses"
foreach ($name in $licenseCandidates) {
    $candidate = Join-Path $qemuRoot $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        New-Item $licenseDir -ItemType Directory -Force | Out-Null
        Copy-Item $candidate (Join-Path $licenseDir "qemu-$name") -Force
    }
}

Require-File (Join-Path $output "qemu\qemu-system-x86_64.exe") "Packaged QEMU"
Require-File (Join-Path $output "qemu\qemu-img.exe") "Packaged qemu-img"
Require-File (Join-Path $output "firmware\edk2-x86_64-code.fd") "Packaged QEMU firmware"

# Regenerate the manifest after Windows QEMU files are assembled. Jawal.exe
# verifies this manifest on every launch before starting Android.
$critical = @(
    "android\kernel",
    "android\initrd.img",
    "images\jawal-system.qcow2",
    "images\jawal-data-template.qcow2",
    "qemu\qemu-system-x86_64.exe",
    "qemu\qemu-img.exe",
    "firmware\edk2-x86_64-code.fd"
)
if (Test-Path (Join-Path $output "firmware\vgabios-virtio.bin")) {
    $critical += "firmware\vgabios-virtio.bin"
}
$critical += @(Get-ChildItem (Join-Path $output "qemu") -Filter *.dll -File | ForEach-Object { "qemu\$($_.Name)" })

$manifest = Join-Path $output "runtime.sha256"
$lines = foreach ($relative in ($critical | Sort-Object -Unique)) {
    $path = Join-Path $output $relative
    Require-File $path "Runtime integrity file"
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($relative.Replace('\','/'))"
}
$lines | Set-Content -LiteralPath $manifest -Encoding ascii

$files = Get-ChildItem $output -Recurse -File
$totalBytes = ($files | Measure-Object Length -Sum).Sum
$sizeMiB = [Math]::Round($totalBytes / 1MB, 1)
$qemuFiles = Get-ChildItem (Join-Path $output "qemu") -File
$qemuBytes = ($qemuFiles | Measure-Object Length -Sum).Sum
$qemuMiB = [Math]::Round($qemuBytes / 1MB, 1)
$firmwareFiles = @(Get-ChildItem (Join-Path $output "firmware") -File)
$firmwareBytes = ($firmwareFiles | Measure-Object Length -Sum).Sum
$firmwareMiB = [Math]::Round($firmwareBytes / 1MB, 1)

@{
    runtimeMiB = $sizeMiB
    qemuMiB = $qemuMiB
    qemuFileCount = $qemuFiles.Count
    firmwareMiB = $firmwareMiB
    firmwareFileCount = $firmwareFiles.Count
    integrityEntries = $lines.Count
} | ConvertTo-Json | Set-Content (Join-Path $output "reports\runtime-size.json") -Encoding UTF8

Write-Host "Jawal Windows runtime assembled: $sizeMiB MiB"
Write-Host "Minimal QEMU payload: $qemuMiB MiB across $($qemuFiles.Count) files"
Write-Host "Firmware payload: $firmwareMiB MiB across $($firmwareFiles.Count) files"
Write-Host "Integrity manifest entries: $($lines.Count)"
Write-Host $output
