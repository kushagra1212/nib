#!/usr/bin/env python3
"""Check that a Windows artifact can actually load.

Every DLL in the directory is walked for its imports, and anything that is
neither a Windows system library nor present in the directory is an error.

This exists because the first artifact shipped three DLLs that could not load
between them. icuuc78.dll was linked against llvm-mingw's libc++.dll and
libunwind.dll, neither of which is ICU, nib, or on any Windows machine. The
import table looked fine, every file listed was present, and Windows reported
it as:

    Unable to load DLL '...\\libnibcore.dll' or one of its dependencies:
    The specified module could not be found. (0x8007007E)

which names the file that was found and says nothing about the one that was
not. Two CI runs went into reading that sentence. This script turns the same
question into one that answers itself.

    check-closure.py <arch-prefix> <directory>
    check-closure.py x86_64 out/
"""
import os
import subprocess
import sys

# Present on every Windows nib supports, so never shipped. api-ms-win-* is the
# Universal CRT, which is part of the OS from Windows 10 onward.
SYSTEM_DLLS = frozenset({
    "kernel32.dll", "advapi32.dll", "user32.dll", "gdi32.dll", "ole32.dll",
    "oleaut32.dll", "shell32.dll", "msvcrt.dll", "ntdll.dll", "ws2_32.dll",
    "bcrypt.dll", "version.dll", "normaliz.dll", "crypt32.dll", "secur32.dll",
})


def is_system(name):
    return name.startswith("api-ms-win-") or name in SYSTEM_DLLS


def imports_of(objdump, path):
    result = subprocess.run([objdump, "-p", path],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"{objdump} failed on {path}:\n{result.stderr}")
    return {line.split("DLL Name:")[1].strip().lower()
            for line in result.stdout.splitlines() if "DLL Name:" in line}


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    arch, directory = sys.argv[1], sys.argv[2]
    objdump = f"{arch}-w64-mingw32-objdump"

    shipped = {name.lower() for name in os.listdir(directory)
               if name.lower().endswith(".dll")}
    if not shipped:
        raise SystemExit(f"no DLLs in {directory}")

    missing = set()
    seen = set()
    queue = list(shipped)
    while queue:
        name = queue.pop()
        if name in seen:
            continue
        seen.add(name)
        for dep in imports_of(objdump, os.path.join(directory, name)):
            if is_system(dep):
                continue
            if dep in shipped:
                if dep not in seen:
                    queue.append(dep)
            else:
                missing.add((name, dep))

    print(f"shipped: {', '.join(sorted(shipped))}")
    if missing:
        for needs_it, dep in sorted(missing):
            print(f"MISSING: {needs_it} imports {dep}, "
                  f"which is not in {directory}")
        raise SystemExit(1)
    print(f"closure complete: {len(seen)} DLLs, every non-system "
          f"dependency is present")


if __name__ == "__main__":
    main()
