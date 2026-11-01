# =============================================================================
# table_lookup.mojo — Highway TableLookupBytes / Shuffle / Permute family.
# =============================================================================
#
# Highway category: Shuffle / Permute (TableLookupBytes, TableLookup16,
# TableLookupLanes).  Per-lane byte permute via an index vector.
#
# CSV / JSON central use: nibble-pair byte classification.  Given a
# 16-byte "low nibble LUT" and a "high nibble LUT", classify each byte
# by `lo_lut[b & 0xF] & hi_lut[(b >> 4) & 0xF]`.  This is the simdjson
# / Daniel Lemire byte-class scan pattern; Highway exposes it as
# `TableLookupBytes(table, idx)` and per-lane AND.
#
# Architecture lowering:
#   - NEON: `tbl.16b` (single-table 16-byte permute), wrapped here as
#     `table_lookup_u8x16_neon` (the same wrapper as `_neon_tbl_16b` in
#     `pattern_copy.mojo`).  Indices >= 16 produce 0 per NEON spec.
#   - x86 SSSE3: `pshufb` (16-byte permute).  Indices wrap mod 16 via
#     the low nibble; high bit acts as zero-mask.
#   - x86 AVX2: `vpshufb` (32-byte permute, two independent 16-byte
#     lanes — i.e. the high lane only indexes bytes 16..31 of `table`).
#   - x86 AVX-512 BW: `vpermb` (true 64-byte permute with linear index
#     range 0..63).  Not wrapped here yet.
#
# Per-function multi-arch dispatch via `comptime if CompilationTarget.is_x86()`.
#
# Encapsulation: SIMD-in / SIMD-out; no pointers.
# =============================================================================

from std.sys.info import CompilationTarget, simd_width_of
from std.sys.intrinsics import llvm_intrinsic


# =============================================================================
# Private: per-arch single-instruction wrappers.
# =============================================================================

@always_inline
def _neon_tbl1_v16i8(
    table: SIMD[DType.uint8, 16],
    indices: SIMD[DType.uint8, 16],
) -> SIMD[DType.uint8, 16]:
    """AArch64 NEON `tbl1.v16i8` — single-table 16-byte permute.

    out[k] = table[indices[k]] for indices[k] in 0..15
    out[k] = 0                  for indices[k] >= 16 (NEON spec)

    Same wrapper as `_neon_tbl_16b` in `pattern_copy.mojo`, exposed in the
    byte_class namespace.
    """
    return llvm_intrinsic[
        "llvm.aarch64.neon.tbl1.v16i8", SIMD[DType.uint8, 16]
    ](table, indices)


@always_inline
def _ssse3_pshufb_x16(
    table: SIMD[DType.uint8, 16],
    indices: SIMD[DType.uint8, 16],
) -> SIMD[DType.uint8, 16]:
    """x86 SSSE3 `pshufb` — 16-byte permute (per-lane low nibble select +
    high-bit zero-mask).
    """
    return llvm_intrinsic[
        "llvm.x86.ssse3.pshuf.b.128", SIMD[DType.uint8, 16]
    ](table, indices)


@always_inline
def _avx2_vpshufb_x32(
    table: SIMD[DType.uint8, 32],
    indices: SIMD[DType.uint8, 32],
) -> SIMD[DType.uint8, 32]:
    """x86 AVX2 `vpshufb` — 32-byte permute, two independent 16-byte
    lanes."""
    return llvm_intrinsic[
        "llvm.x86.avx2.pshuf.b", SIMD[DType.uint8, 32]
    ](table, indices)


# =============================================================================
# Public API — multi-arch dispatch.
# =============================================================================

@always_inline
def table_lookup_u8x16(
    table: SIMD[DType.uint8, 16],
    indices: SIMD[DType.uint8, 16],
) -> SIMD[DType.uint8, 16]:
    """16-byte table lookup: `out[k] = table[indices[k] mod 16]` (mod-16
    semantics on x86 SSSE3; index >= 16 → 0 on NEON / x86 high-bit).

    Highway `TableLookupBytes(table, idx)` (16-byte vector form).
    """
    comptime if CompilationTarget.is_x86():
        return _ssse3_pshufb_x16(table, indices)
    else:
        return _neon_tbl1_v16i8(table, indices)


@always_inline
def table_lookup_u8x32(
    table: SIMD[DType.uint8, 32],
    indices: SIMD[DType.uint8, 32],
) -> SIMD[DType.uint8, 32]:
    """32-byte table lookup: per-16-byte-lane permute.

    On x86 AVX2: single `vpshufb ymm` (two independent 16-byte halves).
    On NEON: two `tbl1.v16i8` invocations (low half + high half), then
    concatenated.
    """
    comptime if CompilationTarget.is_x86():
        return _avx2_vpshufb_x32(table, indices)
    else:
        # NEON: split, lookup, concat.
        var t_lo = table.slice[16, offset=0]()
        var t_hi = table.slice[16, offset=16]()
        var i_lo = indices.slice[16, offset=0]()
        var i_hi = indices.slice[16, offset=16]()
        var r_lo = _neon_tbl1_v16i8(t_lo, i_lo)
        var r_hi = _neon_tbl1_v16i8(t_hi, i_hi)
        return r_lo.join(r_hi)


# =============================================================================
# Nibble-LUT byte classifier — the Highway+simdjson canonical shape.
# =============================================================================
#
# For a 16/32-byte chunk, classify each byte by:
#   lo_class = lo_lut[byte & 0x0F]
#   hi_class = hi_lut[(byte >> 4) & 0x0F]
#   classified = lo_class & hi_class
#
# The two LUTs encode per-nibble class bits; AND'ing gives the final
# classification.  This is the shape CSV byte-class scan and JSON
# `_byte_classify` use to detect 8+ structural byte types in 2 lookups.

@always_inline
def nibble_lut_classify_u8x16(
    lo_lut: SIMD[DType.uint8, 16],
    hi_lut: SIMD[DType.uint8, 16],
    chunk: SIMD[DType.uint8, 16],
) -> SIMD[DType.uint8, 16]:
    """Nibble-LUT byte classification, 16-byte form.

    Each byte b in `chunk` produces:
      `out[k] = lo_lut[b & 0x0F] & hi_lut[(b >> 4) & 0x0F]`.

    Used by simdjson-style Stage 1 scans + the CSV byte-class scan: a single
    classification produces an 8-bit class-bitvector per byte, with
    each bit representing membership in one of 8 byte classes (e.g.
    "is whitespace", "is structural", "is escape", ...).
    """
    var lo_nibble = chunk & SIMD[DType.uint8, 16](0x0F)
    # Right-shift by 4 to extract high nibble. Mojo SIMD `>>` is
    # lane-parallel; the LUT-shape mask AND'd after is the safe
    # form (high nibble of UInt8 is at most 0x0F, so the AND is a
    # safety net for any LUT > 16 entries).
    var hi_nibble = (chunk >> SIMD[DType.uint8, 16](4)) & SIMD[DType.uint8, 16](0x0F)
    var lo_class = table_lookup_u8x16(lo_lut, lo_nibble)
    var hi_class = table_lookup_u8x16(hi_lut, hi_nibble)
    return lo_class & hi_class


@always_inline
def nibble_lut_classify_u8x32(
    lo_lut: SIMD[DType.uint8, 16],
    hi_lut: SIMD[DType.uint8, 16],
    chunk: SIMD[DType.uint8, 32],
) -> SIMD[DType.uint8, 32]:
    """Nibble-LUT byte classification, 32-byte form (AVX2-class width).

    NOTE: x86 `vpshufb ymm` operates on two independent 16-byte lanes —
    the lookup table is DUPLICATED across the two halves automatically
    by Mojo's `SIMD[uint8, 16].join(SIMD[uint8, 16])` shape promotion.
    The wrapper accepts the 16-byte LUT once and replicates internally.
    """
    var lut_lo_dup = lo_lut.join(lo_lut)  # SIMD[uint8, 32]
    var lut_hi_dup = hi_lut.join(hi_lut)
    var lo_nibble = chunk & SIMD[DType.uint8, 32](0x0F)
    var hi_nibble = (chunk >> SIMD[DType.uint8, 32](4)) & SIMD[DType.uint8, 32](0x0F)
    var lo_class = table_lookup_u8x32(lut_lo_dup, lo_nibble)
    var hi_class = table_lookup_u8x32(lut_hi_dup, hi_nibble)
    return lo_class & hi_class
