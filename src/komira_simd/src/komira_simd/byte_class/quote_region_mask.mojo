# =============================================================================
# quote_region_mask.mojo — simdcsv-style quote-region scan via PCLMULQDQ / PMULL64.
# =============================================================================
#
# The simdcsv-style CSV scan's central primitive: given a 64-bit
# quote-bitmask (bit k = 1 iff byte k is an unescaped quote `"`),
# compute the "in-string" bitmask (bit k = 1 iff byte k is INSIDE a
# quoted region) via carry-less multiplication.
#
# Algorithm (Geoff Langdale / Daniel Lemire — simdcsv §4.2):
#   in_string = clmul(quote_bits, 0xFFFFFFFFFFFFFFFF, "lower 64 bits")
#
# The carry-less multiply (`pclmulqdq` on x86 / `pmull` on ARM) with
# the all-ones multiplier produces a bitmask where bit k is set iff
# the XOR of bits 0..k of the input is 1 — exactly the cumulative XOR
# that prefix_xor_u64 computes via the shift-XOR ladder, but in ONE
# instruction.
#
# The NEON PMULL64 intrinsic is the same one a CRC-32 fold uses;
# the implementation here follows that pattern.
#
# Encapsulation: scalar in, scalar out.  No pointers.
# =============================================================================

from std.sys.info import CompilationTarget
from std.sys.intrinsics import llvm_intrinsic

from komira_simd.byte_class.prefix_xor import prefix_xor_u64


# =============================================================================
# Private: per-arch single-instruction carry-less multiply.
# =============================================================================

@always_inline
def _x86_pclmulqdq_low64(a: UInt64, b: UInt64) -> UInt64:
    """x86 PCLMULQDQ — carry-less multiply of two 64-bit words, return
    lower 64 bits of the 128-bit result.

    LLVM intrinsic: `llvm.x86.pclmulqdq` takes a 128-bit operand pair
    plus a 1-byte immediate selecting which halves to multiply
    (immediate=0 → low * low).  Mojo's `llvm_intrinsic[]` wrapper
    requires us to pass the immediate as a runtime SSA Int8(0) value;
    LLVM accepts this for the pclmulqdq family.

    Input/output shape: caller packs the two UInt64s into SIMD[uint64,
    2] and the intrinsic returns SIMD[uint64, 2]; we extract lane 0.
    """
    var a_vec = SIMD[DType.uint64, 2](a, 0)
    var b_vec = SIMD[DType.uint64, 2](b, 0)
    var result = llvm_intrinsic[
        "llvm.x86.pclmulqdq",
        SIMD[DType.uint64, 2],
    ](a_vec, b_vec, Int8(0))
    return result[0]


@always_inline
def _arm_pmull_p64_low(a: UInt64, b: UInt64) -> UInt64:
    """ARM PMULL — polynomial multiply, 64-bit × 64-bit → 128-bit
    (return lower 64 bits).

    LLVM intrinsic: `llvm.aarch64.neon.pmull64`.  Operands are P64
    (polynomial-64) lanes.  A CRC-32 fold uses the same intrinsic.

    NEON return is `<16 x i8>` (128 bits); we bitcast to SIMD[uint64, 2]
    via an UnsafePointer detour (no native SIMD bitcast across DTypes
    here).
    """
    var result_v16 = llvm_intrinsic[
        "llvm.aarch64.neon.pmull64",
        SIMD[DType.uint8, 16],
    ](a, b)
    # Bitcast SIMD[uint8, 16] → SIMD[uint64, 2] via stack-local detour.
    var as_u64 = SIMD[DType.uint64, 2](0, 0)
    var dst_ptr = UnsafePointer(to=as_u64).bitcast[UInt8]()
    var src_ptr = UnsafePointer(to=result_v16).bitcast[UInt8]()
    # Per-byte copy — 16 bytes total.  The Mojo backend inlines this
    # to a single 128-bit load/store pair on aarch64.
    comptime for k in range(16):
        dst_ptr[k] = src_ptr[k]
    return as_u64[0]


# =============================================================================
# Public API — quote-region mask via clmul.
# =============================================================================

@always_inline
def quote_region_mask_u64(quote_bits: UInt64, carry_in: Bool) -> UInt64:
    """Convert an unescaped-quote bitmask (64 bits) to an in-string
    bitmask via carry-less multiply.

    Bit k of result = `carry_in XOR (parity of quote_bits[0..k])`.
    I.e. bit k is set iff byte k is INSIDE a quoted region.

    Architecture:
      - x86 PCLMULQDQ: ONE `pclmulqdq xmm, xmm, 0x00` instruction
        (~7 cycles latency on Skylake-X, but throughput 1 per cycle).
      - ARM PMULL: ONE `pmull` instruction (~3-5 cycles).
      - x86 without the `pclmul` target feature, or another architecture:
        fall back to `prefix_xor_u64`.

    Carry-in handling: if `carry_in` is True, the result is XOR'd with
    all-ones (flipping every bit — equivalent to "we started inside a
    string").  This is consistent with the shift-ladder form.
    """
    # PCLMULQDQ is not part of any x86-64 psABI level (v2, v3 or v4), so it is
    # used only when the compilation target enables the feature; an x86 target
    # without it takes the shift-XOR ladder below.
    comptime if CompilationTarget.is_x86() and CompilationTarget._has_feature[
        "pclmul"
    ]():
        var clm = _x86_pclmulqdq_low64(quote_bits, UInt64(0xFFFFFFFFFFFFFFFF))
        if carry_in:
            return clm ^ UInt64(0xFFFFFFFFFFFFFFFF)
        else:
            return clm
    else:
        # ARM PMULL path (the same intrinsic a CRC-32 fold uses on arm64).
        comptime if not CompilationTarget.is_x86():
            var clm = _arm_pmull_p64_low(quote_bits, UInt64(0xFFFFFFFFFFFFFFFF))
            if carry_in:
                return clm ^ UInt64(0xFFFFFFFFFFFFFFFF)
            else:
                return clm
        else:
            # Other targets: fall back to shift-XOR ladder.
            var carry_v = carry_in
            return prefix_xor_u64(quote_bits, carry_v)


@always_inline
def quote_region_mask_u64_with_carry_out(
    quote_bits: UInt64, mut carry: Bool
) -> UInt64:
    """Same as `quote_region_mask_u64` but threads the carry-out for
    multi-chunk scans.

    `carry` on entry: carry-in (True iff prior chunk ended INSIDE a string).
    `carry` on exit:  carry-out for the next chunk (high bit of the
    cumulative parity).
    """
    var result = quote_region_mask_u64(quote_bits, carry)
    # Carry-out = parity of all quote bits XOR'd with carry-in =
    # high bit of the result (bit 63).
    carry = (result & UInt64(0x8000000000000000)) != 0
    return result
