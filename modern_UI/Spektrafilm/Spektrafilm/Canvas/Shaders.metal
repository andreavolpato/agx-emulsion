//  Shaders.metal — the canvas: Layer 2 as a compute pass, a display quad, and
//  the histogram.
//
//  Colour rules (UI-GUIDELINE §4): the image textures already hold Display P3
//  *encoded* values (the engine applied `output_cctf_encoding`; the decoder
//  preview was rendered into Display P3). Nothing here applies a transfer
//  curve to the output; the CAMetalLayer's colour space is Display P3 and
//  ColorSync does the display transform. Layer 2 works on encoded values on
//  purpose — it is an adjustment to a scan — except `exposure`, which is done
//  in a pseudo-linear domain so that "one stop" means one stop.

#include <metal_stdlib>
using namespace metal;

struct Layer2Uniforms {           // must match Adjustments.swift
    float3 wbGain;     float exposureGain;
    float3 cbMaster;   float contrast;
    float3 cbShadows;  float brightness;
    float3 cbMidtones; float saturation;
    float3 cbHighlights; float highlights;
    float4 cbLum;
    float shadows; float blackPoint; float whitePoint;
    float vignetteAmount; float vignetteMidpoint;
    uint curvesActive; uint enabled; uint _pad;
};

struct GeometryUniform {           // must match Geometry.Uniform in Geometry.swift
    float2 centre;                // crop centre, normalised to the source
    float2 halfExtent;            // crop half-size, normalised
    float2 cosSin;                // the straighten angle
    float2 pixelRatio;            // (w/h, h/w) — the rotation is rigid in pixels
    uint quarterTurns;
    uint flips;                   // bit 0 horizontal, bit 1 vertical
    uint active;
    uint pad;
};

struct CanvasUniforms {           // must match Renderer.swift
    float2 viewportSize;          // in device pixels
    float2 imageSize;             // the *output* size in logical pixels
    float2 offset;                // output origin in device pixels
    float scale;                  // device pixels per output logical pixel
    float surroundGray;           // encoded value of the ground
    float magnification;          // device pixels per *source texture* pixel
    GeometryUniform geometry;
    uint editingCrop;             // show the whole frame, dim outside the crop
    uint checker;                 // draw a soft focus frame (unused)
};

//  Output uv → source uv. A transliteration of
//  `Geometry.sourcePoint(forOutput:imageSize:)`; `GeometryTests` pins the
//  pairs both must produce, because a divergence here is a picture that is
//  subtly the wrong part of the frame and nothing says so.
static inline float2 geometryMap(float2 uv, constant GeometryUniform &g) {
    if (g.active == 0) return uv;
    float2 u = uv;
    if (g.flips & 1u) u.x = 1.0 - u.x;
    if (g.flips & 2u) u.y = 1.0 - u.y;
    switch (g.quarterTurns) {
        case 1: u = float2(u.y, 1.0 - u.x); break;
        case 2: u = float2(1.0 - u.x, 1.0 - u.y); break;
        case 3: u = float2(1.0 - u.y, u.x); break;
        default: break;
    }
    // Crop-local, in units where one unit of x and one of y are the same
    // number of source pixels — otherwise the rotation shears on a
    // non-square frame.
    float px = (u.x - 0.5) * 2.0 * g.halfExtent.x;
    float py = (u.y - 0.5) * 2.0 * g.halfExtent.y * g.pixelRatio.y;
    float rx = px * g.cosSin.x - py * g.cosSin.y;
    float ry = px * g.cosSin.y + py * g.cosSin.x;
    return float2(g.centre.x + rx, g.centre.y + ry * g.pixelRatio.x);
}

/// Whether a *source* uv is inside the oriented crop. The inverse rotation of
/// the map above, used only while the crop is being edited.
static inline bool insideCrop(float2 suv, constant GeometryUniform &g) {
    float dx = suv.x - g.centre.x;
    float dy = (suv.y - g.centre.y) * g.pixelRatio.y;
    float lx =  dx * g.cosSin.x + dy * g.cosSin.y;
    float ly = -dx * g.cosSin.y + dy * g.cosSin.x;
    return abs(lx) <= g.halfExtent.x && abs(ly) <= g.halfExtent.y * g.pixelRatio.y;
}

static inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static inline float curveLookup(texture2d<float> table, sampler s, float x, int row) {
    return table.sample(s, float2(x, (float(row) + 0.5) / 5.0)).r;
}

kernel void layer2(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   texture2d<float> curves [[texture(2)]],
                   constant Layer2Uniforms &u [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 c = src.read(gid).rgb;
    if (u.enabled == 0) { dst.write(float4(c, 1), gid); return; }

    constexpr sampler lin(filter::linear, address::clamp_to_edge);

    // 1. white balance (scan-side gains on encoded values)
    c *= u.wbGain;
    // 2. exposure in a pseudo-linear domain, then contrast and brightness
    if (u.exposureGain != 1.0) {
        c = pow(max(c, 0.0), 2.2) * u.exposureGain;
        c = pow(c, 1.0 / 2.2);
    }
    if (u.contrast != 0.0) {
        float k = 1.0 + u.contrast * 1.2;
        c = (c - 0.5) * k + 0.5;
    }
    if (u.brightness != 0.0) {
        c = pow(max(c, 0.0), 1.0 / (1.0 + u.brightness * 0.8));
    }
    // 3. highlights / shadows — tone-region masks on luma
    float l = luma(c);
    if (u.shadows != 0.0) {
        float w = (1.0 - l); w = w * w;
        c += u.shadows * 0.25 * w * (1.0 - c);
    }
    if (u.highlights != 0.0) {
        float w = l * l;
        c += u.highlights * 0.25 * w * (u.highlights > 0 ? (1.0 - c) : c);
    }
    // 4. black / white point (the scanner's job)
    c = (c - u.blackPoint) / max(1.0 - u.blackPoint - u.whitePoint, 0.05);
    // 5. saturation
    l = luma(c);
    c = l + (c - l) * u.saturation;
    // 6. colour balance — master + three zones
    {
        float ls = saturate(l);
        float wS = (1.0 - ls) * (1.0 - ls);
        float wH = ls * ls;
        float wM = max(1.0 - wS - wH, 0.0);
        c += u.cbMaster + u.cbShadows * wS + u.cbMidtones * wM + u.cbHighlights * wH;
        c *= 1.0 + u.cbLum.x + u.cbLum.y * wS + u.cbLum.z * wM + u.cbLum.w * wH;
    }
    // 7. curves — luma, then RGB master, then per channel
    if (u.curvesActive != 0) {
        c = saturate(c);
        float ly = luma(c);
        float ly2 = curveLookup(curves, lin, ly, 1);
        c *= (ly > 1e-4) ? (ly2 / ly) : 1.0;
        c = saturate(c);
        c = float3(curveLookup(curves, lin, c.r, 0), curveLookup(curves, lin, c.g, 0), curveLookup(curves, lin, c.b, 0));
        c = float3(curveLookup(curves, lin, c.r, 2), curveLookup(curves, lin, c.g, 3), curveLookup(curves, lin, c.b, 4));
    }
    // 8. vignette — radial, in encoded space
    if (u.vignetteAmount != 0.0) {
        float2 size = float2(dst.get_width(), dst.get_height());
        float2 p = (float2(gid) + 0.5) / size - 0.5;
        float d = length(p * 2.0);          // 0 centre … ~1.41 corner
        float fall = smoothstep(u.vignetteMidpoint * 1.2, 1.5, d);
        c *= 1.0 + u.vignetteAmount * fall * 0.9;
    }
    dst.write(float4(saturate(c), 1), gid);
}

//  Export's geometry pass. Deliberately the *same* `geometryMap` the canvas
//  uses rather than a CoreGraphics transform beside it: two implementations
//  of a rotation are two chances to disagree about a sign, and the way that
//  failure presents is an exported file that is subtly the wrong part of the
//  frame, which nothing checks.
kernel void geometryResample(texture2d<float, access::sample> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant GeometryUniform &g [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler lin(filter::linear, address::clamp_to_edge, mip_filter::none);
    float2 ouv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(float4(src.sample(lin, geometryMap(ouv, g)).rgb, 1), gid);
}

struct QuadOut { float4 position [[position]]; float2 uv; };

vertex QuadOut canvasVertex(uint vid [[vertex_id]]) {
    // Two triangles covering clip space; uv has (0,0) at top-left.
    float2 pos[6] = { {-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1} };
    QuadOut o;
    o.position = float4(pos[vid], 0, 1);
    o.uv = float2(pos[vid].x * 0.5 + 0.5, 0.5 - pos[vid].y * 0.5);
    return o;
}

fragment float4 canvasFragment(QuadOut in [[stage_in]],
                               texture2d<float> image [[texture(0)]],
                               constant CanvasUniforms &u [[buffer(0)]])
{
    // Below 100 % the image is minified: linear. At or above 100 % every
    // image pixel covers whole device pixels: nearest, so a 400 % view shows
    // the actual pixels (and grain) instead of a smear. The test is on
    // `magnification` — device pixels per *source texture* pixel — not on
    // `scale`, because with a crop applied those are no longer the same
    // number and a 12 % crop would otherwise pick nearest at 40 % zoom.
    constexpr sampler lin(filter::linear, address::clamp_to_edge, mip_filter::none);
    constexpr sampler near(filter::nearest, address::clamp_to_edge, mip_filter::none);
    float2 px = in.uv * u.viewportSize;                    // device pixel, top-left origin
    float2 ip = (px - u.offset) / u.scale;                 // output logical pixel
    float2 ouv = ip / u.imageSize;                         // 0…1 across the output
    float3 ground = float3(u.surroundGray);
    if (ouv.x < 0.0 || ouv.y < 0.0 || ouv.x > 1.0 || ouv.y > 1.0) {
        return float4(ground, 1);
    }
    // While the crop is being edited the canvas shows the whole frame, the
    // way Capture One's crop tool does: you cannot judge a crop against
    // pixels you cannot see.
    float2 suv = (u.editingCrop != 0) ? ouv : geometryMap(ouv, u.geometry);
    if (suv.x < 0.0 || suv.y < 0.0 || suv.x > 1.0 || suv.y > 1.0) {
        return float4(ground, 1);
    }
    float3 c = (u.magnification >= 1.0) ? image.sample(near, suv).rgb : image.sample(lin, suv).rgb;
    if (u.editingCrop != 0 && u.geometry.active != 0 && !insideCrop(suv, u.geometry)) {
        c = mix(c, ground, 0.6);
    }
    return float4(c, 1);
}

// 4 rows × 256 bins: R, G, B, luma. Sampled on a stride so a 2 MP frame costs
// ~130k reads; plenty for a 256-bin plot.
kernel void histogram(texture2d<float, access::read> src [[texture(0)]],
                      device atomic_uint *bins [[buffer(0)]],
                      constant uint &stride [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]])
{
    uint2 p = gid * stride;
    if (p.x >= src.get_width() || p.y >= src.get_height()) return;
    float3 c = saturate(src.read(p).rgb);
    uint r = uint(c.r * 255.0 + 0.5), g = uint(c.g * 255.0 + 0.5), b = uint(c.b * 255.0 + 0.5);
    uint y = uint(saturate(luma(c)) * 255.0 + 0.5);
    atomic_fetch_add_explicit(&bins[r], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[256 + g], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[512 + b], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[768 + y], 1u, memory_order_relaxed);
}
