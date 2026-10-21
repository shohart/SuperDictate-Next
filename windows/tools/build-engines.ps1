<#
.SYNOPSIS
    Build the engines\ directory: silero-vad.dll (pause detection for long
    dictation) and, experimentally, superdictate-llm-host.exe.

.DESCRIPTION
    Both come from the vendored sources the macOS app is built from
    (swift/Sources/silero_vad, swift/Sources/llama_cpp_host), through
    windows\native\engines\CMakeLists.txt. The staged tree:

        engines\silero-vad.dll              whisper_vad_* (CPU only)
        engines\LICENSE-*.txt               upstream notices

    and with -ExperimentalLlmHost also

        engines\superdictate-llm-host.exe   local LLM post-processing
        engines\vulkan-shaders\*.spv        with -Vulkan only

    Release builds leave the LLM host out: on Windows, correction and
    rewrite go through a user-supplied OpenAI-compatible endpoint. The app
    offers the bundled models only when the host is present.

    Needs Visual Studio 2022 (or Build Tools) with the C++ workload and
    CMake 3.20+; -Vulkan also needs the Vulkan SDK (build time only: at run
    time the host uses the GPU driver's vulkan-1.dll). SuperDictate.spec
    copies engines\ as is.

.EXAMPLE
    .\tools\build-engines.ps1
    .\tools\build-engines.ps1 -ExperimentalLlmHost            # CPU LLM host
    .\tools\build-engines.ps1 -ExperimentalLlmHost -Vulkan    # GPU LLM host
#>
[CmdletBinding()]
param(
    [switch]$ExperimentalLlmHost,
    [switch]$Vulkan
)

$ErrorActionPreference = "Stop"
if ($Vulkan -and -not $ExperimentalLlmHost) { throw "-Vulkan applies to the LLM host: add -ExperimentalLlmHost" }

$WindowsDir = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WindowsDir
$SourceDir = Join-Path $WindowsDir "native\engines"
$BuildDir = Join-Path $SourceDir "build"
$Stage = Join-Path $WindowsDir "engines"
$Llama = Join-Path $RepoRoot "swift\Sources\llama_cpp_host\upstream"
$Vad = Join-Path $RepoRoot "swift\Sources\silero_vad"

$vs = $null
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake -and $vs) {
    $candidate = Join-Path $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (Test-Path $candidate) { $cmake = Get-Item $candidate }
}
if (-not $cmake) { throw "cmake not found: install CMake or the Visual Studio C++ workload" }
$cmakeExe = if ($cmake -is [System.Management.Automation.CommandInfo]) { $cmake.Source } else { $cmake.FullName }

if ($Vulkan -and -not $env:VULKAN_SDK) {
    # The SDK installer sets VULKAN_SDK machine-wide; a shell opened before
    # the install does not see it yet.
    $sdk = Get-ChildItem "C:\VulkanSDK" -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $sdk) { throw "Vulkan SDK not found: install it (winget install KhronosGroup.VulkanSDK)" }
    $env:VULKAN_SDK = $sdk.FullName
}

$onOff = { param($flag) if ($flag) { "ON" } else { "OFF" } }
Write-Host "Configuring windows\native\engines..." -ForegroundColor Cyan
& $cmakeExe -S $SourceDir -B $BuildDir -A x64 `
    "-DSD_LLM_HOST=$(& $onOff $ExperimentalLlmHost)" `
    "-DSD_LLM_VULKAN=$(& $onOff $Vulkan)" | Out-Host
if ($LASTEXITCODE) { throw "CMake configure failed" }

Write-Host "Building..." -ForegroundColor Cyan
& $cmakeExe --build $BuildDir --config Release --parallel | Out-Host
if ($LASTEXITCODE) { throw "CMake build failed" }

if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage | Out-Null
$binaries = @("silero-vad.dll")
Copy-Item (Join-Path $BuildDir "Release\silero-vad.dll") $Stage
Copy-Item (Join-Path $Vad "upstream\LICENSE-ggml.txt") $Stage
Copy-Item (Join-Path $Vad "upstream-vad\LICENSE-whisper-cpp.txt") $Stage
Copy-Item (Join-Path $Vad "upstream-vad\LICENSE-silero-vad.txt") $Stage
if ($ExperimentalLlmHost) {
    $binaries += "superdictate-llm-host.exe"
    Copy-Item (Join-Path $BuildDir "Release\superdictate-llm-host.exe") $Stage
    Copy-Item (Join-Path $Llama "LICENSE-llama-cpp.txt") $Stage
    if ($Vulkan) {
        Copy-Item (Join-Path $Llama "ggml-vulkan\vulkan-shaders") (Join-Path $Stage "vulkan-shaders") -Recurse
    }
}

# Everything must run on a machine with nothing but a GPU driver: no VC++
# redistributable, no Vulkan SDK.
$dumpbin = $null
if ($vs) {
    $dumpbin = Get-ChildItem (Join-Path $vs "VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe") -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $dumpbin) {
    Write-Warning "dumpbin not found: skipping the import check"
} else {
    foreach ($binary in $binaries) {
        $deps = & $dumpbin.FullName /nologo /dependents (Join-Path $Stage $binary) |
            Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim() }
        Write-Host ("$binary imports: " + ($deps -join ", ")) -ForegroundColor DarkGray
        $crt = $deps | Where-Object { $_ -match '^(vcruntime|msvcp)' }
        if ($crt) { throw "$binary depends on the VC runtime: $($crt -join ', ')" }
    }
}

if ($Vulkan) {
    & (Join-Path $Stage "superdictate-llm-host.exe") --list-devices | Out-Host
}
Write-Host "Staged engines into $Stage" -ForegroundColor Green
