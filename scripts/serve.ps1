#Requires -Version 5.1
# Runs the control server on the LAN. Uses TLS when certs exist (see gen_cert.ps1);
# refuses plain HTTP unless -AllowPlainHttp is passed explicitly (dev only, never for a phone).
param([switch]$AllowPlainHttp)
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
$venvPy = Join-Path (Get-Location) "venv312\Scripts\python.exe"
$py = if (Test-Path $venvPy) { $venvPy } else { "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" }
$cert = Join-Path (Get-Location) "certs\dev-cert.pem"
$key = Join-Path (Get-Location) "certs\dev-key.pem"
if ((Test-Path $cert) -and (Test-Path $key)) {
  & $py -m uvicorn server.main:app --host 0.0.0.0 --port 8443 --ssl-certfile $cert --ssl-keyfile $key
} elseif ($AllowPlainHttp) {
  Write-Warning "No certs found — serving PLAIN HTTP for local dev only."
  & $py -m uvicorn server.main:app --host 127.0.0.1 --port 8443
} else {
  throw "No TLS certs. Run scripts/gen_cert.ps1 first (or pass -AllowPlainHttp for loopback dev)."
}
