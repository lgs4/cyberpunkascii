// CyberpunkFX_End.fx
// Pipeline exit point — must be the LAST CyberpunkFX shader in your ReShade load order.
// Blits the final internal buffer back to the game backbuffer.

#include "Includes/CyberpunkFX_Common.fxh"

float4 PS_End(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    return tex2D(CyberpunkFX::CyberpunkBufferPoint, uv);
}

technique CyberpunkFXEnd < ui_label = "CyberpunkFX End"; ui_tooltip = "(REQUIRED) Place after all CyberpunkFX shaders."; > {
    pass {
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_End;
    }
}
