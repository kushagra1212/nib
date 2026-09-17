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

# icuuc finds icudt beside it, so the directory has to be on the search path.
$env:PATH = "$dir;$env:PATH"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Core
{
    [DllImport("libnibcore.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nib_abi_version();

    [DllImport("libnibcore.dll", CallingConvention = CallingConvention.Cdecl,
               CharSet = CharSet.Unicode)]
    public static extern IntPtr nib_sentences(IntPtr text, int length,
                                              int minimumWords, string locale);

    [DllImport("libnibcore.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nib_sentence_count(IntPtr list);

    [DllImport("libnibcore.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void nib_sentence_list_free(IntPtr list);
}
"@

$version = [Core]::nib_abi_version()
if ($version -ne 1) { throw "expected ABI version 1, got $version" }
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
    [Core]::nib_sentence_list_free($list)
} finally {
    $handle.Free()
}

Write-Host "split into $count sentences"
if ($count -ne 2) {
    throw "expected 2 sentences, got $count -- ICU data or the abbreviation list is wrong"
}

Write-Host "core probe passed"
