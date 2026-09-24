#Requires -Version 5.1
<#
Generates a local dev TLS certificate with NO external tools (Windows built-in
New-SelfSignedCertificate + .NET PEM export). For a phone-trusted cert, prefer
mkcert per SECURITY.md - this script is the zero-dependency fallback.

Outputs: certs/dev-cert.pem, certs/dev-key.pem (both gitignored).
#>
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$certs = Join-Path $root "certs"
New-Item -ItemType Directory -Path $certs -Force | Out-Null

$cert = New-SelfSignedCertificate `
  -DnsName "buddy.local", $env:COMPUTERNAME `
  -CertStoreLocation "Cert:\CurrentUser\My" `
  -NotAfter (Get-Date).AddYears(2) `
  -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
  -KeyExportPolicy Exportable -Type SSLServerAuthentication

$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
$keyB64 = [Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey(), "InsertLineBreaks")
"-----BEGIN PRIVATE KEY-----`n$keyB64`n-----END PRIVATE KEY-----" | Out-File (Join-Path $certs "dev-key.pem") -Encoding ascii -NoNewline

$certB64 = [Convert]::ToBase64String($cert.Export("Cert"), "InsertLineBreaks")
"-----BEGIN CERTIFICATE-----`n$certB64`n-----END CERTIFICATE-----" | Out-File (Join-Path $certs "dev-cert.pem") -Encoding ascii -NoNewline

Write-Output "wrote certs/dev-cert.pem + certs/dev-key.pem"
Write-Output ("SHA256 fingerprint: " + $cert.Thumbprint)
Write-Output "Pin this fingerprint in the phone app on first pairing (SECURITY.md)."
