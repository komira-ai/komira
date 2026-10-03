# =============================================================================
# komira_simd.width_policy — centralized CPU-aware SIMD width policy.
# =============================================================================
#
# ONE source of truth for "how wide should a hand-staged SIMD loop be on THIS
# target?". Call sites do:
#
#     comptime W = komira_simd_width[DType.uint64]()
#     ... ptr.load[width=W](i) ...
#
# instead of raw `simd_width_of[DType.uint64]()`. The policy returns the
# element-count width (lanes), NOT bytes.
#
# -----------------------------------------------------------------------------
# WHY a policy and not just `simd_width_of`
# -----------------------------------------------------------------------------
# `simd_width_of[T]()` reports the NATIVE vector width for the build target.
# On a CPU with AVX-512 it reports 512-bit (8 lanes of u64, 16 lanes of u32).
# That is correct as a hardware fact, but on the **AVX-512 downclocking
# microarchitectures** (Skylake-X / Skylake-SP / Cascade Lake) issuing
# 512-bit (zmm) ops can trigger a core frequency downclock + execution-port
# contention. So the policy caps AVX-512 targets at 256-bit (ymm) by default
# — vectorized, but no zmm downclock.
#
# On a write path dominated by compression libraries, kernel copies and
# runtime overhead (e.g. a parquet encode), the lever width is perf-neutral:
# scalar/128/256/512 land within run-to-run noise. The 256-cap is therefore
# a PRINCIPLED default, not a benchmark win: it is the safe choice for other,
# more SIMD-bound call sites, it never regresses vs scalar, and on a
# genuinely SIMD-bound kernel the zmm-downclock hazard is real.
#
# -----------------------------------------------------------------------------
# COMPTIME-DETECTION LIMITATION (read before trusting the default)
# -----------------------------------------------------------------------------
# Mojo does not expose `CompilationTarget.has_avx512()` (see
# `komira_simd/gather.mojo`). The only comptime signal we have is
# `CompilationTarget.is_x86()` plus `simd_width_of[u32]() == 16` (a build
# targeting AVX-512 reports a 16-lane native u32 width). Crucially, comptime
# CANNOT distinguish Skylake-X (severe 512 downclock) from Ice Lake / Tiger
# Lake / Sapphire Rapids / Zen4 (where 512 is essentially free). BOTH report
# avx512f and BOTH give `simd_width_of[u32]() == 16`.
#
# Therefore the SAFE DEFAULT is: when AVX-512 is detected, cap at 256-bit.
#   * On Skylake-X it AVOIDS the worst-case zmm-downclock regression.
#   * On Ice Lake+ it "leaves a little on the table" (256 instead of 512) but
#     is never a REGRESSION vs scalar — 256-bit ymm is fast everywhere.
#
# For machines where 512-bit is genuinely free (Ice Lake+, SPR, Zen4) and you
# want the full native width back, build with the comptime override:
#
#     -D KOMIRA_SIMD_ALLOW_AVX512
#
# (Mojo `is_defined["KOMIRA_SIMD_ALLOW_AVX512"]()`.) With the override set,
# `komira_simd_width` returns the full native `simd_width_of` width on x86.
# The define must be visible when THIS package is compiled: a define passed
# only when building a consumer does not reach a prebuilt package.
#
# -----------------------------------------------------------------------------
# ARM / NEON
# -----------------------------------------------------------------------------
# NEON is 128-bit native; `simd_width_of` already reports that and there is no
# downclock hazard, so the policy returns the native width unchanged.
# =============================================================================

from std.sys.info import CompilationTarget, simd_width_of
from std.sys.defines import is_defined


# -----------------------------------------------------------------------------
# Build override: force full native AVX-512 width on machines where 512 is free.
# -----------------------------------------------------------------------------
comptime KOMIRA_SIMD_ALLOW_AVX512: Bool = is_defined[
    "KOMIRA_SIMD_ALLOW_AVX512"
]()


# -----------------------------------------------------------------------------
# WIDTH-SWEEP knobs (SOURCE-EDIT instrument — default 0 = OFF = use policy).
# -----------------------------------------------------------------------------
# `komira_simd_width` is a COMPTIME function (its value feeds `load[width=W]`,
# which requires a compile-time width), so a width sweep needs one build per
# width. A `-D` define on a CONSUMER build cannot do it: comptime values
# inside an already-compiled package are frozen when that package is built,
# so a consumer-side `-D` produces identical codegen. Sweeping a
# package-resident comptime requires a SOURCE edit + package rebuild.
#
# Therefore the sweep instrument is these SOURCE constants. To run a sweep step:
# set the relevant constant, rebuild `komira_core` and `komira_parquet` (the
# package bakes the width) and then the benchmark, measure, repeat.
#
#   value -> forced U64 LANE COUNT (scaled per-dtype, clamped to native):
#     0 -> OFF: use the CPU-aware policy below (the production default = 256-cap).
#     1 -> SCALAR (1 u64 lane; the lever's chunk loop degenerates to scalar).
#     2 -> 128-bit (SSE2 / NEON / xmm).
#     4 -> 256-bit (AVX2 / AVX-512 ymm).
#     8 -> 512-bit (AVX-512 zmm — the hardware-native width on AVX-512 parts).
#
# `_SIMD_W_U64_FORCE` overrides BOTH SIMD levers at once (aggregate sweep);
# the per-lever constants override one lever while the other falls back to
# `_SIMD_W_U64_FORCE`, then to the policy (per-lever isolation sweep). Production
# ships with ALL of these at 0 (policy default).
comptime _SIMD_W_U64_FORCE: Int = 0
comptime _SIMD_W_U64_BITPACK: Int = 0
comptime _SIMD_W_U64_DELTA: Int = 0


# -----------------------------------------------------------------------------
# AVX-512 detection (comptime).
# -----------------------------------------------------------------------------
# We treat the build as "AVX-512 native" when it is x86 AND the native u32
# width is 16 lanes (= 512 bits). `simd_width_of[u32]()` is the honest native
# width (see gather.mojo). This is
# the SAME gate the explicit-intrinsic SIMD wrappers (compress / gather) use to
# decide whether to emit AVX-512 intrinsics.
def _target_is_avx512() -> Bool:
    return CompilationTarget.is_x86() and simd_width_of[DType.uint32]() == 16


# -----------------------------------------------------------------------------
# The policy function — element-count width for a hand-staged SIMD loop.
# -----------------------------------------------------------------------------
def komira_simd_width[dtype: DType]() -> Int:
    """Return the element-count SIMD width to use for `dtype` on this target.

    This is the centralized policy that hand-staged SIMD loops should call
    INSTEAD of raw `simd_width_of[dtype]()`. It returns lanes (element count),
    matching `simd_width_of`'s units, so call sites can drop-in replace:

        comptime W = komira_simd_width[DType.uint64]()
        var v = ptr.load[width=W](i)

    Policy:
      * On AVX-512-native x86 WITHOUT the `KOMIRA_SIMD_ALLOW_AVX512` override:
        cap at 256-bit (half the native 512-bit lane count). This avoids the
        Skylake-X/SP/Cascade-Lake zmm downclock. SAFE DEFAULT (see module
        header — comptime cannot tell Skylake-X from Ice Lake).
      * On AVX-512-native x86 WITH the override: full native width (512-bit).
      * On AVX2 x86 / NEON / scalar: native width unchanged (no downclock
        hazard at 256/128-bit).

    The 256-bit cap is computed as `native // 2` rather than a hardcoded lane
    count so it is correct for every dtype (u64: 8->4, u32: 16->8, u16: 32->16,
    u8: 64->32, f64: 8->4, f32: 16->8). `native` for an AVX-512 build is always
    even, so `// 2` lands exactly on the 256-bit lane count.
    """
    return _width_with_force[dtype, _SIMD_W_U64_FORCE]()


def komira_simd_width_bitpack[dtype: DType]() -> Int:
    """Policy width for the parquet dict-RLE / DBP BITPACK lever.

    Honors the `_SIMD_W_U64_BITPACK` source sweep constant (per-lever isolation),
    falling back to the shared `_SIMD_W_U64_FORCE`, then the CPU-aware policy.
    Same units as `komira_simd_width` (element lanes).
    """
    comptime force = _SIMD_W_U64_BITPACK if _SIMD_W_U64_BITPACK != 0 else _SIMD_W_U64_FORCE
    return _width_with_force[dtype, force]()


def komira_simd_width_delta[dtype: DType]() -> Int:
    """Policy width for the parquet DBP DELTA-subtract lever.

    Honors the `_SIMD_W_U64_DELTA` source sweep constant (per-lever isolation),
    falling back to the shared `_SIMD_W_U64_FORCE`, then the CPU-aware policy.
    """
    comptime force = _SIMD_W_U64_DELTA if _SIMD_W_U64_DELTA != 0 else _SIMD_W_U64_FORCE
    return _width_with_force[dtype, force]()


def _width_with_force[dtype: DType, force: Int]() -> Int:
    """Shared policy core: apply a forced U64-lane count `force` (0 = OFF), else
    the CPU-aware downclock-avoiding default."""
    comptime native = simd_width_of[dtype]()

    # WIDTH-SWEEP override (default 0 = OFF). When set, force the U64-lane count
    # scaled to this dtype's byte width, clamped to native. Lets the tuning
    # harness pin scalar/128/256/512 per build without editing source. See the
    # _SIMD_W_U64_FORCE define header above.
    comptime if force != 0:
        # u64 has 8 bytes; lanes-at-same-byte-width = force * (8 / size_of[dt]).
        # Use simd_width_of ratios (native_dt / native_u64) which equals the
        # byte-width ratio (both are 512/elem_bytes on this build), avoiding a
        # size_of import. native_u64 is >=1 on every target.
        comptime native_u64 = simd_width_of[DType.uint64]()
        comptime scaled = force * (native // native_u64)
        # Clamp [1, native]; never exceed the hardware native width.
        comptime if scaled < 1:
            return 1
        elif scaled > native:
            return native
        else:
            return scaled

    comptime if _target_is_avx512() and not KOMIRA_SIMD_ALLOW_AVX512:
        # Cap at 256-bit: half the 512-bit native lane count.
        return native // 2
    else:
        return native
