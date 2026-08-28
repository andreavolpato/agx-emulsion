//  Shaders.metal — canvas compositing.
//
//  What is here in step one: a full-screen triangle, a zoom/pan sampling
//  transform, and the Layer 2 adjustment stage. What is deliberately NOT
//  here: any gamma curve, in either direction.
//
//  The texture arrives already Display P3-encoded (ImageDecoder renders it
//  that way, exactly once) and the CAMetalLayer's colour space is set to
//  Display P3, so ColorSync performs the display transform. Applying a curve
//  here, or converting primaries here while also letting the layer convert,
//  is the double-application class of bug API-SPEC §4 cost a session to find.
//  UI-GUIDELINE §4 rules 1–3.
//
//  Layer 2 operating on encoded values is likewise deliberate, not an
//  oversight (UI-GUIDELINE §4 rule 4). These are adjustments to a scan of a
//  print — frontend SPEC §3.1 — so linearising first would make them
//  physically-flavoured operations, which they are not, and would change
//  their behaviour away from what the reference apps do.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct CanvasUniforms {
    // Image-space sampling transform: uv * scale + offset.
    float2 scale;
    float2 offset;
    // Layer 2. All zero means "pass through" — the neutral state is the
    // unmodified output of Layer 1, and nothing is pre-applied.
    float exposure;      // stops
    float highlights;
    float shadows;
    float blackPoint;
    float whitePoint;
    float layer2Enabled; // the bypass switch, frontend SPEC §3.1 rule 2
};

// A single oversized triangle rather than a quad: no diagonal seam, three
// vertices instead of six, and no vertex buffer to bind.
vertex VertexOut canvas_vertex(uint vid [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    const float2 uvs[3]       = { float2( 0.0,  2.0), float2( 0.0, 0.0), float2(2.0, 0.0) };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

// Soft highlight/shadow region weights. Smooth, so a recovery move does not
// leave a visible boundary where the region ends.
static inline float highlight_weight(float luma) {
    return smoothstep(0.45, 1.0, luma);
}
static inline float shadow_weight(float luma) {
    return 1.0 - smoothstep(0.0, 0.55, luma);
}

fragment float4 canvas_fragment(VertexOut in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                constant CanvasUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_border,
                          border_color::opaque_black, mip_filter::none);

    float2 uv = in.uv * u.scale + u.offset;
    float4 texel = source.sample(smp, uv);
    float3 rgb = texel.rgb;

    if (u.layer2Enabled > 0.5) {
        // Fixed order, matching frontend SPEC §5.2 item 6:
        // exposure -> highlights/shadows -> black/white point -> curve.
        // Fixed because it is what keeps the sidecar replayable at export
        // without storing a node graph.
        rgb *= exp2(u.exposure);

        float luma = dot(rgb, float3(0.2289, 0.6917, 0.0793)); // Display P3 luma
        rgb += rgb * (u.highlights * highlight_weight(luma));
        rgb += rgb * (u.shadows * shadow_weight(luma));

        // The headroom these two work in is the scan-normalisation margin
        // between the paper's Dmin/Dmax and 0/1 — roughly 1/3 to 2/3 stop at
        // each end (frontend SPEC §6.1). Not enough to recover highlights;
        // the paper's toe and shoulder are irreversible, and large tonal
        // moves belong to print exposure in Layer 1.
        float black = u.blackPoint;
        float white = 1.0 + u.whitePoint;
        rgb = (rgb - black) / max(white - black, 1e-4);
    }

    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// Checkerboard for the region outside the image, so the frame edge reads as
// an edge rather than as black clipping in the picture.
fragment float4 canvas_backdrop(VertexOut in [[stage_in]],
                                constant float2 &viewport [[buffer(0)]]) {
    float2 p = floor(in.uv * viewport / 16.0);
    float checker = fmod(p.x + p.y, 2.0);
    float v = mix(0.052, 0.068, checker);
    return float4(v, v, v, 1.0);
}
