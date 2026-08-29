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

// No explicit padding field: simd_float4 forces 16-byte alignment, so both the
// C and MSL compilers independently place `color` at offset 16 and size the
// struct at 32 bytes. Spelling the padding out would only add an awkward
// initialiser parameter on the Swift side.
typedef struct {
    simd_float2 position;  // clip space, -1...1
    float       edge;      // -1...+1 across the ribbon width; used for edge antialiasing
    simd_float4 color;     // premultiplied RGBA
} MSStrokeVertex;

typedef struct {
    int32_t mode;      // matches mc::BlendMode in core/blend.h
    float   opacity;   // layer opacity, 0...1
} MSBlendUniforms;

typedef enum {
    MSBufferIndexVertices = 0,
    MSBufferIndexUniforms = 1
} MSBufferIndex;

#endif /* SHADER_TYPES_H */
