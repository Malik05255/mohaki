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
Require-File (Join-Path $androidRoot "runtime.sha256") "Jawal runtime integrity manifest"

if (Test-Path $output) {
    Remove-Item $output -Recurse -Force
}
New-Item $output -ItemType Directory | Out-Null
New-Item (Join-Path $output "qemu") -ItemType Directory | Out-Null
New-Item (Join-Path $output "firmware") -ItemType Directory | Out-Null

Copy-Item (Join-Path $androidRoot "android") $output -Recurse
Copy-Item (Join-Path $androidRoot "images") $output -Recurse
Copy-Item (Join-Path $androidRoot "runtime.sha256") $output

# QEMU's Windows build needs several runtime DLLs beside the executable. Copy
# only runtime files, never development headers/import libraries.
$runtimePatterns = @(
    "qemu-system-x86_64.exe",
    "qemu-img.exe",
    "*.dll"
)
foreach ($pattern in $runtimePatterns) {
    Get-ChildItem -LiteralPath $qemuRoot -Filter $pattern -File -ErrorAction SilentlyContinue |
        Copy-Item -Destination (Join-Path $output "qemu") -Force
}

# Firmware location varies between QEMU Windows distributions.
$firmwareCandidates = @(
    (Join-Path $qemuRoot "share\edk2-x86_64-code.fd"),
    (Join-Path $qemuRoot "share\qemu\edk2-x86_64-code.fd"),
    (Join-Path $qemuRoot "edk2-x86_64-code.fd")
)
$firmware = $firmwareCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($firmware) {
    Copy-Item $firmware (Join-Path $output "firmware\edk2-x86_64-code.fd") -Force
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

$files = Get-ChildItem $output -Recurse -File
$totalBytes = ($files | Measure-Object Length -Sum).Sum
$sizeMiB = [Math]::Round($totalBytes / 1MB, 1)
Write-Host "Jawal Windows runtime assembled: $sizeMiB MiB"
Write-Host $output
