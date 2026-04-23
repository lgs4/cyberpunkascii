#pragma once

// Shared scratch texture 2 — RGBA16F, full resolution.
// ASCII uses this for screen-space normals (xyz) + linearized depth (w).

namespace CPTemp2 {
    texture2D CP_RenderTex2 { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
    sampler2D RenderTex       { Texture = CP_RenderTex2; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
    sampler2D RenderTexLinear { Texture = CP_RenderTex2; };
    storage2D s_RenderTex     { Texture = CP_RenderTex2; };
}
