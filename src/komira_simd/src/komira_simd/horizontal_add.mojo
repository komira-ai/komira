# =============================================================================
# horizontal_add.mojo — SIMD horizontal-add (reduce-add) wrappers.
# =============================================================================
#
# PERF-CRITICAL. Direct AArch64 NEON intrinsic substitutions for the
# stdlib `SIMD[uint8/16/32, *].reduce_add()` operation, which lowers
# via a generic LLVM vector-reduce that hits a 5-7 op widening cascade
# (`ushll/shl/cmlt/ssra + addv.8h`) instead of the single instruction the
# hardware provides.
#
# Swapping `llvm.vector.reduce.add.v16i8` for `llvm.aarch64.neon.uaddv`
# speeds up a JSON key-scan inner loop by about 1.7x on Apple Silicon —
# from a single intrinsic substitution.
#
# Architecture dispatch:
#   * ARM64:    direct AArch64 NEON intrinsics (`uaddv` / `uaddlv`).
#   * x86_64:   stdlib `reduce_add()` fallback. On AVX2 the stdlib path
#               lowers via `vpsadbw` or similar; an AVX2-specific
#               intrinsic has not been shown to win, so x86 uses the
#               correct-by-stdlib path.
#
# Mojo gotchas:
#   * `llvm_intrinsic[...]` syntax does NOT take LLVM mangled-type
#     suffixes. Use the bare AArch64 name (`llvm.aarch64.neon.uaddv`);
#     Mojo derives the signature from the wrapper's `-> UInt8` return
#     type. The mangled form `.i16.v16i8` crashes AArch64 ISel with
#     "LLVM ERROR: Do not know how to promote this operator!".
#   * `comptime if`, not `@parameter if`.
#   * ARM-only intrinsics sit behind the usual
#     `comptime if CompilationTarget.is_x86():` dispatch pattern.
# =============================================================================

from std.sys.info import CompilationTarget
from std.sys.intrinsics import llvm_intrinsic


# =============================================================================
# Public API
# =============================================================================


@always_inline
def hadd_u8x16(v: SIMD[DType.uint8, 16]) -> UInt8:
    """Horizontal-sum 16 u8 lanes into a single u8 (truncated mod 256).

    Byte-identical to `v.reduce_add()` on `SIMD[uint8, 16]`.

    ARM64: single `addv b0, v.16b` instruction via the
    `llvm.aarch64.neon.uaddv` intrinsic. The stdlib `reduce_add()` on
    `SIMD[uint8, 16]` lowers as a 5-op widening cascade
    (`ushll/shl/cmlt/ssra + addv.8h`) due to LLVM's generic vector-reduce
    pattern preferring widened-accumulator codegen. The arch-specific
    `uaddv` is the direct hardware match.

    x86_64: falls through to stdlib `v.reduce_add()` (correct, not yet
    tuned for AVX2).
    """
    comptime if CompilationTarget.is_x86():
        return v.reduce_add()
    else:
        return llvm_intrinsic["llvm.aarch64.neon.uaddv", UInt8](v)


@always_inline
def hadd_widening_u8x16(v: SIMD[DType.uint8, 16]) -> UInt16:
    """Widening horizontal-sum: 16 u8 lanes → single u16 (no mod 256).

    Returns the EXACT sum of all 16 byte lanes (max value 16 * 0xFF =
    0x0FF0, well within u16 range). Use this when the sum could exceed
    255 — e.g. for raw `0/0xFF` masks where `count = sum / 0xFF`, or
    for any byte-counting hot loop where the result must not truncate.

    ARM64: single `uaddlv h0, v.16b` instruction via the
    `llvm.aarch64.neon.uaddlv` intrinsic (widening lane-sum). The LLVM
    convention returns i32; we narrow to u16 because the sum is bounded.

    x86_64: cast input to `SIMD[uint16, 16]` and use stdlib `reduce_add`.
    The cast is the LLVM `zext` instruction sequence, then the widened
    reduce. Correct, not yet empirically tuned.
    """
    comptime if CompilationTarget.is_x86():
        var wide = v.cast[DType.uint16]()
        return wide.reduce_add()
    else:
        # uaddlv.16b returns i32 by LLVM convention; the sum fits in u16
        # (max 0x0FF0). Mojo intrinsic name maps the i32 return to UInt32;
        # narrow at the wrapper boundary.
        var s32 = llvm_intrinsic["llvm.aarch64.neon.uaddlv", UInt32](v)
        return UInt16(s32)


@always_inline
def hadd_u16x8(v: SIMD[DType.uint16, 8]) -> UInt16:
    """Horizontal-sum 8 u16 lanes into a single u16 (truncated mod 65536).

    Byte-identical to `v.reduce_add()` on `SIMD[uint16, 8]`.

    ARM64: single `addv h0, v.8h` instruction via
    `llvm.aarch64.neon.uaddv`. The same trap as `hadd_u8x16` applies on
    the 8-lane u16 path — stdlib reduce can emit a multi-op pair-add
    chain; the direct intrinsic is one instruction.

    x86_64: falls through to stdlib `v.reduce_add()`.
    """
    comptime if CompilationTarget.is_x86():
        return v.reduce_add()
    else:
        return llvm_intrinsic["llvm.aarch64.neon.uaddv", UInt16](v)


@always_inline
def hadd_u32x4(v: SIMD[DType.uint32, 4]) -> UInt32:
    """Horizontal-sum 4 u32 lanes into a single u32 (truncated mod 2^32).

    Byte-identical to `v.reduce_add()` on `SIMD[uint32, 4]`.

    ARM64: single `addv s0, v.4s` instruction via
    `llvm.aarch64.neon.uaddv`.

    x86_64: falls through to stdlib `v.reduce_add()`.
    """
    comptime if CompilationTarget.is_x86():
        return v.reduce_add()
    else:
        return llvm_intrinsic["llvm.aarch64.neon.uaddv", UInt32](v)
