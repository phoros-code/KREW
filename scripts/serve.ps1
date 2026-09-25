#Requires -Version 5.1
# Runs the control server on the LAN. Uses TLS when certs exist (see gen_cert.ps1);
# refuses plain HTTP unless -AllowPlainHttp is passed explicitly (dev only, never for a phone).
#
# Cert/key/bind come from config/security.yaml when present (tls.cert_path,
# tls.key_path, network.bind_host, network.bind_port); any missing key falls
# back to the hardcoded defaults below. See CONFIG.md. No new Python deps:
# the probe uses only `yaml` (pyyaml is already a dependency).
param([switch]$AllowPlainHttp)
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
$venvPy = Join-Path (Get-Location) "venv312\Scripts\python.exe"
$py = if (Test-Path $venvPy) { $venvPy } else { "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" }

# Hardcoded defaults — used when config/security.yaml or a key is absent.
$cert = Join-Path (Get-Location) "certs\dev-cert.pem"
$key = Join-Path (Get-Location) "certs\dev-key.pem"
$bindHost = "0.0.0.0"
$bindPort = "8443"

$secYaml = Join-Path (Get-Location) "config\security.yaml"
if (Test-Path $secYaml) {
  try {
    $probe = @'
import yaml
d = yaml.safe_load(open("config/security.yaml", encoding="utf-8")) or {}
tls = d.get("tls") or {}
net = d.get("network") or {}
print(tls.get("cert_path") or "")
print(tls.get("key_path") or "")
print(net.get("bind_host") or "")
print(net.get("bind_port") or "")
'@
    $vals = & $py -c $probe 2>$null
    if ($vals -and $vals.Count -ge 4) {
      if ($vals[0]) { $cert = Join-Path (Get-Location) $vals[0] }
      if ($vals[1]) { $key = Join-Path (Get-Location) $vals[1] }
      if ($vals[2]) { $bindHost = $vals[2] }
      if ($vals[3]) { $bindPort = $vals[3] }
    }
  } catch { }
}

if ((Test-Path $cert) -and (Test-Path $key)) {
  & $py -m uvicorn server.main:app --host $bindHost --port $bindPort --ssl-certfile $cert --ssl-keyfile $key
} elseif ($AllowPlainHttp) {
  Write-Warning "No certs found - serving PLAIN HTTP for local dev only."
  & $py -m uvicorn server.main:app --host 127.0.0.1 --port $bindPort
} else {
  throw "No TLS certs. Run scripts/gen_cert.ps1 first (or pass -AllowPlainHttp for loopback dev)."
}
