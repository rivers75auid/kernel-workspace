# Kernel Development & CI Discipline Rules

## 1. Autonomous CI Monitoring & Verification (Strict Completion Discipline)
- **Never Abandon a Triggered Build**: When a commit is pushed to trigger a GitHub Actions build, you MUST actively monitor its progress (`gh run list`, `gh run view`).
- **Immediate Failure Diagnosis**: If a build fails, immediately fetch `--log-failed`, isolate the exact line number and compiler error, and present the factual root cause. Never leave the user waiting blindly.
- **Evidence Before Assertion**: Verify build output sizes and internal files (e.g. `Image.gz`, `dtbo.img`, marker checks) BEFORE declaring a build successful or ready to flash.

## 2. Kernel & Hardware Architecture Ground Truth (Redmi 10C - fog / khaje)
- **SoC Identity**: Snapdragon 680 (SM6225), code-named **`khaje`** (arch `vendor/qcom`).
- **Cirno Canonical Packaging**:
  - Cirno's base uses `CONFIG_BUILD_ARM64_DT_OVERLAY=y`.
  - The compiler generates `Image.gz` (~12 MB) and `dtbo.img` (~9.5 MB).
  - AnyKernel3 packages BOTH `Image.gz` and `dtbo.img` into the flashable ZIP (matching `fog-Cirno-KSU-20260101-160234.zip`).
  - Total package size is ~16 MB compressed (~22-24 MB uncompressed).
  - DO NOT omit `dtbo.img` when `CONFIG_BUILD_ARM64_DT_OVERLAY=y`, because the board DTB overlays for `fog-khaje-idp-nopmi` reside in `dtbo.img`!
- **Core Goals Preserved**:
  - Base: `rivers75auid/kernel_xiaomi_sm6225` (branch `cirno-pin`, Linux 4.19.325-cip126) for Wi-Fi SoftAP/Hotspot stability.
  - Root: SuSFS v2.3.0 + BakaSU (ReSukiSU) Non-GKI 4.19.
  - Memory: MGLRU (`CONFIG_LRU_GEN=y`), ZRAM ZSTD + writeback.
  - Scene Alignment: Scene uses PSI on Android 11+ (`ro.lmk.use_psi=true`). DO NOT hardcode destructive C-level watermark overrides (`min + 64`).
  - Companion Modules: Keep AnyKernel3 clean (kernel only). Companion modules are built as standalone optional ZIPs for debugging.
  - Hardware: Novatek ESD recovery, DT2W via KEY_POWER, Quick Charge 3.0 (SMB1351).

## 3. Anti-Guessing & Senior Dev Rigor
- Never guess or speculate on root causes. Always inspect byte-level binaries, transcripts, logs, and git diffs before providing conclusions.
- When an assumption is proven wrong by user or logs, immediately acknowledge the factual reality and adjust based on hard evidence.
