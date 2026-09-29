$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    throw "Python 3.10以降が必要です: https://www.python.org/downloads/windows/"
}

if (-not (Test-Path -LiteralPath ".venv-build\Scripts\python.exe")) {
    & py -3 -m venv .venv-build
    if ($LASTEXITCODE -ne 0) { throw "Python仮想環境の作成に失敗しました。" }
}

& .\.venv-build\Scripts\python.exe -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "pipの更新に失敗しました。" }
& .\.venv-build\Scripts\python.exe -m pip install -e ".[dev]"
if ($LASTEXITCODE -ne 0) { throw "依存パッケージのインストールに失敗しました。" }
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
if ($LASTEXITCODE -ne 0) { throw "Windowsアプリのビルドに失敗しました。" }

Compress-Archive `
    -LiteralPath ".\dist\KindleCapture.exe", ".\FIRST_RUN.txt" `
    -DestinationPath ".\dist\KindleCapture-Windows.zip" `
    -Force
Write-Host "作成完了: $PSScriptRoot\dist\KindleCapture.exe"
Write-Host "配布ZIP: $PSScriptRoot\dist\KindleCapture-Windows.zip"
