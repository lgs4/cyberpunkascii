// CyberpunkFX_Start.fx
// Pipeline entry point — must be the FIRST CyberpunkFX shader in your ReShade load order.
// Copies the game backbuffer into our internal pipeline buffer so all subsequent
// effects operate on CyberpunkBufferTex rather than fighting over the backbuffer.

#include "Includes/CyberpunkFX_Common.fxh"

float4 PS_Start(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    return tex2D(ReShade::BackBuffer, uv);
}

technique CyberpunkFXStart < ui_label = "CyberpunkFX Start"; ui_tooltip = "(REQUIRED) Place before all CyberpunkFX shaders."; > {
    pass {
        RenderTarget = CyberpunkFX::CyberpunkBufferTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_Start;
    }
}
