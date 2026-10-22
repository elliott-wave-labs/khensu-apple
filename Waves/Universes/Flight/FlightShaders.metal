// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes flight: camera-facing point sprites whose size and brightness follow from
// absolute magnitude and true distance, the same model as khensu.nu/universes.
//
// Per vertex: position = source centre (pc), uv0 = quad corner (-1…1),
// uv2 = (absolute magnitude, diameter pc, gain, twinkle seed), uv3 = colour.
// custom_parameter = (focal length px, limiting magnitude + exposure, scintillation σ, time).

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

[[visible]]
void nuFlightGeometry(realitykit::geometry_parameters params)
{
    auto g = params.geometry();
    float2 corner = g.uv0();
    float4 a = g.uv2();
    float4 tint = g.uv3();
    float4 cp = params.uniforms().custom_parameter();

    float4x4 m2v = params.uniforms().model_to_view();
    float3x3 m = float3x3(m2v[0].xyz, m2v[1].xyz, m2v[2].xyz);
    float scale2 = dot(m[0], m[0]);           // model → view is rotation × uniform scale
    float scale = sqrt(scale2);
    float3 vpos = (m2v * float4(g.model_position(), 1.0)).xyz;
    float dView = max(length(vpos), 1e-12);
    float d = dView / scale;                   // parsecs

    float mag = a.x + 5.0 * log10(max(d, 1e-9) / 10.0);
    float flux = pow(10.0, -0.4 * (mag - cp.y)) * a.z;
    if (cp.z > 0.0 && a.w > 0.0) {             // Earth's air: frozen-flow phase screen, σ from Kolmogorov theory
        float t = cp.w;
        float n = sin(t * 9.1 + a.w * 17.0) * 0.5 + sin(t * 23.7 + a.w * 41.0) * 0.35 + sin(t * 51.3 + a.w * 7.0) * 0.15;
        flux *= max(0.0, 1.0 + cp.z * n * 1.6);
    }
    float fs = pow(max(flux, 0.0), 0.25) * 2.2;
    float disc = a.y / d * cp.x;
    float s = max(fs, disc);
    float px = clamp(s, 0.0, 220.0);
    float alpha = clamp(flux, 0.0, 1.0) * smoothstep(0.0, 1.2, s) * min(1.0, (fs * fs) / max(s * s, 1e-6) * 4.0);

    float hs = 0.5 * px * dView / cp.x;      // view-space half-size of the sprite
    float3 offsetModel = transpose(m) * float3(corner * hs, 0.0) / scale2;
    g.set_model_position_offset(offsetModel);
    g.set_custom_attribute(float4(tint.rgb, alpha));
}

[[visible]]
void nuFlightSurface(realitykit::surface_parameters params)
{
    float2 c = params.geometry().uv0();
    float r2 = dot(c, c);
    float core = (exp(-r2 * 6.0) + 0.25 * exp(-r2 * 1.5)) * (1.0 - smoothstep(0.55, 1.0, r2));
    float4 col = params.geometry().custom_attribute();
    float k = core * col.a;
    // The unlit lighting model ignores base colour; emissive is the only colour it draws.
    params.surface().set_emissive_color(half3(col.rgb * min(k * 1.6, 1.0)));
    params.surface().set_opacity(half(saturate(k * 1.6)));
}

// The Hubble mosaic: its black sky becomes transparent so the particle disc shows around and through it.
[[visible]]
void nuMosaicSurface(realitykit::surface_parameters params)
{
    constexpr sampler bilinear(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 uv = params.geometry().uv0();
    half3 c = params.textures().emissive_color().sample(bilinear, float2(uv.x, 1.0 - uv.y)).rgb;
    half lum = max(c.r, max(c.g, c.b));
    params.surface().set_emissive_color(c);
    params.surface().set_opacity(saturate(lum * 2.2h));
}
