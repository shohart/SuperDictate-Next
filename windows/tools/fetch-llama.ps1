<#
.SYNOPSIS
    Stage engines\llama\: llama.cpp's own llama-server (Vulkan build), the
    local LLM host for the correction stage.

.DESCRIPTION
    The official Windows Vulkan release of llama.cpp, pinned by build number
    and SHA-256, unpacked and trimmed to what llama-server needs:

        engines\llama\llama-server.exe (+ llama-server-impl.dll)
        engines\llama\llama.dll, llama-common.dll, mtmd.dll
        engines\llama\ggml*.dll        ggml, Vulkan and every CPU variant
                                       (picked at run time by CPU features)
        engines\llama\libomp.dll, LICENSE-*

    It speaks the same /health and /v1/chat/completions as the hand-written
    macOS host, so llm\host.py drives either; see its docstring for the
    flags this build needs (a LoRA scale is "--lora-scaled FILE:SCALE", and
    cooperative-matrix shaders are off on Intel's driver).

    Why a prebuilt binary and not the vendored sources: it is the backend the
    benchmark on the target (Core Ultra 5 225H, Arc 130T) was measured with,
    and it needs neither Visual Studio nor the Vulkan SDK to build. Vulkan
    itself is the GPU driver's vulkan-1.dll.

    The zip is cached in tools\.cache and verified before every use.

.EXAMPLE
    .\tools\fetch-llama.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 redraws the progress bar per chunk, which slows a
# 35 MB download to a crawl.
$ProgressPreference = "SilentlyContinue"

$Build = "b11826"
$Asset = "llama-$Build-bin-win-vulkan-x64.zip"
$Url = "https://github.com/ggml-org/llama.cpp/releases/download/$Build/$Asset"
$Sha256 = "20ea4d13f0762b60281ba54d5e48d83de6d3688ca2bf41c280fb28a0596c4bb0"

$WindowsDir = Split-Path -Parent $PSScriptRoot
$Cache = Join-Path $PSScriptRoot ".cache"
$Zip = Join-Path $Cache $Asset
$Stage = Join-Path $WindowsDir "engines\llama"

New-Item -ItemType Directory -Force $Cache | Out-Null
if (-not (Test-Path $Zip) -or (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLower() -ne $Sha256) {
    Write-Host "Downloading llama.cpp $Build (Vulkan)..." -ForegroundColor Cyan
    $partial = "$Zip.part"
    Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
    $actual = (Get-FileHash $partial -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Sha256) {
        Remove-Item $partial -Force
        throw "$Asset SHA-256 mismatch: $actual"
    }
    Move-Item $partial $Zip -Force
}

$unpacked = Join-Path $Cache "llama-$Build-vulkan"
Remove-Item $unpacked -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $Zip -DestinationPath $unpacked

Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Stage | Out-Null
$keep = @("llama-server.exe", "llama-server-impl.dll", "llama.dll", "llama-common.dll",
          "mtmd.dll", "libomp.dll", "ggml*.dll", "LICENSE*")
foreach ($pattern in $keep) {
    Copy-Item (Join-Path $unpacked $pattern) $Stage
}
Remove-Item $unpacked -Recurse -Force

if (-not (Test-Path (Join-Path $Stage "llama-server.exe"))) { throw "llama-server.exe was not staged" }
$size = [math]::Round((Get-ChildItem $Stage | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
Write-Host "Staged engines\llama ($size MB, llama.cpp $Build Vulkan)" -ForegroundColor Green
