#pragma once

#include "ReShade.fxh"

// Reversed-Z depth for Cyberpunk 2077 DX12 — define before including ReShade.fxh
// in your preset or add to the preprocessor definitions in ReShade:
//   RESHADE_DEPTH_INPUT_IS_REVERSED=1
//   RESHADE_DEPTH_INPUT_IS_LOGARITHMIC=0

#define CP_PI 3.14159265359f

namespace CyberpunkFX {

    // -------------------------------------------------------------------------
    // Main pipeline buffer — Start.fx writes here, all effects read/write here,
    // End.fx blits back to the backbuffer.
    // -------------------------------------------------------------------------
    texture2D CyberpunkBufferTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };

    sampler2D CyberpunkBuffer       { Texture = CyberpunkBufferTex; };
    sampler2D CyberpunkBufferLinear { Texture = CyberpunkBufferTex; };
    sampler2D CyberpunkBufferPoint  { Texture = CyberpunkBufferTex; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
    sampler2D CyberpunkBufferBorder { Texture = CyberpunkBufferTex; AddressU = BORDER; AddressV = BORDER; };
    sampler2D CyberpunkBufferBorderLinear { Texture = CyberpunkBufferTex; AddressU = BORDER; AddressV = BORDER; };
    sampler2D CyberpunkBufferMirror { Texture = CyberpunkBufferTex; AddressU = MIRROR; AddressV = MIRROR; };
    sampler2D CyberpunkBufferWrap   { Texture = CyberpunkBufferTex; AddressU = WRAP;   AddressV = WRAP; };

    // -------------------------------------------------------------------------
    // Utility
    // -------------------------------------------------------------------------

    // Perceived luminance (Rec. 709)
    float Luminance(float3 color) {
        return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
    }

    // Remap value from [inMin, inMax] to [outMin, outMax]
    float Map(float value, float inMin, float inMax, float outMin, float outMax) {
        return outMin + (outMax - outMin) * ((value - inMin) / (inMax - inMin));
    }

    // Simple Reinhard tonemap — used before luminance sampling to handle CP2077 HDR
    float3 ReinhardTonemap(float3 hdr) {
        return hdr / (1.0f + hdr);
    }

    // -------------------------------------------------------------------------
    // Full-screen triangle vertex shader — standard ReShade idiom
    // -------------------------------------------------------------------------
    void PostProcessVS(in uint id : SV_VERTEXID, out float4 position : SV_POSITION, out float2 uv : TEXCOORD) {
        uv.x = (id == 2) ? 2.0f : 0.0f;
        uv.y = (id == 1) ? 2.0f : 0.0f;
        position = float4(uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    }
}
