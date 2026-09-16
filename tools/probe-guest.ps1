param(
    [string]$HostAddress = "127.0.0.1",
    [int]$Port = 27184,
    [int]$TimeoutSeconds = 180,
    [switch]$RequireWebView,
    [switch]$RequireNetwork,
    [switch]$RequireAudio,
    [switch]$RequirePhoneFeatures,
    [string]$OutputJson = ""
)

$ErrorActionPreference = "Stop"
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$lastError = $null
$health = $null

while ([DateTime]::UtcNow -lt $deadline) {
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($HostAddress, $Port)
        if (-not $task.Wait(1000)) {
            throw "Timed out connecting to Jawal guest health port."
        }
        if (-not $client.Connected) {
            throw "Guest health port is not connected."
        }

        $stream = $client.GetStream()
        $stream.ReadTimeout = 3000
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw "Guest health probe returned an empty response."
        }
        $health = $line | ConvertFrom-Json
        break
    }
    catch {
        $lastError = $_.Exception.Message
        Start-Sleep -Milliseconds 500
    }
    finally {
        if ($client) { $client.Dispose() }
    }
}

if (-not $health) {
    throw "Jawal Android health probe did not become ready within $TimeoutSeconds seconds. Last error: $lastError"
}
if (-not $health.ready) { throw "Jawal Android reported ready=false." }
if ([int]$health.sdk -lt 35) { throw "Unexpected Android SDK level: $($health.sdk). Expected Android 15 / API 35 or newer." }
if ([long]$health.dataFreeBytes -lt 1GB) { throw "Jawal Android data volume has less than 1 GiB free." }
if ($RequireWebView -and [string]::IsNullOrWhiteSpace([string]$health.webview)) {
    throw "No active WebView provider was reported."
}
if ($RequireNetwork -and -not $health.networkInternet) {
    throw "Android did not report an INTERNET-capable active network."
}
if ($RequireAudio -and -not $health.audioOutput) {
    throw "Android did not report audio output support."
}
if ($RequirePhoneFeatures -and (-not $health.touchscreen -or -not $health.portrait)) {
    throw "Android is not exposing the expected handheld touchscreen/portrait feature set."
}

if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
    $directory = Split-Path -Parent $OutputJson
    if ($directory) { New-Item $directory -ItemType Directory -Force | Out-Null }
    $health | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
}

$health
