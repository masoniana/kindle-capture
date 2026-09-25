$ErrorActionPreference = "Stop"

$compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not [System.IO.File]::Exists($compiler)) {
    throw ".NET Framework C# compiler was not found: $compiler"
}

$launcher = Join-Path $PSScriptRoot "KindleCaptureLauncher.cs"
$guiScript = Join-Path $PSScriptRoot "KindleCapture-GUI.ps1"
$coreScript = Join-Path $PSScriptRoot "KindleCapture-Core.ps1"
$executable = Join-Path $PSScriptRoot "KindleCapture.exe"
$archive = Join-Path $PSScriptRoot "KindleCapture.zip"

& $compiler `
    /nologo `
    /target:winexe `
    /optimize+ `
    /reference:System.Windows.Forms.dll `
    "/resource:$guiScript,KindleCapture.GuiScript" `
    "/resource:$coreScript,KindleCapture.CoreScript" `
    "/out:$executable" `
    $launcher

if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE."
}

Compress-Archive -LiteralPath $executable -DestinationPath $archive -CompressionLevel Optimal -Force
Write-Output "Built: $executable"
Write-Output "Packed: $archive"
