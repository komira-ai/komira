# =============================================================================
# BITMAP_OPS — SIMD compute kernels that consume a Bitmap as a predicate
# =============================================================================
#
# Split from bitmap.mojo because these are dtype-parametric compute kernels,
# not bitmap-on-bitmap ops. Keeps bitmap.mojo small and focused.
#
# PERF-CRITICAL: these primitives serve CASE-expression vectorization (the
# `arrow_zip::zip` shape): a SIMD mask-driven overwrite of a result buffer
# from a source buffer, which is what `select_into` provides.
#
# Why explicit SIMD: Mojo does NOT reliably auto-vectorize mask-based select
# loops; on conditional-accumulate at 50% selectivity the scalar loop is
# about 9x slower.
# =============================================================================

from std.sys import simd_width_of, size_of

from komira_buffer.heap_region import HeapRegion
from komira_buffer.aligned_buffer_trait import AlignedBufferTrait
from komira_arrow.bitmap import Bitmap


# -----------------------------------------------------------------------------
# select_into: `if mask[r]: dst[r] = src[r]` over a numeric buffer.
#
# NULL propagation is the CALLER's concern -- this kernel operates on raw
# value buffers only. For CASE evaluation the caller will separately combine
# the validity bitmaps of each branch (via Bitmap.and_ / Bitmap.and_not).
# -----------------------------------------------------------------------------
#
# SAFETY:
#   - `dst` and `src` must each hold at least `n_rows` elements of `dtype`.
#   - `dst` and `src` must NOT alias.
#   - `mask.length` must be >= n_rows (caller checks; we do NOT raise here to
#     keep the hot path branchless).
#   - Callers pass MmapAlignedBuffer refs, which pad to 64 bytes -- SIMD tail
#     reads past `n_rows` read deterministic zeros and are discarded by the
#     lane mask (non-observable). WRITES past `n_rows` land in the same
#     pad region (never read by anyone).
#
# Pattern: stride = W = simd_width_of[dtype]. For each chunk of W rows we
# construct a SIMD[DType.bool, W] from the bitmap's bit-packed bytes and
# call `bool_mask.select(src_vec, dst_vec)` then store.
#
# Bit-decode cost: W is small on NEON (e.g. 2 for Float64, 8 for Int8) so
# decoding `W` bits into a lane-bool vector is a tight unrollable loop.
# For the W-lane-per-chunk case we read `(W+7)/8` mask bytes per iteration;
# the compiler unrolls the per-lane extraction because W is comptime.
#
# Origin tracking:
#   The public API takes buffer refs rather than a wildcard-origin
#   raw-pointer pair. The MmapAlignedBuffer refs carry
#   concrete origins through `mut dst: MmapAlignedBuffer[64]` and `src:
#   MmapAlignedBuffer[64]` so the compiler tracks liveness against the
#   caller. Internal SIMD access uses MmapAlignedBuffer.load_simd /
#   store_simd by byte-offset.


def select_into[
    dtype: DType,
    B_dst: AlignedBufferTrait,
    B_src: AlignedBufferTrait,
](
    mut dst: B_dst,
    src: B_src,
    mask: Bitmap[HeapRegion],
    n_rows: Int,
):
    """For each row r in 0..n_rows, if mask.get(r) then dst[r] = src[r].

    Parameters:
        dtype: The numeric DType of the source and destination buffers.

    Args:
        dst:    Destination buffer (holds >= n_rows Scalar[dtype] slots).
                Mutated in place.
        src:    Source buffer (holds >= n_rows Scalar[dtype] slots). Read only.
        mask:   Bitmap whose bits drive the selection. mask.length >= n_rows.
        n_rows: Number of rows to process.

    SIMD pattern: stride = simd_width_of[dtype]. Unconditional SIMD load of
    `dst` and `src`, build bool mask from `ceil(W/8)` bytes of the bitmap,
    `select` fused into a single store.

    NULL propagation is NOT handled here -- caller must combine validity
    bitmaps separately (see the module docstring).
    """
    if n_rows <= 0:
        return

    comptime W: Int = simd_width_of[dtype]()
    comptime elem_size: Int = size_of[Scalar[dtype]]()

    var mask_view = mask.buffer.view_ro()

    var i = 0
    var simd_limit = (n_rows // W) * W
    while i < simd_limit:
        # Build SIMD bool mask for lanes i..i+W from the packed bitmap.
        # We unroll over lanes; W is comptime so this compiles to a fixed
        # sequence of byte-load + shift + and + insert.
        var bool_mask = SIMD[DType.bool, W](fill=False)
        comptime for lane in range(W):
            var bit_idx = i + lane
            var byte = mask_view.read_u8_at(bit_idx >> 3)
            bool_mask[lane] = (byte >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1)

        var byte_off = i * elem_size
        var dst_vec = dst.load_simd[dtype, W](byte_off)
        var src_vec = src.load_simd[dtype, W](byte_off)
        dst.store_simd[dtype, W](byte_off, bool_mask.select(src_vec, dst_vec))
        i += W

    # Scalar tail -- at most W-1 rows.
    while i < n_rows:
        var byte = mask_view.read_u8_at(i >> 3)
        if (byte >> UInt8(i & 7)) & UInt8(1) == UInt8(1):
            var v = src.get_typed[Scalar[dtype]](i)
            dst.set_typed[Scalar[dtype]](i, v)
        i += 1


# -----------------------------------------------------------------------------
# blend_into: `dst[r] = mask[r] ? then_buf[r] : else_buf[r]` for binary CASE.
#
# Sub-slot 1 of Replaces the
# 2-pass `memcpy(dst, else_buf); select_into(dst, then_buf, mask)` shape
# used by `_run_case_overlay` on the N=1 binary-CASE fast path with a
# single-pass SIMD blend.
#
# NULL propagation is the CALLER's concern; validity is merged separately
# via `bitmap_blend_into`.
# -----------------------------------------------------------------------------
#
# SAFETY:
#   - `dst`, `then_buf`, `else_buf` must each hold at least `n_rows` elements
#     of `dtype`.
#   - `dst` must NOT alias `then_buf` or `else_buf` (no overlap).
#   - `then_buf` and `else_buf` MAY be the same buffer (idempotent).
#   - `mask.length` must be >= n_rows (caller checks; not raised here to keep
#     the hot path branchless).
#   - SIMD tail reads past `n_rows` read deterministic zeros from the
#     MmapAlignedBuffer 64-byte pad; writes past `n_rows` land in the pad and
#     are never read.
#
# Pattern: stride = W = simd_width_of[dtype]. Per chunk: load `then` +
# `else`, build the W-bit bool mask, single `mask.select(t, e)` ALU op,
# store. ALU is identical to `select_into`'s `select(src, dst)`; the win
# is producing a fresh `dst` in one pass without the upfront memcpy.

def blend_into[
    dtype: DType,
    B_dst: AlignedBufferTrait,
    B_then: AlignedBufferTrait,
    B_else: AlignedBufferTrait,
](
    mut dst: B_dst,
    then_buf: B_then,
    else_buf: B_else,
    mask: Bitmap[HeapRegion],
    n_rows: Int,
):
    """For each row r in 0..n_rows, dst[r] = mask.get(r) ? then_buf[r] : else_buf[r].

    Parameters:
        dtype: The numeric DType of the source and destination buffers.

    Args:
        dst:      Destination buffer (holds >= n_rows Scalar[dtype] slots).
                  Mutated in place. Must not alias inputs.
        then_buf: Source buffer (used where mask=1).
        else_buf: Source buffer (used where mask=0).
        mask:     Bitmap whose bits drive the selection. mask.length >= n_rows.
        n_rows:   Number of rows to process.

    SIMD pattern: stride = simd_width_of[dtype]. Unconditional SIMD load
    of `then_buf` and `else_buf`, build bool mask from `ceil(W/8)` bytes
    of the bitmap, `select` fused into a single store.

    NULL propagation is NOT handled here -- caller must combine validity
    bitmaps separately (see `bitmap_blend_into`).
    """
    if n_rows <= 0:
        return

    comptime W: Int = simd_width_of[dtype]()
    comptime elem_size: Int = size_of[Scalar[dtype]]()

    var mask_view = mask.buffer.view_ro()

    var i = 0
    var simd_limit = (n_rows // W) * W
    while i < simd_limit:
        # Build SIMD bool mask for lanes i..i+W from the packed bitmap.
        # We unroll over lanes; W is comptime so this compiles to a fixed
        # sequence of byte-load + shift + and + insert.
        var bool_mask = SIMD[DType.bool, W](fill=False)
        comptime for lane in range(W):
            var bit_idx = i + lane
            var byte = mask_view.read_u8_at(bit_idx >> 3)
            bool_mask[lane] = (byte >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1)

        var byte_off = i * elem_size
        var t_vec = then_buf.load_simd[dtype, W](byte_off)
        var e_vec = else_buf.load_simd[dtype, W](byte_off)
        dst.store_simd[dtype, W](byte_off, bool_mask.select(t_vec, e_vec))
        i += W

    # Scalar tail -- at most W-1 rows.
    while i < n_rows:
        var byte = mask_view.read_u8_at(i >> 3)
        if (byte >> UInt8(i & 7)) & UInt8(1) == UInt8(1):
            var v = then_buf.get_typed[Scalar[dtype]](i)
            dst.set_typed[Scalar[dtype]](i, v)
        else:
            var v = else_buf.get_typed[Scalar[dtype]](i)
            dst.set_typed[Scalar[dtype]](i, v)
        i += 1


# -----------------------------------------------------------------------------
# bitmap_blend_into: `out_v[r] = cond[r] ? then_v[r] : else_v[r]` SIMD u64.
#
# Replaces the bytewise scalar validity-merge loop in `_run_case_overlay`
# for the binary-CASE fast path. Single SIMD pass over the packed validity
# bytes: out_v = (cond AND then_v) OR ((NOT cond) AND else_v).
# -----------------------------------------------------------------------------

def bitmap_blend_into[
    B_out: AlignedBufferTrait,
    B_cond: AlignedBufferTrait,
    B_then: AlignedBufferTrait,
    B_else: AlignedBufferTrait,
](
    mut out_v: B_out,
    cond: B_cond,
    then_v: B_then,
    else_v: B_else,
    n_bits: Int,
):
    """SIMD u64-wide validity merge for binary CASE.

    out_v[r] = cond[r] ? then_v[r] : else_v[r]
            = (cond & then_v) | (~cond & else_v)

    Args:
        out_v:  Output validity buffer. Mutated in place.
        cond:   Condition bitmap buffer (drives the per-bit selection).
        then_v: THEN-branch validity buffer.
        else_v: ELSE-branch validity buffer.
        n_bits: Number of logical bits to process.

    Trailing bits in the final partial u64 (past `n_bits & 63`) are cleared
    after the merge so popcount() / test() never observe stale bits.

    SAFETY:
      - All four buffers must each hold at least `ceil(n_bits/8)` bytes.
      - `out_v` must not alias the input buffers.
      - MmapAlignedBuffer 64-byte pad makes the u64 scalar tail and the final
        byte-mask safe even when `n_bits` is not a multiple of 64.
    """
    if n_bits <= 0:
        return

    var num_bytes = (n_bits + 7) >> 3
    var full_u64 = num_bytes >> 3
    var tail_bytes = num_bytes & 7

    comptime W: Int = simd_width_of[DType.uint64]()
    var i = 0
    var simd_limit = (full_u64 // W) * W
    while i < simd_limit:
        var byte_off = i * 8
        var vc = cond.load_simd[DType.uint64, W](byte_off)
        var vt = then_v.load_simd[DType.uint64, W](byte_off)
        var ve = else_v.load_simd[DType.uint64, W](byte_off)
        out_v.store_simd[DType.uint64, W](byte_off, (vc & vt) | (~vc & ve))
        i += W

    # Scalar u64 tail
    while i < full_u64:
        var byte_off = i * 8
        var xc = cond.read_u64_le_at(byte_off)
        var xt = then_v.read_u64_le_at(byte_off)
        var xe = else_v.read_u64_le_at(byte_off)
        out_v.write_u64_le_at(byte_off, (xc & xt) | (~xc & xe))
        i += 1

    # Remaining 0..7 bytes
    if tail_bytes > 0:
        var byte_off = full_u64 << 3
        for k in range(tail_bytes):
            var yc = cond.read_u8_at(byte_off + k)
            var yt = then_v.read_u8_at(byte_off + k)
            var ye = else_v.read_u8_at(byte_off + k)
            out_v.write_u8_at(byte_off + k, (yc & yt) | (~yc & ye))

    # Zero trailing bits past n_bits in the final byte
    var trailing = n_bits & 7
    if trailing > 0 and num_bytes > 0:
        var cur = out_v.read_u8_at(num_bytes - 1)
        var keep = UInt8((1 << trailing) - 1)
        out_v.write_u8_at(num_bytes - 1, cur & keep)

    out_v.set_length(Int64(num_bytes))

