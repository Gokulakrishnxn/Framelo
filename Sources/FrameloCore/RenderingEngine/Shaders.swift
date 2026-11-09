/// Metal Shading Language source, compiled at runtime with `MTLDevice.makeLibrary(source:)`
/// (the offline `metal` compiler ships only with Xcode).
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Every field is a float4 so the layout matches the Swift `FrameUniforms` struct exactly.
    struct Uniforms {
        float4 canvas;         // xy size, w tap count
        float4 card;           // xy origin, zw size (canvas px, before camera)
        float4 content;        // xy origin, zw size of the screen picture inside the card
        float4 cam;            // xy camera centre (card px), z scale, w screen opacity
        float4 cardStyle;      // x corner radius, y shadow radius, z shadow opacity, w has screen
        float4 blur;           // xy camera blur vector (card px), z blur scale, w title bar height
        float4 bgA;
        float4 bgB;
        float4 bgParams;       // x kind (0 solid, 1 gradient, 2 image), yz gradient direction
        float4 bgImage;        // xy uv scale (aspect fill)
        float4 cursorRect;     // xy top-left (card px), zw size
        float4 cursorParams;   // x has cursor, y opacity, zw cursor blur vector (card px)
        float4 rippleParams;   // x count, y max radius (card px), z style (1 ripple, 2 ring)
        float4 rippleColor;
        float4 ripples[4];     // xy position (card px), z progress
        float4 pipRect;        // xy centre, zw half size (canvas px)
        float4 pipStyle;       // x has pip, y corner radius, z border width, w shadow opacity
        float4 pipBorderColor;
        float4 pipBackground;
        float4 pipUV;          // xy uv scale (aspect fill), z mirrored
        float4 titleBar;       // rgb colour
    };

    struct VertexOut {
        float4 position [[position]];
    };

    vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    static float sdRoundBox(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    static float3 background(float2 p, constant Uniforms &u, texture2d<float> bgTex, sampler s) {
        if (u.bgParams.x > 1.5) {
            float2 uv = (p / u.canvas.xy - 0.5) * u.bgImage.xy + 0.5;
            return bgTex.sample(s, uv).rgb;
        }
        if (u.bgParams.x > 0.5) {
            float t = dot(p / u.canvas.xy - 0.5, u.bgParams.yz) + 0.5;
            return mix(u.bgA.rgb, u.bgB.rgb, saturate(t));
        }
        return u.bgA.rgb;
    }

    static float3 cardColor(float2 q, constant Uniforms &u, texture2d<float> screenTex, sampler s) {
        float titleHeight = u.blur.w;
        if (titleHeight > 0.0 && q.y < u.content.y) {
            float3 c = u.titleBar.rgb;
            float radius = titleHeight * 0.17;
            float cy = u.card.y + titleHeight * 0.5;
            float3 lights[3] = { float3(1.0, 0.37, 0.34), float3(1.0, 0.74, 0.18), float3(0.16, 0.78, 0.25) };
            for (int i = 0; i < 3; i++) {
                float cx = u.card.x + titleHeight * (0.6 + 0.6 * float(i));
                float d = length(q - float2(cx, cy)) - radius;
                c = mix(c, lights[i], saturate(0.5 - d));
            }
            return c;
        }
        float2 uv = saturate((q - u.content.xy) / u.content.zw);
        return screenTex.sample(s, uv).rgb;
    }

    // Click effects, drawn on the picture and underneath the cursor.
    static float3 applyRipples(float3 card, float2 q, float scale, constant Uniforms &u) {
        int count = int(u.rippleParams.x);
        for (int i = 0; i < count; i++) {
            float progress = u.ripples[i].z;
            float eased = 1.0 - pow(1.0 - progress, 3.0);
            float r = u.rippleParams.y * (0.25 + 0.75 * eased);
            float dist = length(q - u.ripples[i].xy);
            float alpha = 0.0;
            if (u.rippleParams.z > 1.5) {
                float thickness = max(u.rippleParams.y * 0.09, 1.5 / scale);
                alpha = saturate((thickness - abs(dist - r)) * scale);
            } else {
                alpha = saturate((r - dist) * scale) * 0.55;
            }
            alpha *= (1.0 - progress) * u.rippleColor.a;
            card = mix(card, u.rippleColor.rgb, alpha);
        }
        return card;
    }

    fragment float4 compositeFragment(VertexOut in [[stage_in]],
                                      constant Uniforms &u [[buffer(0)]],
                                      texture2d<float> screenTex [[texture(0)]],
                                      texture2d<float> cameraTex [[texture(1)]],
                                      texture2d<float> cursorTex [[texture(2)]],
                                      texture2d<float> bgTex [[texture(3)]],
                                      sampler s [[sampler(0)]]) {
        float2 p = in.position.xy;
        float3 color = background(p, u, bgTex, s);

        if (u.cardStyle.w > 0.5) {
            float scale = u.cam.z;
            // Canvas pixel -> card space (inverse camera transform).
            float2 q = (p - u.canvas.xy * 0.5) / scale + u.cam.xy;
            float2 cardCentre = u.card.xy + u.card.zw * 0.5;
            float2 halfSize = u.card.zw * 0.5;
            float radius = u.cardStyle.x;
            float opacity = u.cam.w;

            // Soft drop shadow, slightly below the card.
            float shadowRadius = u.cardStyle.y;
            if (u.cardStyle.z > 0.0 && shadowRadius > 0.0) {
                float2 offset = float2(0.0, shadowRadius * 0.35 / scale);
                float sd = sdRoundBox(q - cardCentre - offset, halfSize, radius) * scale;
                float a = 1.0 - smoothstep(-shadowRadius * 0.6, shadowRadius, sd);
                color = mix(color, float3(0.0), a * a * u.cardStyle.z * opacity);
            }

            float d = sdRoundBox(q - cardCentre, halfSize, radius) * scale;
            float cover = saturate(0.5 - d);
            if (cover > 0.0) {
                int taps = int(u.canvas.w);
                float3 sum = float3(0.0);
                for (int i = 0; i < taps; i++) {
                    float t = taps > 1 ? (float(i) + 0.5) / float(taps) - 0.5 : 0.0;
                    // Where this pixel looked at shutter time t: camera pan plus zoom about the camera centre.
                    float2 qi = (q - u.cam.xy) * (1.0 + u.blur.z * t) + u.cam.xy + u.blur.xy * t;
                    float3 c = applyRipples(cardColor(qi, u, screenTex, s), qi, scale, u);
                    if (u.cursorParams.x > 0.5) {
                        float2 cuv = (qi - u.cursorRect.xy - u.cursorParams.zw * t) / u.cursorRect.zw;
                        if (cuv.x > 0.0 && cuv.x < 1.0 && cuv.y > 0.0 && cuv.y < 1.0) {
                            float4 cur = cursorTex.sample(s, cuv) * u.cursorParams.y;   // premultiplied
                            c = c * (1.0 - cur.a) + cur.rgb;
                        }
                    }
                    sum += c;
                }
                float3 card = sum / float(max(taps, 1));

                color = mix(color, card, cover * opacity);
            }
        }

        if (u.pipStyle.x > 0.5) {
            float2 centre = u.pipRect.xy;
            float2 halfSize = u.pipRect.zw;
            float radius = u.pipStyle.y;
            float border = u.pipStyle.z;
            if (u.pipStyle.w > 0.0) {
                float spread = halfSize.y * 0.28;
                float sd = sdRoundBox(p - centre - float2(0.0, halfSize.y * 0.1), halfSize, radius);
                float a = 1.0 - smoothstep(-spread * 0.5, spread, sd);
                color = mix(color, float3(0.0), a * a * u.pipStyle.w);
            }
            float d = sdRoundBox(p - centre, halfSize, radius);
            float cover = saturate(0.5 - d);
            if (cover > 0.0) {
                float2 uv = (p - centre) / (halfSize * 2.0) * u.pipUV.xy + 0.5;
                if (u.pipUV.z > 0.5) { uv.x = 1.0 - uv.x; }
                float4 cam = cameraTex.sample(s, saturate(uv));
                float3 inner = mix(u.pipBackground.rgb, cam.rgb, cam.a);
                float inside = saturate(0.5 - (d + border));
                float3 pip = mix(mix(inner, u.pipBorderColor.rgb, u.pipBorderColor.a), inner, border > 0.0 ? inside : 1.0);
                color = mix(color, pip, cover);
            }
        }
        return float4(color, 1.0);
    }

    // Textured quad for text and captions (premultiplied alpha).
    struct QuadUniforms {
        float4 rect;      // xy origin, zw size, in normalised device coordinates
        float4 params;    // x opacity
    };

    struct QuadOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex QuadOut quadVertex(uint vid [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
        float2 unit = float2(vid & 1, (vid >> 1) & 1);
        QuadOut out;
        out.position = float4(u.rect.xy + unit * u.rect.zw, 0.0, 1.0);
        out.uv = float2(unit.x, 1.0 - unit.y);
        return out;
    }

    fragment float4 quadFragment(QuadOut in [[stage_in]], constant QuadUniforms &u [[buffer(0)]],
                                 texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv) * u.params.x;
    }
    """
}
