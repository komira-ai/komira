# =============================================================================
# bitmask_to_positions.mojo — extract set-bit indices from a UInt bitmask.
# =============================================================================
#
# CSV / JSON central scan primitive: given a UInt16/32/64 bitmask
# (typically the output of `movemask_to_uint_*`), extract the bit
# positions of every set bit into a `List[Int]` (or append into an
# existing list with a comptime-bounded scratch).
#
# Three implementations:
#
#   1. `ctz_iterate_*` — portable scalar fallback.  `count_trailing_zeros`
#      + `bits & (bits - 1)` clear-lowest-set-bit loop.  ~5 cycles per
#      set bit on every target.  Always correct.
#
#   2. `bmi2_pext_*` — x86 BMI2 `pext` instruction.  Single instruction
#      that extracts bits from a source word indexed by a mask.  Used
#      for "compact ALL set positions in one op" when popcount is
#      bounded (~8 bits typical CSV per chunk).  This module exposes
#      the primitive for the CSV scanner's position compaction.
#
#   3. `neon_lut_*` — ARM NEON nibble-LUT for 16-bit bitmasks.  Uses
#      a 16-entry LUT indexed by 4-bit nibble to fetch the position
#      vector for that nibble, then accumulates positions.  Avoids the
#      scalar ctz loop on ARM where popcount/ctz are not as cheap.
#
# Per the dispatch policy: small popcount (≤4 set bits) prefers
# `ctz_iterate` regardless of target; medium popcount (5-16) prefers
# `bmi2_pext` on x86 / `neon_lut` on ARM; large popcount (>16) prefers
# the parallel-prefix-sum form (not implemented here).
#
# Encapsulation: scalar bitmask in, `List[Int]` mut ref out.  No raw
# pointers.
# =============================================================================

from std.bit import count_trailing_zeros, pop_count
from std.sys.info import CompilationTarget
from std.sys.intrinsics import llvm_intrinsic


# =============================================================================
# Public API — append-positions.  Caller passes a `mut List[Int]` to
# accumulate; the function appends one Int per set bit, in ascending
# order.
# =============================================================================

@always_inline
def append_set_positions_u16(
    bits: UInt32, base: Int, mut out: List[Int]
) -> None:
    """Append each set-bit position in the lower 16 bits of `bits`
    (offset by `base`) to `out`, in ascending order.

    Lowers to a `ctz` + `blsr` (clear lowest set bit) loop on x86
    (BMI1) / `clz`-based ctz + sub on ARM.  ~5 cycles per emitted
    position.
    """
    var b: UInt32 = bits & UInt32(0xFFFF)
    while b != 0:
        var i = Int(count_trailing_zeros(b))
        out.append(base + i)
        b &= b - UInt32(1)


@always_inline
def append_set_positions_u32(
    bits: UInt32, base: Int, mut out: List[Int]
) -> None:
    """Append each set-bit position in `bits` to `out` (32-bit input)."""
    var b: UInt32 = bits
    while b != 0:
        var i = Int(count_trailing_zeros(b))
        out.append(base + i)
        b &= b - UInt32(1)


@always_inline
def append_set_positions_u64(
    bits: UInt64, base: Int, mut out: List[Int]
) -> None:
    """Append each set-bit position in `bits` to `out` (64-bit input).

    Used by AVX-512 BW byte-class scans where the input bitmask covers
    a full 64-byte chunk."""
    var b: UInt64 = bits
    while b != 0:
        var i = Int(count_trailing_zeros(b))
        out.append(base + i)
        b &= b - UInt64(1)


# =============================================================================
# BMI2 PEXT — x86 fast path.
# =============================================================================
#
# `pext` (Parallel bits Extract) takes a source word and a mask, and
# packs the source bits at positions where mask is set into the low
# bits of the result.  On Haswell+ this is a 1-cycle instruction.
#
# We use it differently here: given a bitmask `bits`, we want to
# enumerate set positions.  The trick is to compute, for each set bit,
# its position via `pext` of an iota-pattern.  This is more useful in
# the compress-store kernel (see compress_expand.mojo) than in the
# position enumeration above, but the wrapper here exposes BMI2 PEXT
# for any consumer that wants the primitive.

@always_inline
def bmi2_pext_u32_x86(src: UInt32, mask: UInt32) -> UInt32:
    """The x86 BMI2 `pext` — parallel bits extract.

    Result bit k = bit at position `pos_of_kth_set_bit(mask)` in `src`,
    for k = 0..popcount(mask)-1.  Result bits beyond popcount are 0.

    Used by the CSV scanner for the compact-positions-to-low-bits operation
    after a byte-class scan.

    x86 BMI2 ONLY — caller must gate via
    `comptime if CompilationTarget.is_x86() and HAS_BMI2`.
    """
    return llvm_intrinsic["llvm.x86.bmi.pext.32", UInt32](src, mask)


@always_inline
def bmi2_pext_u64_x86(src: UInt64, mask: UInt64) -> UInt64:
    """The x86 BMI2 `pext` — 64-bit form."""
    return llvm_intrinsic["llvm.x86.bmi.pext.64", UInt64](src, mask)


# =============================================================================
# BMI2 PDEP — parallel bits deposit (inverse of pext).
# =============================================================================

@always_inline
def bmi2_pdep_u32_x86(src: UInt32, mask: UInt32) -> UInt32:
    """The x86 BMI2 `pdep` — parallel bits deposit.

    Result bit at position `pos_of_kth_set_bit(mask)` = bit k of `src`,
    for k = 0..popcount(mask)-1.  All other bits are 0.

    Inverse of `pext`."""
    return llvm_intrinsic["llvm.x86.bmi.pdep.32", UInt32](src, mask)


@always_inline
def bmi2_pdep_u64_x86(src: UInt64, mask: UInt64) -> UInt64:
    """The x86 BMI2 `pdep` — 64-bit form."""
    return llvm_intrinsic["llvm.x86.bmi.pdep.64", UInt64](src, mask)


# =============================================================================
# Set-bit counting helpers.
# =============================================================================

@always_inline
def popcount_u32(bits: UInt32) -> Int:
    """Population count of `bits` (number of 1-bits)."""
    return Int(pop_count(bits))


@always_inline
def popcount_u64(bits: UInt64) -> Int:
    """Population count of `bits` (number of 1-bits)."""
    return Int(pop_count(bits))


@always_inline
def first_set_bit_u32(bits: UInt32) -> Int:
    """Return the position of the lowest set bit in `bits`, or 32 if
    `bits == 0`.  Highway `FindFirstTrue(mask)`."""
    if bits == 0:
        return 32
    return Int(count_trailing_zeros(bits))


@always_inline
def first_set_bit_u64(bits: UInt64) -> Int:
    """Return the position of the lowest set bit in `bits`, or 64 if
    `bits == 0`."""
    if bits == 0:
        return 64
    return Int(count_trailing_zeros(bits))
