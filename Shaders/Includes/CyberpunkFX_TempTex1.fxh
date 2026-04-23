#pragma once

// Shared scratch texture 1 — RGBA16F, full resolution.
// Used as a ping-pong buffer between passes within a single effect.
// Never persist data across technique boundaries.

namespace CPTemp1 {
    texture2D CP_RenderTex1 { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
    sampler2D RenderTex       { Texture = CP_RenderTex1; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
    sampler2D RenderTexLinear { Texture = CP_RenderTex1; };
    storage2D s_RenderTex     { Texture = CP_RenderTex1; };
}
