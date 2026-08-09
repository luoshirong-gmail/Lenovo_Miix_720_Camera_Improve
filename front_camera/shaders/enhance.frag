/*
 * USB Camera Enhancement v2 — Single-Pass GLSL ES 1.00 Fragment Shader
 * ======================================================================
 * Runs on Intel HD 620 (Kaby Lake gen9) via GStreamer glshader.
 * GL context is Wayland/EGL -> GLSL ES 1.00 (GLES 2.0):
 *   - varying (not in/out), texture2D (not texture), gl_FragColor
 *   - explicit precision qualifiers required
 *   - no array constructors, no inline functions (forbidden in ES 1.00)
 *
 * Pipeline (all GPU, zero CPU compute):
 *   MJPG dmabuf -> jpegdec(CPU) -> glupload -> glcolorconvert(RGBA)
 *   -> THIS SHADER (renders 720p texture -> 1080p FBO)
 *   -> glcolorconvert(NV12) -> gldownload -> v4l2sink
 *
 * Architecture (single-pass, one input texture):
 *   The shader receives a 720p RGBA texture and renders to a 1080p FBO.
 *   All stages read from the same source texture — intermediate results
 *   are computed per-fragment without framebuffer ping-pong.
 *
 *   When DENOISE_SS > 0: bilateral filter does upscale + denoise in one step
 *     (samples 5x5 neighborhood from 720p source, outputs to 1080p fragment).
 *     This is superior to "upscale then denoise" — denoising at native
 *     resolution preserves more detail.
 *   When DENOISE_SS = 0: pure bicubic upscale (no denoise).
 *
 * Stages (v2 upgrade — 2026-08-09):
 *   0. Bicubic upscale (Catmull-Rom, 4x4 taps) — fallback when denoise off
 *   1. Bilateral filter denoise + upscale (5x5, edge-preserving)
 *      Replaces Gaussian blur: spatial × color_similarity weight → preserves edges
 *   2. CAS sharpening (Contrast Adaptive Sharpen) — replaces unsharp mask
 *      Only sharpens where contrast exists; flat areas untouched → no noise amplification
 *   3. ACES filmic tone mapping + color enhancement — replaces simple gamma pow
 *      Cinematic tone curve, natural shadow lift without highlight blowout
 *
 * IN_WIDTH/IN_HEIGHT are substituted at runtime by scripts/make_shader.py.
 */

precision highp float;
precision highp int;

uniform sampler2D tex;
varying vec2 v_texcoord;

// Resolution (auto-set by pipeline, do not edit manually)
const float IN_WIDTH   = 640.0;
const float IN_HEIGHT  = 480.0;

// ========================================
// Tunable parameters — edit these values:
// ========================================

const float UPSCALE     = 1.0;   // 1.0 = bicubic/bilateral 720p→1080p; 0.0 = native 720p output
// ⚠️ 2026-08-09 参数演变: v2 调优版 (2.0/0.12/1.0) → 用户手动调参版 (1.0/0.25/1.8)
// 实测效果: 降噪空间扩散减弱 (保留细节) + 范围阈值放宽 (边缘保持更自然) + 锐化回中
const float DENOISE_SS  = 1.0;   // Bilateral spatial sigma [0.5 .. 3.0] (higher = stronger denoise)
const float DENOISE_SR  = 0.25;  // Bilateral range sigma [0.05 .. 0.3] (lower = better edge preservation)
const float SHARPEN     = 1.8;   // CAS strength [0.0 .. 3.0]
const float CONTRAST    = 1.12;  // Contrast multiplier [1.0 .. 1.5]
const float SATURATION  = 1.25;  // Color saturation boost [1.0 .. 2.0]

// ========================================
// Stage 0: Bicubic (Catmull-Rom) interpolation — upscale only, no denoise
// Used when DENOISE_SS < 0.1 (denoise disabled).
// ========================================

float cubic_weight(float t) {
    float at = abs(t);
    if (at <= 1.0) {
        return (1.5 * at - 2.5) * at * at + 1.0;
    } else if (at < 2.0) {
        return ((-0.5 * at + 2.5) * at - 4.0) * at + 2.0;
    }
    return 0.0;
}

vec3 sample_bicubic(vec2 uv) {
    vec2 texel = uv * vec2(IN_WIDTH, IN_HEIGHT) - 0.5;
    vec2 base = floor(texel);
    vec2 frac = texel - base;

    vec3 result = vec3(0.0);
    float total = 0.0;

    // Row -1
    float wx = cubic_weight(frac.x + 1.0); float wy = cubic_weight(frac.y + 1.0);
    result += texture2D(tex, (base + vec2(-1.0,-1.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x); wy = cubic_weight(frac.y + 1.0);
    result += texture2D(tex, (base + vec2( 0.0,-1.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x - 1.0); wy = cubic_weight(frac.y + 1.0);
    result += texture2D(tex, (base + vec2( 1.0,-1.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x - 2.0); wy = cubic_weight(frac.y + 1.0);
    result += texture2D(tex, (base + vec2( 2.0,-1.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;

    // Row 0
    wx = cubic_weight(frac.x + 1.0); wy = cubic_weight(frac.y);
    result += texture2D(tex, (base + vec2(-1.0, 0.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x); wy = cubic_weight(frac.y);
    result += texture2D(tex, (base + vec2( 0.0, 0.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x - 1.0); wy = cubic_weight(frac.y);
    result += texture2D(tex, (base + vec2( 1.0, 0.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x - 2.0); wy = cubic_weight(frac.y);
    result += texture2D(tex, (base + vec2( 2.0, 0.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;

    // Row 1
    wx = cubic_weight(frac.x + 1.0); wy = cubic_weight(frac.y - 1.0);
    result += texture2D(tex, (base + vec2(-1.0, 1.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x); wy = cubic_weight(frac.y - 1.0);
    result += texture2D(tex, (base + vec2( 0.0, 1.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x - 1.0); wy = cubic_weight(frac.y - 1.0);
    result += texture2D(tex, (base + vec2( 1.0, 1.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x - 2.0); wy = cubic_weight(frac.y - 1.0);
    result += texture2D(tex, (base + vec2( 2.0, 1.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;

    // Row 2
    wx = cubic_weight(frac.x + 1.0); wy = cubic_weight(frac.y - 2.0);
    result += texture2D(tex, (base + vec2(-1.0, 2.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x); wy = cubic_weight(frac.y - 2.0);
    result += texture2D(tex, (base + vec2( 0.0, 2.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x - 1.0); wy = cubic_weight(frac.y - 2.0);
    result += texture2D(tex, (base + vec2( 1.0, 2.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;
    wx = cubic_weight(frac.x - 2.0); wy = cubic_weight(frac.y - 2.0);
    result += texture2D(tex, (base + vec2( 2.0, 2.0) + 0.5) / vec2(IN_WIDTH, IN_HEIGHT)).rgb * (wx * wy); total += wx * wy;

    return result / total;
}

// ========================================
// Bilateral weight computation helper (ES 1.00 compatible function)
// Returns: spatial_weight × color_similarity_weight
// ========================================

float bilateral_weight(vec3 neighbor, vec3 center, float dx, float dy, float ss2, float sr2) {
    // Spatial Gaussian falloff
    float sd = sqrt(dx*dx + dy*dy);
    float sw = exp(-(sd*sd) / ss2);
    // Color similarity (edge detection: large color diff → low weight)
    float cd = length(neighbor - center);
    float cw = exp(-(cd*cd) / sr2);
    return sw * cw;
}

// ========================================
// Stage 1: Bilateral filter denoise + upscale (edge-preserving)
//
// Architecture: samples 5x5 neighborhood from the 720p source texture,
// applies bilateral weights (spatial × color similarity), and outputs
// directly to the current fragment position (1080p FBO). This combines
// denoising and upscaling in a single operation — superior to "upscale
// then denoise" because denoising at native resolution preserves detail.
//
// Key insight vs Gaussian blur:
//   Gaussian: weight = spatial_distance_only → blurs edges too
//   Bilateral: weight = spatial × color_similarity → preserves edges
// ========================================

vec3 bilateral_filter(vec2 uv, vec2 px) {
    vec3 center = texture2D(tex, uv).rgb;

    // sigmaS controls how far the influence extends (spatial spread)
    float ss2 = 2.0 * DENOISE_SS * DENOISE_SS;
    // sigmaR controls edge sensitivity — lower = sharper edge detection
    float sr2 = 2.0 * DENOISE_SR * DENOISE_SR;

    vec3 result = vec3(0.0);
    float total_w = 0.0;

    // 5x5 kernel — unrolled (no loops over arrays in ES 1.00)
    vec3 n; float w;

    n = texture2D(tex, uv + vec2(-2.0,-2.0)*px).rgb; w = bilateral_weight(n, center, -2.0, -2.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2(-1.0,-2.0)*px).rgb; w = bilateral_weight(n, center, -1.0, -2.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 0.0,-2.0)*px).rgb; w = bilateral_weight(n, center,  0.0, -2.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 1.0,-2.0)*px).rgb; w = bilateral_weight(n, center,  1.0, -2.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 2.0,-2.0)*px).rgb; w = bilateral_weight(n, center,  2.0, -2.0, ss2, sr2); result += n*w; total_w += w;

    n = texture2D(tex, uv + vec2(-2.0,-1.0)*px).rgb; w = bilateral_weight(n, center, -2.0, -1.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2(-1.0,-1.0)*px).rgb; w = bilateral_weight(n, center, -1.0, -1.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 0.0,-1.0)*px).rgb; w = bilateral_weight(n, center,  0.0, -1.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 1.0,-1.0)*px).rgb; w = bilateral_weight(n, center,  1.0, -1.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 2.0,-1.0)*px).rgb; w = bilateral_weight(n, center,  2.0, -1.0, ss2, sr2); result += n*w; total_w += w;

    n = texture2D(tex, uv + vec2(-2.0, 0.0)*px).rgb; w = bilateral_weight(n, center, -2.0,  0.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2(-1.0, 0.0)*px).rgb; w = bilateral_weight(n, center, -1.0,  0.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 0.0, 0.0)*px).rgb; w = bilateral_weight(n, center,  0.0,  0.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 1.0, 0.0)*px).rgb; w = bilateral_weight(n, center,  1.0,  0.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 2.0, 0.0)*px).rgb; w = bilateral_weight(n, center,  2.0,  0.0, ss2, sr2); result += n*w; total_w += w;

    n = texture2D(tex, uv + vec2(-2.0, 1.0)*px).rgb; w = bilateral_weight(n, center, -2.0,  1.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2(-1.0, 1.0)*px).rgb; w = bilateral_weight(n, center, -1.0,  1.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 0.0, 1.0)*px).rgb; w = bilateral_weight(n, center,  0.0,  1.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 1.0, 1.0)*px).rgb; w = bilateral_weight(n, center,  1.0,  1.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 2.0, 1.0)*px).rgb; w = bilateral_weight(n, center,  2.0,  1.0, ss2, sr2); result += n*w; total_w += w;

    n = texture2D(tex, uv + vec2(-2.0, 2.0)*px).rgb; w = bilateral_weight(n, center, -2.0,  2.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2(-1.0, 2.0)*px).rgb; w = bilateral_weight(n, center, -1.0,  2.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 0.0, 2.0)*px).rgb; w = bilateral_weight(n, center,  0.0,  2.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 1.0, 2.0)*px).rgb; w = bilateral_weight(n, center,  1.0,  2.0, ss2, sr2); result += n*w; total_w += w;
    n = texture2D(tex, uv + vec2( 2.0, 2.0)*px).rgb; w = bilateral_weight(n, center,  2.0,  2.0, ss2, sr2); result += n*w; total_w += w;

    return result / max(total_w, 0.0001);
}

// ========================================
// Stage 2: CAS — Contrast Adaptive Sharpening
//
// Key insight vs unsharp mask:
//   Unsharp mask: sharpens everywhere → amplifies noise in flat areas
//   CAS: only sharpens where local contrast exists → preserves clean flat regions
//
// Reads from source texture for contrast detection, returns sharpened result.
// ========================================

vec3 cas_sharpen(vec2 uv, vec2 px) {
    vec3 center = texture2D(tex, uv).rgb;

    // 4 orthogonal neighbors (sufficient for contrast detection)
    vec3 top    = texture2D(tex, uv + vec2( 0.0,-1.0)*px).rgb;
    vec3 bottom = texture2D(tex, uv + vec2( 0.0, 1.0)*px).rgb;
    vec3 left   = texture2D(tex, uv + vec2(-1.0, 0.0)*px).rgb;
    vec3 right  = texture2D(tex, uv + vec2( 1.0, 0.0)*px).rgb;

    // Local contrast: sum of absolute differences from center
    float c_top    = length(top - center);
    float c_bottom = length(bottom - center);
    float c_left   = length(left - center);
    float c_right  = length(right - center);

    float local_contrast = c_top + c_bottom + c_left + c_right;

    // Adaptive threshold: below this, area is "flat" → no sharpening
    // 2026-08-09: 0.03→0.06 — 跳过微弱对比度的亮点噪点（不锐化放大）
    float flat_threshold = 0.06;

    if (local_contrast < flat_threshold) {
        return center;  // Flat area — skip sharpening entirely
    }

    // Contrast-adaptive strength: more contrast = stronger sharpening
    float adapt = clamp(local_contrast / 0.2, 0.0, 1.0);

    // Unsharp mask with adaptive application
    vec3 blur_approx = (top + bottom + left + right) * 0.25;
    vec3 diff = center - blur_approx;

    return center + SHARPEN * diff * adapt;
}

// ========================================
// Stage 3: ACES filmic tone mapping + color enhancement
//
// Key insight vs simple gamma pow:
//   Gamma pow: lifts shadows but can blow out highlights (no dynamic range control)
//   ACES filmic: cinematic tone curve — natural shadow lift, controlled highlight roll-off
// ========================================

vec3 aces_filmic(vec3 x) {
    // ACEScct filmic tone mapping (simplified for GLSL ES 1.00)
    vec3 a = vec3(2.51, 2.43, 2.37);
    vec3 b = vec3(0.03, 0.03, 0.03);
    vec3 c = vec3(2.43, 2.23, 2.15);
    vec3 d = vec3(0.59, 0.63, 0.62);
    vec3 e = vec3(0.14, 0.14, 0.14);

    return clamp((x * (a*x + b)) / (x*(c*x + d) + e), 0.0, 1.0);
}

vec3 tone_map_and_color(vec3 color) {
    // ACES filmic tone mapping (replaces simple gamma pow)
    // Exposure multiplier lifts shadows naturally without highlight blowout
    color = aces_filmic(color * 1.25);

    // Contrast boost (anchored below midpoint to preserve shadows)
    float c = clamp(CONTRAST, 1.0, 1.5);
    color = (color - 0.45) * c + 0.45;

    // Saturation via luminance mixing
    float luma = dot(color, vec3(0.299, 0.587, 0.114));
    float s = clamp(SATURATION, 1.0, 2.0);
    color = mix(vec3(luma), color, s);

    return clamp(color, 0.0, 1.0);
}

// ========================================
// Main — single pass pipeline
//
// Architecture:
//   - DENOISE_SS > 0: bilateral filter does upscale + denoise (reads from tex)
//   - DENOISE_SS = 0: bicubic upscale only (no denoise)
//   - CAS sharpening blends with base based on local contrast
//   - ACES tone mapping applied to final result
// ========================================

void main() {
    vec2 uv = v_texcoord;
    vec2 px = vec2(1.0 / IN_WIDTH, 1.0 / IN_HEIGHT);

    // --- STAGE 0/1: Upscale + denoise (bilateral or bicubic) ---
    vec3 color;
    if (DENOISE_SS < 0.1) {
        // No denoise — pure bicubic upscale (or direct sample if UPSCALE=0)
        if (UPSCALE > 0.5) {
            color = sample_bicubic(uv);
        } else {
            color = texture2D(tex, uv).rgb;
        }
    } else {
        // Bilateral filter: upscale + denoise in one step
        color = bilateral_filter(uv, px);
    }

    // --- STAGE 2: CAS sharpening (contrast-adaptive) ---
    if (SHARPEN > 0.0) {
        vec3 sharp_result = cas_sharpen(uv, px);
        // Smart blend: use CAS where it has high contrast effect, bilateral elsewhere
        float center_luma = dot(texture2D(tex, uv).rgb, vec3(0.299, 0.587, 0.114));
        float sharp_luma  = dot(sharp_result, vec3(0.299, 0.587, 0.114));
        float contrast_boost = clamp(abs(sharp_luma - center_luma) * 20.0, 0.0, 1.0);
        color = mix(color, sharp_result, contrast_boost * (SHARPEN / 3.0));
    }

    // --- STAGE 3: ACES tone mapping + color enhancement ---
    color = tone_map_and_color(color);

    gl_FragColor = vec4(color, 1.0);
}
