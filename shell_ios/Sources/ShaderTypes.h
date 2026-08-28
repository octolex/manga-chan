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

typedef enum {
    MSBufferIndexVertices = 0,
    MSBufferIndexUniforms = 1
} MSBufferIndex;

#endif /* SHADER_TYPES_H */
