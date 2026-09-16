param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,
    [string]$HostAddress = "127.0.0.1",
    [int]$Port = 27183,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
$apk = (Resolve-Path $ApkPath).Path
$file = Get-Item -LiteralPath $apk
if ($file.Length -le 0) { throw "Smoke APK is empty." }

function Write-BE32([System.IO.Stream]$Stream, [uint32]$Value) {
    $bytes = [byte[]]@(
        (($Value -shr 24) -band 0xff),
        (($Value -shr 16) -band 0xff),
        (($Value -shr 8) -band 0xff),
        ($Value -band 0xff)
    )
    $Stream.Write($bytes, 0, 4)
}

function Write-BE64([System.IO.Stream]$Stream, [uint64]$Value) {
    $bytes = New-Object byte[] 8
    for ($i = 7; $i -ge 0; $i--) {
        $bytes[$i] = [byte]($Value -band 0xff)
        $Value = $Value -shr 8
    }
    $Stream.Write($bytes, 0, 8)
}

function Read-Exact([System.IO.Stream]$Stream, [int]$Count) {
    $buffer = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { throw "Connection closed before response completed." }
        $offset += $read
    }
    return $buffer
}

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$client = $null
while ([DateTime]::UtcNow -lt $deadline) {
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($HostAddress, $Port)
        if ($task.Wait(1000) -and $client.Connected) { break }
        $client.Dispose(); $client = $null
    } catch {
        if ($client) { $client.Dispose(); $client = $null }
    }
    Start-Sleep -Milliseconds 500
}
if (-not $client -or -not $client.Connected) {
    throw "Jawal package bridge did not become ready within $TimeoutSeconds seconds."
}

try {
    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutSeconds * 1000
    $stream.WriteTimeout = $TimeoutSeconds * 1000

    Write-BE32 $stream 0x4A41504B
    Write-BE32 $stream 1
    Write-BE64 $stream ([uint64]$file.Length)

    $input = [System.IO.File]::OpenRead($apk)
    try {
        $buffer = New-Object byte[] (256KB)
        while (($count = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $stream.Write($buffer, 0, $count)
        }
    } finally {
        $input.Dispose()
    }
    $stream.Flush()

    $response = Read-Exact $stream 4
    [uint32]$unsigned = ([uint32]$response[0] -shl 24) -bor ([uint32]$response[1] -shl 16) -bor ([uint32]$response[2] -shl 8) -bor [uint32]$response[3]
    $status = [BitConverter]::ToInt32([BitConverter]::GetBytes($unsigned), 0)
    if ($status -ne 0) {
        throw "Jawal PackageInstaller smoke test failed with Android status $status."
    }
    Write-Host "Jawal APK install smoke passed: $($file.Name)"
} finally {
    $client.Dispose()
}
