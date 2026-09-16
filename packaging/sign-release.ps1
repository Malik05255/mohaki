param(
    [Parameter(Mandatory = $true)] [string[]]$Paths,
    [string]$CertificateThumbprint = $env:JAWAL_SIGNING_CERT_THUMBPRINT,
    [string]$SignTool = "signtool.exe",
    [string]$TimestampUrl = "http://timestamp.digicert.com",
    [switch]$RequireSigning
)

$ErrorActionPreference = "Stop"
$resolved = @($Paths | ForEach-Object { (Resolve-Path $_).Path })

if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    if ($RequireSigning) { throw "Release signing certificate thumbprint is required." }
    Write-Warning "No signing certificate configured; leaving development artifacts unsigned."
    return
}

$sign = Get-Command $SignTool -ErrorAction Stop
foreach ($path in $resolved) {
    & $sign.Source sign /sha1 $CertificateThumbprint /fd SHA256 /td SHA256 /tr $TimestampUrl /v $path
    if ($LASTEXITCODE -ne 0) { throw "Authenticode signing failed: $path" }

    & $sign.Source verify /pa /v $path
    if ($LASTEXITCODE -ne 0) { throw "Authenticode verification failed: $path" }

    $auth = Get-AuthenticodeSignature -FilePath $path
    if ($auth.Status -ne 'Valid') { throw "Invalid Authenticode state for ${path}: $($auth.Status)" }
    Write-Host "SIGNED: $path"
}
