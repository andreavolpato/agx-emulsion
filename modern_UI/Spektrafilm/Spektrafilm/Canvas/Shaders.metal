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


//  ── masks (蒙版) ────────────────────────────────────────────────────────────
//
//  A mask is a region plus its own tone adjustments (`Model/Mask.swift`).
//  Every component except `brush` is closed-form, so coverage is computed per
//  pixel from parameters at whatever resolution the canvas happens to be
//  showing: a radial gradient is exact at 400 % zoom and costs no memory at
//  any tier. Only `brush` reads a texture, and a mask with no brush in it
//  binds none.
//
//  Distances are aspect-corrected into "long-edge units" so an ellipse is an
//  ellipse on a 3:2 frame and a gradient's feather is the same width whether
//  it runs across the frame or down it.

struct MaskComponentUniform {     // must match MaskComponentUniform in Mask.swift
    uint kind;                    // 0 linear · 1 radial · 2 luminance · 3 colour · 4 brush
    uint subtract;
    uint inverted;
    uint pad0;
    float2 a;
    float2 b;
    float2 radii;
    float2 cosSin;
    float4 range;                 // low, high, softness, tolerance
    float4 color;
    float feather;
    float3 pad1;
};

struct MaskUniform {              // must match MaskUniform in Mask.swift
    Layer2Uniforms adjustments;
    MaskComponentUniform components[6];
    uint componentCount;
    uint inverted;
    float amount;
    int rasterSlice;              // −1 when the mask has no brush component
};

/// Normalised uv → long-edge units, so x and y are the same physical
/// distance. `aspect` is width ÷ height.
static inline float2 toLongEdge(float2 uv, float aspect) {
    return aspect >= 1.0 ? float2(uv.x, uv.y / aspect) : float2(uv.x * aspect, uv.y);
}

static inline float linearCoverage(float2 uv, constant MaskComponentUniform &c, float aspect) {
    float2 p = toLongEdge(uv, aspect);
    float2 a = toLongEdge(c.a, aspect), b = toLongEdge(c.b, aspect);
    float2 axis = b - a;
    float len2 = max(dot(axis, axis), 1e-9);
    float t = dot(p - a, axis) / len2;
    return smoothstep(0.0, 1.0, saturate(t));
}

static inline float radialCoverage(float2 uv, constant MaskComponentUniform &c, float aspect) {
    float2 d = toLongEdge(uv, aspect) - toLongEdge(c.a, aspect);
    // Into the ellipse's own frame, then normalise by its semi-axes: `r` is
    // 1 exactly on the boundary whatever the rotation and the aspect.
    float2 e = float2( d.x * c.cosSin.x + d.y * c.cosSin.y,
                      -d.x * c.cosSin.y + d.y * c.cosSin.x) / c.radii;
    float r = length(e);
    // Feather 0 is a hard edge; 1 falls off from the centre.
    float inner = 1.0 - saturate(c.feather);
    return 1.0 - smoothstep(inner, 1.0, r);
}

static inline float luminanceCoverage(float3 rgb, constant MaskComponentUniform &c) {
    float l = luma(rgb);
    float soft = c.range.z;
    return smoothstep(c.range.x - soft, c.range.x + soft, l) *
           (1.0 - smoothstep(c.range.y - soft, c.range.y + soft, l));
}

static inline float colorCoverage(float3 rgb, constant MaskComponentUniform &c) {
    // Distance in a cheap chroma space: the two opponent axes plus a much
    // lighter weight on luminance, so "this green" selects the green in the
    // shade as well as the green in the sun.
    float3 t = c.color.rgb;
    float2 ca = float2(rgb.r - rgb.g, rgb.b - (rgb.r + rgb.g) * 0.5);
    float2 cb = float2(t.r - t.g, t.b - (t.r + t.g) * 0.5);
    float d = length(ca - cb) + abs(luma(rgb) - luma(t)) * 0.25;
    return 1.0 - smoothstep(c.range.w * 0.5, c.range.w, d);
}

/// One mask's coverage at a pixel, before `amount`. Components union when
/// they add and cut when they subtract, which is what makes "the sky, minus
/// the trees" one mask rather than two.
static inline float maskCoverage(constant MaskUniform &m, float2 uv, float3 rgb, float aspect,
                                 texture2d_array<float> rasters, sampler s)
{
    float total = 0.0;
    for (uint i = 0; i < m.componentCount && i < 6; ++i) {
        constant MaskComponentUniform &c = m.components[i];
        float cc = 0.0;
        switch (c.kind) {
            case 0: cc = linearCoverage(uv, c, aspect); break;
            case 1: cc = radialCoverage(uv, c, aspect); break;
            case 2: cc = luminanceCoverage(rgb, c); break;
            case 3: cc = colorCoverage(rgb, c); break;
            case 4: cc = (m.rasterSlice >= 0) ? rasters.sample(s, uv, uint(m.rasterSlice)).r : 0.0; break;
            default: break;
        }
        if (c.inverted != 0) cc = 1.0 - cc;
        // The first component is additive whatever its flag says; there is
        // nothing to subtract from yet. `Mask.swift` packs it that way, and
        // this is the same rule stated where it is used.
        if (i > 0 && c.subtract != 0) total = min(total, 1.0 - cc);
        else                          total = max(total, cc);
    }
    if (m.inverted != 0) total = 1.0 - total;
    return saturate(total) * m.amount;
}

/// Steps 1–6 of Layer 2: white balance, exposure, contrast, brightness,
/// highlights/shadows, black/white point, saturation and colour balance.
///
/// A function rather than the body of the kernel because **a mask runs the
/// same arithmetic on the same values** — a mask is a local Layer 2, so "+1
/// stop" has to mean the same thing whichever slider it came from. Curves and
/// the vignette stay in the kernel: a curve is a global statement about a
/// tone scale and a vignette is a lens, and neither means anything applied to
/// a region.
static inline float3 layer2Tone(float3 c, constant Layer2Uniforms &u) {
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
    return c;
}

kernel void layer2(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   texture2d<float> curves [[texture(2)]],
                   texture2d_array<float> maskRasters [[texture(3)]],
                   constant Layer2Uniforms &u [[buffer(0)]],
                   constant MaskUniform *masks [[buffer(1)]],
                   constant uint &maskCount [[buffer(2)]],
                   constant int &maskOverlay [[buffer(3)]],
                   uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 c = src.read(gid).rgb;
    if (u.enabled == 0 && maskCount == 0) { dst.write(float4(c, 1), gid); return; }

    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    constexpr sampler maskSampler(filter::linear, address::clamp_to_edge, mip_filter::none);

    float2 size = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float aspect = size.x / max(size.y, 1.0);

    // Coverage is computed against the image *before* the global adjustments,
    // so a luminance-range or colour-range mask selects what the photograph
    // has in it rather than what the exposure slider just did to it. Move a
    // global slider and the region a "highlights" mask covers stays put,
    // which is the behaviour that makes the two independently adjustable.
    float3 masked = c;

    if (u.enabled != 0) {
        c = layer2Tone(c, u);
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
    }

    // 8. masks — local Layer 2. Applied after the global pass, the way every
    // comparable editor orders them: a mask is a correction to the picture
    // you have, not to the one you started with.
    float shown = 0.0;
    for (uint i = 0; i < maskCount && i < 8; ++i) {
        float cover = maskCoverage(masks[i], uv, masked, aspect, maskRasters, maskSampler);
        if (cover > 0.0005) {
            c = mix(c, layer2Tone(c, masks[i].adjustments), cover);
        }
        // Only the selected mask tints. Showing every mask's coverage at
        // once is a red picture and tells you nothing about the one you are
        // editing.
        if (int(i) == maskOverlay) shown = cover;
    }

    // 9. vignette — radial, in encoded space
    if (u.enabled != 0 && u.vignetteAmount != 0.0) {
        float2 p = uv - 0.5;
        float d = length(p * 2.0);          // 0 centre … ~1.41 corner
        float fall = smoothstep(u.vignetteMidpoint * 1.2, 1.5, d);
        c *= 1.0 + u.vignetteAmount * fall * 0.9;
    }

    // The red overlay, drawn last so it is not itself adjusted. Every editor
    // uses red and every editor's users turn it off, so it is a toggle — and
    // it tints only the mask at `maskOverlay`, the selected one. −1 is off.
    if (maskOverlay >= 0 && shown > 0.0005) {
        c = mix(c, float3(0.85, 0.15, 0.15), shown * 0.45);
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
