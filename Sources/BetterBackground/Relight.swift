import Foundation
import Metal
import simd

/// Lighting handed to the relight shader, in the person's image space:
/// x to the right of the image, y up, z out of the screen towards the viewer.
struct RelightParams {
    var keyDir: SIMD4<Float> = [0.5, 0.4, 0.8, 0]
    var keyColor: SIMD4<Float> = [0.8, 0.75, 0.7, 0]
    var rimDir: SIMD4<Float> = [-0.6, 0.3, -0.7, 0]
    var rimColor: SIMD4<Float> = [0.2, 0.3, 0.5, 0]
    var ambient: SIMD4<Float> = [0.45, 0.45, 0.45, 0]
    /// x: relight amount, y: relief (normal strength), z: depth low, w: depth span
    var misc: SIMD4<Float> = [0.7, 2, 0, 1]
    /// x: feather radius in pixels, y: mask threshold, z: invert depth, w: unused
    var misc2: SIMD4<Float> = [1.5, 0.5, 0, 0]
}

/// GPU pass that turns the camera image, Vision mask and depth map into
/// a relit colour texture and a soft alpha texture for the person surface.
enum RelightShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float4 keyDir;
        float4 keyColor;
        float4 rimDir;
        float4 rimColor;
        float4 ambient;
        float4 misc;
        float4 misc2;
    };

    kernel void relight(texture2d<float, access::sample> cam   [[texture(0)]],
                        texture2d<float, access::sample> depth [[texture(1)]],
                        texture2d<float, access::sample> mask  [[texture(2)]],
                        texture2d<float, access::write> outColor [[texture(3)]],
                        texture2d<float, access::write> outAlpha [[texture(4)]],
                        constant Params& p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
    {
        uint w = outColor.get_width(), h = outColor.get_height();
        if (gid.x >= w || gid.y >= h) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 size = float2(w, h);
        float2 uv = (float2(gid) + 0.5) / size;

        float3 c = cam.sample(s, uv).rgb;

        // Soft, feathered mask: small box blur of the upsampled Vision mask, then a smooth ramp.
        float2 fs = max(p.misc2.x, 0.0) * 2.0 / size;
        float m = 0.0;
        for (int j = -2; j <= 2; j++) {
            for (int i = -2; i <= 2; i++) {
                m += mask.sample(s, uv + float2(i, j) * fs).r;
            }
        }
        m /= 25.0;
        float t = p.misc2.y;
        float a = smoothstep(t - 0.2, t + 0.2, m);

        // Normals from the depth map (bigger = closer).
        float2 ds = 1.5 / float2(depth.get_width(), depth.get_height());
        float span = max(p.misc.w, 1e-4);
        float dl = depth.sample(s, uv - float2(ds.x, 0)).r;
        float dr = depth.sample(s, uv + float2(ds.x, 0)).r;
        float du = depth.sample(s, uv - float2(0, ds.y)).r;
        float dd = depth.sample(s, uv + float2(0, ds.y)).r;
        float gx = (dr - dl) / span;
        float gy = (dd - du) / span;
        if (p.misc2.z > 0.5) { gx = -gx; gy = -gy; }
        float k = p.misc.y;
        float3 n = normalize(float3(-gx * k, gy * k, 1.0));

        // Wrapped diffuse key light, soft for skin.
        float3 L = normalize(p.keyDir.xyz);
        float key = saturate((dot(n, L) + 0.35) / 1.35);

        // Rim: strongest where the surface turns away from the viewer, on the rim light's side.
        float edge = pow(saturate(1.0 - n.z), 1.2) + (1.0 - a) * 0.6;
        float2 rd = p.rimDir.xy;
        float side = length(n.xy) > 1e-4 && length(rd) > 1e-4 ? saturate(dot(normalize(n.xy), normalize(rd)) * 0.5 + 0.5) : 0.5;
        float rim = saturate(edge) * side;

        float3 light = p.ambient.rgb + p.keyColor.rgb * key + p.rimColor.rgb * rim;
        float3 lit = c * light;
        float3 col = mix(c, lit, saturate(p.misc.x));

        outColor.write(float4(col, 1.0), gid);
        outAlpha.write(float4(a, a, a, a), gid);
    }
    """

    static func makePipeline(device: MTLDevice) throws -> MTLComputePipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "relight") else {
            throw NSError(domain: "BetterBackground", code: 2, userInfo: [NSLocalizedDescriptionKey: "relight kernel missing"])
        }
        return try device.makeComputePipelineState(function: function)
    }
}
