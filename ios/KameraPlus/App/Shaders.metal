#include <metal_stdlib>
using namespace metal;

// Søgerens shader: kamerabillede → (det ægte målkort lagt præcist over det fysiske kort) → evt. afsløring → skærm.
// Overgangene bruger samme formler som Logic/Transition.swift (RevealPlan), overlay-området samme som
// CardGeometry.overlayDistance, og lyset samme model som CardTracker (kamera ≈ gain · skabelon + offset, lineært).

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut kp_vertex(uint vid [[vertex_id]]) {
    const float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    o.uv = float2((p[vid].x + 1) * 0.5, 1 - (p[vid].y + 1) * 0.5);
    return o;
}

struct Uniforms {
    float4 hinv0;       // rækker i homografien kamerapixel → kanoniske kortkoordinater
    float4 hinv1;
    float4 hinv2;
    float4 gain;        // rgb: lys på kortet (lineært)
    float4 offset;      // rgb
    float4 overlay;     // minX, minY, maxX, maxY af overlay-området (kanonisk)
    float2 cardSize;    // kanonisk bredde/højde
    float2 cropOrigin;  // synligt udsnit af billedet (0…1)
    float2 cropSize;
    float2 frameSize;   // billedets pixels
    float2 center;      // bølgens centrum (pixels)
    float mirror;
    float effect;       // 1 = målkortet tegnes (helt eller under afsløring)
    float kind;         // 0 bølge, 1 øjeblikkelig, 2 fade, 3 fej
    float progress;     // easet fremdrift 0…1 (0 = forklædt)
    float radius;       // bølgefront (pixels)
    float softness;     // kantblødhed (pixels)
    float sweepY;       // fej-front (pixels)
    float glow;         // svag lys kant (0…1)
    float showMask;
    float flash;        // lukkerblink (0…1, sort)
    float white;        // forsidelys/hvid skærm (0…1)
    float feather;      // blød kant om overlay-området (kanonisk)
    float overlayRadius;
    float lodBias;      // uskarphed (mipmap-niveauer)
    float grain;        // korn (0…1 af 8-bit-trin)
    float seed;
};

static float3 toLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
}

static float3 toSRGB(float3 c) {
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= 0.0031308);
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fragment float4 kp_fragment(VOut in [[stage_in]],
                            texture2d<float> cam [[texture(0)]],
                            texture2d<float> vis [[texture(1)]],
                            texture2d<float> card [[texture(2)]],
                            constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler ms(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(4));
    float2 uv = in.uv;
    if (u.mirror > 0.5) { uv.x = 1.0 - uv.x; }
    float2 fuv = u.cropOrigin + uv * u.cropSize;
    float3 c = cam.sample(s, fuv).rgb;
    float2 p = fuv * u.frameSize;
    float mark = 0.0;
    if (u.effect > 0.5) {
        float3 ph = float3(p, 1.0);
        float3 q = float3(dot(u.hinv0.xyz, ph), dot(u.hinv1.xyz, ph), dot(u.hinv2.xyz, ph));
        // prøverne tages uden for betingede grene (mipmap-niveauet kræver afledte værdier for hele 2×2-blokken)
        float2 cu = q.xy / max(q.z, 1e-6);
        float3 t = card.sample(ms, cu / u.cardSize, bias(u.lodBias)).rgb;
        float2 vv = vis.sample(s, fuv).rg;
        float2 cen = (u.overlay.xy + u.overlay.zw) * 0.5;
        float2 hs = (u.overlay.zw - u.overlay.xy) * 0.5 - u.overlayRadius;
        float2 d = abs(cu - cen) - hs;
        float sd = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - u.overlayRadius;
        float region = q.z > 1e-6 ? 1.0 - smoothstep(-u.feather, 0.0, sd) : 0.0;
        if (region > 0.001) {
            float visible = vv.r;
            float shade = vv.g * (255.0 / 128.0);
            float3 lin = (toLinear(t) * u.gain.rgb + u.offset.rgb) * shade;
            float3 target = toSRGB(clamp(lin, 0.0, 1.0));
            target += (hash12(p + u.seed) - 0.5) * u.grain * (2.0 / 255.0);
            float r;
            if (u.kind < 0.5) {
                r = 1.0 - smoothstep(u.radius - u.softness, u.radius + u.softness, distance(p, u.center));
            } else if (u.kind < 2.5) {
                r = u.progress;
            } else {
                r = 1.0 - smoothstep(u.sweepY - u.softness, u.sweepY + u.softness, p.y);
            }
            float k = region * visible * (1.0 - r);
            float3 outc = mix(c, target, k);
            if (u.glow > 0.0 && u.kind < 0.5) {
                float dd = distance(p, u.center) - u.radius;
                float w = max(1.0, 0.6 * u.softness);
                outc += region * visible * u.glow * 0.12 * exp(-(dd * dd) / (w * w));
            }
            c = outc;
            mark = region * visible;
        }
    }
    if (u.showMask > 0.5) {
        c = mix(c, float3(1.0, 0.0, 1.0), 0.3 * mark);
    }
    c = mix(c * (1.0 - u.flash), float3(1.0), u.white);
    return float4(c, 1.0);
}
