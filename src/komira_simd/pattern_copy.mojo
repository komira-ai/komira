# =============================================================================
# pattern_copy.mojo — SIMD pattern-copy (cyclic byte-extend) primitive.
# =============================================================================
#
# PERF-CRITICAL. The cyclic byte-pattern extend
#
#     out[out_pos + k] = out[out_pos - offset + k]    for k in 0..length-1
#
# is the back-reference body of LZ77-family decompressors (snappy, lz4,
# zstd, deflate) and the run-length expansion shape for byte-typed RLE
# decoders. When `offset < 16` the read range overlaps the write range,
# so the SIMD primitive cannot be a plain 16-byte load + 16-byte store —
# the bytes must be expanded by the cyclic period before the wide store.
#
# The primitive is byte-identical to a scalar reference copy across the
# snappy decompressor's correctness cases on NEON.
#
# Architecture lowering:
#   * ARM64 NEON (offset < 16): one `ld1` + one `tbl.16b` per output
#     16-byte block. The lookup table is the 16-byte source window; the
#     index vector is the comptime cyclic mask
#     `[base, base+1, ..., base+15] mod period`. Up to 4 blocks per
#     primitive call (length <= 64 stops at 4 stores).
#   * ARM64 NEON (offset >= 16): plain `ld1.16b` + `st1.16b` pairs in a
#     16-byte unrolled loop. No overlap, no shuffle needed.
#   * x86_64 AVX-512 (offset < 16): NOT IMPLEMENTED. The natural
#     intrinsic is `llvm.x86.avx512.permvar.qi.512` (`vpermb zmm`) with a
#     64-byte cyclic index vector. Bare-name AVX-512 intrinsics that take
#     a packed mask are REJECTED by Mojo's bundled LLVM overload matcher;
#     `vpermb` only takes SIMD-vector args so it MAY be accepted, but that
#     is unverified. (`llvm.experimental.vector.compress` does NOT cover
#     this case.) x86 therefore falls through to scalar.
#   * x86_64 / any (offset >= 16, or unknown): scalar fallback. The
#     scalar loop is correct for any (offset, length) including the
#     small-offset cyclic case.
#
# Encapsulation: public API takes `Span[UInt8, _]`. NO `UnsafePointer`
# crosses the module boundary. Internal helpers
# call `Span.unsafe_ptr()` confined to module scope.
#
# Slop-buffer contract:
#   The NEON small-offset path always writes UP TO the next 16-byte
#   block boundary past `out_pos + length`. Callers MUST reserve at
#   least 16 bytes of slop past the promised write end. Snappy uses
#   `kSlopBytes=64` which more than covers the 4 × 16-byte blocks; any
#   caller that materializes RLE-byte runs into an owned buffer should
#   over-allocate by 16 bytes and truncate at return.
#
# Mojo gotchas:
#   * `llvm.aarch64.neon.tbl1.v16i8` is the correct bare-name LLVM
#     intrinsic for the single-table `tbl.16b` instruction. Mojo derives
#     operand + return types from the wrapper signature.
#   * `UnsafePointer.store[width=N](offset, value)` is required — bare
#     `dst.store(value)` errors with "no matching method".
#   * `UnsafePointer.load[width=N](offset)` likewise.
#   * `comptime if CompilationTarget.is_x86():` — not `@parameter if`.
#   * The `_cyclic_mask_16[period, base]()` helper builds a comptime
#     SIMD constant — `comptime for k in range(16)` writes lane-by-lane.
# =============================================================================

from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.sys.intrinsics import llvm_intrinsic


# =============================================================================
# Internal helpers — cyclic mask + NEON tbl1 + unaligned load/store.
# =============================================================================


@always_inline
def _cyclic_mask_16[period: Int, base: Int]() -> SIMD[DType.uint8, 16]:
    """Build a 16-lane index vector `out[k] = (base + k) mod period` at
    compile time. Used as the index argument to `tbl.16b` to expand a
    16-byte source window into a 16-byte output block where each lane
    picks the appropriate source byte for the cyclic pattern.

    Periods 1..15 are valid; period 0 would divide-by-zero (caller's
    responsibility — `_neon_pattern_block` only calls with period 1..15).
    """
    comptime assert period >= 1 and period <= 15, "period must be 1..15"
    var m = SIMD[DType.uint8, 16](0)
    comptime for k in range(16):
        m[k] = UInt8((base + k) % period)
    return m


@always_inline
def _neon_tbl_16b(
    table: SIMD[DType.uint8, 16],
    indices: SIMD[DType.uint8, 16],
) -> SIMD[DType.uint8, 16]:
    """Wrap `llvm.aarch64.neon.tbl1.v16i8` — single-table byte lookup.

    For each lane `k`: `out[k] = table[indices[k]]` (indices >= 16
    produce 0 per the AArch64 spec).
    """
    return llvm_intrinsic[
        "llvm.aarch64.neon.tbl1.v16i8",
        SIMD[DType.uint8, 16],
    ](table, indices)


@always_inline
def _store_u8x16_unaligned[o: Origin[mut=True]](
    dst: UnsafePointer[UInt8, o],
    v: SIMD[DType.uint8, 16],
) -> None:
    """Unaligned 16-byte store. SAFETY: caller guarantees 16 bytes of
    valid writable memory at `dst`.
    """
    dst.store[width=16](0, v)


@always_inline
def _load_u8x16_unaligned[o: Origin[mut=True]](
    src: UnsafePointer[UInt8, o],
) -> SIMD[DType.uint8, 16]:
    """Unaligned 16-byte load (mutable-origin source). SAFETY: caller
    guarantees 16 bytes of valid readable memory at `src`.
    """
    return src.load[width=16](0)


@always_inline
def _scalar_pattern_copy[o: Origin[mut=True]](
    out_buf: UnsafePointer[UInt8, o],
    out_pos: Int,
    length: Int,
    offset: Int,
) -> None:
    """Scalar reference / fallback: byte-by-byte copy honoring the
    cyclic overlap when `offset < length`. Correct for any (offset >= 1,
    length >= 0).
    """
    for k in range(length):
        out_buf.store[width=1](
            out_pos + k, out_buf.load[width=1](out_pos - offset + k)
        )


@always_inline
def _neon_pattern_block[base: Int](
    table: SIMD[DType.uint8, 16],
    offset: Int,
) -> SIMD[DType.uint8, 16]:
    """Dispatch on runtime `offset` (1..15) to the comptime
    `_cyclic_mask_16[period, base]` and emit one `tbl.16b` per block.

    `base` is the byte position of the FIRST lane of this output block
    relative to `out_pos`. Block 0 starts at base=0, block 1 at base=16,
    etc. The cyclic mask values shift by `base mod period` across blocks
    so each block can read from the SAME 16-byte source window (the
    bytes immediately before `out_pos`).
    """
    if offset == 1:
        return _neon_tbl_16b(table, _cyclic_mask_16[1, base]())
    elif offset == 2:
        return _neon_tbl_16b(table, _cyclic_mask_16[2, base]())
    elif offset == 3:
        return _neon_tbl_16b(table, _cyclic_mask_16[3, base]())
    elif offset == 4:
        return _neon_tbl_16b(table, _cyclic_mask_16[4, base]())
    elif offset == 5:
        return _neon_tbl_16b(table, _cyclic_mask_16[5, base]())
    elif offset == 6:
        return _neon_tbl_16b(table, _cyclic_mask_16[6, base]())
    elif offset == 7:
        return _neon_tbl_16b(table, _cyclic_mask_16[7, base]())
    elif offset == 8:
        return _neon_tbl_16b(table, _cyclic_mask_16[8, base]())
    elif offset == 9:
        return _neon_tbl_16b(table, _cyclic_mask_16[9, base]())
    elif offset == 10:
        return _neon_tbl_16b(table, _cyclic_mask_16[10, base]())
    elif offset == 11:
        return _neon_tbl_16b(table, _cyclic_mask_16[11, base]())
    elif offset == 12:
        return _neon_tbl_16b(table, _cyclic_mask_16[12, base]())
    elif offset == 13:
        return _neon_tbl_16b(table, _cyclic_mask_16[13, base]())
    elif offset == 14:
        return _neon_tbl_16b(table, _cyclic_mask_16[14, base]())
    else:  # 15
        return _neon_tbl_16b(table, _cyclic_mask_16[15, base]())


# =============================================================================
# Public API
# =============================================================================


def pattern_copy_extend[
    out_origin: Origin[mut=True],
](
    out_span: Span[UInt8, out_origin],
    out_pos: Int,
    length: Int,
    offset: Int,
) -> None:
    """Cyclic byte-pattern extend: `out[out_pos+k] = out[out_pos-offset+k]`
    for `k` in `[0, length)`. The semantics handle the cyclic overlap
    when `offset < length`: each output byte is computed in order, so
    earlier output bytes feed into later read positions (the LZ77
    back-reference shape).

    Slop-buffer contract: on NEON with `offset < 16` this function MAY
    write past `out_pos + length` up to the next 16-byte block boundary.
    Callers must reserve at least 16 bytes of valid writable slop past
    the promised end. The over-written bytes are deterministic (extend
    the cyclic pattern); callers should truncate to `length` at return.

    Args:
        out_span: Mutable Span of UInt8 bytes. The function operates
            in-place on this span; the source bytes `[out_pos-offset,
            out_pos)` must already be initialized.
        out_pos: Output position (byte index) where the new bytes begin.
            Must satisfy `out_pos >= offset` (the read window is
            `[out_pos-offset, out_pos)`).
        length: Number of bytes to extend. Must be >= 0; zero is a no-op.
        offset: Lookback distance. Must be >= 1.

    Architecture dispatch:
        - ARM64 + `offset < 16`: NEON `tbl.16b` cyclic shuffle (up to
          4 × 16-byte output blocks for `length <= 64`).
        - ARM64 + `offset >= 16`: NEON `ld1`/`st1` 16-byte unrolled loop.
        - x86_64 (any offset): scalar byte-by-byte (no AVX-512 path yet).
    """
    if length == 0:
        return
    var out_ptr = out_span.unsafe_ptr()

    comptime if not CompilationTarget.is_x86():
        if offset >= 16:
            # No overlap: plain 16-byte loads + stores.
            var written = 0
            while written < length:
                var src = _load_u8x16_unaligned(
                    out_ptr + (out_pos - offset + written)
                )
                _store_u8x16_unaligned(
                    out_ptr + (out_pos + written), src
                )
                written += 16
        else:
            # Overlap: load the 16-byte source window once, emit up to
            # 4 × 16-byte output blocks via cyclic `tbl.16b`.
            var table = _load_u8x16_unaligned(
                out_ptr + (out_pos - offset)
            )
            var b0 = _neon_pattern_block[0](table, offset)
            _store_u8x16_unaligned(out_ptr + out_pos, b0)
            if length > 16:
                var b1 = _neon_pattern_block[16](table, offset)
                _store_u8x16_unaligned(out_ptr + out_pos + 16, b1)
            if length > 32:
                var b2 = _neon_pattern_block[32](table, offset)
                _store_u8x16_unaligned(out_ptr + out_pos + 32, b2)
            if length > 48:
                var b3 = _neon_pattern_block[48](table, offset)
                _store_u8x16_unaligned(out_ptr + out_pos + 48, b3)
    else:
        # x86 fallback: scalar. An AVX-512 vpermb-based fast path is not
        # implemented.
        _scalar_pattern_copy(out_ptr, out_pos, length, offset)
