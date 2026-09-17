param(
    [string]$Makensis = "makensis.exe"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$host = Join-Path $repoRoot "build\host\Release\Jawal.exe"
$runtime = Join-Path $repoRoot "dist\runtime"
$manifest = Join-Path $runtime "runtime.sha256"

if (-not (Test-Path $host -PathType Leaf)) {
    throw "Jawal.exe is missing. Build the Windows host first: cmake --build build/host --config Release"
}
if (-not (Test-Path $manifest -PathType Leaf)) {
    throw "Jawal runtime is incomplete. Run packaging/assemble-windows-runtime.ps1 first."
}

$command = Get-Command $Makensis -ErrorAction SilentlyContinue
if (-not $command) {
    throw "NSIS makensis.exe was not found. Install NSIS or pass -Makensis with its full path."
}

New-Item (Join-Path $repoRoot "dist") -ItemType Directory -Force | Out-Null

Push-Location $PSScriptRoot
try {
    & $command.Source "Jawal.nsi"
    if ($LASTEXITCODE -ne 0) {
        throw "NSIS failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$installer = Join-Path $repoRoot "dist\JawalSetup.exe"
if (-not (Test-Path $installer -PathType Leaf)) {
    throw "Installer build completed without producing JawalSetup.exe"
}

$sizeMiB = [Math]::Round((Get-Item $installer).Length / 1MB, 1)
Write-Host "Jawal single-file installer: $sizeMiB MiB"
Write-Host $installer
