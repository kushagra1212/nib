# Stages nib for Windows into the layout an install has, zips it, and builds
# the MSI.
#
#   pwsh Scripts\windows\package.ps1 [-Arch x64|arm64] [-Version 1.1.0]
#
# The layout -- nib.exe and ICU beside it, the engines under engines\ -- is the
# one nib.exe looks for first, so a staged folder runs exactly as installed:
#
#   nib\
#     nib.exe  icuuc78.dll  icuin78.dll  icudt78.dll
#     engines\harper\harper-ls.exe
#     engines\llama\llama-server.exe + its DLLs
#     engines\whisper\whisper.dll + ggml
#     engines\onnx\onnxruntime.dll
#     engines\espeak\espeak-ng.dll + espeak-ng-data\
#     LICENSE.txt  THIRD-PARTY-LICENSES.txt
#
# Models are never packaged: they are a choice, and a download nib makes when
# asked.
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [string]$Version = '1.1.0',
    [switch]$NoMsi
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$build = Join-Path $root "windows\build-$Arch"
if (-not (Test-Path (Join-Path $build 'nib.exe'))) {
    $build = Join-Path $root 'windows\build'
}
$exe = Join-Path $build 'nib.exe'
if (-not (Test-Path $exe)) { throw "no nib.exe; run Scripts\windows\build.ps1 -Arch $Arch first" }
$vendor = Join-Path $root "windows\vendor\$Arch"

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist "nib-$Version-windows-$Arch"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

Copy-Item $exe $stage
Copy-Item (Join-Path $vendor 'icu\bin\*.dll') $stage
$engines = Join-Path $stage 'engines'
foreach ($engine in 'harper', 'llama', 'whisper', 'onnx', 'espeak') {
    $from = Join-Path $vendor $engine
    if (-not (Test-Path $from)) {
        Write-Warning "$engine is missing for $Arch; that feature will report itself unavailable"
        continue
    }
    $to = Join-Path $engines $engine
    New-Item -ItemType Directory -Force $to | Out-Null
    Get-ChildItem $from -Force | Where-Object { $_.Name -ne '.version' -and $_.Name -ne 'LICENSE' } |
        Copy-Item -Destination $to -Recurse
}

Copy-Item (Join-Path $root 'LICENSE') (Join-Path $stage 'LICENSE.txt')
$licences = (Get-Content -Raw (Join-Path $root 'THIRD-PARTY-LICENSES.txt')) + "`r`n`r`n" +
            (Get-Content -Raw (Join-Path $root 'windows\THIRD-PARTY-WINDOWS.txt'))
foreach ($pair in @(@('ICU', 'icu\LICENSE'), @('ONNX Runtime', 'onnx\LICENSE'), @('llama.cpp', 'llama\LICENSE'))) {
    $file = Join-Path $vendor $pair[1]
    if (Test-Path $file) {
        $licences += "`r`n`r`n-------------------------------------------------------------------------------`r`n" +
                     "$($pair[0])`r`n-------------------------------------------------------------------------------`r`n`r`n" +
                     (Get-Content -Raw $file)
    }
}
Set-Content -Path (Join-Path $stage 'THIRD-PARTY-LICENSES.txt') -Value $licences -Encoding utf8

# A portable zip: unzip anywhere, run nib.exe.
$zip = "$stage.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "zip: $zip ($size MB)"

if ($NoMsi) { return }

# The MSI, through WiX v5 as a .NET tool: per-user, into %LOCALAPPDATA%, no
# administrator prompt -- the same promise as everything else nib does.
# A user-scoped .NET install is not where a tool's launcher looks by default.
if (-not $env:DOTNET_ROOT) {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnet) { $env:DOTNET_ROOT = Split-Path $dotnet.Source }
}
$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) {
    dotnet tool install --global wix --version 5.0.2 | Out-Host
    $env:PATH += ";$env:USERPROFILE\.dotnet\tools"
}
$msi = "$stage.msi"
wix build (Join-Path $root 'windows\installer\nib.wxs') `
    -arch $Arch `
    -d "Version=$Version" -d "StageDir=$stage" `
    -bindpath "$stage" `
    -o $msi
if ($LASTEXITCODE) { throw 'wix build failed' }
$size = [math]::Round((Get-Item $msi).Length / 1MB, 1)
Write-Host "msi: $msi ($size MB)"

$hashes = Get-FileHash $zip, $msi -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  $(Split-Path $_.Path -Leaf)" }
Set-Content -Path "$stage.sha256" -Value $hashes
$hashes
