#Requires -Version 5.1
# Manual Flutter SDK install (winget has no Google.Flutter package in this environment).
# Downloads latest stable, extracts to C:\src\flutter, precaches. Logs to flutter_install.log.
$ErrorActionPreference = "Stop"
$log = "C:\Users\hiren\OneDrive\Desktop\ME\maxxy\flutter_install.log"
function Log($m) { $m | Tee-Object -FilePath $log -Append; Write-Output $m }
if (Get-Command flutter -ErrorAction SilentlyContinue) { Log "flutter already installed: $(flutter --version | Select-Object -First 1)"; exit 0 }
New-Item -ItemType Directory -Path "C:\src" -Force | Out-Null
$rel = Invoke-RestMethod -Uri "https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json"
$stable = $rel.current_release.stable
$arch = $rel.releases | Where-Object { $_.hash -eq $stable -and $_.channel -eq "stable" } | Select-Object -First 1
$zipUrl = $rel.base_url + "/" + $arch.archive
Log "downloading $zipUrl"
Invoke-WebRequest -Uri $zipUrl -OutFile "C:\src\flutter_sdk.zip"
Log "extracting to C:\src\flutter"
if (Test-Path "C:\src\flutter") { Remove-Item "C:\src\flutter" -Recurse -Force }
Expand-Archive -LiteralPath "C:\src\flutter_sdk.zip" -DestinationPath "C:\src"
Remove-Item "C:\src\flutter_sdk.zip" -Force
$env:PATH = "C:\src\flutter\bin;$env:PATH"
[Environment]::SetEnvironmentVariable("PATH", "C:\src\flutter\bin;" + [Environment]::GetEnvironmentVariable("PATH", "User"), "User")
Log "precaching + version:"
& "C:\src\flutter\bin\flutter.bat" --version 2>&1 | Tee-Object -FilePath $log -Append
& "C:\src\flutter\bin\flutter.bat" precache 2>&1 | Select-Object -Last 2 | Tee-Object -FilePath $log -Append
Log "flutter install complete"
