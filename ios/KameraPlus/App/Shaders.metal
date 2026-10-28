#include <metal_stdlib>
using namespace metal;

// Søgerens shader: kamerabillede → (forklædning i kortmasken) → evt. afsløring → skærm.
// Samme formler som Logic/Transition.swift og ColorTransfer.apply(to:weight:gain:).

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
    float4 gain;        // rgb: forstærkning der fjerner skærmens lys på kortet
    float2 cropOrigin;  // synligt udsnit af billedet (0…1)
    float2 cropSize;
    float2 frameSize;   // billedets pixels
    float2 center;      // bølgens centrum (pixels)
    float mirror;
    float effect;       // 1 = forklædning tegnes (helt eller under afsløring)
    float kind;         // 0 bølge, 1 øjeblikkelig, 2 fade, 3 fej
    float progress;     // easet fremdrift 0…1 (0 = forklædt)
    float radius;       // bølgefront (pixels)
    float softness;     // kantblødhed (pixels)
    float sweepY;       // fej-front (pixels)
    float glow;         // svag lys kant (0…1)
    float showMask;
    float flash;        // lukkerblink (0…1, sort)
    float lutSize;
    float white;        // forsidelys/hvid skærm (0…1)
};

static float3 toLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
}

static float3 toSRGB(float3 c) {
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= 0.0031308);
}

fragment float4 kp_fragment(VOut in [[stage_in]],
                            texture2d<float> cam [[texture(0)]],
                            texture2d<float> mask [[texture(1)]],
                            texture3d<float> lut [[texture(2)]],
                            constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    if (u.mirror > 0.5) { uv.x = 1.0 - uv.x; }
    float2 fuv = u.cropOrigin + uv * u.cropSize;
    float3 c = cam.sample(s, fuv).rgb;
    float m = 0.0;
    if (u.effect > 0.5) {
        m = mask.sample(s, fuv).r;
        if (m > 0.002) {
            // Hvidbalancér efter skærmens lys, slå op i overførsels-tabellen, læg lyset på igen.
            float3 n = toSRGB(clamp(toLinear(c) * u.gain.rgb, 0.0, 1.0));
            float N = u.lutSize;
            float3 coord = n * ((N - 1.0) / N) + 0.5 / N;
            float3 d = lut.sample(s, coord).rgb;
            float3 disguised = toSRGB(clamp(toLinear(d) / u.gain.rgb, 0.0, 1.0));
            float2 p = fuv * u.frameSize;
            float r;
            if (u.kind < 0.5) {
                r = 1.0 - smoothstep(u.radius - u.softness, u.radius + u.softness, distance(p, u.center));
            } else if (u.kind < 2.5) {
                r = u.progress;
            } else {
                r = 1.0 - smoothstep(u.sweepY - u.softness, u.sweepY + u.softness, p.y);
            }
            float k = m * (1.0 - r);
            float3 outc = mix(c, disguised, k);
            if (u.glow > 0.0 && u.kind < 0.5) {
                float dd = distance(p, u.center) - u.radius;
                float w = max(1.0, 0.6 * u.softness);
                outc += m * u.glow * 0.12 * exp(-(dd * dd) / (w * w));
            }
            c = outc;
        }
    }
    if (u.showMask > 0.5) {
        float mm = mask.sample(s, fuv).r;
        c = mix(c, float3(1.0, 0.0, 1.0), 0.35 * mm);
    }
    c = mix(c * (1.0 - u.flash), float3(1.0), u.white);
    return float4(c, 1.0);
}
