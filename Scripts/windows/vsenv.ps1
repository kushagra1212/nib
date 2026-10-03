# Loads the Visual Studio C++ developer environment into this PowerShell
# session, so cl, link and the Windows SDK are on PATH for cmake and ninja.
#
#   . Scripts/windows/vsenv.ps1            # x64
#   . Scripts/windows/vsenv.ps1 -Arch arm64 # cross-compile for ARM64
param([ValidateSet('x64', 'arm64')][string]$Arch = 'x64')

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$root = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $root) { throw 'Visual Studio with the C++ workload was not found.' }

# An ARM64 machine builds natively; an x64 one cross-compiles.
$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$target = if ($Arch -eq $hostArch) { $Arch } else { "${hostArch}_$Arch" }

$vcvars = Join-Path $root 'VC\Auxiliary\Build\vcvarsall.bat'
cmd /c "`"$vcvars`" $target >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] }
}

# vcvarsall falls back to the host toolset without a word when the target's is
# not installed, and the build then fails later on a missing library. Said here.
$cl = (Get-Command cl -ErrorAction SilentlyContinue).Source
if (-not $cl) { throw 'cl.exe is not on PATH after vcvarsall; is the C++ workload installed?' }
if ($Arch -ne $hostArch -and $cl -notmatch "\$Arch\\") {
    throw "The MSVC $Arch build tools are not installed. Add 'MSVC v143 - VS 2022 C++ ARM64 build tools' in the Visual Studio Installer, or build on an $Arch machine."
}
