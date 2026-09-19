$ErrorActionPreference = "Continue"
$env:PYTHONUTF8 = "1"
Set-Location -LiteralPath "C:\Users\hiren\OneDrive\Desktop\ME\maxxy"
.\venv312\Scripts\python.exe -m pip install --upgrade pip 2>&1 | Tee-Object -FilePath pip312.log
.\venv312\Scripts\python.exe -m pip install -e "./[dev]" 2>&1 | Tee-Object -FilePath pip312.log -Append
.\venv312\Scripts\python.exe -m pip install crewai 2>&1 | Tee-Object -FilePath pip312.log -Append
.\venv312\Scripts\python.exe -m pytest tests/ -q 2>&1 | Tee-Object -FilePath pip312.log -Append
