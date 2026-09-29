$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    throw "Python 3.10 or later is required: https://www.python.org/downloads/windows/"
}

if (-not (Test-Path -LiteralPath ".venv-build\Scripts\python.exe")) {
    & py -3 -m venv .venv-build
    if ($LASTEXITCODE -ne 0) { throw "Failed to create the Python virtual environment." }
}

& .\.venv-build\Scripts\python.exe -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "Failed to upgrade pip." }
& .\.venv-build\Scripts\python.exe -m pip install -e ".[dev]"
if ($LASTEXITCODE -ne 0) { throw "Failed to install build dependencies." }
& .\.venv-build\Scripts\python.exe -m PyInstaller `
    --noconfirm `
    --clean `
    --onefile `
    --windowed `
    --name "KindleCapture" `
    --hidden-import winrt.windows.foundation `
    --hidden-import winrt.windows.foundation.collections `
    --hidden-import winrt.windows.globalization `
    --hidden-import winrt.windows.graphics.imaging `
    --hidden-import winrt.windows.media.ocr `
    --hidden-import winrt.windows.storage.streams `
    app_entry.py
if ($LASTEXITCODE -ne 0) { throw "Failed to build the Windows application." }

Compress-Archive `
    -LiteralPath ".\dist\KindleCapture.exe", ".\FIRST_RUN.txt" `
    -DestinationPath ".\dist\KindleCapture-Windows.zip" `
    -Force
Write-Host "Build complete: $PSScriptRoot\dist\KindleCapture.exe"
Write-Host "Distribution ZIP: $PSScriptRoot\dist\KindleCapture-Windows.zip"
