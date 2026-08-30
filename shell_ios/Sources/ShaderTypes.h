//
//  ShaderTypes.h
//
//  Shared between Swift and Metal Shading Language. Both sides include this
//  one file, so a struct can never drift out of sync between CPU and GPU —
//  a mismatch there produces garbage geometry with no error message, which is
//  exactly the class of bug we cannot afford without a frame debugger.
//

#ifndef SHADER_TYPES_H
#define SHADER_TYPES_H

#include <simd/simd.h>

typedef struct {
    simd_float2 position;  // clip space, -1...1
    simd_float4 color;     // premultiplied RGBA
} MSVertex;

// One stamp of the brush shape. Must stay byte-identical to MCDab in
// core/brush_api.h and to mc::Dab, because the engine's dab array is handed
// straight to a Metal buffer with no copy or conversion. brush_api.cpp holds
// static assertions pinning the C and C++ sides together; this comment is the
// third corner of that triangle.
typedef struct {
    float x;
    float y;
    float radius;
    float angle;
    float flow;
    float roundness;
    float hardness;
} MSDab;

typedef struct {
    simd_float2 viewportSize;  // drawable size in pixels
} MSDabUniforms;

typedef struct {
    int32_t mode;         // matches mc::BlendMode in core/blend.h
    float   opacity;      // layer opacity, 0...1
    int32_t useClipMask;  // non-zero: multiply source alpha by the mask texture
    int32_t _pad;
} MSBlendUniforms;

typedef enum {
    MSBufferIndexVertices = 0,
    MSBufferIndexUniforms = 1
} MSBufferIndex;

#endif /* SHADER_TYPES_H */
