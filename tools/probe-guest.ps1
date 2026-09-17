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
$sessionTokenPath = Join-Path (Join-Path $env:LOCALAPPDATA "Jawal") "session.token"

function Read-JawalSessionToken {
    if (-not (Test-Path -LiteralPath $sessionTokenPath -PathType Leaf)) { return $null }
    $value = (Get-Content -LiteralPath $sessionTokenPath -Raw).Trim()
    if ($value -notmatch '^[0-9a-fA-F]{64}$') { return $null }
    return $value
}

while ([DateTime]::UtcNow -lt $deadline) {
    $client = $null
    $reader = $null
    $writer = $null
    try {
        $sessionToken = Read-JawalSessionToken
        if ([string]::IsNullOrWhiteSpace($sessionToken)) {
            throw "Jawal authenticated session token is not ready yet."
        }

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
        $stream.WriteTimeout = 3000
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.NewLine = "`n"
        $writer.WriteLine("AUTH $sessionToken")
        $writer.Flush()

        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw "Guest health probe returned an empty response."
        }
        if ($line -eq 'ERR AUTH') {
            throw "Guest rejected the current Jawal session token."
        }
        $health = $line | ConvertFrom-Json
        break
    }
    catch {
        $lastError = $_.Exception.Message
        Start-Sleep -Milliseconds 500
    }
    finally {
        if ($writer) { $writer.Dispose() }
        if ($reader) { $reader.Dispose() }
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
if ($RequireAudio) {
    if (-not $health.audioOutput) {
        throw "Android did not report audio output support."
    }
    if (-not $health.microphone) {
        throw "Android did not report the duplex microphone capability Jawal exposes."
    }
}
if ($RequirePhoneFeatures) {
    if (-not $health.touchscreen -or -not $health.portrait) {
        throw "Android is not exposing the expected touchscreen/portrait feature set."
    }

    $characteristics = ([string]$health.buildCharacteristics).ToLowerInvariant()
    $characteristicSet = @($characteristics.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($characteristicSet -notcontains 'phone') {
        throw "Android build characteristics are not phone-oriented: '$($health.buildCharacteristics)'."
    }
    if ($characteristicSet -contains 'tablet') {
        throw "Android unexpectedly reports the tablet build characteristic."
    }

    $densityDpi = [int]$health.densityDpi
    if ($densityDpi -lt 320 -or $densityDpi -gt 560) {
        throw "Android display density $densityDpi dpi is outside Jawal's phone-scale range (320-560 dpi)."
    }

    $smallestWidthDp = [int]$health.smallestScreenWidthDp
    if ($smallestWidthDp -lt 320 -or $smallestWidthDp -ge 600) {
        throw "Android smallest width is $smallestWidthDp dp; expected a phone layout below 600 dp."
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
    $directory = Split-Path -Parent $OutputJson
    if ($directory) { New-Item $directory -ItemType Directory -Force | Out-Null }
    $health | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
}

$health
