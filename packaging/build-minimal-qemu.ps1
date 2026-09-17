param(
    [Parameter(Mandatory = $true)]
    [string]$QemuSourceDir,

    [string]$OutputDir = "dist/qemu-minimal",
    [string]$MsysBash = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$source = (Resolve-Path $QemuSourceDir).Path
$output = Join-Path $repoRoot $OutputDir
$script = Join-Path $repoRoot "packaging\build-minimal-qemu-msys2.sh"

if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "Minimal QEMU MSYS2 build script is missing: $script"
}

if (-not $MsysBash) {
    $candidates = @(
        "C:\msys64\usr\bin\bash.exe",
        "C:\tools\msys64\usr\bin\bash.exe",
        "C:\msys2\usr\bin\bash.exe"
    )
    $MsysBash = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $MsysBash -or -not (Test-Path -LiteralPath $MsysBash -PathType Leaf)) {
    throw "MSYS2 bash.exe was not found. Install MSYS2 or pass -MsysBash explicitly."
}

# Resolve Windows paths from inside the same MSYS2 installation so spaces and
# drive letters are handled correctly. UCRT64 is preferred for a modern 64-bit
# Windows runtime; callers may override MSYSTEM on the runner if needed.
$msysRoot = Split-Path -Parent (Split-Path -Parent $MsysBash)
$usrBin = Join-Path $msysRoot "usr\bin"
$cygpath = Join-Path $usrBin "cygpath.exe"
if (-not (Test-Path -LiteralPath $cygpath -PathType Leaf)) {
    throw "MSYS2 cygpath.exe is missing next to the selected bash installation."
}

$sourceUnix = (& $cygpath -u $source).Trim()
$outputUnix = (& $cygpath -u $output).Trim()
$scriptUnix = (& $cygpath -u $script).Trim()

New-Item $output -ItemType Directory -Force | Out-Null

$command = @"
set -euo pipefail
export MSYSTEM="`${MSYSTEM:-UCRT64}"
if [ "`$MSYSTEM" = "UCRT64" ]; then
  export MINGW_PREFIX=/ucrt64
  export PATH=/ucrt64/bin:/usr/bin:`$PATH
elif [ "`$MSYSTEM" = "MINGW64" ]; then
  export MINGW_PREFIX=/mingw64
  export PATH=/mingw64/bin:/usr/bin:`$PATH
elif [ "`$MSYSTEM" = "CLANG64" ]; then
  export MINGW_PREFIX=/clang64
  export PATH=/clang64/bin:/usr/bin:`$PATH
fi
"$scriptUnix" "$sourceUnix" "$outputUnix"
"@

& $MsysBash -lc $command
if ($LASTEXITCODE -ne 0) {
    throw "Minimal QEMU build failed with exit code $LASTEXITCODE"
}

$required = @(
    "qemu-system-x86_64.exe",
    "qemu-img.exe",
    "edk2-x86_64-code.fd",
    "qemu-minimal-build.json",
    "qemu-final-dependencies.json"
)
foreach ($name in $required) {
    $candidate = Join-Path $output $name
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Minimal QEMU build completed without required output: $name"
    }
}

$bytes = (Get-ChildItem -LiteralPath $output -File | Measure-Object Length -Sum).Sum
$sizeMiB = [Math]::Round($bytes / 1MB, 1)
Write-Host "Minimal QEMU Windows payload: $sizeMiB MiB"
Write-Host $output
