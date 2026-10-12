# =============================================================================
# Fixed-width LSB-first bitpacker
# =============================================================================
#
# The shared fixed-width packing primitive for BOTH:
#   (a) DELTA_BINARY_PACKED miniblock bodies, and
#   (b) the RLE/BITPACKED-hybrid dict-index bodies
# (the delta and dictionary page encoders, later parts of this package).
#
# Byte layout (LSB-first) — the invariant:
#   Pack values v[0], v[1], ... at width w. Value v[k] occupies bits
#   [k*w, k*w+w) of a little-endian bitstream, low bit first:
#     output_byte[j] bit b = bitstream bit (j*8 + b).
#     v[k]'s bit i (i in [0,w)) lands at bitstream position k*w + i.
#
# This is the scalar RLE-hybrid packer's layout (`bit_buf |= idx <<
# bits_in_buf`, flush low byte) AND exactly what komira_parquet's
# `rle` and `delta` decoders read (`(byte >> bit) & mask`).
#
# PERF-CRITICAL: the hot pack path is hand-staged SIMD. Mojo does NOT
# auto-vectorize the scalar carry-accumulator loop (the `while bits_in_buf
# >= 8` variable-trip inner loop blocks the autovectorizer). The SIMD path
# processes values in GROUPS OF 8: at any width w, a group
# of 8 values spans exactly 8*w bits = w whole bytes, so group boundaries are
# byte-aligned, bits_in_buf returns to 0 at each boundary, and carry NEVER
# crosses a group. Per-group processing is therefore byte-identical to a
# single continuous u64 accumulator.
#
# The SIMD group packer handles widths w <= _SIMD_MAX_BW (56). Under that
# bound each lane's in-byte shift sh (0..7) plus w stays <= 63 < 64, so a
# lane's positioned bits `masked << sh` fit ENTIRELY in one 64-bit output
# word — no spill word, no bit-drop. The per-lane arithmetic (mask + variable
# left shift) runs as SIMD[DType.uint64, 8] ops (one vpand + one vpsllvq),
# then a bounded 8-lane OR-merge scatters the single-word lanes into the
# output. Widths 57..64 (rare: frame-of-reference DBP deltas almost always
# fit in << 32 bits) AND any slack-short final group fall back to the scalar
# group writer, which is the byte-identity oracle for those widths.
#
# The output is BYTE-IDENTICAL to the scalar reference (proved by construction
# for w <= 56 — single-word LSB placement, no drop — and guarded by a
# randomized A/B property test over ALL widths 1..64 and many counts in
# tests/test_writer_bitpack_direct.mojo). DO NOT delete the SIMD group
# path or the scalar group writer as "dead-looking duplicate code": both the
# SIMD body and the scalar fallback (wide widths + tail + width-0) are
# load-bearing.
#
# SAFETY: pack_fixed_width_into uses UnsafePointer for the strided bit
# writes across byte boundaries. The pointer is module-internal (the public
# pack_fixed_width returns a List[UInt8]); the dest pointer's origin is the
# caller's List. No pointer crosses a module boundary in a public signature.
# =============================================================================

from std.memory import UnsafePointer

from komira_simd.width_policy import komira_simd_width_bitpack


@always_inline
def _pack_count_bytes(count: Int, bit_width: Int) -> Int:
    """Number of bytes needed to pack `count` values at `bit_width` bits each."""
    return (count * bit_width + 7) >> 3


# The maximum bit-width the SIMD group packer handles. For bw <= 56 a
# group-of-8 lane's in-byte shift (sh in [0,7]) plus bw never reaches 64
# (7 + 56 = 63 < 64), so a lane NEVER spills past its single 64-bit `lo`
# output word. That single-word property is what makes the SIMD form
# trivially byte-identical to the scalar accumulator. Widths 57..64 are
# rare (frame-of-reference DBP deltas almost always fit in << 32 bits) and
# fall back to the scalar group writer, which is the byte-identity oracle
# for those widths (the reader's per-value 64-bit-load decode shares the
# same single-word constraint — see delta._unpack_miniblock).
comptime _SIMD_MAX_BW = 56


@always_inline
def _pack_group8_simd[
    o_dst: Origin[mut=True]
](
    values: UnsafePointer[Int64, _],
    bw: Int,
    mask: UInt64,
    dst: UnsafePointer[UInt8, o_dst],
):
    """Pack exactly 8 values at width `bw` (1..56), LSB-first, into `dst`.

    Writes exactly `bw` bytes. A group of 8 values spans 8*bw bits = bw
    whole bytes, so the group is self-contained — no carry crosses the group
    boundary, which is what makes the SIMD form byte-identical to the scalar
    accumulator and lets us write the bytes with no inter-group state.

    PRECONDITION: bw <= _SIMD_MAX_BW (56). Under that bound, each lane's bits
    `[k*bw, k*bw+bw)` start at in-byte shift `sh_k = (k*bw) & 7` (0..7) and
    span sh_k + bw <= 63 bits, so the positioned contribution `masked_k << sh_k`
    fits ENTIRELY in one 64-bit word at byte offset `boff_k = (k*bw) >> 3` —
    no spill word is ever needed. (Widths 57..64 go scalar; see _SIMD_MAX_BW.)

    Topology (hand-staged SIMD; the autovec trap is the scalar `while
    bits_in_buf >= 8` flush loop — see module header PERF-CRITICAL):
      - Load the 8 values as SIMD[uint64, 8] and `& mask` (one vpand).
      - `lo = masked << shifts_lo` — one SIMD per-lane variable left shift
        (vpsllvq) positions every lane's bits within its 64-bit word.
      - OR-merge the 8 single-word contributions into the output via a bounded
        8-iteration unaligned 64-bit read-modify-write. The heavy arithmetic
        (mask + 8-lane shift) already happened in the two SIMD ops above.

    SAFETY: `dst` must have at least `bw` writable bytes PLUS 8 bytes of slack
    past the group's `bw`-th byte (the lo 64-bit OR-store touches up to 8 bytes
    from `boff_k <= bw-1`); the caller (`_pack_fixed_width_into`) only takes the
    SIMD path when >= 8 trailing slack bytes exist, else uses the scalar writer.
    `values` must point to at least 8 readable Int64s.
    """
    # The parquet bitpack GROUP is always 8 values (algorithmic constant — a
    # group of 8 at width bw spans exactly bw whole bytes). But a single
    # SIMD[uint64, 8] op is a 512-bit (zmm) op, which DOWNCLOCKS the core on
    # AVX-512 Skylake-X/SP/Cascade-Lake (a net write-wall regression). So we
    # compute the per-lane heavy arithmetic (mask + variable shift) in chunks
    # of `PW = komira_simd_width_bitpack[uint64]()` lanes — 4 (two 256-bit ops) on
    # Skylake-X, 8 (one 512-bit op) under the KOMIRA_SIMD_ALLOW_AVX512
    # override / Ice Lake, 2 on NEON. The group semantics are unchanged: each
    # lane's `masked << sh` is per-lane independent (no inter-lane carry), so
    # splitting the group into PW-lane sub-vectors is BYTE-IDENTICAL to the
    # 8-lane form. See komira_simd/width_policy.mojo.
    comptime PW = komira_simd_width_bitpack[DType.uint64]()

    # Spill the positioned lanes to a stack scratch; the OR-merge then reads
    # scalar words from the scratch (the vector store survives because its
    # result feeds a contiguous store, not 8 separate lane extractions).
    var lane_words = InlineArray[UInt64, 8](uninitialized=True)
    var lane_ptr = lane_words.unsafe_ptr()

    comptime IOTA8 = SIMD[DType.uint64, 8](0, 1, 2, 3, 4, 5, 6, 7)
    var c = 0
    while c < 8:
        # Per-lane in-byte shift sh_k = (k*bw) & 7 for this PW-lane sub-group.
        # Slicing IOTA8 at comptime would require a comptime base, so build the
        # sub-iota at runtime from the chunk base `c` (cheap; the compiler
        # keeps the subsequent mask+shift vectorized).
        var sub_iota = IOTA8.slice[PW, offset=0]() + SIMD[DType.uint64, PW](
            UInt64(c)
        )
        var bw_vec = SIMD[DType.uint64, PW](UInt64(bw))
        var shifts_lo = (sub_iota * bw_vec) & SIMD[DType.uint64, PW](7)

        # SAFETY: PW contiguous Int64s at values+c; bitcast to u64 reinterprets
        # the same bytes (values are pre-masked below). c+PW <= 8 always (8 is a
        # multiple of PW for PW in {2,4,8}).
        var v = (values + c).bitcast[UInt64]().load[width=PW](0)
        var masked = v & SIMD[DType.uint64, PW](mask)
        var lo = masked << shifts_lo

        # SAFETY: lane_words is 8 contiguous UInt64 (stack-owned); this store
        # writes lanes [c, c+PW) which are in-bounds (c+PW <= 8).
        (lane_ptr + c).store[width=PW](0, lo)
        c += PW

    # Zero the bw output bytes first (the OR-merge accumulates into them).
    for j in range(bw):
        (dst + j)[] = UInt8(0)

    # OR-merge the 8 positioned lanes. Bounded 8-iteration loop; the heavy
    # arithmetic already happened vectorized above. Each lane ORs its single
    # 64-bit word at byte boff_k = (k*bw) >> 3.
    for k in range(8):
        var boff = (k * bw) >> 3
        # SAFETY: boff <= ((7*bw) >> 3) <= bw-1 for bw>=1; dst has bw bytes
        # plus >=8 slack (caller guarantee), so [boff, boff+8) is writable.
        # lane_ptr[k] is in-bounds (k in [0,8)).
        var cur = (dst + boff).bitcast[UInt64]().load[width=1](0)
        (dst + boff).bitcast[UInt64]().store[width=1](0, cur | lane_ptr[k])


@always_inline
def _pack_group8_scalar[
    o_dst: Origin[mut=True]
](
    values: UnsafePointer[Int64, _],
    n: Int,
    bw: Int,
    mask: UInt64,
    dst: UnsafePointer[UInt8, o_dst],
):
    """Scalar pack of `n` (1..8) values at width `bw` into `dst`.

    Writes exactly `_pack_count_bytes(n, bw)` bytes when `n < 8`, or `bw`
    bytes when `n == 8`. Used for the final group of a call (no 8-byte slack
    for the SIMD lo/hi stores) and the sub-8 remainder. This IS the scalar
    reference shape (u64 carry accumulator, flush low byte) — keeping it as a
    distinct helper makes the SIMD/scalar A/B comparison direct. A value that
    does not fit beside the bits still in the accumulator (widths 58..64) is
    added in two parts, so no bit is shifted out of the 64-bit word.

    SAFETY: `dst` must hold at least `_pack_count_bytes(n, bw)` writable
    bytes; `values` at least `n` readable Int64s.
    """
    var bit_buf = UInt64(0)
    var bits_in_buf = 0
    var out_pos = 0
    for i in range(n):
        var val = UInt64((values + i)[]) & mask
        # ⚠ A value can straddle the 64-bit accumulator: after a flush up to
        # 7 bits remain, and 7 + bw > 64 for bw >= 58, so `val << bits_in_buf`
        # would drop the value's top bits. Add it in parts that fit.
        var remaining = bw
        while remaining > 0:
            var take = min(remaining, 64 - bits_in_buf)
            var part_mask = (UInt64(1) << UInt64(take)) - 1 if take < 64 else ~UInt64(0)
            bit_buf = bit_buf | ((val & part_mask) << UInt64(bits_in_buf))
            bits_in_buf += take
            remaining -= take
            val = val >> UInt64(take) if take < 64 else UInt64(0)
            while bits_in_buf >= 8:
                (dst + out_pos)[] = UInt8(bit_buf & UInt64(0xFF))
                out_pos += 1
                bit_buf = bit_buf >> UInt64(8)
                bits_in_buf -= 8
    if bits_in_buf > 0:
        (dst + out_pos)[] = UInt8(bit_buf & UInt64(0xFF))
        out_pos += 1


@always_inline
def _pack_fixed_width_into[
    o_dst: Origin[mut=True]
](
    values: UnsafePointer[Int64, _],
    count: Int,
    bit_width: Int,
    dst: UnsafePointer[UInt8, o_dst],
):
    """Pack `count` Int64 values at `bit_width` bits each, LSB-first, into dst.

    Writes exactly `_pack_count_bytes(count, bit_width)` bytes. `bit_width`
    must be in [0, 64]. A bit_width of 0 emits 0 bytes (caller must not call
    with bit_width 0 when count > 0 unless that is intentional — the DBP and
    RLE callers handle width-0 specially).

    PERF-CRITICAL: hot path is the SIMD group-of-8 packer (`_pack_group8_simd`,
    see module header) for widths <= _SIMD_MAX_BW (56). Groups of 8 are
    byte-aligned at every width so they carry no inter-group state. Wider
    widths (57..64), the slack-short final group, and the sub-8 tail go through
    the scalar group writer (`_pack_group8_scalar`).

    SAFETY: `dst` must have at least `_pack_count_bytes(count, bit_width)`
    writable bytes. `values` must point to at least `count` readable Int64s.
    Only the low `bit_width` bits of each input are written (callers guarantee
    the inputs fit the width; we mask to be safe). The SIMD group path is taken
    only when the group's `bw`-th output byte is followed by >= 8 slack bytes
    within the dst region this call owns.
    """
    if bit_width == 0 or count == 0:
        return

    var bw = bit_width
    var mask = (UInt64(1) << UInt64(bw)) - 1 if bw < 64 else ~UInt64(0)

    var total_bytes = _pack_count_bytes(count, bw)
    var n_full_groups = count >> 3  # count // 8
    var rem = count & 7  # count % 8

    # Per-group processing is byte-identical to a single continuous u64
    # accumulator: at every group-of-8 boundary, 8*bw bits have been emitted
    # (a whole-byte multiple), so bits_in_buf returns to 0 and the byte stream
    # is aligned. SIMD handles widths <= _SIMD_MAX_BW (no lane spill); wider
    # widths and slack-short last groups use the scalar group writer.
    var simd_ok = bw <= _SIMD_MAX_BW
    var gi = 0
    var out_off = 0  # byte offset for the current group (always == gi*bw)
    while gi < n_full_groups:
        # The SIMD group writer's lo 64-bit OR-store touches up to 8 bytes from
        # the group's first byte. Take the SIMD path only when the group has
        # >= 8 trailing slack bytes within the region this call owns.
        var slack = total_bytes - (out_off + bw)
        if simd_ok and slack >= 8:
            # SAFETY: 8 readable Int64s at values+gi*8; dst[out_off..out_off+bw)
            # plus >= 8 slack bytes are writable (slack check above).
            _pack_group8_simd(values + gi * 8, bw, mask, dst + out_off)
        else:
            # Wide width (bw > 56) or insufficient trailing slack; scalar.
            _pack_group8_scalar(values + gi * 8, 8, bw, mask, dst + out_off)
        gi += 1
        out_off += bw

    # Sub-8 remainder (0..7 values). Always scalar.
    if rem > 0:
        # SAFETY: `rem` readable Int64s at values + n_full_groups*8; the
        # remaining bytes of dst from out_off are writable (total_bytes).
        _pack_group8_scalar(
            values + n_full_groups * 8, rem, bw, mask, dst + out_off
        )


def pack_fixed_width(
    values: List[Int64],
    count: Int,
    bit_width: Int,
) raises -> List[UInt8]:
    """Pack the first `count` values of `values` at `bit_width` bits, LSB-first.

    Returns exactly `_pack_count_bytes(count, bit_width)` bytes (0 bytes when
    bit_width == 0 or count == 0). Public, safe convenience wrapper over the
    internal `_pack_fixed_width_into` (which operates on raw pointers); the
    public surface takes/returns only safe `List` types per the encapsulation
    rule.

    Raises:
        If `count` is negative or larger than `len(values)`, or `bit_width`
        is outside [0, 64]: the packer would read past `values` or shift by
        an undefined amount.
    """
    if count < 0 or count > len(values):
        raise Error(
            "pack_fixed_width: count "
            + String(count)
            + " is outside [0, len(values) = "
            + String(len(values))
            + "]"
        )
    if bit_width < 0 or bit_width > 64:
        raise Error(
            "pack_fixed_width: bit_width " + String(bit_width) + " is outside [0, 64]"
        )
    var n_bytes = _pack_count_bytes(count, bit_width)
    if n_bytes == 0:
        return List[UInt8]()
    var result = List[UInt8](capacity=n_bytes)
    result.resize(n_bytes, UInt8(0))
    # SAFETY: result holds exactly n_bytes; `_pack_fixed_width_into` writes
    # at most n_bytes; `values` holds >= count Int64s. Both Lists are alive
    # through the call; the pointers are module-internal.
    _pack_fixed_width_into(
        values.unsafe_ptr(), count, bit_width, result.unsafe_ptr()
    )
    return result^


@always_inline
def min_bit_width(max_value: Int) -> Int:
    """Minimum number of bits to represent values in [0, max_value].

    ceil(log2(max_value + 1)). Returns 0 for max_value == 0 (all values
    equal — no body bytes needed for that miniblock). Matches
    `dict_encoder.num_required_bits` semantics.
    """
    if max_value <= 0:
        return 0
    var v = max_value
    var bits = 0
    if v >= (1 << 32):
        bits += 32
        v = v >> 32
    if v >= (1 << 16):
        bits += 16
        v = v >> 16
    if v >= (1 << 8):
        bits += 8
        v = v >> 8
    if v >= (1 << 4):
        bits += 4
        v = v >> 4
    if v >= (1 << 2):
        bits += 2
        v = v >> 2
    if v >= (1 << 1):
        bits += 1
        v = v >> 1
    bits += v
    return bits
