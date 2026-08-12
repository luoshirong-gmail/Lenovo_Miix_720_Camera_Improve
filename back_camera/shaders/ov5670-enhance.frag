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

// ⚠️ 2026-08-11 (行 FPN 机制): sensor 固定行噪声逐行校正。
// GLSL ES 1.0 无数组初始化 → 段化查表函数 (每 ROW_FPN_STEP 行一段,
// make_shader.py --fpn-file 注入生成 if-else 链, 并置 ROW_FPN_EN=1)。
const float ROW_FPN_EN = 0.0;
const int ROW_FPN_STEP = 4;   // 段宽 (行) — make_shader 生成时匹配
float row_fpn(int row) { return 0.0; }  // 占位 — --fpn-file 注入替换

// ========================================
// Tunable parameters — edit these values:
// ========================================

const float UPSCALE     = 1.0;   // 1.0 = bicubic/bilateral 720p→1080p; 0.0 = native 720p output
// ⚠️ 2026-08-09 参数演变: v2 调优版 (2.0/0.12/1.0) → 用户手动调参版 (1.0/0.25/1.8)
// 实测效果: 降噪空间扩散减弱 (保留细节) + 范围阈值放宽 (边缘保持更自然) + 锐化回中
const float DENOISE_SS  = 0.3;   // Bilateral spatial sigma — 2026-08-10 后摄版 v2:
                                 // 0.6 实测过度平滑 (拉普拉斯 3.74→2.52, 细节被抹)。
                                 // 高分辨率降噪要更轻 (0.3), 保留原生细节
const float DENOISE_SR  = 0.2;   // Bilateral range sigma — 中性边缘保持
const float SHARPEN     = 1.2;   // CAS strength — 高分辨率细节丰富, 温和锐化防过度
                                 // (前摄 1.8 为 upscale 补偿; 后摄 1:1 无需强锐化)
const float CONTRAST    = 1.05;  // Contrast multiplier — 轻度 (不改变曝光特性)
const float SATURATION  = 1.05;  // Color saturation — 轻度 (AWB 未修, 饱和不宜高)
// ⚠️ 2026-08-10 (画质三件套): 相机固有问题的增强管道补偿
// ⚠️ 2026-08-12 (清理): R_GAIN/B_GAIN 全局色平衡已移除 — imgU AWB
//    (grey world + 补偿 0.8/1.3) 已接管全局 R/B 平衡, GPU 链不再重复干预。
//    保留: DARK_B_CORR/BRIGHT_B_CORR (亮度相关色偏) + CORNER_R_CORR
//    (位置相关色偏) — imgU LSC 不可用, 这些是 LSC 色偏的替代补偿。
// ⚠️ 2026-08-10 (分区色度校正): 相机固有偏色是亮度相关 + 位置相关
// (基线实测: 暗部偏蓝 U+4.7 / 亮部偏黄 U-5.8 / 角落偏绿 V-13.6)
// → 固定 R/B 增益调不平 (暗部/亮部方向相反, 角落位置相关)
const float DARK_B_CORR  = 0.15; // 暗部去蓝 (Y<0.25 时 B 降 15% — 加性偏移
                                 // 需大增益, 0.04 实测无效: 暗部 B 值低乘性弱)
const float BRIGHT_B_CORR= 0.05; // 亮部加蓝 (Y>0.8 时 B 升 5% — 去黄, 实测有效)
const float CORNER_R_CORR= 0.18; // 角落加红 (dist² 加权, 角落 R 升 18% — 去绿,
                                 // 0.10 实测 V-13.6→-11.5 不够)
const float RIPPLE      = 0.3;   // 水波纹抑制: 垂直 3-tap 轻模糊 (波纹周期
                                 // ~549 行 = 水平条纹 → 沿行方向平滑)
                                 // 0.0 = 关, 0.1-0.5 = 轻, 1.0 = 强 (会糊)
// ⚠️ 2026-08-10 (暗角 v2 — 中心减亮方案): 角落增益受限 (放大噪点),
// 改为中心压暗 + 角落微增益: 中心 0.85 / 角落 1.1 → 角落:中心比 ≈0.9
// (等效暗角明显减轻, 角落不放大噪点; AE 测增强前帧不反馈补偿)
const float CENTER_DIM   = 0.85;  // 中心亮度系数 (<1 压暗中心)
const float VIGNETTE     = 1.1;   // 角落增益 (dist^4 加权, 轻增益防噪点)

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
    // ⚠️ 2026-08-10 (后摄版修复): 去掉 ACES filmic — 前摄版为 720p
    // upscale 设计 (1.25x 曝光 + shadow lift 补偿), 后摄 AE 已调好
    // 曝光 (AGC 0.35), 叠加 ACES 导致过亮 (+22% 亮度实测) + 色偏
    // (ACES 曲线 RGB 通道非对称 → 偏蓝, U +1.1→+4.5 实测)。
    // 后摄: 直通 (保持 libcamera 原始色彩), 仅保留轻 CONTRAST/SAT。

    // Contrast boost (anchored below midpoint to preserve shadows)
    float c = clamp(CONTRAST, 1.0, 1.5);
    color = (color - 0.45) * c + 0.45;

    // Saturation via luminance mixing
    // ⚠️ 2026-08-12 (语义修正): 0.0=中性(不处理) 1.0=原色  >1.0=增强。
    // 原 clamp(1.0,2.0) 下限 1.0 使 0 被钳到 1.0 (歧义), 且 0 会走灰度。
    float luma = dot(color, vec3(0.299, 0.587, 0.114));
    float s = clamp(SATURATION, 0.0, 2.0);
    if (s > 0.01)
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

    // --- STAGE 3: tone mapping + color enhancement ---
    color = tone_map_and_color(color);

    // --- STAGE 4: 色度校正 (亮度相关 + 位置相关 — LSC 缺失替代) ---
    // (2026-08-12: 全局 R/B 平衡由 imgU AWB 接管, 此处不再乘 R_GAIN/B_GAIN)
    // 亮度相关: 暗部去蓝 (偏蓝 U+4.7) / 亮部加蓝 (偏黄 U-5.8)
    float lum4 = dot(color, vec3(0.299, 0.587, 0.114));
    float dark_w = 1.0 - clamp(lum4 / 0.25, 0.0, 1.0);
    float bright_w = clamp((lum4 - 0.8) / 0.2, 0.0, 1.0);
    color.b *= 1.0 - DARK_B_CORR * dark_w + BRIGHT_B_CORR * bright_w;
    // 位置相关: 角落加红 (角落偏绿 V-13.6 — LSC 缺失的光学色偏)
    float cdist = distance(v_texcoord, vec2(0.5, 0.5));
    color.r *= 1.0 + CORNER_R_CORR * (cdist * cdist * 2.0);

    // --- STAGE 5: 暗角补偿 (中心压暗 + 角落微增益 — 用户方案 v2) ---
    // gain = CENTER_DIM + (VIGNETTE-CENTER_DIM)*dist⁴*4: 中心 0.85,
    // 角落 1.1; dist⁴ 集中角落过渡, 中间区域影响小
    float vdist = distance(v_texcoord, vec2(0.5, 0.5));
    float vgain = CENTER_DIM + (VIGNETTE - CENTER_DIM) * (vdist * vdist * vdist * vdist * 4.0);
    color *= vgain;

    // --- STAGE 6: 水波纹抑制 (垂直 3-tap 轻模糊, 沿行方向) ---
    // 波纹周期 ~549 行 (水平条纹) → 垂直相邻行平滑; RIPPLE=0 跳过
    if (RIPPLE > 0.01) {
        vec2 tp = vec2(1.0 / IN_WIDTH, 1.0 / IN_HEIGHT);
        vec3 c_up  = texture2D(tex, uv - vec2(0.0, tp.y)).rgb;
        vec3 c_dn  = texture2D(tex, uv + vec2(0.0, tp.y)).rgb;
        float w = clamp(RIPPLE, 0.0, 1.0);
        color = mix(color, (color + c_up + c_dn) / 3.0, w);
    }

    // --- STAGE 7: 行 FPN 校正 (sensor 固定行噪声 — 逐行减偏移) ---
    // 机制 (2026-08-11): row_fpn() 由 make_shader.py --fpn-file 注入
    // (gen-row-fpn.py 生成的行偏移表, 段化 if-else 链, 段宽 ROW_FPN_STEP).
    // ROW_FPN_EN=1 时按行索引查表减偏移 (RGB 等量近似 — FPN 幅度 <1 级).
    // ⚠️ 方向: GL 纹理 y=0 在底部 — 帧顶行 = (1.0 - y) 处 (2026-08-11 实测 r=-0.89 修正)
    if (ROW_FPN_EN > 0.5) {
        int row = int((1.0 - v_texcoord.y) * IN_HEIGHT + 0.5);
        row = clamp(row, 0, int(IN_HEIGHT) - 1);
        float fpn = row_fpn(row);
        color.rgb -= vec3(fpn, fpn, fpn);
    }

    gl_FragColor = vec4(color, 1.0);
}
