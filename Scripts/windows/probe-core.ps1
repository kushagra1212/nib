# Loads the core DLL that would ship and checks it actually works.
#
# A DLL that links is not a DLL that runs: ICU's data can be missing while the
# import table still looks right, and the failure only appears when something
# asks for a break iterator. So this calls across the ABI rather than merely
# resolving a symbol.
#
#   pwsh Scripts/windows/probe-core.ps1 -Directory path\to\core-bin
param(
    [Parameter(Mandatory = $true)]
    [string]$Directory
)

$ErrorActionPreference = 'Stop'

$dir = (Resolve-Path $Directory).Path
Get-ChildItem $dir | Format-Table Name, Length | Out-String | Write-Host

# Everything is loaded by absolute path, and none of it relies on PATH.
#
# Setting $env:PATH looks like it should work and does nothing. .NET resolves
# DllImport with the LOAD_LIBRARY_SEARCH_* flags, which replace the legacy
# search order and deliberately leave PATH out of it. The first version of this
# script set PATH, the DLL was not found, and .NET then probed the calling
# assembly's own directory -- which for a type built by Add-Type is an
# in-memory assembly whose Location is "". Path.GetDirectoryName("") is null,
# so the not-found path died inside Path.Combine:
#
#   Exception calling "nib_abi_version" with "0" argument(s):
#   "Value cannot be null. (Parameter 'path1')"
#
# That error names neither the DLL nor the directory, and says nothing about a
# library being missing. Hence the absolute paths below, and the checks first.
$expected = 'libnibcore.dll', 'icuuc78.dll', 'icudt78.dll'
foreach ($name in $expected) {
    $path = Join-Path $dir $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "missing $name in $dir -- the artifact is incomplete"
    }
}

$core = Join-Path $dir 'libnibcore.dll'

# Loaded leaf first, by absolute path, rather than letting the loader find
# them.
#
# .NET calls SetDefaultDllDirectories at startup, which replaces the legacy
# search order with the LOAD_LIBRARY_SEARCH_* one. Under that, the directory
# holding a DLL is not searched for its dependencies, so loading
# libnibcore.dll by absolute path still leaves icuuc78.dll unfindable. Once a
# module is in the process under its own name the loader matches it by name
# and does not search at all, so loading in dependency order sidesteps the
# question entirely.
$order = 'icudt78.dll', 'icuuc78.dll', 'libnibcore.dll'
foreach ($name in $order) {
    $path = Join-Path $dir $name
    try {
        $handle = [System.Runtime.InteropServices.NativeLibrary]::Load($path)
        Write-Host "loaded $name (handle 0x$($handle.ToString('X')))"
    } catch {
        Write-Host "NativeLibrary.Load failed for $path"
        Write-Host "  $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Host "  inner: $($_.Exception.InnerException.Message)"
        }
        # 0x8007007E names the file it did find, never the dependency it did
        # not. Scripts/windows/check-closure.py answers that question directly.
        Write-Host "  if this is 0x8007007E, a dependency is missing rather"
        Write-Host "  than this file -- run check-closure.py over the artifact"
        throw
    }
}

# Baked into the DllImport rather than passed at run time, because DllImport
# takes a compile-time constant. A rooted path makes .NET load the file
# directly instead of probing for it.
$escaped = $core.Replace('\', '\\')

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Core
{
    [DllImport("$escaped", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nib_abi_version();

    // locale is a C string. Marshalled as UTF-16 it would arrive as
    // "e\0n\0_\0I\0N\0", which ICU reads as "e" and silently segments with the
    // wrong locale rather than failing.
    [DllImport("$escaped", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr nib_sentences(
        IntPtr text, int length, int minimumWords,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string locale);

    [DllImport("$escaped", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nib_sentence_count(IntPtr list);

    // Returned by value. Eight bytes comes back in a register on both
    // architectures, which a 12-byte parameter would not have.
    [DllImport("$escaped", CallingConvention = CallingConvention.Cdecl)]
    public static extern NibRange nib_sentence_range(IntPtr list, int index);

    [DllImport("$escaped", CallingConvention = CallingConvention.Cdecl)]
    public static extern void nib_sentence_list_free(IntPtr list);
}

[StructLayout(LayoutKind.Sequential)]
public struct NibRange
{
    public int Location;
    public int Length;
}
"@

# Recorded, not merely assumed. An empty Location is what made the previous
# failure unreadable, so the next person reading a log can see it directly.
Write-Host "probe assembly location: '$([Core].Assembly.Location)'"

$version = [Core]::nib_abi_version()
if ($version -ne 2) { throw "expected ABI version 2, got $version" }
Write-Host "libnibcore.dll reports ABI version $version"

# Two sentences, not three. "Dr." must not split, which needs both ICU's data
# and the core's abbreviation list to be present -- if either is missing this
# is where it shows.
$text = "Dr. Smith arrived here today. Another long sentence follows here."
$chars = $text.ToCharArray()
$handle = [System.Runtime.InteropServices.GCHandle]::Alloc($chars, 'Pinned')
try {
    $list = [Core]::nib_sentences($handle.AddrOfPinnedObject(), $text.Length, 5, "en_IN")
    $count = [Core]::nib_sentence_count($list)
    # Exercised here because a struct returned by value is the other shape
    # whose ABI differs by architecture, and nothing else tests it on Windows.
    $first = [Core]::nib_sentence_range($list, 0)
    [Core]::nib_sentence_list_free($list)
} finally {
    $handle.Free()
}

Write-Host "split into $count sentences"
if ($count -ne 2) {
    throw "expected 2 sentences, got $count -- ICU data or the abbreviation list is wrong"
}

# "Dr. Smith arrived here today." is 29 units, from offset 0.
Write-Host "first sentence: location $($first.Location), length $($first.Length)"
if ($first.Location -ne 0 -or $first.Length -ne 29) {
    throw "expected the first sentence at 0 length 29, got $($first.Location)/$($first.Length)"
}

Write-Host "core probe passed"
