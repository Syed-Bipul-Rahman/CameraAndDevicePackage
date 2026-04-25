#include <metal_stdlib>
using namespace metal;

// Kernel size for bilateral filter (must match Swift code)
constant int KERNEL_RADIUS = 7;
constant float SIGMA_SPACE = 7.0;
constant float SIGMA_COLOR = 0.1;

// Skin tone detection thresholds (HSV space)
constant float SKIN_H_MIN = 0.0;
constant float SKIN_H_MAX = 50.0 / 360.0;  // 0-50 degrees normalized
constant float SKIN_S_MIN = 0.10;
constant float SKIN_S_MAX = 0.75;
constant float SKIN_V_MIN = 0.20;
constant float SKIN_V_MAX = 0.95;

// Convert RGB to HSV
float3 rgbToHsv(float3 rgb) {
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    float maxC = max(max(r, g), b);
    float minC = min(min(r, g), b);
    float delta = maxC - minC;

    float h = 0.0;
    float s = 0.0;
    float v = maxC;

    if (delta > 0.00001) {
        s = delta / maxC;

        if (r >= maxC) {
            h = (g - b) / delta;
        } else if (g >= maxC) {
            h = 2.0 + (b - r) / delta;
        } else {
            h = 4.0 + (r - g) / delta;
        }

        h *= 60.0;
        if (h < 0.0) h += 360.0;
        h /= 360.0;  // Normalize to 0-1
    }

    return float3(h, s, v);
}

// Check if pixel is skin tone
bool isSkinTone(float3 rgb) {
    float3 hsv = rgbToHsv(rgb);

    // Check if in skin tone range
    bool hInRange = (hsv.x >= SKIN_H_MIN && hsv.x <= SKIN_H_MAX) ||
                    (hsv.x >= 0.95);  // Red wraps around
    bool sInRange = hsv.y >= SKIN_S_MIN && hsv.y <= SKIN_S_MAX;
    bool vInRange = hsv.z >= SKIN_V_MIN && hsv.z <= SKIN_V_MAX;

    return hInRange && sInRange && vInRange;
}

// Gaussian weight for spatial distance
float spatialWeight(float2 offset, float sigma) {
    float distSq = dot(offset, offset);
    return exp(-distSq / (2.0 * sigma * sigma));
}

// Gaussian weight for color/intensity difference
float colorWeight(float3 diff, float sigma) {
    float distSq = dot(diff, diff);
    return exp(-distSq / (2.0 * sigma * sigma));
}

// Bilateral filter kernel - smooths skin while preserving edges
kernel void bilateralSkinSmooth(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    texture2d<float, access::read> faceMask [[texture(2)]],
    constant float &intensity [[buffer(0)]],
    constant float &sigmaSpace [[buffer(1)]],
    constant float &sigmaColor [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) {
        return;
    }

    float4 centerPixel = inTexture.read(gid);
    float3 centerRgb = centerPixel.rgb;

    // Check face mask - if outside face region, skip processing
    float maskValue = faceMask.read(gid).r;
    if (maskValue < 0.01) {
        outTexture.write(centerPixel, gid);
        return;
    }

    // Check if center pixel is skin tone
    bool centerIsSkin = isSkinTone(centerRgb);
    if (!centerIsSkin) {
        // Not skin - preserve original (eyes, lips, eyebrows, etc.)
        outTexture.write(centerPixel, gid);
        return;
    }

    // Apply bilateral filter for skin pixels
    float3 sum = float3(0.0);
    float weightSum = 0.0;

    int radius = int(sigmaSpace);

    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 samplePos = int2(gid) + int2(dx, dy);

            // Bounds check
            if (samplePos.x < 0 || samplePos.x >= int(inTexture.get_width()) ||
                samplePos.y < 0 || samplePos.y >= int(inTexture.get_height())) {
                continue;
            }

            float4 samplePixel = inTexture.read(uint2(samplePos));
            float3 sampleRgb = samplePixel.rgb;

            // Only include skin tone pixels in the smoothing
            if (!isSkinTone(sampleRgb)) {
                continue;
            }

            // Calculate bilateral weight
            float2 offset = float2(dx, dy);
            float ws = spatialWeight(offset, sigmaSpace);

            float3 colorDiff = centerRgb - sampleRgb;
            float wc = colorWeight(colorDiff, sigmaColor);

            float weight = ws * wc;

            sum += sampleRgb * weight;
            weightSum += weight;
        }
    }

    // Normalize
    float3 smoothed = (weightSum > 0.0001) ? sum / weightSum : centerRgb;

    // Blend based on intensity and mask value
    float blendFactor = intensity * maskValue;
    float3 result = mix(centerRgb, smoothed, blendFactor);

    outTexture.write(float4(result, centerPixel.a), gid);
}

// High-pass filter for texture preservation (frequency separation)
kernel void highPassExtract(
    texture2d<float, access::read> original [[texture(0)]],
    texture2d<float, access::read> blurred [[texture(1)]],
    texture2d<float, access::write> highPass [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= original.get_width() || gid.y >= original.get_height()) {
        return;
    }

    float4 origPixel = original.read(gid);
    float4 blurPixel = blurred.read(gid);

    // High-pass = original - blurred + 0.5 (to keep in valid range)
    float3 hp = origPixel.rgb - blurPixel.rgb + 0.5;

    highPass.write(float4(hp, 1.0), gid);
}

// Combine smoothed low-frequency with original high-frequency (texture)
kernel void frequencySeparationCombine(
    texture2d<float, access::read> smoothedLow [[texture(0)]],
    texture2d<float, access::read> originalHigh [[texture(1)]],
    texture2d<float, access::read> faceMask [[texture(2)]],
    texture2d<float, access::write> outTexture [[texture(3)]],
    constant float &texturePreserve [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= smoothedLow.get_width() || gid.y >= smoothedLow.get_height()) {
        return;
    }

    float4 lowFreq = smoothedLow.read(gid);
    float4 highFreq = originalHigh.read(gid);
    float maskValue = faceMask.read(gid).r;

    // Combine: smoothed color + texture details
    // highFreq was stored as (high + 0.5), so subtract 0.5
    float3 texture = (highFreq.rgb - 0.5) * texturePreserve;
    float3 combined = lowFreq.rgb + texture;

    // Only apply in face region
    float3 original = smoothedLow.read(gid).rgb + (highFreq.rgb - 0.5);
    float3 result = mix(original, combined, maskValue);

    outTexture.write(float4(saturate(result), 1.0), gid);
}

// Create grayscale mask from face regions for the shader
kernel void createFaceMaskTexture(
    texture2d<float, access::write> maskTexture [[texture(0)]],
    constant float4 *faceRects [[buffer(0)]],
    constant int &faceCount [[buffer(1)]],
    constant float4 *excludeRects [[buffer(2)]],
    constant int &excludeCount [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= maskTexture.get_width() || gid.y >= maskTexture.get_height()) {
        return;
    }

    float2 uv = float2(gid) / float2(maskTexture.get_width(), maskTexture.get_height());
    float maskValue = 0.0;

    // Check if inside any face ellipse
    for (int i = 0; i < faceCount; i++) {
        float4 rect = faceRects[i];  // x, y, width, height (normalized)
        float2 center = float2(rect.x + rect.z * 0.5, rect.y + rect.w * 0.5);
        float2 radius = float2(rect.z * 0.5, rect.w * 0.5);

        float2 diff = (uv - center) / radius;
        float dist = length(diff);

        if (dist < 1.0) {
            // Soft edge falloff
            float edge = smoothstep(1.0, 0.7, dist);
            maskValue = max(maskValue, edge);
        }
    }

    // Subtract exclusion regions (eyes, nose, mouth)
    for (int i = 0; i < excludeCount; i++) {
        float4 rect = excludeRects[i];
        float2 center = float2(rect.x + rect.z * 0.5, rect.y + rect.w * 0.5);
        float2 radius = float2(rect.z * 0.5, rect.w * 0.5);

        float2 diff = (uv - center) / radius;
        float dist = length(diff);

        if (dist < 1.2) {
            // Soft edge for exclusions
            float exclude = smoothstep(1.2, 0.6, dist);
            maskValue = maskValue * (1.0 - exclude);
        }
    }

    maskTexture.write(float4(maskValue, maskValue, maskValue, 1.0), gid);
}
