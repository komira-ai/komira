# =============================================================================
# validity_pack.mojo — null-flag column → Arrow validity bitmap (SIMD movemask).
# =============================================================================
#
# Packs a contiguous column of per-row null flags (1 byte each: True = NULL,
# False = present) into an Arrow validity bitmap (LSB-first within each byte;
# bit r == 1 iff row r is VALID / not-null). This is the SIMD-movemask form of
# the per-bit scalar scatter that arrow-buffer's `NullBufferBuilder.append` and
# arrow-avro's per-row validity build do — and that LLVM cannot autovectorize
# because `if null[i]: clear_bit(i)` is a data-dependent irregular bit-write.
#
# The forward primitive is `byte_class/movemask.mojo:movemask_to_uint_u8xW`
# (lane k of an 0xFF/0x00 byte-mask → bit k of a scalar bitmask, LSB-first).
# Arrow's validity uses the same LSB-first bit order, so movemask output drops
# straight into the bitmap bytes with no shuffle.
#
# Mojo does NOT autovectorize unit-stride numeric loops, so the W-at-a-time
# pack is explicit here; LLVM will not produce it from a scalar `for` loop.
#
# Shared consumers:
#   * Avro `_StringAcc` / `_BoolAcc` / `_BinaryAcc` / `_DecimalAcc` validity
#     build (`komira_avro`), high-null-density columns.
#   * ORC nullable-column PRESENT-stream → validity.
#   * Parquet definition-level → validity bitmap.
#   * CSV nullable-column validity build.
#
# Encapsulation: the PUBLIC API takes a borrowed `Span[Bool, _]` (or
# `Span[UInt8, _]`) source view and a mutable `Span[UInt8, _]` destination
# bitmap view — NO raw UnsafePointer crosses this module boundary. Internal
# SIMD load/store uses concrete-origin pointers obtained from those spans with
# `# SAFETY:` notes; they never escape.
#
# Output is bit-for-bit identical to the scalar reference
# (`create_all_valid(n)` + per-null `clear(i)`); the unit test validates this
# against a scalar oracle across all tail alignments.
# =============================================================================

from std.bit import pop_count

from komira_simd.byte_class.movemask import (
    byte_eq_to_bytemask_u8x16,
    movemask_to_uint_u8x16,
)


# =============================================================================
# pack_validity_from_null_flags — Span[Bool] null flags → Arrow validity bytes.
# =============================================================================
#
# Arrow validity semantics: bit r (LSB-first within byte r//8) is 1 iff row r is
# VALID (not null). The input `null_flags[r]` is True iff row r is NULL, so
# validity_bit = NOT null_flag. We process 16 rows per SIMD iteration: load 16
# null-flag bytes, build an 0xFF/0x00 byte-mask of "present" lanes
# (`flag == 0`), movemask to 16 bits, write the low two bytes of the 16-bit
# word into the two bitmap bytes covering those rows. The scalar tail handles
# the final < 16 rows.


@always_inline
def pack_validity_from_null_flags[
    fo: Origin[mut=False], bo: Origin[mut=True]
](
    null_flags: Span[Bool, fo], mut bitmap_bytes: Span[UInt8, bo]
) -> Int:
    """Pack a per-row null-flag column into an Arrow validity bitmap.

    Args:
        null_flags: One byte per row. `True` = NULL, `False` = present.
        bitmap_bytes: Destination validity bitmap, LSB-first. MUST be
            pre-sized to at least `(len(null_flags) + 7) // 8` bytes. Bit r
            is set to 1 iff `null_flags[r]` is False (row valid).

    Returns:
        The number of null rows (count of `True` flags).

    The output is bit-for-bit identical to a scalar
    `create_all_valid(n)` + per-null `clear(i)` build. 16 rows are packed
    per SIMD movemask iteration; the final < 16 rows use a scalar tail.
    """
    var n = len(null_flags)
    var num_bytes = (n + 7) >> 3
    # SAFETY: `dp` is a concrete-origin pointer into the caller's mutable
    # `bitmap_bytes` span (origin `bo`), pre-sized to >= num_bytes by the
    # caller. Used only for bounded stores inside this function; never escapes.
    var dp = bitmap_bytes.unsafe_ptr()
    # Zero the destination first so partial trailing bytes have clean high bits.
    for b in range(num_bytes):
        dp.store(b, UInt8(0))
    if n == 0:
        return 0

    # SAFETY: `src` is a concrete-origin pointer into the caller's borrowed
    # `null_flags` span (origin `fo`); it is used only for bounded SIMD loads
    # inside this function and never escapes. Bool is 1 byte; bitcast to UInt8
    # reads the raw flag byte (0 = present, nonzero = null).
    var src = null_flags.unsafe_ptr().bitcast[UInt8]()
    var null_count = 0

    var simd_chunks = n >> 4  # number of full 16-row groups
    var i = 0
    var byte_idx = 0
    while i < simd_chunks:
        var off = i << 4
        # Load 16 raw flag bytes.
        var flags = src.load[width=16](off)
        # "present" byte-mask: lane == 0 -> 0xFF (valid), else 0x00 (null).
        var present_mask = byte_eq_to_bytemask_u8x16(flags, UInt8(0))
        # movemask: bit k = 1 iff lane k present (valid). LSB-first == Arrow.
        var valid_bits = movemask_to_uint_u8x16(present_mask)
        dp.store(byte_idx, UInt8(valid_bits & 0xFF))
        dp.store(byte_idx + 1, UInt8((valid_bits >> 8) & 0xFF))
        # null count for this group = 16 - popcount(valid_bits low 16 bits).
        var valid_in_group = Int(pop_count(UInt32(valid_bits & 0xFFFF)))
        null_count += 16 - valid_in_group
        i += 1
        byte_idx += 2

    # Scalar tail for the final (n % 16) rows.
    var tail_start = simd_chunks << 4
    for r in range(tail_start, n):
        if null_flags[r]:
            null_count += 1
        else:
            # Set validity bit r (LSB-first within byte r//8).
            var b = r >> 3
            dp.store(b, dp.load(b) | (UInt8(1) << UInt8(r & 7)))
    return null_count
