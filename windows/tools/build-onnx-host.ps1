<#
.SYNOPSIS
    Build SuperDictateOnnxHost.exe (native\asr-runtime) and stage it, with
    ONNX Runtime and the speech-model resources, into windows\onnx-asr\.

.DESCRIPTION
    The Windows counterpart of scripts/build-onnx-host.sh. The staged tree is
    flat, like the macOS bundle's Resources/onnx-asr/:

        onnx-asr\SuperDictateOnnxHost.exe   static MSVC runtime (/MT)
        onnx-asr\onnxruntime.dll            ONNX Runtime 1.23.2, pinned
        onnx-asr\onnx-models.json           pinned model catalog
        onnx-asr\nemo128.onnx               bundled feature graph (Parakeet)
        onnx-asr\gigaam_v3.onnx             bundled feature graph (GigaAM v3)
        onnx-asr\ThirdPartyNotices.txt, onnxruntime-LICENSE.txt, onnx-asr-LICENSE.txt

    The app finds it there both when run from source and inside the
    PyInstaller folder (SuperDictate.spec copies it as is).

    Needs CMake 3.20+ and Visual Studio 2022 (or Build Tools) with the C++
    workload; run from any shell, the VS generator finds the compiler.

.EXAMPLE
    .\tools\build-onnx-host.ps1
    .\tools\build-onnx-host.ps1 -Test     # also run the native contract/IPC tests
#>
[CmdletBinding()]
param(
    [switch]$Test
)

$ErrorActionPreference = "Stop"

$WindowsDir = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WindowsDir
$RuntimeDir = Join-Path $RepoRoot "native\asr-runtime"
$BuildDir = Join-Path $RuntimeDir "build-win"
$Stage = Join-Path $WindowsDir "onnx-asr"
$OrtRoot = Join-Path $RuntimeDir "third_party\onnxruntime\win-x64"

& (Join-Path $RepoRoot "scripts\fetch-onnxruntime.ps1")
if ($LASTEXITCODE) { throw "fetch-onnxruntime failed" }

# Visual Studio or Build Tools, wherever installed (Build Tools land under
# Program Files (x86)).
$vs = $null
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}

$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake -and $vs) {
    # Visual Studio ships its own CMake; use it when none is on PATH.
    $candidate = Join-Path $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (Test-Path $candidate) { $cmake = Get-Item $candidate }
}
if (-not $cmake) { throw "cmake not found: install CMake or the Visual Studio C++ workload" }
$cmakeExe = if ($cmake -is [System.Management.Automation.CommandInfo]) { $cmake.Source } else { $cmake.FullName }
$ctestExe = Join-Path (Split-Path -Parent $cmakeExe) "ctest.exe"

Write-Host "Configuring native\asr-runtime..." -ForegroundColor Cyan
& $cmakeExe -S $RuntimeDir -B $BuildDir -A x64 `
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded" `
    "-DSD_ASR_BUILD_TESTS=$(if ($Test) { 'ON' } else { 'OFF' })" | Out-Host
if ($LASTEXITCODE) { throw "CMake configure failed" }

Write-Host "Building SuperDictateOnnxHost..." -ForegroundColor Cyan
& $cmakeExe --build $BuildDir --config Release --parallel | Out-Host
if ($LASTEXITCODE) { throw "CMake build failed" }

$Host_ = Join-Path $BuildDir "Release\SuperDictateOnnxHost.exe"
if (-not (Test-Path $Host_)) { throw "the build did not produce $Host_" }

if ($Test) {
    Write-Host "Running native tests..." -ForegroundColor Cyan
    & $ctestExe --test-dir $BuildDir -C Release --output-on-failure | Out-Host
    if ($LASTEXITCODE) { throw "native tests failed" }
}

if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage | Out-Null
Copy-Item $Host_ $Stage
Copy-Item (Join-Path $OrtRoot "lib\onnxruntime.dll") $Stage
Copy-Item (Join-Path $RuntimeDir "catalog\onnx-models.json") $Stage
Copy-Item (Join-Path $RuntimeDir "assets\nemo128.onnx") $Stage
Copy-Item (Join-Path $RuntimeDir "assets\gigaam_v3.onnx") $Stage
Copy-Item (Join-Path $RuntimeDir "assets\onnx-asr-LICENSE.txt") $Stage
Copy-Item (Join-Path $OrtRoot "ThirdPartyNotices.txt") $Stage
Copy-Item (Join-Path $OrtRoot "LICENSE") (Join-Path $Stage "onnxruntime-LICENSE.txt")

# Packaging check (spec section 10): the host must load ONNX Runtime from
# beside itself and need no Visual C++ redistributable of its own.
$dumpbin = $null
if ($vs) {
    $dumpbin = Get-ChildItem (Join-Path $vs "VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe") -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $dumpbin) {
    Write-Warning "dumpbin not found: skipping the import check of SuperDictateOnnxHost.exe"
} else {
    $deps = & $dumpbin.FullName /nologo /dependents (Join-Path $Stage "SuperDictateOnnxHost.exe") |
        Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim() }
    Write-Host ("SuperDictateOnnxHost.exe imports: " + ($deps -join ", ")) -ForegroundColor DarkGray
    $crt = $deps | Where-Object { $_ -match '^(vcruntime|msvcp)' }
    if ($crt) { throw "SuperDictateOnnxHost.exe depends on the VC runtime: $($crt -join ', ')" }
    if ($deps -notcontains "onnxruntime.dll") { throw "SuperDictateOnnxHost.exe does not import onnxruntime.dll" }
}

Write-Host "Staged SuperDictateOnnxHost and ONNX Runtime into $Stage" -ForegroundColor Green
