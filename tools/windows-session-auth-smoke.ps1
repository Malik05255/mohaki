param(
    [string]$HostAddress = "127.0.0.1",
    [int]$TimeoutMilliseconds = 5000,
    [string]$ReportPath = "dist/reports/session-auth-smoke.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$report = Join-Path $repoRoot $ReportPath
$reportDir = Split-Path -Parent $report
if ($reportDir) { New-Item $reportDir -ItemType Directory -Force | Out-Null }

$wrongToken = '0' * 64

function Open-Client([int]$Port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    $task = $client.ConnectAsync($HostAddress, $Port)
    if (-not $task.Wait($TimeoutMilliseconds) -or -not $client.Connected) {
        $client.Dispose()
        throw "Unable to connect to Jawal localhost port $Port for authentication negative test."
    }
    $client.ReceiveTimeout = $TimeoutMilliseconds
    $client.SendTimeout = $TimeoutMilliseconds
    return $client
}

function Send-All($Stream, [byte[]]$Bytes) {
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush()
}

function UInt32-BE([uint32]$Value) {
    return [byte[]]@(
        [byte](($Value -shr 24) -band 0xFF),
        [byte](($Value -shr 16) -band 0xFF),
        [byte](($Value -shr 8) -band 0xFF),
        [byte]($Value -band 0xFF)
    )
}

function Read-UInt32BE($Stream) {
    [byte[]]$bytes = New-Object byte[] 4
    $offset = 0
    while ($offset -lt 4) {
        $count = $Stream.Read($bytes, $offset, 4 - $offset)
        if ($count -le 0) { throw "Bridge closed before returning a 32-bit status." }
        $offset += $count
    }
    return [uint32]((([uint32]$bytes[0]) -shl 24) -bor
                    (([uint32]$bytes[1]) -shl 16) -bor
                    (([uint32]$bytes[2]) -shl 8) -bor
                    ([uint32]$bytes[3]))
}

function Test-TextReject([int]$Port, [string]$Request, [string]$Label) {
    $client = Open-Client $Port
    try {
        $stream = $client.GetStream()
        $encoding = [System.Text.UTF8Encoding]::new($false)
        Send-All $stream ($encoding.GetBytes($Request + "`n"))
        $reader = [System.IO.StreamReader]::new($stream, $encoding, $false, 1024, $true)
        try { $reply = $reader.ReadLine() } finally { $reader.Dispose() }
        if ($reply -ne 'ERR AUTH') {
            throw "$Label accepted an unauthenticated request or returned unexpected reply '$reply'."
        }
    }
    finally { $client.Dispose() }
}

function Test-PackageReject {
    $client = Open-Client 27183
    try {
        $stream = $client.GetStream()
        $bytes = [System.Collections.Generic.List[byte]]::new()
        $bytes.AddRange((UInt32-BE 0x4A41504B)) # JAPK
        $bytes.AddRange((UInt32-BE 3))
        $bytes.AddRange((UInt32-BE 64))
        $bytes.AddRange(([System.Text.Encoding]::ASCII.GetBytes($wrongToken)))
        Send-All $stream $bytes.ToArray()

        $status = Read-UInt32BE $stream
        $packageLength = Read-UInt32BE $stream
        if ($status -ne [uint32]4294967283 -or $packageLength -ne 0) { # -13
            throw "Package bridge did not reject wrong session token with status -13. status=$status length=$packageLength"
        }
    }
    finally { $client.Dispose() }
}

function Test-FileReject {
    $client = Open-Client 27188
    try {
        $stream = $client.GetStream()
        $bytes = [System.Collections.Generic.List[byte]]::new()
        $bytes.AddRange((UInt32-BE 0x4A46494C)) # JFIL
        $bytes.AddRange((UInt32-BE 2))
        $bytes.AddRange((UInt32-BE 64))
        $bytes.AddRange(([System.Text.Encoding]::ASCII.GetBytes($wrongToken)))
        Send-All $stream $bytes.ToArray()

        $status = Read-UInt32BE $stream
        if ($status -ne [uint32]4294967271) { # -25
            throw "File bridge did not reject wrong session token with status -25. status=$status"
        }
    }
    finally { $client.Dispose() }
}

# Health receives a syntactically valid but incorrect token. Control receives no
# AUTH envelope at all. Binary bridges receive their current protocol versions
# but a wrong 256-bit token. All four paths must fail closed.
Test-TextReject -Port 27184 -Request ("AUTH " + $wrongToken) -Label "Health bridge"
Test-TextReject -Port 27185 -Request "PING" -Label "Control bridge"
Test-PackageReject
Test-FileReject

[ordered]@{
    passed = $true
    healthRejectsWrongToken = $true
    controlRejectsMissingAuth = $true
    packageRejectsWrongToken = $true
    fileRejectsWrongToken = $true
    packageProtocolVersion = 3
    fileProtocolVersion = 2
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $report -Encoding UTF8

Write-Host "PASS: Jawal localhost guest bridges reject unauthenticated clients."
