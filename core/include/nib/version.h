#ifndef NIB_CORE_VERSION_H
#define NIB_CORE_VERSION_H

/* Bumped on every change to nib_core.h that is not source-compatible.
   Both bindings assert against it at load, so a stale DLL fails loudly
   instead of reading the wrong offsets out of a struct. */
#define NIB_CORE_ABI_VERSION 1

#endif
