<#
.SYNOPSIS
    Download the pinned ONNX Runtime SDK for win-x64, verify its SHA-256 and
    extract it to native\asr-runtime\third_party\onnxruntime\win-x64\.

.DESCRIPTION
    The Windows counterpart of scripts/fetch-onnxruntime.sh: same version,
    same digest (docs/specs/cross-platform-onnx-asr-spec.md section 2.1).
    Bumping the pin means bumping it in both scripts together.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$OrtVersion = "1.23.2"
$Platform = "win-x64"
$Sha256 = "0b38df9af21834e41e73d602d90db5cb06dbd1ca618948b8f1d66d607ac9f3cd"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Dest = Join-Path $RepoRoot "native\asr-runtime\third_party\onnxruntime\$Platform"
$Name = "onnxruntime-$Platform-$OrtVersion"
$Url = "https://github.com/microsoft/onnxruntime/releases/download/v$OrtVersion/$Name.zip"
$Stamp = Join-Path $Dest ".sd-ort-version"

if ((Test-Path $Stamp) -and ((Get-Content $Stamp -Raw).Trim() -eq "$OrtVersion $Sha256")) {
    Write-Host "fetch-onnxruntime: $Platform $OrtVersion already present at $Dest"
    exit 0
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("sd-ort-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Work | Out-Null
try {
    $Archive = Join-Path $Work "archive.zip"
    Write-Host "fetch-onnxruntime: downloading $Url"
    $ProgressPreference = "SilentlyContinue"   # the progress bar makes IWR ~10x slower
    Invoke-WebRequest -Uri $Url -OutFile $Archive -UseBasicParsing

    $Actual = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
    if ($Actual -ne $Sha256) {
        throw "fetch-onnxruntime: SHA-256 mismatch for $Name.zip`n  expected $Sha256`n  actual   $Actual"
    }

    $Extracted = Join-Path $Work "x"
    Expand-Archive -Path $Archive -DestinationPath $Extracted
    if (-not (Test-Path (Join-Path $Extracted "$Name\include"))) {
        throw "fetch-onnxruntime: unexpected archive layout"
    }

    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Dest) -Force | Out-Null
    Move-Item (Join-Path $Extracted $Name) $Dest
    Set-Content -Path $Stamp -Value "$OrtVersion $Sha256" -NoNewline
    Write-Host "fetch-onnxruntime: $Platform $OrtVersion -> $Dest"
}
finally {
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}
