<#
.SYNOPSIS
    Build SuperDictate into dist\SuperDictate\SuperDictate.exe.

.DESCRIPTION
    Regenerates the icon, runs the self-tests (a failing port should never
    reach a build), builds and stages SuperDictateOnnxHost
    (tools\build-onnx-host.ps1) and the LLM host and Silero VAD
    (tools\build-engines.ps1), then packages with PyInstaller.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -SkipTests
    .\build.ps1 -SkipEngines     # no Vulkan SDK: ship without LLM and VAD
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$SkipEngines,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$python = ".\.venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    throw "Virtual environment not found. Create it with: python -m venv .venv; .\.venv\Scripts\pip install -r requirements.txt"
}

if ($Clean) {
    Write-Host "Cleaning build/ and dist/..." -ForegroundColor Cyan
    Remove-Item build, dist -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Generating icon..." -ForegroundColor Cyan
$env:QT_QPA_PLATFORM = "offscreen"
& $python tools\make_icon.py
Remove-Item Env:\QT_QPA_PLATFORM

if (-not $SkipTests) {
    Write-Host "Running self-tests..." -ForegroundColor Cyan
    & $python main.py --self-test
    if ($LASTEXITCODE -ne 0) { throw "Self-tests failed; not building." }
}

Write-Host "Building the speech-recognition host..." -ForegroundColor Cyan
& .\tools\build-onnx-host.ps1
if ($LASTEXITCODE) { throw "build-onnx-host failed." }

if (-not $SkipEngines) {
    Write-Host "Building the LLM host and Silero VAD..." -ForegroundColor Cyan
    & .\tools\build-engines.ps1
    if ($LASTEXITCODE) { throw "build-engines failed." }
}

Write-Host "Packaging with PyInstaller..." -ForegroundColor Cyan
& $python -m PyInstaller --noconfirm SuperDictate.spec
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed." }

$exe = "dist\SuperDictate\SuperDictate.exe"
if (-not (Test-Path $exe)) { throw "Expected $exe, but it was not produced." }

$size = [math]::Round((Get-ChildItem dist\SuperDictate -Recurse |
                       Measure-Object -Property Length -Sum).Sum / 1MB, 1)
Write-Host ""
Write-Host "Built $exe ($size MB folder)" -ForegroundColor Green
Write-Host "The speech model (~600 MB) downloads on first run." -ForegroundColor DarkGray
