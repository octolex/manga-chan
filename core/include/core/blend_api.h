/*
 * blend_api.h — the blend reference, exposed to Swift.
 *
 * This exists for one purpose: so the simulator test suite can render each
 * blend mode in Metal and compare the result, pixel by pixel, against the CPU
 * implementation in blend.cpp.
 *
 * That comparison is the only thing standing between us and a shader that
 * blends subtly wrong. It would compile, run at full speed, and produce output
 * that looks approximately right on a device we cannot attach a frame debugger
 * to. Approximately right is the hardest kind of wrong to notice.
 *
 * Mode indices are the integer values of mc::BlendMode in blend.h, and the
 * shader hardcodes the same numbering. Nothing enforces that they agree —
 * except the test, which is precisely the point.
 */
#ifndef BLEND_API_H
#define BLEND_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Number of implemented modes. Valid indices are 0 to this minus one. */
int32_t mc_blend_mode_count(void);

/* Display name for a mode index, or "Unknown". Static storage. */
const char* mc_blend_mode_name(int32_t mode);

/* Non-zero when the mode operates per channel. The others mix channels and
 * need the whole colour at once. */
int32_t mc_blend_mode_is_separable(int32_t mode);

/*
 * Composites one premultiplied RGBA8 pixel over another.
 *
 * `backdrop`, `source` and `out` are each four bytes. `out` may alias neither
 * input. Out-of-range modes fall back to Normal rather than reading past the
 * end of the table.
 */
void mc_blend_pixel(int32_t mode,
                    const uint8_t* backdrop,
                    const uint8_t* source,
                    float opacity,
                    uint8_t* out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* BLEND_API_H */
