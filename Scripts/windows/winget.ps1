# Renders the winget manifests in windows\winget for a published release, into
# dist\winget\<version>, ready to submit to microsoft/winget-pkgs with
# `wingetcreate submit` or a pull request.
#
#   pwsh Scripts\windows\winget.ps1 -Version 1.1.0
#
# The checksums are read from the release's own MSIs, downloaded fresh, so the
# manifest describes exactly what winget will fetch.
param([Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $root "dist\winget\$Version"
New-Item -ItemType Directory -Force $out | Out-Null

$sha = @{}
foreach ($arch in 'x64', 'arm64') {
    $url = "https://github.com/kushagra1212/nib/releases/download/v$Version/nib-$Version-windows-$arch.msi"
    $file = Join-Path $env:TEMP "nib-$Version-$arch.msi"
    Invoke-WebRequest $url -OutFile $file -UseBasicParsing
    $sha[$arch] = (Get-FileHash $file -Algorithm SHA256).Hash
}
Get-ChildItem (Join-Path $root 'windows\winget') -Filter *.yaml | ForEach-Object {
    (Get-Content -Raw $_.FullName).Replace('${VERSION}', $Version).
        Replace('${SHA256_X64}', $sha['x64']).Replace('${SHA256_ARM64}', $sha['arm64']) |
        Set-Content -Path (Join-Path $out $_.Name) -Encoding utf8
}
Write-Host "manifests in $out"
