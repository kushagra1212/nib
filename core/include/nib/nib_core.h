#ifndef NIB_CORE_H
#define NIB_CORE_H

#include <stddef.h>
#include <stdint.h>
/* Relative, not "nib/version.h". CMake puts core/include on the search path,
   but SwiftPM reaches this header through a module map with no include path at
   all, and a quoted include resolves against this file's own directory first.
   One form that works for every consumer. */
#include "version.h"

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

/* Opaque. The caller drains it with the accessors below, then frees it.
   Never dereference, never copy. */
typedef struct nib_sentence_list nib_sentence_list;

/* Splits text into sentences worth a clarity suggestion. Never returns NULL.

   The returned list borrows nothing from `text` -- it owns its own copies, so
   the caller may free `text` immediately.

   `locale` names the locale to segment with, as a BCP 47 or ICU identifier
   such as "en_IN". Foundation's .localized uses the user's locale, so the
   platform layer passes the user's rather than letting the core guess. NULL
   takes ICU's default, which is right for a probe and wrong for the app. */
NIB_API nib_sentence_list* nib_sentences(nib_str text, int32_t minimum_words,
                                         const char* locale);

/* Safe on NULL, which reports zero. */
NIB_API int32_t   nib_sentence_count(const nib_sentence_list* list);

/* An out-of-range index reports {0, 0} rather than failing. */
NIB_API nib_range nib_sentence_range(const nib_sentence_list* list, int32_t index);

/* Copies sentence `index` into `buffer`, writing at most `capacity` UTF-16
   units. Returns the full length, which may exceed `capacity` -- call with a
   null buffer and capacity 0 first to size it. */
NIB_API int32_t nib_sentence_text(const nib_sentence_list* list, int32_t index,
                                  uint16_t* buffer, int32_t capacity);

/* Safe on NULL. */
NIB_API void nib_sentence_list_free(nib_sentence_list* list);

#ifdef __cplusplus
}
#endif

#endif
