param(
    [Parameter(Mandatory = $true)] [string]$QemuDir
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $QemuDir).Path
$qemu = Join-Path $root 'qemu-system-x86_64.exe'
$qemuImg = Join-Path $root 'qemu-img.exe'
if (-not (Test-Path $qemu -PathType Leaf)) { throw "Missing $qemu" }
if (-not (Test-Path $qemuImg -PathType Leaf)) { throw "Missing $qemuImg" }

function Run-Capture([string[]]$Args) {
    $text = & $qemu @Args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "QEMU command failed: $($Args -join ' ')`n$text" }
    return $text
}

$version = Run-Capture @('--version')
$accels = Run-Capture @('-accel','help')
$displays = Run-Capture @('-display','help')
$devices = Run-Capture @('-device','help')
$audio = Run-Capture @('-audiodev','help')

foreach ($required in @('whpx')) {
    if ($accels -notmatch [regex]::Escape($required)) { throw "Minimal QEMU missing accelerator: $required" }
}
foreach ($required in @('sdl')) {
    if ($displays -notmatch [regex]::Escape($required)) { throw "Minimal QEMU missing display backend: $required" }
}
foreach ($required in @('virtio-vga-gl','ich9-intel-hda','hda-duplex','qemu-xhci','usb-tablet','usb-kbd','virtio-rng-pci','virtio-net-pci')) {
    if ($devices -notmatch [regex]::Escape($required)) { throw "Minimal QEMU missing required device: $required" }
}
if ($audio -notmatch 'sdl') { throw 'Minimal QEMU missing SDL audio backend.' }

# Jawal intentionally ships one system emulator only.
$unexpected = @(Get-ChildItem $root -Filter 'qemu-system-*.exe' -File | Where-Object { $_.Name -ne 'qemu-system-x86_64.exe' })
if ($unexpected.Count -gt 0) { throw "Unexpected system emulators present: $($unexpected.Name -join ', ')" }

$files = @(Get-ChildItem $root -File)
$bytes = ($files | Measure-Object Length -Sum).Sum
$sizeMiB = [Math]::Round($bytes / 1MB, 1)

Write-Host 'PASS: minimal Jawal QEMU capability gate'
Write-Host ($version.Trim())
Write-Host "Top-level payload: $sizeMiB MiB across $($files.Count) files"
