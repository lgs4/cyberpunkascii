// CyberpunkFX_ASCII.fx
// ASCII character rendering for Cyberpunk 2077 via ReShade.
//
// 6-pass pipeline:
//   Luminance → CellSample → BlurH → EdgeDir → Render (compute) → Commit
//
// Edge detection: Gaussian-blurred luminance Sobel + relative depth edges + depth-Sobel
// normal proxy. Blurring before Sobel suppresses film grain and surface texture noise,
// keeping edges on geometry boundaries rather than material detail.

#include "Includes/CyberpunkFX_Common.fxh"
#include "Includes/CyberpunkFX_TempTex1.fxh"
#include "Includes/CyberpunkFX_TempTex2.fxh"

// =============================================================================
// Uniforms
// =============================================================================

uniform float _HDRWhitePoint <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_min = 1.0f; ui_max = 20.0f;
    ui_type = "slider";
    ui_label = "HDR White Point";
    ui_tooltip = "Scene brightness mapped to 1.0. Higher = neon lights stay as dense fill characters.";
> = 4.0f;

uniform int _BlurRadius <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_min = 1; ui_max = 6;
    ui_type = "slider";
    ui_label = "Edge Blur Radius";
    ui_tooltip = "Gaussian blur radius applied to luminance before edge detection. Higher = softer, more structural edges — suppresses texture and film grain noise.";
> = 2;

uniform float _BlurSigma <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_min = 0.5f; ui_max = 5.0f;
    ui_type = "slider";
    ui_label = "Edge Blur Sigma";
    ui_tooltip = "Gaussian falloff. Higher = smoother blur, fewer small edges.";
> = 1.5f;

uniform float _LumEdgeThreshold <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1.0f;
    ui_type = "slider";
    ui_label = "Luminance Edge Sensitivity";
    ui_tooltip = "Sobel magnitude on blurred luminance required to count as an edge. Lower = more edges.";
> = 0.1f;

uniform bool _UseDepth <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_label = "Depth Edges";
    ui_tooltip = "Detect edges at depth discontinuities (object silhouettes).";
> = true;

uniform float _DepthEdgeThreshold <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1.0f;
    ui_type = "slider";
    ui_label = "Depth Edge Sensitivity";
    ui_tooltip = "Relative depth change required for a depth edge (fraction of local depth). 0.2 = 20% depth jump. Lower = more silhouette edges, but raise it if depth edges drown out luminance.";
> = 0.2f;

uniform bool _UseNormals <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_label = "Normal Edges";
    ui_tooltip = "Detect edges from surface orientation changes — improves object separation independent of lighting.";
> = true;

uniform float _NormalThreshold <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 2.0f;
    ui_type = "slider";
    ui_label = "Normal Edge Sensitivity";
    ui_tooltip = "Depth-Sobel magnitude required for a surface-orientation edge. Lower = more object separation. Raise this if normal edges overwhelm luminance-based edges.";
> = 1.0f;

uniform float _DepthCutoff <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1000.0f;
    ui_type = "slider";
    ui_label = "Edge Depth Cutoff";
    ui_tooltip = "Suppress edge characters beyond this distance.";
> = 0.0f;

uniform int _TileEdgeThreshold <
    ui_category = "Preprocess";
    ui_category_closed = true;
    ui_min = 0; ui_max = 64;
    ui_type = "slider";
    ui_label = "Tile Edge Threshold";
    ui_tooltip = "Edge pixels needed per 8x8 tile to use an edge character. Raise to show more fill.";
> = 24;

// --- Characters ---

uniform bool _DrawEdges <
    ui_category = "Characters";
    ui_category_closed = true;
    ui_label = "Edge Characters";
> = true;

uniform bool _DrawFill <
    ui_category = "Characters";
    ui_category_closed = true;
    ui_label = "Fill Characters";
> = true;

uniform float _FillExposure <
    ui_category = "Characters";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 5.0f;
    ui_type = "slider";
    ui_label = "Fill Exposure";
    ui_tooltip = "Boost cell luminance before density mapping. Raise to fill dark areas.";
> = 1.5f;

uniform float _FillGamma <
    ui_category = "Characters";
    ui_category_closed = true;
    ui_min = 0.1f; ui_max = 3.0f;
    ui_type = "slider";
    ui_label = "Fill Gamma";
    ui_tooltip = "Curve fill density. <1 pushes mid-tones denser, >1 sparser.";
> = 0.7f;

// --- Presets ---

uniform int _ActivePreset <
    ui_category = "Preset";
    ui_type = "combo";
    ui_label = "Factory Preset";
    ui_tooltip = "Quick aesthetic presets. 'Custom' uses sliders below.\nTo save your own settings: open ReShade overlay (Home key) → preset bar at top.";
    ui_items = "Custom\0Neon Noir\0Glitch Terminal\0Ghost Wire\0Outrun\0";
> = 0;

// --- Color ---

uniform int _ColorMode <
    ui_category = "Color";
    ui_category_closed = true;
    ui_type = "combo";
    ui_label = "Color Mode";
    ui_items = "Flat\0Neon Gradient\0";
    ui_tooltip = "Flat: uniform character color. Neon Gradient: vertical sweep from Character Color (top) to Gradient Bottom (bottom). Scene Blend applies on top of either mode.";
> = 1;

uniform float3 _CharColor <
    ui_category = "Color";
    ui_category_closed = true;
    ui_type = "color";
    ui_label = "Character Color";
    ui_tooltip = "Flat mode: this is the character color. Neon Gradient: top-of-screen color.";
> = float3(0.0f, 1.0f, 0.9f);

uniform float3 _GradientColor <
    ui_category = "Color";
    ui_category_closed = true;
    ui_type = "color";
    ui_label = "Gradient Bottom Color";
> = float3(1.0f, 0.0f, 0.8f);

uniform float3 _BgColor <
    ui_category = "Color";
    ui_category_closed = true;
    ui_type = "color";
    ui_label = "Background Color";
> = float3(0.0f, 0.0f, 0.0f);

uniform float _SceneBlend <
    ui_category = "Color";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1.0f;
    ui_type = "slider";
    ui_label = "Scene Blend";
    ui_tooltip = "Blends scene color into characters in any mode. 0 = pure char color, 1 = full scene color on characters. Works alongside Flat and Neon Gradient.";
> = 0.5f;

// --- Terminal FX ---

uniform float _ScanlineStrength <
    ui_category = "Terminal FX";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1.0f;
    ui_type = "slider";
    ui_label = "Scanline Strength";
    ui_tooltip = "Dims every other row — monitor/terminal aesthetic.";
> = 0.25f;

uniform float _DepthFade <
    ui_category = "Terminal FX";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 0.02f;
    ui_type = "slider";
    ui_label = "Depth Fade";
    ui_tooltip = "Fade distant characters into the background. At 0.005, objects at 200m are 50% faded. At 0.01, objects at 100m are 50% faded.";
> = 0.0f;

uniform float _DepthFadeStart <
    ui_category = "Terminal FX";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1000.0f;
    ui_type = "slider";
    ui_label = "Depth Fade Start";
> = 0.0f;

// --- Debug ---

uniform bool _DebugEdges <
    ui_category = "Debug";
    ui_category_closed = true;
    ui_label = "Visualize Edge Directions";
    ui_tooltip = "Red=vertical, Green=horizontal, Cyan=diag, Yellow=anti-diag.";
> = false;

// =============================================================================
// Textures & Samplers
// =============================================================================

// Glyph atlases — drop your own PNGs in the Textures/ folder to replace them.
// edgesASCII.png : 40×8  — 4 edge characters (|, —, \, /) each 8px wide, 1 per column-group
// fillASCII.png  : 80×8  — 10 fill characters ordered sparse→dense, each 8px wide
texture2D CP_EdgeGlyphTex < source = "edgesASCII.png"; > { Width = 40; Height = 8; };
texture2D CP_FillGlyphTex < source = "fillASCII.png";  > { Width = 80; Height = 8; };
sampler2D sEdgeGlyphs { Texture = CP_EdgeGlyphTex; AddressU = CLAMP; AddressV = CLAMP; };
sampler2D sFillGlyphs { Texture = CP_FillGlyphTex; AddressU = CLAMP; AddressV = CLAMP; };

texture2D CP_LumTex     { Width = BUFFER_WIDTH;     Height = BUFFER_HEIGHT;     Format = R16F;   };
texture2D CP_CellTex    { Width = BUFFER_WIDTH / 8; Height = BUFFER_HEIGHT / 8; Format = RGBA16F; };
texture2D CP_EdgeDirTex { Width = BUFFER_WIDTH;     Height = BUFFER_HEIGHT;     Format = RG16F;  };

sampler2D sLum     { Texture = CP_LumTex;              MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler2D sBlurH   { Texture = CPTemp2::CP_RenderTex2; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler2D sCell    { Texture = CP_CellTex;             MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler2D sEdgeDir { Texture = CP_EdgeDirTex;          MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

sampler2D sRenderOut { Texture = CPTemp1::CP_RenderTex1; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
storage2D  sRenderRW { Texture = CPTemp1::CP_RenderTex1; };

// =============================================================================
// Helpers
// =============================================================================

float3 Tonemap(float3 c) {
    c /= _HDRWhitePoint;
    return c / (1.0f + c);
}

// Map a normalized gradient vector to one of 4 edge directions: 0=|  1=—  2=\  3=/
// Uses projection onto reference gradient axes for each edge orientation.
// Vertical edge (|) → gradient is horizontal → aligns with (1,0)
// Horizontal edge (—) → gradient is vertical → aligns with (0,1)
// Diagonal (\) → gradient aligns with (1,-1)/√2
// Anti-diagonal (/) → gradient aligns with (1,+1)/√2
int GradientToEdgeDir(float2 g) {
    float a0 = abs(g.x);
    float a1 = abs(g.y);
    float a2 = abs(g.x - g.y) * 0.7071f;
    float a3 = abs(g.x + g.y) * 0.7071f;
    float best = max(max(a0, a1), max(a2, a3));
    if (a0 >= best) return 0;
    if (a1 >= best) return 1;
    if (a2 >= best) return 2;
    return 3;
}

// Aesthetic settings resolved from either a factory preset or the user's sliders.
// Technical settings (edge thresholds, depth) are always read from sliders.
struct CPPreset {
    int    colorMode;
    float3 charColor;
    float3 gradColor;
    float3 bgColor;
    float  sceneBlend;
    float  fillExposure;
    float  fillGamma;
    float  scanStrength;
};

CPPreset ResolvePreset() {
    CPPreset p;
    if (_ActivePreset == 1) {       // Neon Noir — cyan/magenta gradient, Night City default
        p.colorMode    = 2;
        p.charColor    = float3(0.00f, 1.00f, 0.90f);
        p.gradColor    = float3(0.80f, 0.00f, 1.00f);
        p.bgColor      = float3(0.00f, 0.00f, 0.00f);
        p.sceneBlend   = 0.0f;
        p.fillExposure = 1.5f;
        p.fillGamma    = 0.7f;
        p.scanStrength = 0.3f;
    } else if (_ActivePreset == 2) { // Glitch Terminal — green on black, Matrix feel
        p.colorMode    = 0;
        p.charColor    = float3(0.00f, 1.00f, 0.20f);
        p.gradColor    = float3(0.00f, 1.00f, 0.20f);
        p.bgColor      = float3(0.00f, 0.02f, 0.00f);
        p.sceneBlend   = 0.0f;
        p.fillExposure = 2.0f;
        p.fillGamma    = 0.5f;
        p.scanStrength = 0.5f;
    } else if (_ActivePreset == 3) { // Ghost Wire — ice blue/white, translucent scene blend
        p.colorMode    = 0;
        p.charColor    = float3(0.70f, 0.95f, 1.00f);
        p.gradColor    = float3(0.70f, 0.95f, 1.00f);
        p.bgColor      = float3(0.00f, 0.03f, 0.06f);
        p.sceneBlend   = 0.6f;
        p.fillExposure = 1.2f;
        p.fillGamma    = 0.8f;
        p.scanStrength = 0.15f;
    } else if (_ActivePreset == 4) { // Outrun — magenta/yellow, synthwave palette
        p.colorMode    = 2;
        p.charColor    = float3(1.00f, 0.00f, 0.80f);
        p.gradColor    = float3(1.00f, 0.85f, 0.00f);
        p.bgColor      = float3(0.02f, 0.00f, 0.08f);
        p.sceneBlend   = 0.0f;
        p.fillExposure = 1.5f;
        p.fillGamma    = 0.7f;
        p.scanStrength = 0.4f;
    } else {                         // Custom — use sliders
        p.colorMode    = _ColorMode;
        p.charColor    = _CharColor;
        p.gradColor    = _GradientColor;
        p.bgColor      = _BgColor;
        p.sceneBlend   = _SceneBlend;
        p.fillExposure = _FillExposure;
        p.fillGamma    = _FillGamma;
        p.scanStrength = _ScanlineStrength;
    }
    return p;
}

// =============================================================================
// Pass 1 — Luminance
// HDR tonemap then extract perceptual grayscale at full resolution.
// =============================================================================
float PS_Luminance(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float3 c = Tonemap(tex2D(CyberpunkFX::CyberpunkBufferBorderLinear, uv).rgb);
    return CyberpunkFX::Luminance(saturate(c));
}

// =============================================================================
// Pass 2 — Cell Sample
// One sample per 8x8 character cell. Stores tonemapped color + luminance in alpha.
// =============================================================================
float4 PS_CellSample(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float3 c = saturate(Tonemap(tex2D(CyberpunkFX::CyberpunkBufferBorderLinear, uv).rgb));
    return float4(c, CyberpunkFX::Luminance(c));
}

// =============================================================================
// Pass 3 — Horizontal Gaussian Blur
// Blurs the luminance buffer horizontally before Sobel edge detection.
// Suppresses film grain and texture noise so edges fire on geometry, not surfaces.
// =============================================================================
float PS_BlurH(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float2 ts     = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float  sigma2 = _BlurSigma * _BlurSigma;
    float  sum    = 0.0f;
    float  wsum   = 0.0f;
    for (int x = -_BlurRadius; x <= _BlurRadius; ++x) {
        float w  = exp(-0.5f * (x * x) / sigma2);
        sum  += tex2D(sLum, uv + float2(x, 0) * ts).r * w;
        wsum += w;
    }
    return sum / wsum;
}

// =============================================================================
// Pass 4 — Edge Direction
// Sobel on H-blurred luminance (V-weights applied inline) for gradient direction.
// Depth edges: relative comparison (threshold = fraction of local depth, not absolute).
// Normal edges: depth Sobel as surface-orientation proxy — catches object boundaries
//               that luminance alone misses in dark or uniformly lit areas.
// =============================================================================
float2 PS_EdgeDir(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float2 ts     = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float  sigma2 = _BlurSigma * _BlurSigma;

    // Gaussian V-weights for the 3 rows used by Sobel (y = -1, 0, +1)
    float wy = exp(-0.5f / sigma2); // weight for top/bottom rows
    float wc = 1.0f;                // center row always full weight

    // Sample H-blurred luminance at 8 neighbors
    float tl = tex2D(sBlurH, uv + float2(-1,-1)*ts).r;
    float tm = tex2D(sBlurH, uv + float2( 0,-1)*ts).r;
    float tr = tex2D(sBlurH, uv + float2( 1,-1)*ts).r;
    float ml = tex2D(sBlurH, uv + float2(-1, 0)*ts).r;
    float mr = tex2D(sBlurH, uv + float2( 1, 0)*ts).r;
    float bl = tex2D(sBlurH, uv + float2(-1, 1)*ts).r;
    float bm = tex2D(sBlurH, uv + float2( 0, 1)*ts).r;
    float br = tex2D(sBlurH, uv + float2( 1, 1)*ts).r;

    // Gaussian-weighted Sobel: V-Gaussian weights applied to the standard kernel
    float Gx = (tr - tl) * wy + (mr - ml) * wc + (br - bl) * wy;
    float Gy = (bl - tl) * wy + (bm - tm) * wc + (br - tr) * wy;
    bool lumEdge = length(float2(Gx, Gy)) > _LumEdgeThreshold;

    // Share depth samples between depth-edge and normal-edge detection
    float dc  = ReShade::GetLinearizedDepth(uv);
    float dTL = ReShade::GetLinearizedDepth(uv + float2(-1,-1)*ts);
    float dTM = ReShade::GetLinearizedDepth(uv + float2( 0,-1)*ts);
    float dTR = ReShade::GetLinearizedDepth(uv + float2( 1,-1)*ts);
    float dML = ReShade::GetLinearizedDepth(uv + float2(-1, 0)*ts);
    float dMR = ReShade::GetLinearizedDepth(uv + float2( 1, 0)*ts);
    float dBL = ReShade::GetLinearizedDepth(uv + float2(-1, 1)*ts);
    float dBM = ReShade::GetLinearizedDepth(uv + float2( 0, 1)*ts);
    float dBR = ReShade::GetLinearizedDepth(uv + float2( 1, 1)*ts);

    // Relative depth edge: compare largest delta against local depth fraction.
    // dc + 0.001 avoids div-by-zero on skybox/far plane.
    float relScale  = 1.0f / (dc + 0.001f);
    float maxRelDelta = max(max(abs(dML - dc), abs(dMR - dc)),
                            max(abs(dTM - dc), abs(dBM - dc))) * relScale;
    bool depthEdge = _UseDepth && maxRelDelta > _DepthEdgeThreshold;

    // Normal-proxy edge: Sobel on depth detects surface orientation changes.
    // Normalised by local depth so distant curved surfaces don't overwhelm near flat ones.
    float DGx = (-dTL + dTR - 2.0f*dML + 2.0f*dMR - dBL + dBR) * relScale;
    float DGy = (-dTL - 2.0f*dTM - dTR + dBL + 2.0f*dBM + dBR) * relScale;
    bool normalEdge = _UseNormals && length(float2(DGx, DGy)) > _NormalThreshold;

    bool cutoff = _DepthCutoff > 0.0f && dc * 1000.0f > _DepthCutoff;
    bool isEdge = (lumEdge || depthEdge || normalEdge) && !cutoff;

    float mag = length(float2(Gx, Gy));
    return isEdge && mag > 1e-4f ? float2(Gx, Gy) / mag : float2(0.0f, 0.0f);
}

// =============================================================================
// Pass 4 — Compute Render
// Each 8x8 thread group = one character tile.
// Threads vote on the dominant edge direction; majority wins or falls back to fill.
// =============================================================================
groupshared int gDirs[64];

void CS_Render(uint3 tid : SV_DISPATCHTHREADID, uint3 gid : SV_GROUPTHREADID) {
    float2 gradient = tex2Dfetch(sEdgeDir, tid.xy).rg;
    int    pixelDir = dot(gradient, gradient) > 0.5f ? GradientToEdgeDir(gradient) : -1;

    gDirs[gid.x + gid.y * 8] = pixelDir;
    barrier();

    int tileDir = -1;
    if (gid.x == 0 && gid.y == 0) {
        uint votes[4] = { 0, 0, 0, 0 };
        for (int i = 0; i < 64; ++i)
            if (gDirs[i] >= 0) votes[gDirs[i]]++;

        uint best = 0;
        for (int j = 0; j < 4; ++j)
            if (votes[j] > best) { best = votes[j]; tileDir = j; }

        if (best < (uint)_TileEdgeThreshold) tileDir = -1;
        gDirs[0] = tileDir;
    }
    barrier();
    tileDir = gDirs[0];

    // -------------------------------------------------------------------------
    // Sample glyph LUT
    // -------------------------------------------------------------------------
    CPPreset pr = ResolvePreset();

    float4 cell  = tex2Dfetch(sCell, tid.xy / 8);
    float  glyph = 0.0f;

    uint lx = tid.x % 8u;
    uint ly = tid.y % 8u;

    if (tileDir >= 0 && _DrawEdges) {
        // Edge atlas: dir 0-3 → column groups 1-4 (col 0 unused), each 8px wide
        glyph = tex2Dfetch(sEdgeGlyphs, int2(lx + (tileDir + 1) * 8, 8 - ly)).r;
    } else if (_DrawFill) {
        // Fill atlas: luminance → one of 10 column groups, each 8px wide
        float lum = saturate(pow(cell.a * pr.fillExposure, pr.fillGamma));
        int   col = (int)min(floor(lum * 10.0f), 9.0f);
        glyph = tex2Dfetch(sFillGlyphs, int2(lx + col * 8, ly)).r;
    }

    // -------------------------------------------------------------------------
    // Resolve character color
    // -------------------------------------------------------------------------
    float3 charColor;
    if (pr.colorMode == 1) {
        charColor = lerp(pr.charColor, pr.gradColor, tid.y / float(BUFFER_HEIGHT));
    } else {
        charColor = pr.charColor;
    }
    // Scene blend applies on top of any mode
    charColor = lerp(charColor, cell.rgb, pr.sceneBlend);

    float3 pixel = lerp(pr.bgColor, charColor, glyph);

    // Scanline: dim every even row — CRT/terminal feel
    pixel *= (tid.y & 1u) ? 1.0f : (1.0f - pr.scanStrength);

    // Depth fade: distant geometry dissolves into background
    if (_DepthFade > 0.0f) {
        float z   = ReShade::GetLinearizedDepth(float2(tid.xy) * float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)) * 1000.0f;
        float fog = exp2(-_DepthFade * max(0.0f, z - _DepthFadeStart));
        pixel = lerp(pr.bgColor, pixel, fog);
    }

    // Debug: color-code tile directions
    if (_DebugEdges) {
        const float3 dirColors[4] = { float3(1,0,0), float3(0,1,0), float3(0,1,1), float3(1,1,0) };
        pixel = tileDir >= 0 ? dirColors[tileDir] : 0.0f;
    }

    tex2Dstore(sRenderRW, tid.xy, float4(pixel, 1.0f));
}

// =============================================================================
// Pass 5 — Commit
// Blit compute output into the shared pipeline buffer.
// =============================================================================
float4 PS_Commit(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    return tex2D(sRenderOut, uv);
}

// =============================================================================
// Technique
// =============================================================================
technique CyberpunkFX_ASCII <
    ui_label = "ASCII [CyberpunkFX]";
    ui_tooltip = "ASCII rendering for Night City. 6-pass pipeline.";
> {
    pass Luminance {
        RenderTarget = CP_LumTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_Luminance;
    }
    pass CellSample {
        RenderTarget = CP_CellTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_CellSample;
    }
    pass BlurH {
        RenderTarget = CPTemp2::CP_RenderTex2;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_BlurH;
    }
    pass EdgeDir {
        RenderTarget = CP_EdgeDirTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_EdgeDir;
    }
    pass Render {
        ComputeShader = CS_Render<8, 8>;
        DispatchSizeX = BUFFER_WIDTH / 8;
        DispatchSizeY = BUFFER_HEIGHT / 8;
    }
    pass Commit {
        RenderTarget = CyberpunkFX::CyberpunkBufferTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_Commit;
    }
}
