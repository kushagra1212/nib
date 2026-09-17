#ifndef NIB_CORE_H
#define NIB_CORE_H

#include <stddef.h>
#include <stdint.h>
#include "nib/version.h"

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(NIB_CORE_BUILDING)
#    define NIB_API __declspec(dllexport)
#  else
#    define NIB_API __declspec(dllimport)
#  endif
#else
#  define NIB_API __attribute__((visibility("default")))
#endif

/* Every string crossing this boundary is UTF-16, because NSString, LSP
   positions and C# strings all are. Offsets are UTF-16 code units, never
   graphemes and never bytes. */
typedef struct {
    const uint16_t* data;
    int32_t         length;
} nib_str;

/* A half-open range in UTF-16 code units, matching NSRange. */
typedef struct {
    int32_t location;
    int32_t length;
} nib_range;

NIB_API int32_t nib_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif
