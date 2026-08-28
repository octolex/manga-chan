/*
 * core_api.h — the ONLY surface the Swift shell may touch.
 *
 * Rules for this boundary (they exist because we cannot attach a debugger to
 * the device, so the boundary has to be obvious enough to reason about blind):
 *
 *   1. Plain C. No C++ types, no templates, no exceptions crossing the line.
 *   2. Opaque handles only — the shell never sees a struct layout.
 *   3. The core owns its memory. Any pointer returned here stays valid until
 *      the matching destroy call; the shell never frees it.
 *   4. Errors are return codes, never exceptions. 0 == success.
 */
#ifndef CORE_API_H
#define CORE_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Semantic version of the engine core, e.g. "0.0.1". Static storage. */
const char* core_version_string(void);

/* Short build identity string shown in the HUD, e.g. "core 0.0.1 (release)".
 * Static storage — do not free. */
const char* core_build_info(void);

/* Exercises the C++ standard library and heap so that a broken libc++ link or
 * a bad cross-compile fails loudly and immediately at launch, rather than
 * later inside the renderer where it would be far harder to diagnose.
 * Returns 0 on success, non-zero on failure. */
int32_t core_self_test(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CORE_API_H */
