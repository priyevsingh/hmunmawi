#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A common one-line pseudo-random hash from the shader community (no particular source or licence).
static float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * valueNoise(p);
        p *= 2.03;
        a *= 0.5;
    }
    return v;
}

static half3 auroraColor(float2 position, float2 size, float time, half3 tint, half3 base);

/// A slow aurora of the page tint over the window colour, with a fixed fine grain (no flicker).
[[ stitchable ]] half4 aurora(float2 position, half4 color, float2 size, float time, half4 tint, half4 base) {
    return half4(auroraColor(position, size, time, tint.rgb, base.rgb), 1.0);
}

// MetalKit path: a full-screen triangle drawn straight on the GPU, no SwiftUI work per frame.
struct AuroraUniforms {
    float2 size;
    float time;
    float pad;
    float4 tint;
    float4 base;
};

struct AuroraVertexOut {
    float4 position [[position]];
};

vertex AuroraVertexOut auroraVertex(uint vid [[vertex_id]]) {
    float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    AuroraVertexOut out;
    out.position = float4(corners[vid], 0, 1);
    return out;
}

fragment half4 auroraFragment(AuroraVertexOut in [[stage_in]], constant AuroraUniforms &u [[buffer(0)]]) {
    return half4(auroraColor(in.position.xy, u.size, u.time, half3(u.tint.rgb), half3(u.base.rgb)), 1.0);
}

static half3 auroraColor(float2 position, float2 size, float time, half3 tint, half3 base) {
    float2 uv = position / max(size, float2(1.0));
    float t = time * 0.035;
    float2 warp = float2(fbm(uv * 1.8 + t), fbm(uv * 1.8 - t + 3.7));
    float field = fbm(uv * 1.4 + warp * 1.5 + float2(t * 0.6, -t * 0.4));

    float glow = smoothstep(0.25, 0.90, field) * 0.55 + (1.0 - uv.y) * 0.10 + (1.0 - uv.x) * 0.05;
    half3 col = mix(base, tint, half(glow));

    float drift = smoothstep(0.55, 0.95, fbm(uv * 2.6 - warp + t * 0.8));
    // A second muted hue drifting through, derived from the tint so it suits light and dark.
    half3 second = mix(base, tint.bgr, 0.8h);
    col = mix(col, second, half(drift * 0.35));

    float grain = (hash21(floor(position)) - 0.5) * 0.012;
    return col + half(grain);
}

/// Hmunmawi's living backdrop: two or three very soft lights of the scene's colour drifting slowly over the
/// window colour. Cheap per pixel (no loops over the screen), drawn at a low frame rate and paused when hidden.
[[ stitchable ]] half4 sceneGlow(float2 position, half4 color, float2 size, float time, half4 tint, float strength) {
    float2 uv = position / max(size, float2(1.0));
    float2 a = float2(0.20 + 0.10 * sin(time * 0.07), 0.25 + 0.08 * cos(time * 0.05));
    float2 b = float2(0.82 + 0.08 * cos(time * 0.06), 0.30 + 0.10 * sin(time * 0.04));
    float2 c = float2(0.55 + 0.12 * sin(time * 0.045), 0.85 + 0.06 * cos(time * 0.08));
    float aspect = size.x / max(size.y, 1.0);
    float2 s = float2(aspect, 1.0);
    float g = exp(-pow(length((uv - a) * s) / 0.55, 2.0))
            + 0.8 * exp(-pow(length((uv - b) * s) / 0.50, 2.0))
            + 0.6 * exp(-pow(length((uv - c) * s) / 0.60, 2.0));
    half k = half(clamp(g * strength, 0.0, 1.0));
    return half4(mix(color.rgb, tint.rgb, k), color.a);
}

// The glyph as a thick piece of coloured glass. On the Mac there is no tilt; the
// light only moves while the pointer is over the icon, so icons cost nothing at rest.

/// The feature mark: the glyph *is* the icon. The symbol's own silhouette (the layer) is read as a
/// height field (blurred coverage = a bevel), lit as a thick piece of coloured glass: drifting key light, rim light, a specular, a slow light sweep, a glow where light leaves the glass
/// at the bottom, and a soft halo around the shape. No disc, no plate behind it.
static inline float gelCoverage(SwiftUI::Layer layer, float2 p, float r) {
    float a = layer.sample(p).a * 2.0;
    for (int i = 0; i < 8; i++) {
        float ang = float(i) * 0.7853982;
        a += layer.sample(p + float2(cos(ang), sin(ang)) * r).a;
    }
    return a / 10.0;
}

[[ stitchable ]] half4 iconGel(float2 position, SwiftUI::Layer layer, float2 size, half4 tint, float time, float2 tilt, float dark) {
    float s = max(size.x, 1.0);
    float r = s * 0.13;                      // bevel width
    float a0 = layer.sample(position).a;     // anti-aliased coverage of the glyph itself
    float h = gelCoverage(layer, position, r);
    if (h < 0.002) return half4(0.0);
    float e = s * 0.06;
    float hx = gelCoverage(layer, position + float2(e, 0.0), r) - gelCoverage(layer, position - float2(e, 0.0), r);
    float hy = gelCoverage(layer, position + float2(0.0, e), r) - gelCoverage(layer, position - float2(0.0, e), r);
    float3 n = normalize(float3(-hx * 2.6, -hy * 2.6, 1.0));

    float2 uv = position / size;
    // Screen space: y grows downwards, so the key light sits up-left and drifts; tilt steers it.
    float3 key = normalize(float3(-0.45 + 0.25 * sin(time * 0.5) + tilt.x * 0.7, -0.65 - tilt.y * 0.5, 0.62));
    float3 fillL = normalize(float3(0.4, 0.8, 0.45));
    float3 view = float3(0.0, 0.0, 1.0);
    float diff = max(dot(n, key), 0.0);
    float fill = max(dot(n, fillL), 0.0);
    float rim = pow(1.0 - max(dot(n, view), 0.0), 1.6);
    float spec = pow(max(dot(n, normalize(key + view)), 0.0), 48.0);
    // A band of light that slowly crosses the glass.
    float sweep = exp(-pow((uv.x - uv.y * 0.35 - (fract(time * 0.09) * 2.6 - 0.8)) * 5.0, 2.0)) * 0.22;

    half3 col = tint.rgb * half(0.5 + 0.55 * diff);
    col = mix(col, tint.rgb * half(1.2) + half3(0.06), half(fill * 0.35));
    col *= half(mix(0.72, 1.0, smoothstep(0.0, 0.85, h)));           // thicker, darker glass towards the edge
    col = mix(col, half3(1.0), half(rim * (0.42 - 0.12 * dark)));     // rim light
    col += half3(1.0, 0.98, 0.95) * half(spec * 0.85 + sweep);        // specular + sweep
    col += tint.rgb * half(pow(clamp(uv.y - 0.45, 0.0, 1.0) * 1.8, 2.0) * 0.5);   // light leaving at the bottom
    col = mix(col, col * half(1.12) + tint.rgb * half(0.08), half(dark));          // glows a little in the dark

    // Inside the glyph: the glass. Outside: a soft halo in the tint, fading with the blurred coverage.
    float halo = (1.0 - a0) * h * (0.28 + 0.12 * dark);
    half3 outCol = clamp(col, half3(0.0), half3(1.0)) * half(a0) + tint.rgb * half(halo);
    float alpha = clamp(a0 + halo, 0.0, 1.0);
    return half4(outCol, half(alpha));
}


// The living backdrop (drifting mist and a glow that breathes).

/// The canvas (`base`, the theme colour for Light or Dark) coming alive: a soft mist and a glow in the scene's
/// colour around `centre`. `pulse` (0…1) brightens it briefly; `breath` (0…1) slowly swells it. Gentle vignette + fine grain for a filmic finish. `dark` = 1 in Dark Mode.
[[ stitchable ]] half4 breathField(float2 position, half4 color, float2 size, float time,
                                   half4 base, half4 accent, float2 centre, float pulse, float breath, float dark) {
    float2 uv = position / max(size.y, 1.0);
    float2 c = centre / max(size.y, 1.0);

    // Slowly drifting, domain-warped mist.
    float2 q = float2(fbm(uv * 2.2 + time * 0.035), fbm(uv * 2.2 - time * 0.03 + 3.7));
    float mist = fbm(uv * 3.0 + q * 1.6 + time * 0.02);

    // Glow around the pet: radius swells with the breath, brightness with the last tap.
    float d = distance(uv, c);
    float radius = 0.36 + 0.05 * breath + 0.05 * pulse;
    float glow = exp(-pow(d / radius, 2.0) * 2.2);

    // Light Mode: tint is mixed in softly so the cream stays cream; Dark Mode: the colour glows.
    float strength = mix(0.30, 0.42, dark) + 0.30 * pulse + 0.10 * breath;
    half3 col = mix(base.rgb, accent.rgb, half(clamp(glow * strength + mist * mix(0.05, 0.09, dark), 0.0, 0.85)));
    // A warm highlight at the heart of the glow (lighter in Light Mode, ember-like in Dark Mode).
    half3 core = mix(half3(1.0, 0.97, 0.92), half3(1.0, 0.86, 0.72), half(dark));
    col = mix(col, core, half(pow(glow, 6.0) * (0.18 + 0.25 * pulse)));

    // Vignette (subtle in Light Mode) + fine grain.
    float vig = smoothstep(1.25, 0.25, distance(position / size, float2(0.5, 0.45)) * 1.6);
    col *= half(mix(0.93, 0.6, dark) + mix(0.07, 0.4, dark) * vig);
    float grain = hash21(position + fract(time * 7.0) * 113.0) - 0.5;
    col += half(grain * mix(0.012, 0.018, dark));

    return half4(clamp(col, half3(0.0), half3(1.0)), 1.0);
}

