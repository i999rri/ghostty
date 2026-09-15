# Compile HLSL shaders to CSO (Compiled Shader Object) files
# Requires Windows SDK (fxc.exe)
# Usage: powershell -File compile_shaders.ps1

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $scriptDir "compiled"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$fxc = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\fxc.exe"
if (-not (Test-Path $fxc)) { throw "fxc.exe not found at $fxc" }

$common = Get-Content (Join-Path $scriptDir "common.hlsl") -Raw
$shaders = @("bg_color", "cell_bg", "cell_text", "image", "bg_image")

foreach ($name in $shaders) {
    $hlslPath = Join-Path $scriptDir "$name.hlsl"
    $hlslContent = $common + "`n" + (Get-Content $hlslPath -Raw)

    # Write combined HLSL to temp file (fxc needs a file)
    $tempFile = Join-Path $outDir "_temp_$name.hlsl"
    [System.IO.File]::WriteAllText($tempFile, $hlslContent, (New-Object System.Text.UTF8Encoding $false))

    $vsOut = Join-Path $outDir "${name}_vs.cso"
    $psOut = Join-Path $outDir "${name}_ps.cso"

    Write-Host "Compiling $name VS..."
    & $fxc /T vs_5_0 /E vs_main /O3 /Fo $vsOut $tempFile
    if ($LASTEXITCODE -ne 0) { throw "Failed to compile $name vertex shader" }

    Write-Host "Compiling $name PS..."
    & $fxc /T ps_5_0 /E ps_main /O3 /Fo $psOut $tempFile
    if ($LASTEXITCODE -ne 0) { throw "Failed to compile $name pixel shader" }

    Remove-Item $tempFile
    Write-Host "  -> $vsOut, $psOut"
}

Write-Host "All shaders compiled successfully!"
