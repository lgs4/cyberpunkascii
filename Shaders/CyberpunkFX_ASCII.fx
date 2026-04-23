// CyberpunkFX_ASCII.fx
// Converts the rendered frame into ASCII characters.
// Based on AcerolaFX_ASCII.fx by GarrettGunnell — adapted for Cyberpunk 2077.
//
// Pipeline:
//   1. Luminance        — extract grayscale, apply Reinhard to handle CP2077 HDR neon
//   2. Downscale 8×     — one sample per 8×8 character cell
//   3. Horizontal blur  — first Gaussian pass for DoG
//   4. Vertical blur+DoG— second Gaussian pass + Difference of Gaussians edge signal
//   5. Normals          — screen-space normals + depth from ReShade depth buffer
//   6. Edge detect      — combine DoG with depth/normal discontinuities
//   7. Sobel H          — horizontal Sobel on edge map
//   8. Sobel V          — vertical Sobel → edge angle θ per pixel
//   9. CS_RenderASCII   — compute (8×8 tiles): dominant direction → edge char or fill char
//  10. EndPass           — blit temp buffer back to CyberpunkBufferTex
//
// Required textures in Textures/ folder:
//   edgesASCII.png  — 40×8  (5 edge characters × 4 directions × 8px tall)
//   fillASCII.png   — 80×8  (10 luminance levels × 8px wide × 8px tall)

#include "Includes/CyberpunkFX_Common.fxh"
#include "Includes/CyberpunkFX_TempTex1.fxh"
#include "Includes/CyberpunkFX_TempTex2.fxh"

// =============================================================================
// Uniforms
// =============================================================================

uniform float _Zoom <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 5.0f;
    ui_label = "Zoom";
    ui_type = "drag";
    ui_tooltip = "Decrease to zoom in, increase to zoom out.";
> = 1.0f;

uniform float2 _Offset <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = -1.0f; ui_max = 1.0f;
    ui_label = "Offset";
    ui_type = "drag";
    ui_tooltip = "Positional offset of the zoom from center.";
> = 0.0f;

uniform int _KernelSize <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 1; ui_max = 10;
    ui_type = "slider";
    ui_label = "Kernel Size";
    ui_tooltip = "Size of the Gaussian blur kernel used for DoG edge detection.";
    ui_spacing = 4;
> = 2;

uniform float _Sigma <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 5.0f;
    ui_type = "slider";
    ui_label = "Blur Strength";
    ui_tooltip = "Sigma of the inner Gaussian (controls edge softness).";
> = 2.0f;

uniform float _SigmaScale <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 5.0f;
    ui_type = "slider";
    ui_label = "Deviation Scale";
    ui_tooltip = "Scale between the two Gaussians in the DoG.";
> = 1.6f;

uniform float _Tau <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1.1f;
    ui_type = "slider";
    ui_label = "Detail";
    ui_tooltip = "Tau parameter in the DoG threshold — lower = more edges.";
> = 1.0f;

uniform float _Threshold <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 0.001f; ui_max = 0.1f;
    ui_type = "slider";
    ui_label = "Threshold";
    ui_tooltip = "Minimum DoG response to count as an edge.";
> = 0.005f;

uniform bool _UseDepth <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_label = "Use Depth";
    ui_tooltip = "Use depth discontinuities to reinforce edge detection.";
    ui_spacing = 4;
> = true;

uniform float _DepthThreshold <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 5.0f;
    ui_type = "slider";
    ui_label = "Depth Threshold";
    ui_tooltip = "Depth difference required to count as an edge.";
> = 0.1f;

uniform bool _UseNormals <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_label = "Use Normals";
    ui_tooltip = "Use surface normal discontinuities to reinforce edge detection.";
> = true;

uniform float _NormalThreshold <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 5.0f;
    ui_type = "slider";
    ui_label = "Normal Threshold";
    ui_tooltip = "Normal difference required to count as an edge.";
> = 0.1f;

uniform float _DepthCutoff <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1000.0f;
    ui_type = "slider";
    ui_label = "Depth Cutoff";
    ui_tooltip = "Distance (in game units) beyond which edges are ignored.";
> = 0.0f;

uniform int _EdgeThreshold <
    ui_category = "Preprocess Settings";
    ui_category_closed = true;
    ui_min = 0; ui_max = 64;
    ui_type = "slider";
    ui_label = "Edge Threshold";
    ui_tooltip = "Minimum edge pixels in an 8×8 tile needed to draw an edge character.";
> = 8;

// -----------------------------------------------------------------------------
// Color Settings
// -----------------------------------------------------------------------------

uniform bool _Edges <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_label = "Draw Edges";
    ui_tooltip = "Render ASCII characters aligned to detected edges.";
> = true;

uniform bool _Fill <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_label = "Draw Fill";
    ui_tooltip = "Fill non-edge tiles with luminance-mapped ASCII characters.";
> = true;

uniform float _Exposure <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 5.0f;
    ui_label = "Luminance Exposure";
    ui_type = "slider";
    ui_tooltip = "Multiplier on luminance before mapping to fill characters. Boost to see more characters in dark areas.";
> = 1.0f;

uniform float _Attenuation <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 5.0f;
    ui_label = "Luminance Attenuation";
    ui_type = "slider";
    ui_tooltip = "Exponent on luminance — raise to compress bright neon into fewer characters.";
> = 1.0f;

uniform bool _InvertLuminance <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_label = "Invert ASCII";
    ui_tooltip = "Swap dark/light mapping so bright areas use sparse characters.";
> = false;

// Default cyan — matches CP2077 holographic/neon aesthetic
uniform float3 _ASCIIColor <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_type = "color";
    ui_label = "ASCII Color";
    ui_spacing = 4;
> = float3(0.0f, 1.0f, 0.9f);

uniform float3 _BackgroundColor <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_type = "color";
    ui_label = "Background Color";
> = float3(0.0f, 0.0f, 0.0f);

uniform float _BlendWithBase <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1.0f;
    ui_label = "Base Color Blend";
    ui_type = "slider";
    ui_tooltip = "0 = use ASCII Color, 1 = tint characters with original scene color.";
> = 0.0f;

uniform float _DepthFalloff <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1.0f;
    ui_label = "Depth Falloff";
    ui_type = "slider";
    ui_tooltip = "Rate at which ASCII fades to background color with distance.";
    ui_spacing = 4;
> = 0.0f;

uniform float _DepthOffset <
    ui_category = "Color Settings";
    ui_category_closed = true;
    ui_min = 0.0f; ui_max = 1000.0f;
    ui_label = "Depth Offset";
    ui_type = "slider";
    ui_tooltip = "Distance at which depth falloff begins.";
> = 0.0f;

// -----------------------------------------------------------------------------
// CP2077-specific: HDR handling
// -----------------------------------------------------------------------------

uniform float _HDRWhitePoint <
    ui_category = "CP2077 HDR Settings";
    ui_category_closed = true;
    ui_min = 1.0f; ui_max = 20.0f;
    ui_type = "slider";
    ui_label = "HDR White Point";
    ui_tooltip = "Brightness value mapped to 1.0 before ASCII luminance sampling. Increase if neon lights wash out characters.";
> = 4.0f;

// -----------------------------------------------------------------------------
// Debug Settings
// -----------------------------------------------------------------------------

uniform bool _ViewDog <
    ui_category = "Debug";
    ui_category_closed = true;
    ui_label = "View DoG";
    ui_tooltip = "Visualize the Difference of Gaussians edge signal.";
> = false;

uniform bool _ViewUncompressed <
    ui_category = "Debug";
    ui_category_closed = true;
    ui_label = "View Uncompressed Edges";
    ui_tooltip = "Show per-pixel edge directions before tile compression.";
> = false;

uniform bool _ViewEdges <
    ui_category = "Debug";
    ui_category_closed = true;
    ui_label = "View Compressed Edges";
    ui_tooltip = "Show dominant edge direction per 8×8 tile (color coded).";
> = false;

// =============================================================================
// Textures / Samplers
// =============================================================================

texture2D CP_ASCIIEdgesLUT < source = "edgesASCII.png"; > { Width = 40; Height = 8; };
sampler2D EdgesASCII { Texture = CP_ASCIIEdgesLUT; AddressU = REPEAT; AddressV = REPEAT; };

texture2D CP_ASCIIFillLUT < source = "fillASCII.png"; > { Width = 80; Height = 8; };
sampler2D FillASCII { Texture = CP_ASCIIFillLUT; AddressU = REPEAT; AddressV = REPEAT; };

// Normals + depth packed into RGBA16F (written by pass 5, read by passes 6 and 9)
sampler2D Normals { Texture = CPTemp2::CP_RenderTex2; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture2D CP_LuminanceTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
sampler2D Luminance { Texture = CP_LuminanceTex; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture2D CP_DownscaleTex { Width = BUFFER_WIDTH / 8; Height = BUFFER_HEIGHT / 8; Format = RGBA16F; };
sampler2D Downscale { Texture = CP_DownscaleTex; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture2D CP_AsciiPingTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D AsciiPing { Texture = CP_AsciiPingTex; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture2D CP_AsciiDogTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
sampler2D DoG { Texture = CP_AsciiDogTex; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture2D CP_AsciiEdgesTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
sampler2D Edges { Texture = CP_AsciiEdgesTex; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture2D CP_AsciiSobelTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG16F; };
sampler2D Sobel { Texture = CP_AsciiSobelTex; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

// ASCII output lives in TempTex1 — EndPass blits it to CyberpunkBufferTex
sampler2D AsciiOut { Texture = CPTemp1::CP_RenderTex1; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
storage2D s_AsciiOut { Texture = CPTemp1::CP_RenderTex1; };

// =============================================================================
// Helpers
// =============================================================================

float gaussian(float sigma, float pos) {
    return (1.0f / sqrt(2.0f * CP_PI * sigma * sigma)) * exp(-(pos * pos) / (2.0f * sigma * sigma));
}

float2 transformUV(float2 uv) {
    float2 z = uv * 2.0f - 1.0f;
    z += float2(-_Offset.x, _Offset.y) * 2.0f;
    z *= _Zoom;
    return z * 0.5f + 0.5f;
}

// Exposure-adjusted Reinhard — maps [0, _HDRWhitePoint] → [0, 1]
float3 tonemapHDR(float3 col) {
    col /= _HDRWhitePoint;
    return col / (1.0f + col);
}

// =============================================================================
// Passes
// =============================================================================

// Pass 1: Luminance
// Tonemaps HDR neon values before extracting grayscale so bright signs produce
// dense ASCII fill rather than washing out to 1.0 and going sparse.
float PS_Luminance(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float3 col = tex2D(CyberpunkFX::CyberpunkBufferBorderLinear, transformUV(uv)).rgb;
    col = tonemapHDR(col);
    return CyberpunkFX::Luminance(saturate(col));
}

// Pass 2: Downscale 8×
// One cell per 8×8 pixel block; stores original (tonemapped) color + luminance in alpha.
float4 PS_Downscale(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float3 col = tex2D(CyberpunkFX::CyberpunkBufferBorderLinear, transformUV(uv)).rgb;
    col = tonemapHDR(col);
    col = saturate(col);
    return float4(col, CyberpunkFX::Luminance(col));
}

// Pass 3: Horizontal Gaussian blur (two sigmas in R and G for DoG)
float4 PS_HorizontalBlur(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float2 texelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float2 blur = 0.0f;
    float2 kernelSum = 0.0f;

    for (int x = -_KernelSize; x <= _KernelSize; ++x) {
        float lum = tex2D(Luminance, uv + float2(x, 0) * texelSize).r;
        float2 g = float2(gaussian(_Sigma, x), gaussian(_Sigma * _SigmaScale, x));
        blur += lum * g;
        kernelSum += g;
    }

    return float4(blur / kernelSum, 0.0f, 0.0f);
}

// Pass 4: Vertical Gaussian blur + Difference of Gaussians
float PS_VerticalBlurAndDifference(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float2 texelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float2 blur = 0.0f;
    float2 kernelSum = 0.0f;

    for (int y = -_KernelSize; y <= _KernelSize; ++y) {
        float2 lum = tex2D(AsciiPing, uv + float2(0, y) * texelSize).rg;
        float2 g = float2(gaussian(_Sigma, y), gaussian(_Sigma * _SigmaScale, y));
        blur += lum * g;
        kernelSum += g;
    }

    blur /= kernelSum;

    float D = blur.x - _Tau * blur.y;
    return (D >= _Threshold) ? 1.0f : 0.0f;
}

// Pass 5: Screen-space normals from depth buffer
// Packs normal.xyz into rgb and linearized depth into alpha.
float4 PS_CalculateNormals(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float3 texelSize = float3(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT, 0.0f);

    float2 posC = uv;
    float2 posN = posC - texelSize.zy;
    float2 posE = posC + texelSize.xz;

    float depthC = ReShade::GetLinearizedDepth(transformUV(posC));
    float3 vC = float3(posC - 0.5f, 1.0f) * depthC;
    float3 vN = float3(posN - 0.5f, 1.0f) * ReShade::GetLinearizedDepth(transformUV(posN));
    float3 vE = float3(posE - 0.5f, 1.0f) * ReShade::GetLinearizedDepth(transformUV(posE));

    return float4(normalize(cross(vC - vN, vC - vE)), depthC);
}

// Pass 6: Edge detection — DoG + depth/normal discontinuities
float4 PS_EdgeDetect(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float2 ts = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

    float4 c  = tex2D(Normals, uv);
    float4 w  = tex2D(Normals, uv + float2(-1,  0) * ts);
    float4 e  = tex2D(Normals, uv + float2( 1,  0) * ts);
    float4 n  = tex2D(Normals, uv + float2( 0, -1) * ts);
    float4 s  = tex2D(Normals, uv + float2( 0,  1) * ts);
    float4 nw = tex2D(Normals, uv + float2(-1, -1) * ts);
    float4 sw = tex2D(Normals, uv + float2( 1, -1) * ts);
    float4 ne = tex2D(Normals, uv + float2(-1,  1) * ts);
    float4 se = tex2D(Normals, uv + float2( 1,  1) * ts);

    float output = 0.0f;

    float depthSum = abs(w.w - c.w) + abs(e.w - c.w) + abs(n.w - c.w) + abs(s.w - c.w)
                   + abs(nw.w - c.w) + abs(sw.w - c.w) + abs(ne.w - c.w) + abs(se.w - c.w);
    if (_UseDepth && depthSum > _DepthThreshold) output = 1.0f;

    float3 normalSum = abs(w.rgb - c.rgb) + abs(e.rgb - c.rgb) + abs(n.rgb - c.rgb) + abs(s.rgb - c.rgb)
                     + abs(nw.rgb - c.rgb) + abs(sw.rgb - c.rgb) + abs(ne.rgb - c.rgb) + abs(se.rgb - c.rgb);
    if (_UseNormals && dot(normalSum, 1.0f) > _NormalThreshold) output = 1.0f;

    float D = tex2D(DoG, uv).r;
    return saturate(abs(D - output));
}

// Pass 7: Horizontal Sobel on edge map
float4 PS_HorizontalSobel(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float2 ts = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

    float l = tex2D(Edges, uv - float2(1, 0) * ts).r;
    float m = tex2D(Edges, uv).r;
    float r = tex2D(Edges, uv + float2(1, 0) * ts).r;

    float Gx =  3.0f * l + 0.0f * m + -3.0f * r;
    float Gy =  3.0f * l + 10.0f * m +  3.0f * r;

    return float4(Gx, Gy, 0.0f, 0.0f);
}

// Pass 8: Vertical Sobel → edge angle θ per pixel
float2 PS_VerticalSobel(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float2 ts = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

    float2 g1 = tex2D(AsciiPing, uv - float2(0, 1) * ts).rg;
    float2 g2 = tex2D(AsciiPing, uv).rg;
    float2 g3 = tex2D(AsciiPing, uv + float2(0, 1) * ts).rg;

    float Gx = 3.0f * g1.x + 10.0f * g2.x +  3.0f * g3.x;
    float Gy = 3.0f * g1.y +  0.0f * g2.y + -3.0f * g3.y;

    float2 G = normalize(float2(Gx, Gy));
    float theta = atan2(G.y, G.x);

    // Discard angle beyond depth cutoff so distant geometry doesn't get edge chars
    if (_DepthCutoff > 0.0f && ReShade::GetLinearizedDepth(transformUV(uv)) * 1000.0f > _DepthCutoff)
        theta = 0.0f / 0.0f; // NaN signals "no edge"

    float valid = 1.0f - isnan(theta);
    return float2(theta, valid);
}

// Pass 9: Compute shader — 8×8 tiles → ASCII characters
// Each tile: collect edge directions from all 64 pixels, vote for most common,
// then sample the correct glyph from the LUT textures.
groupshared int edgeCount[64];

void CS_RenderASCII(uint3 tid : SV_DISPATCHTHREADID, uint3 gid : SV_GROUPTHREADID) {
    float2 sobel = tex2Dfetch(Sobel, tid.xy).rg;
    float theta = sobel.r;
    float absTheta = abs(theta) / CP_PI;

    int direction = -1;
    if (any(sobel.g)) {
        if      ((0.0f  <= absTheta) && (absTheta < 0.05f))  direction = 0; // vertical  |
        else if ((0.9f  <  absTheta) && (absTheta <= 1.0f))  direction = 0;
        else if ((0.45f <  absTheta) && (absTheta < 0.55f))  direction = 1; // horizontal —
        else if ((0.05f <  absTheta) && (absTheta < 0.45f))  direction = sign(theta) > 0 ? 3 : 2; // diagonal /  \.
        else if ((0.55f <  absTheta) && (absTheta < 0.9f))   direction = sign(theta) > 0 ? 2 : 3;
    }

    edgeCount[gid.x + gid.y * 8] = direction;
    barrier();

    int commonEdgeIndex = -1;
    if (gid.x == 0 && gid.y == 0) {
        uint buckets[4] = { 0, 0, 0, 0 };
        for (int i = 0; i < 64; ++i) {
            int d = edgeCount[i];
            if (d >= 0) buckets[d]++;
        }
        uint maxVal = 0;
        for (int j = 0; j < 4; ++j) {
            if (buckets[j] > maxVal) {
                commonEdgeIndex = j;
                maxVal = buckets[j];
            }
        }
        if (maxVal < (uint)_EdgeThreshold) commonEdgeIndex = -1;
        edgeCount[0] = commonEdgeIndex;
    }

    barrier();
    commonEdgeIndex = _ViewUncompressed ? direction : edgeCount[0];

    // -------------------------------------------------------------------------
    // Sample LUT
    // -------------------------------------------------------------------------
    float4 downscaleInfo = tex2Dfetch(Downscale, tid.xy / 8);
    float3 ascii = 0.0f;

    if (saturate(commonEdgeIndex + 1) && _Edges) {
        // Edge character: pick glyph column from direction (0-3), 8px wide each
        float2 localUV;
        localUV.x = (tid.x % 8) + (commonEdgeIndex + 1) * 8;
        localUV.y = 8 - (tid.y % 8);
        ascii = tex2Dfetch(EdgesASCII, localUV).r;
    } else if (_Fill) {
        // Fill character: map tile luminance to one of 10 glyph columns
        float lum = saturate(pow(downscaleInfo.w * _Exposure, _Attenuation));
        if (_InvertLuminance) lum = 1.0f - lum;
        lum = max(0.0f, floor(lum * 10.0f) - 1.0f) / 10.0f;

        float2 localUV;
        localUV.x = (tid.x % 8) + lum * 80.0f;
        localUV.y = (tid.y % 8);
        ascii = tex2Dfetch(FillASCII, localUV).r;
    }

    // Tint: flat ASCII color or blend with scene color
    ascii = lerp(_BackgroundColor, lerp(_ASCIIColor, downscaleInfo.rgb, _BlendWithBase), ascii);

    // Depth-based falloff so distant Night City fades to background
    float depth = tex2Dfetch(Normals, (tid.xy - gid.xy) + 4).w;
    float z = depth * 1000.0f;
    float fog = (_DepthFalloff * 0.005f / sqrt(log(2.0f))) * max(0.0f, z - _DepthOffset);
    fog = exp2(-fog * fog);
    ascii = lerp(_BackgroundColor, ascii, fog);

    // Debug visualizations
    if (_ViewDog) ascii = tex2Dfetch(Edges, tid.xy).r;
    if (_ViewEdges || _ViewUncompressed) {
        ascii = 0.0f;
        if (commonEdgeIndex == 0) ascii = float3(1, 0, 0);
        if (commonEdgeIndex == 1) ascii = float3(0, 1, 0);
        if (commonEdgeIndex == 2) ascii = float3(0, 1, 1);
        if (commonEdgeIndex == 3) ascii = float3(1, 1, 0);
    }

    tex2Dstore(s_AsciiOut, tid.xy, float4(ascii, 1.0f));
}

// Pass 10: Blit compute output to pipeline buffer
float4 PS_EndPass(float4 position : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    return tex2D(AsciiOut, uv).rgba;
}

// =============================================================================
// Technique
// =============================================================================
technique CyberpunkFX_ASCII < ui_label = "ASCII"; ui_tooltip = "(LDR) Replace the scene with ASCII characters. Neon-tuned for Cyberpunk 2077."; > {
    pass Luminance {
        RenderTarget = CP_LuminanceTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_Luminance;
    }
    pass Downscale {
        RenderTarget = CP_DownscaleTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_Downscale;
    }
    pass HorizontalBlur {
        RenderTarget = CP_AsciiPingTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_HorizontalBlur;
    }
    pass VerticalBlurAndDoG {
        RenderTarget = CP_AsciiDogTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_VerticalBlurAndDifference;
    }
    pass CalculateNormals {
        RenderTarget = CPTemp2::CP_RenderTex2;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_CalculateNormals;
    }
    pass EdgeDetect {
        RenderTarget = CP_AsciiEdgesTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_EdgeDetect;
    }
    pass HorizontalSobel {
        RenderTarget = CP_AsciiPingTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_HorizontalSobel;
    }
    pass VerticalSobel {
        RenderTarget = CP_AsciiSobelTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_VerticalSobel;
    }
    pass RenderASCII {
        ComputeShader = CS_RenderASCII<8, 8>;
        DispatchSizeX = BUFFER_WIDTH / 8;
        DispatchSizeY = BUFFER_HEIGHT / 8;
    }
    pass EndPass {
        RenderTarget = CyberpunkFX::CyberpunkBufferTex;
        VertexShader = CyberpunkFX::PostProcessVS;
        PixelShader  = PS_EndPass;
    }
}
