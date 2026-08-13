$ErrorActionPreference = "Stop"
$env:PYTHONUNBUFFERED = "1"

$devices = "C:\Users\siddh\haystack-secrets\devices.json"
if (-not (Test-Path $devices)) {
  Write-Error "Copy your _devices.json to $devices once. Do not put it on GitHub."
}

$python = "C:\Users\siddh\AppData\Local\Python\pythoncore-3.14-64\python.exe"
& $python -m pip install --quiet cryptography requests
& $python "$PSScriptRoot\publish_locations.py" --devices $devices --interval 600
