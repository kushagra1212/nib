# Downloads every engine nib bundles on Windows into windows\vendor\.
#
#   pwsh Scripts\windows\fetch-engines.ps1            # x64
#   pwsh Scripts\windows\fetch-engines.ps1 -Arch arm64
#
# The same engines and versions as macOS (see docs\windows-engine-assets.md),
# so both platforms underline and rewrite the same way:
#
#   icu        78.3     unicode-org official MSVC build
#   harper     2.8.0    harper-ls; arm64 is extracted from the VS Code .vsix
#   llama      b10400   llama-server, CPU build
#   whisper    b4938    whisper.dll, linked at runtime for dictation
#   onnx       1.29.0   onnxruntime.dll, for the Kokoro voice
#   espeak     0.2.4    espeak-ng.dll and its data, from the loader wheel
#
# Each engine lands in windows\vendor\<arch>\<engine>\ with a .version file,
# and is skipped when that version is already present.
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [string[]]$Only
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is 10x slower with it

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$vendor = Join-Path $root "windows\vendor\$Arch"
$work = Join-Path ([IO.Path]::GetTempPath()) "nib-fetch-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force $vendor, $work | Out-Null

function Wanted($name) { -not $Only -or $Only -contains $name }

function Present($dir, $version) {
    $stamp = Join-Path $dir '.version'
    (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $version)
}

function Stamp($dir, $version) { Set-Content -Path (Join-Path $dir '.version') -Value $version }

function Fetch($url, $name) {
    $out = Join-Path $work $name
    Write-Host "  $url"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    $out
}

function Fresh($dir) {
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force $dir | Out-Null
}

try {
    # --- ICU --------------------------------------------------------------
    if (Wanted 'icu') {
        $v = '78.3'
        $dir = Join-Path $vendor 'icu'
        if (-not (Present $dir $v)) {
            Write-Host "icu $v"
            $asset = if ($Arch -eq 'x64') { "icu4c-$v-Win64-MSVC2022.zip" } else { "icu4c-$v-WinARM64-MSVC2022.zip" }
            $zip = Fetch "https://github.com/unicode-org/icu/releases/download/release-$v/$asset" $asset
            $x = Join-Path $work 'icu'
            Expand-Archive $zip $x -Force
            Fresh $dir
            $bin = Get-ChildItem $x -Directory | Where-Object Name -like 'bin*' | Select-Object -First 1
            $lib = Get-ChildItem $x -Directory | Where-Object Name -like 'lib*' | Select-Object -First 1
            Copy-Item -Recurse (Join-Path $x 'include') (Join-Path $dir 'include')
            New-Item -ItemType Directory -Force (Join-Path $dir 'lib'), (Join-Path $dir 'bin') | Out-Null
            Copy-Item (Join-Path $lib.FullName '*.lib') (Join-Path $dir 'lib')
            # Only the three libraries nib links. The tools and test DLLs are
            # half the archive and nothing loads them.
            Copy-Item (Join-Path $bin.FullName 'icuuc*.dll'), (Join-Path $bin.FullName 'icuin*.dll'), (Join-Path $bin.FullName 'icudt*.dll') (Join-Path $dir 'bin')
            Copy-Item (Join-Path $x 'LICENSE') (Join-Path $dir 'LICENSE')
            Stamp $dir $v
        }
    }

    # --- harper-ls ----------------------------------------------------------
    if (Wanted 'harper') {
        $v = '2.8.0'
        $dir = Join-Path $vendor 'harper'
        if (-not (Present $dir $v)) {
            Write-Host "harper-ls $v"
            Fresh $dir
            if ($Arch -eq 'x64') {
                $zip = Fetch "https://github.com/Automattic/harper/releases/download/v$v/harper-ls-x86_64-pc-windows-msvc.zip" 'harper.zip'
                $x = Join-Path $work 'harper'
                Expand-Archive $zip $x -Force
            } else {
                # No standalone ARM64 build is published; the VS Code
                # extension carries one, and a .vsix is an ordinary zip.
                $vsix = Fetch "https://github.com/Automattic/harper/releases/download/v$v/harper-win32-arm64-$v.vsix" 'harper.zip'
                $x = Join-Path $work 'harper'
                Expand-Archive $vsix $x -Force
            }
            $exe = Get-ChildItem $x -Recurse -Filter 'harper-ls.exe' | Select-Object -First 1
            if (-not $exe) { throw 'harper-ls.exe not found in the archive' }
            Copy-Item $exe.FullName (Join-Path $dir 'harper-ls.exe')
            Stamp $dir $v
        }
    }

    # --- llama-server ---------------------------------------------------------
    if (Wanted 'llama') {
        $v = 'b10400'
        $dir = Join-Path $vendor 'llama'
        if (-not (Present $dir $v)) {
            Write-Host "llama.cpp $v"
            $asset = "llama-$v-bin-win-cpu-$Arch.zip"
            # nib's own mirror first: upstream prunes release assets within
            # days. Upstream is the fallback until the mirror carries Windows.
            $zip = $null
            foreach ($url in @("https://github.com/kushagra1212/nib/releases/download/llama-runtime-$v/$asset",
                               "https://github.com/ggml-org/llama.cpp/releases/download/$v/$asset")) {
                try { $zip = Fetch $url $asset; break } catch { Write-Host "    not there" }
            }
            if (-not $zip) { throw "llama.cpp $v for $Arch could not be downloaded" }
            $x = Join-Path $work 'llama'
            Expand-Archive $zip $x -Force
            Fresh $dir
            # llama-server and the DLLs it loads travel together. The other
            # tools in the archive are left out: nib runs only the server.
            $server = Get-ChildItem $x -Recurse -Filter 'llama-server.exe' | Select-Object -First 1
            Copy-Item $server.FullName $dir
            # The -impl DLLs for the bench, quantize and cli tools ship in the
            # same folder and are 10MB nib never loads.
            Get-ChildItem $server.DirectoryName -Filter '*.dll' |
                Where-Object { $_.Name -notmatch '^llama-(batched-bench|bench|cli|completion|fit-params|perplexity|quantize)-impl\.dll$' } |
                Copy-Item -Destination $dir
            Get-ChildItem $x -Recurse -Filter 'LICENSE*' | Select-Object -First 1 | Copy-Item -Destination (Join-Path $dir 'LICENSE')
            Stamp $dir $v
        }
    }

    # --- whisper ---------------------------------------------------------------
    if (Wanted 'whisper') {
        $v = 'b4938.1'
        $dir = Join-Path $vendor 'whisper'
        if (-not (Present $dir $v)) {
            Write-Host "whisper.cpp b4938"
            if ($Arch -ne 'x64') {
                Write-Warning "whisper.cpp b4938 publishes no ARM64 Windows build; dictation needs one built from source"
            } else {
                $zip = Fetch "https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-bin-x64.zip" 'whisper.zip'
                $x = Join-Path $work 'whisper'
                Expand-Archive $zip $x -Force
                Fresh $dir
                # whisper.dll, ggml and every CPU backend variant: ggml picks the
                # one matching this processor at runtime, and with none present
                # whisper has no backend to run on.
                Get-ChildItem $x -Recurse -Include 'whisper.dll', 'ggml.dll', 'ggml-base.dll', 'ggml-cpu-*.dll' |
                    Copy-Item -Destination $dir
                if (-not (Test-Path (Join-Path $dir 'whisper.dll'))) { throw 'whisper.dll not found in the archive' }
                Stamp $dir $v
            }
        }
    }

    # --- onnxruntime -------------------------------------------------------------
    if (Wanted 'onnx') {
        $v = '1.29.0'
        $dir = Join-Path $vendor 'onnx'
        if (-not (Present $dir $v)) {
            Write-Host "onnxruntime $v"
            $asset = "onnxruntime-win-$Arch-$v.zip"
            $zip = Fetch "https://github.com/microsoft/onnxruntime/releases/download/v$v/$asset" $asset
            $x = Join-Path $work 'onnx'
            Expand-Archive $zip $x -Force
            Fresh $dir
            $dll = Get-ChildItem $x -Recurse -Filter 'onnxruntime.dll' | Select-Object -First 1
            Copy-Item $dll.FullName $dir
            Get-ChildItem $x -Recurse -Filter 'LICENSE*' | Select-Object -First 1 | Copy-Item -Destination (Join-Path $dir 'LICENSE')
            Stamp $dir $v
        }
    }

    # --- espeak-ng -------------------------------------------------------------
    if (Wanted 'espeak') {
        $v = '0.2.4'
        $dir = Join-Path $vendor 'espeak'
        if (-not (Present $dir $v)) {
            Write-Host "espeak-ng (loader $v)"
            $wheels = @{
                'x64'   = 'https://files.pythonhosted.org/packages/9d/ed/a3d872fbad4f3a3f3db0e8c31768ab14e77cd77306de16b8b20b1e1df7ea/espeakng_loader-0.2.4-py3-none-win_amd64.whl'
                'arm64' = 'https://files.pythonhosted.org/packages/29/64/0b75bc50ec53b4e000bac913625511215aa96124adf5dba8c4baa17c02cd/espeakng_loader-0.2.4-py3-none-win_arm64.whl'
            }
            $whl = Fetch $wheels[$Arch] 'espeak.zip'   # a wheel is a zip
            $x = Join-Path $work 'espeak'
            Expand-Archive $whl $x -Force
            Fresh $dir
            $dll = Get-ChildItem $x -Recurse -Filter '*.dll' | Where-Object Name -like '*espeak*' | Select-Object -First 1
            if (-not $dll) { throw 'espeak-ng DLL not found in the wheel' }
            Copy-Item $dll.FullName (Join-Path $dir 'espeak-ng.dll')
            $data = Get-ChildItem $x -Recurse -Directory -Filter 'espeak-ng-data' | Select-Object -First 1
            if (-not $data) { throw 'espeak-ng-data not found in the wheel' }
            Copy-Item -Recurse $data.FullName (Join-Path $dir 'espeak-ng-data')
            Stamp $dir $v
        }
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host "engines in $vendor"
Get-ChildItem $vendor -Directory | ForEach-Object {
    $stamp = Join-Path $_.FullName '.version'
    $ver = if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { '?' }
    '  {0,-8} {1}' -f $_.Name, $ver
}
