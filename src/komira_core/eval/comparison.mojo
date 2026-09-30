# =============================================================================
# SIMD Comparison Expression Evaluators
# =============================================================================
#
# Comparisons produce BooleanArray (bit-packed, Arrow-compliant) instead of
# PrimitiveArray[DType.bool] (byte-per-element). This is 8x more compact and
# matches the Arrow specification.
#
# Implementation: SIMD comparisons write packed bits directly into the output
# bitmap, avoiding the intermediate byte array and scalar bit-packing loop
# that dominated filter evaluation time.
#
# For each group of 8 elements, we accumulate comparison results into a single
# byte (LSB-first, matching Arrow bitmap convention) and write it directly.
# =============================================================================

from std.algorithm import vectorize
from std.bit import count_trailing_zeros, pop_count
from std.sys import simd_width_of

from ..arrow.primitive_array import PrimitiveArray
from ..arrow.boolean_array import BooleanArray
from ..arrow.bitmap import Bitmap, bytes_for_bits
from ..arrow.constants import SIMD_WIDTH_U8


# =============================================================================
# filter_to_indices -- pure-Mojo SIMD block-walk
# =============================================================================
# PERF-CRITICAL: bulk path is `_filter_to_indices_simd` below, which walks
# the mask 64 bits at a time with three fast paths (all-zero / all-one /
# mixed-via-ctz). Mask-to-index conversion is a large share of a
# late-materialising scan's filter time, so it is kept tight.
#
# It is pure Mojo on purpose: a C helper called through FFI from worker
# threads is exposed to allocator interactions across the language boundary
# that a pure-Mojo SIMD kernel cannot trigger.
#
# `_filter_to_indices_scalar` is kept as the correctness oracle for
# `_filter_to_indices_simd`; tests assert byte-for-byte parity.


# =============================================================================
# Internal: Direct SIMD-to-bit comparison kernel
# =============================================================================
#
# Strategy: Process elements in groups of 8 (one output byte). For each group,
# do 8 scalar load[width=1] comparisons and pack the results into a bitmap byte.
#
# WHY SCALAR AND NOT EXPLICIT SIMD:
# These width=1 loads look scalar, but LLVM auto-vectorizes them into native
# SIMD instructions for the target hardware. On ARM NEON (Float64 native
# width=2), LLVM groups pairs of comparisons into FCMP + NEON instructions.
# On x86 AVX2 (width=4) or AVX-512 (width=8), LLVM uses wider vector compares.
#
# We tried explicit SIMD[DType.float64, 8].gt() — it was 4x SLOWER on ARM
# NEON because the compiler emulated width=8 with 4 separate width=2 ops plus
# complex packing logic. The scalar unrolled pattern gives LLVM freedom to
# choose the optimal native width, which it does better than we can.
#
# RULE: Never hardcode a SIMD width larger than the hardware native width.
# Let LLVM auto-vectorize scalar patterns, or use vectorize[] with
# simd_width_of[dtype]() for explicit SIMD loops.
# =============================================================================


def _eval_cmp_gt[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column > scalar with direct bit packing.

    PERF-CRITICAL: Explicit-SIMD compare-then-bit-pack.

    The native SIMD width for `dtype` on the target CPU is W
    (= simd_width_of[dtype]). On Apple M-series NEON this is 2 for f64/i64,
    4 for f32/i32, 16 for i8. We process W elements per SIMD compare,
    accumulating exactly 8 boolean results (one output byte) across
    ceil(8/W) iterations using weighted AND+reduce.

    For the common f64/i64 case: 4 iterations of SIMD[dtype, 2].gt, each
    producing 2 mask bits, scattered by weight (bits 0-1, 2-3, 4-5, 6-7)
    into a single output byte. Mojo 0.26 lowers `SIMD[f64, 2].gt(t)` to
    NEON `fcmgt.2d` — 4 compares per byte = 2 fcmgt per byte on a single
    128-bit register, which is what DuckDB's reference ASM does.

    A scalar-unroll pattern produces scalar codegen in both Mojo and
    clang, so the compare is explicit SIMD.
    Scalar fallback: the tail loop for length & 7 leftover elements.
    """
    # The column is read through PrimitiveArray's `load[W]` element-index SIMD
    # helper (offset-aware, @always_inline); codegen is equivalent to a raw
    # typed pointer. `bm.buffer` is written through view_mut + write_u8_at.
    #
    # SIMD-width-symmetric design:
    # Native SIMD width can be wider than 8 lanes (e.g. AVX-512 int32 gives
    # `W=16`). The bitmap stores 8 bits per byte, so we comptime-branch:
    #   * W <  8 (NEON i32=4, NEON i64=2, etc): each output byte = (8 // W)
    #     SIMD compares; pack via weighted reduce.
    #   * W >= 8 (AVX-512 i32=16, AVX-512 i64=8): each SIMD compare emits
    #     (W // 8) output bytes; pack each 8-lane sub-window via weights.
    # A single shape `for k in range(8 // W)` would produce an EMPTY loop on
    # AVX-512 i32, silently writing an all-zero bitmap, and a runtime
    # `debug_assert(W <= 8 ...)` only fires in debug builds.
    var length = col.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    # Native SIMD width for this dtype.
    comptime W: Int = simd_width_of[dtype]()

    # Broadcast threshold to W-wide SIMD vector (hoisted out of the loop).
    var t_vec = SIMD[dtype, W](threshold)

    comptime if W < 8:
        # Each output byte = (8 // W) SIMD compares, weighted-pack.
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var v = col.load[W](elem_idx + k * W)
                var cmp_mask = v.gt(t_vec)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        # Tail: residual < 8 elements.
        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if col.load[1](elem_idx + bit) > threshold:
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        # W >= 8 (W in {8, 16, 32}). One SIMD compare emits W lanes ⇒
        # (W // 8) output bytes. For each 8-lane sub-window, weighted-pack
        # into a byte (weights are always [1,2,4,...,128] within the 8-lane
        # window).
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var v = col.load[W](elem_idx)
            var cmp_mask = v.gt(t_vec)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                # Pack lanes [byte_off*8 .. byte_off*8+8) into one output byte.
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        # Tail: residual elements [num_full_chunks * W, length). The
        # `length & 7` mask is INSUFFICIENT — when BYTES_PER_CHUNK > 1 the
        # residual can be up to W-1 elements (more than 7).
        var num_processed = num_full_chunks * W
        # Fill any partial bytes at the boundary.
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            # Read the existing byte (it MAY contain bits already written by
            # the chunk loop if (num_processed & 7) != 0 — only relevant when
            # length is between two chunk boundaries on an 8-misaligned
            # residual, which can't happen here since num_processed = k*W
            # and W is a multiple of 8). Safe to start fresh per byte.
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if col.load[1](i) > threshold:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    # Keepalive: prevent premature destruction of col before comparisons complete.
    _ = col
    return BooleanArray.from_bitmap(bm^)


def _eval_cmp_lt[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column < scalar with direct bit packing. See _eval_cmp_gt."""
    # Reads through `col.load[W]`. See _eval_cmp_gt for the
    # SIMD-width-symmetric design rationale.
    var length = col.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    comptime W: Int = simd_width_of[dtype]()
    var t_vec = SIMD[dtype, W](threshold)

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var v = col.load[W](elem_idx + k * W)
                var cmp_mask = v.lt(t_vec)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if col.load[1](elem_idx + bit) < threshold:
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var v = col.load[W](elem_idx)
            var cmp_mask = v.lt(t_vec)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if col.load[1](i) < threshold:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    _ = col
    return BooleanArray.from_bitmap(bm^)


def _eval_cmp_eq[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column == scalar with direct bit packing. See _eval_cmp_gt."""
    # Reads through `col.load[W]`. See _eval_cmp_gt for the
    # SIMD-width-symmetric design rationale.
    var length = col.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    comptime W: Int = simd_width_of[dtype]()
    var t_vec = SIMD[dtype, W](threshold)

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var v = col.load[W](elem_idx + k * W)
                var cmp_mask = v.eq(t_vec)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if col.load[1](elem_idx + bit) == threshold:
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var v = col.load[W](elem_idx)
            var cmp_mask = v.eq(t_vec)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if col.load[1](i) == threshold:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    _ = col
    return BooleanArray.from_bitmap(bm^)


def _eval_cmp_ne[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column != scalar with direct bit packing. See _eval_cmp_gt.

    NaN semantics — IEEE UNORDERED not-equal: `NaN != x → true`. Mojo's
    SIMD `.ne` lowers to LLVM `fcmp one` (ORDERED: NaN!=NaN→false), so we
    use `~v.eq(t)`: `NaN.eq(NaN) → false`, then `~false → true`. For non-NaN
    inputs this is bit-identical to `.ne`; for integer types the
    distinction is moot. Mirrors `sel_kernels._cmp_ne`.

    ⚠ KNOWN DIVERGENCE. DuckDB v1.5.3 returns FALSE for `NaN <> NaN`, as do
    PostgreSQL and Spark SQL. The SQL standard does not define NaN for
    approximate numerics.

    A first-class NE kernel rather than `eval_not(eval_eq[T](col, threshold))`:
    it saves one BooleanArray allocation + one full SIMD pass over the bitmap +
    one validity-bitmap deep-copy per call.
    """
    var length = col.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    comptime W: Int = simd_width_of[dtype]()
    var t_vec = SIMD[dtype, W](threshold)

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var v = col.load[W](elem_idx + k * W)
                # IEEE unordered not-equal (NOT DuckDB's; see docstring).
                var cmp_mask = ~v.eq(t_vec)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if not (col.load[1](elem_idx + bit) == threshold):
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var v = col.load[W](elem_idx)
            var cmp_mask = ~v.eq(t_vec)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if not (col.load[1](i) == threshold):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    _ = col
    return BooleanArray.from_bitmap(bm^)


def _eval_cmp_le[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column <= scalar with direct bit packing. See _eval_cmp_gt.

    Standard IEEE 754 semantics — NaN comparisons all-false for `<=`,
    which matches both SQL and the existing `_eval_cmp_lt`/`_eval_cmp_gt`
    treatment. `lv.le(rv)` lowers to LLVM `fcmp ole` (ordered-less-equal:
    NaN-on-either-side → false).

    A first-class LE kernel rather than
    `eval_not(eval_gt[T](col, threshold))`.
    """
    var length = col.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    comptime W: Int = simd_width_of[dtype]()
    var t_vec = SIMD[dtype, W](threshold)

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var v = col.load[W](elem_idx + k * W)
                var cmp_mask = v.le(t_vec)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if col.load[1](elem_idx + bit) <= threshold:
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var v = col.load[W](elem_idx)
            var cmp_mask = v.le(t_vec)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if col.load[1](i) <= threshold:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    _ = col
    return BooleanArray.from_bitmap(bm^)


def _eval_cmp_ge[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column >= scalar with direct bit packing. See _eval_cmp_gt.

    Standard IEEE 754 semantics — NaN comparisons all-false for `>=`.

    A first-class GE kernel rather than
    `eval_not(eval_lt[T](col, threshold))`.
    """
    var length = col.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    comptime W: Int = simd_width_of[dtype]()
    var t_vec = SIMD[dtype, W](threshold)

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var v = col.load[W](elem_idx + k * W)
                var cmp_mask = v.ge(t_vec)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if col.load[1](elem_idx + bit) >= threshold:
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var v = col.load[W](elem_idx)
            var cmp_mask = v.ge(t_vec)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if col.load[1](i) >= threshold:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    _ = col
    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# Public API
# =============================================================================


@always_inline
def eval_gt[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column > scalar. Returns BooleanArray (bit-packed).

    Writes packed bits directly — no intermediate byte array.
    """
    return _eval_cmp_gt(col, threshold)


@always_inline
def eval_lt[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column < scalar. Returns BooleanArray (bit-packed).

    Writes packed bits directly — no intermediate byte array.
    """
    return _eval_cmp_lt(col, threshold)


@always_inline
def eval_eq[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column == scalar. Returns BooleanArray (bit-packed).

    Writes packed bits directly — no intermediate byte array.
    """
    return _eval_cmp_eq(col, threshold)


@always_inline
def eval_ne[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column != scalar. Returns BooleanArray (bit-packed).

    IEEE UNORDERED not-equal: NaN != x → true (uses `~eq` internally).
    ⚠ KNOWN DIVERGENCE from DuckDB/Postgres/Spark on NaN — see the
    `_eval_cmp_ne` docstring.

    A first-class kernel rather than `eval_not(eval_eq[T](col, t))`.
    """
    return _eval_cmp_ne(col, threshold)


@always_inline
def eval_le[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column <= scalar. Returns BooleanArray (bit-packed).

    Standard IEEE semantics — NaN-on-either-side → false.

    A first-class kernel rather than `eval_not(eval_gt[T](col, t))`.
    """
    return _eval_cmp_le(col, threshold)


@always_inline
def eval_ge[dtype: DType](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Evaluate column >= scalar. Returns BooleanArray (bit-packed).

    Standard IEEE semantics — NaN-on-either-side → false.

    A first-class kernel rather than `eval_not(eval_lt[T](col, t))`.
    """
    return _eval_cmp_ge(col, threshold)


# =============================================================================
# Column-vs-column comparisons
# =============================================================================
#
# PERF-CRITICAL: These kernels enable the decorrelation optimization pattern
# (join-back + col-vs-col filter) that eliminates correlated subqueries such
# as TPC-H Q17/Q20. Without them a plan needs per-row loops over a second
# scan, which is several times slower.


def eval_col_gt[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) -> BooleanArray:
    """Evaluate left_column > right_column element-wise. Returns BooleanArray."""
    # PERF-CRITICAL: SIMD compare-pack. Same pattern as _eval_cmp_gt;
    # both sides load W elements at native width (`load[W]`), lane-wise SIMD
    # compare, weighted pack into the output byte. See _eval_cmp_gt for the
    # SIMD-width-symmetric design rationale.
    debug_assert(left.length == right.length, "eval_col_gt: length mismatch")
    var length = left.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    comptime W: Int = simd_width_of[dtype]()

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var lv = left.load[W](elem_idx + k * W)
                var rv = right.load[W](elem_idx + k * W)
                var cmp_mask = lv.gt(rv)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if left.load[1](elem_idx + bit) > right.load[1](elem_idx + bit):
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var lv = left.load[W](elem_idx)
            var rv = right.load[W](elem_idx)
            var cmp_mask = lv.gt(rv)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if left.load[1](i) > right.load[1](i):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    _ = left
    _ = right
    return BooleanArray.from_bitmap(bm^)


def eval_col_lt[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) -> BooleanArray:
    """Evaluate left_column < right_column element-wise. Returns BooleanArray."""
    return eval_col_gt[dtype](right, left)


def eval_col_ge[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) -> BooleanArray:
    """Evaluate left_column >= right_column element-wise. Returns BooleanArray.

    A first-class GE kernel rather than `eval_not(eval_col_lt[T](l, r))`.
    Saves one BooleanArray alloc + one bitmap SIMD-pass + one validity
    deep-copy per call. Reduces to `eval_col_le[T](right, left)` for
    free — `a >= b ≡ b <= a` (both follow standard IEEE 754 ordered
    comparisons; NaN-on-either-side → false on both sides).
    """
    return eval_col_le[dtype](right, left)


def eval_col_eq[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) -> BooleanArray:
    """Evaluate left_column == right_column element-wise. Returns BooleanArray.

    PERF-CRITICAL: SIMD compare-pack. See eval_col_gt for the
    SIMD-width-symmetric design rationale.
    """
    # Reads through `load[W]`.
    debug_assert(left.length == right.length, "eval_col_eq: length mismatch")
    var length = left.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    comptime W: Int = simd_width_of[dtype]()

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var lv = left.load[W](elem_idx + k * W)
                var rv = right.load[W](elem_idx + k * W)
                var cmp_mask = lv.eq(rv)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if left.load[1](elem_idx + bit) == right.load[1](elem_idx + bit):
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var lv = left.load[W](elem_idx)
            var rv = right.load[W](elem_idx)
            var cmp_mask = lv.eq(rv)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if left.load[1](i) == right.load[1](i):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    _ = left
    _ = right
    return BooleanArray.from_bitmap(bm^)


def eval_col_ne[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) -> BooleanArray:
    """Evaluate left_column != right_column element-wise. Returns BooleanArray.

    IEEE UNORDERED not-equal: NaN != x → true. Uses `~lv.eq(rv)` (Mojo's
    `.ne` lowers to LLVM `fcmp one`, the ORDERED form). For non-NaN inputs
    this is bit-identical to `.ne`; for integer types the distinction is
    moot. ⚠ KNOWN DIVERGENCE from DuckDB/Postgres/Spark on NaN — see the
    `_eval_cmp_ne` docstring.

    A first-class NE kernel rather than `eval_not(eval_col_eq[T](l, r))`.
    Saves one BooleanArray alloc + one bitmap SIMD-pass + one validity
    deep-copy per call.
    """
    debug_assert(left.length == right.length, "eval_col_ne: length mismatch")
    var length = left.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    comptime W: Int = simd_width_of[dtype]()

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var lv = left.load[W](elem_idx + k * W)
                var rv = right.load[W](elem_idx + k * W)
                # IEEE unordered not-equal (NOT DuckDB's; see docstring).
                var cmp_mask = ~lv.eq(rv)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if not (left.load[1](elem_idx + bit) == right.load[1](elem_idx + bit)):
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var lv = left.load[W](elem_idx)
            var rv = right.load[W](elem_idx)
            var cmp_mask = ~lv.eq(rv)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if not (left.load[1](i) == right.load[1](i)):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    _ = left
    _ = right
    return BooleanArray.from_bitmap(bm^)


def eval_col_le[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) -> BooleanArray:
    """Evaluate left_column <= right_column element-wise. Returns BooleanArray.

    Standard IEEE 754 ordered comparison — NaN-on-either-side → false.
    `lv.le(rv)` lowers to LLVM `fcmp ole`.

    A first-class LE kernel rather than `eval_not(eval_col_gt[T](l, r))`.
    Saves one BooleanArray alloc + one bitmap SIMD-pass + one validity
    deep-copy per call. Note that `eval_col_ge[T](l, r) ≡ eval_col_le[T]
    (r, l)` (one-line wrapper above) so this is the load-bearing
    implementation for both LE and GE.
    """
    debug_assert(left.length == right.length, "eval_col_le: length mismatch")
    var length = left.length
    var bm = Bitmap.create(length)
    var bm_view = bm.buffer.view_mut()

    comptime W: Int = simd_width_of[dtype]()

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)
            comptime for k in range(ITERS_PER_BYTE):
                var lv = left.load[W](elem_idx + k * W)
                var rv = right.load[W](elem_idx + k * W)
                var cmp_mask = lv.le(rv)
                var b = cmp_mask.cast[DType.uint8]()
                comptime base_shift: Int = k * W
                var weights = SIMD[DType.uint8, W](0)
                comptime for lane in range(W):
                    weights[lane] = UInt8(1 << (base_shift + lane))
                byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)

        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                if left.load[1](elem_idx + bit) <= right.load[1](elem_idx + bit):
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(full_bytes, byte_val)
    else:
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var lv = left.load[W](elem_idx)
            var rv = right.load[W](elem_idx)
            var cmp_mask = lv.le(rv)
            var b = cmp_mask.cast[DType.uint8]()
            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)
                comptime for lane in range(8):
                    byte_val = byte_val | (b[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            if left.load[1](i) <= right.load[1](i):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1

    _ = left
    _ = right
    return BooleanArray.from_bitmap(bm^)


def filter_to_indices(mask: BooleanArray) raises -> List[Int]:
    """Convert a BooleanArray mask to a list of matching row indices.

    PERF-CRITICAL: dispatches to the SIMD-fused
    block-walk implementation `_filter_to_indices_simd` for the bulk
    path. The pure-Mojo SIMD kernel processes 64 bits per iteration
    via `load_simd[DType.uint64, 1]`, with three fast paths:
      * all-zero u64 → skip 64 indices in one branch (low selectivity)
      * all-one u64  → emit 64 contiguous indices via a ctz-free fast
                       loop (high selectivity)
      * mixed u64    → ctz-based bit-extraction loop (one append per
                       set bit, no per-bit branch)
    The kernel is pure Mojo, with no FFI helper, so it has no allocator
    interaction across a language boundary under worker-thread concurrency.
    """
    return _filter_to_indices_simd(mask)


# =============================================================================
# SIMD-fused filter_to_indices kernel (pure Mojo, no FFI)
# =============================================================================
#
# Strategy: walk the mask 64 bits at a time. Each u64 takes one of three
# fast paths:
#
#   1. AllZero (most common at low selectivity, e.g. 1% sel):
#      single `== 0` branch → skip 64 indices in one iteration.
#      The scalar path does this at byte granularity, but at low
#      selectivity ~99% of bytes are zero AND ~99% of u64s
#      are zero, so widening from 8 bits to 64 bits per branch ~8x's
#      the throughput of the skip phase.
#
#   2. AllOne (common at high selectivity, e.g. ~40% sel over
#      sorted date pages with date < cutoff):
#      emit indices `[base, base+1, ..., base+63]` via a tight
#      append loop. Critically this loop has no branch on bit value.
#
#   3. Mixed (fall-through): use `count_trailing_zeros` to extract
#      one set bit at a time. `for k in range(pop_count(word))`:
#         tz = ctz(word); indices.append(base + Int(tz)); word &= word-1.
#      One append per set bit, branch-free per bit. Beats the scalar
#      8-`if` path because the scalar path executes 8 conditional
#      branches per byte regardless of density; this path executes
#      exactly `popcount` iterations.
#
# Tail handling: bytes past the last full u64 use the scalar 8-`if`
# pattern (preserves correctness); the trailing partial byte uses
# the bit-mask loop.
#
# Output ownership: `List[Int]` returned by-value (consumes the local
# `indices`). Reservation `length * 1 / 8` is a low-density hint;
# at high selectivity the List grows up to 4x. We deliberately do NOT
# reserve `length` because that wastes ~7x at typical filter
# selectivities (1-40%). The List geometric-grow handles the high
# end correctly with one or two reallocations.
#
# Why not pre-popcount + exact reserve? `_simd_popcount_bytes` on the
# whole mask costs an extra full pass over the bitmap. At 1% sel over
# 16k rows (2k bytes) the popcount pass is ~3-5us, vs ~2us savings
# from avoiding List grow. Net loss. At 38% sel over ~1M rows (125kB)
# the popcount pass is ~30us; the List grow saves ~20us. Net loss.
# So there is no popcount pre-pass.
#
# Compiler note: this function uses one `count_trailing_zeros` per set
# bit. The Mojo stdlib lowers that to ARM `clz` on the bit-reversed
# input (NEON has no native `ctz`); LLVM auto-vectorizes the surrounding
# loop where possible.
# =============================================================================


def _filter_to_indices_simd(mask: BooleanArray) raises -> List[Int]:
    """SIMD-fused block-walk implementation of filter_to_indices.

    Walks the mask 64 bits per iteration, with all-zero / all-one
    fast paths and a ctz-based extraction for mixed u64s. Byte-tail
    and bit-tail are handled by the same scalar pattern as the
    reference path so partial-byte semantics are preserved exactly.

    Postcondition: result is byte-identical to
    `_filter_to_indices_scalar(mask)` for any well-formed BooleanArray.
    """
    var indices = List[Int]()
    var bm_view = mask.data.buffer.view_ro()
    var length = mask.length
    var full_bytes = length >> 3

    # Process 8 bytes (64 bits) at a time.
    var u64_end = full_bytes >> 3
    var u64_byte_end = u64_end << 3  # = u64_end * 8

    var u64_idx = 0
    while u64_idx < u64_end:
        var byte_off = u64_idx << 3
        var word = bm_view.read_u64_le_at(byte_off)
        if word == UInt64(0):
            # Fast path 1: 64 zero bits, skip.
            u64_idx += 1
            continue
        var base = byte_off << 3  # = u64_idx * 64
        if word == UInt64(0xFFFFFFFFFFFFFFFF):
            # Fast path 2: all 64 bits set, emit a contiguous run.
            # Loop unrolled by 8 to give LLVM a clean vectorization shape.
            for k in range(64):
                indices.append(base + k)
            u64_idx += 1
            continue
        # Fast path 3: mixed. Extract one bit per iteration via ctz.
        # Iteration count is exactly `pop_count(word)`.
        var w = word
        while w != UInt64(0):
            var tz = Int(count_trailing_zeros(w))
            indices.append(base + tz)
            # Clear lowest set bit: w &= w - 1.
            w = w & (w - UInt64(1))
        u64_idx += 1

    # Byte tail: bytes [u64_byte_end, full_bytes). Up to 7 bytes.
    # Reuses the scalar 8-`if` pattern (preserves byte-level correctness).
    for byte_idx in range(u64_byte_end, full_bytes):
        var byte_val = bm_view.read_u8_at(byte_idx)
        if byte_val == 0:
            continue
        var base = byte_idx << 3
        if byte_val & UInt8(1) != 0:
            indices.append(base)
        if byte_val & UInt8(2) != 0:
            indices.append(base + 1)
        if byte_val & UInt8(4) != 0:
            indices.append(base + 2)
        if byte_val & UInt8(8) != 0:
            indices.append(base + 3)
        if byte_val & UInt8(16) != 0:
            indices.append(base + 4)
        if byte_val & UInt8(32) != 0:
            indices.append(base + 5)
        if byte_val & UInt8(64) != 0:
            indices.append(base + 6)
        if byte_val & UInt8(128) != 0:
            indices.append(base + 7)

    # Bit tail: trailing partial byte (length % 8 bits).
    var remaining = length & 7
    if remaining > 0:
        var byte_val = bm_view.read_u8_at(full_bytes)
        var base = full_bytes << 3
        for bit in range(remaining):
            if byte_val & (UInt8(1) << UInt8(bit)) != 0:
                indices.append(base + bit)

    return indices^


def _filter_to_indices_scalar(mask: BooleanArray) raises -> List[Int]:
    """Scalar reference path for filter_to_indices — the correctness
    oracle for `_filter_to_indices_simd`.

    Tests assert
    `_filter_to_indices_simd(mask) == _filter_to_indices_scalar(mask)`
    byte-for-byte across selectivity, length, and alignment edge
    cases.
    """
    # Reads through `view_ro` + `read_u8_at`.
    var indices = List[Int]()
    var bm_view = mask.data.buffer.view_ro()
    var length = mask.length
    var full_bytes = length >> 3

    for byte_idx in range(full_bytes):
        var byte_val = bm_view.read_u8_at(byte_idx)
        if byte_val == 0:
            continue
        var base = byte_idx << 3
        if byte_val & UInt8(1) != 0:
            indices.append(base)
        if byte_val & UInt8(2) != 0:
            indices.append(base + 1)
        if byte_val & UInt8(4) != 0:
            indices.append(base + 2)
        if byte_val & UInt8(8) != 0:
            indices.append(base + 3)
        if byte_val & UInt8(16) != 0:
            indices.append(base + 4)
        if byte_val & UInt8(32) != 0:
            indices.append(base + 5)
        if byte_val & UInt8(64) != 0:
            indices.append(base + 6)
        if byte_val & UInt8(128) != 0:
            indices.append(base + 7)

    var remaining = length & 7
    if remaining > 0:
        var byte_val = bm_view.read_u8_at(full_bytes)
        var base = full_bytes << 3
        for bit in range(remaining):
            if byte_val & (UInt8(1) << UInt8(bit)) != 0:
                indices.append(base + bit)

    return indices^


# =============================================================================
# Kleene-aware column-vs-column comparisons
# =============================================================================
#
# The kernels above (eval_gt / eval_col_gt / eval_col_eq / ...) produce
# bit-packed compare-results but DROP both operands' validity bitmaps,
# returning a non-nullable BooleanArray. SQL/Arrow semantics require that
# `x > y` propagate NULL when EITHER operand is NULL.
#
# The variants below mirror `arithmetic.mojo`'s `_finish_kleene_result`
# shape: wrap the fast-path kernel, then byte-iterate to
# compute `result_valid = left.valid & right.valid` for the
# comparison case. For comparison kernels (gt/lt/eq/ge/le/ne), the
# result lane is VALID iff BOTH operand lanes are VALID — comparison
# has no value-dependent short-circuit unlike AND/OR (which carry
# the Kleene value-aware rules in arithmetic.mojo).
#
# There are THREE column-vs-column Kleene variants
# (eval_col_gt_kleene / _lt_kleene / _eq_kleene). The scalar
# (column-vs-threshold) Kleene case is handled by
# `eval_gt_nullable` in cast_null.mojo. The planner decides when to
# emit the Kleene variant vs the non-nullable fast path.
#
# Performance: the all-valid fast path is exactly the eval_col_gt
# kernel — the validity merge is gated on
# `left.validity or right.validity` so non-nullable inputs pay zero
# added cost (as in arithmetic.mojo's no-validity fast path).
# =============================================================================


@always_inline
def _read_validity_byte_pa[
    dtype: DType
](arr: PrimitiveArray[dtype], byte_idx: Int) raises -> UInt8:
    """Read validity byte `byte_idx` for `arr`; 0xFF when `arr` is
    all-valid (no bitmap).

    Adapted from arithmetic.mojo's `_validity_byte` (BooleanArray-shaped).
    Mirrors that helper's behavior for PrimitiveArray inputs.
    """
    if arr.validity:
        return arr.validity.value().buffer.read_u8_at(byte_idx)
    return UInt8(0xFF)


def _attach_cmp_kleene_validity[
    dtype: DType
](
    var result: BooleanArray,
    left: PrimitiveArray[dtype],
    right: PrimitiveArray[dtype],
) raises -> BooleanArray:
    """Attach Kleene-correct validity bitmap to a comparison result.

    Fast path: if neither operand has a validity bitmap, return the
    result unchanged (preserves the non-nullable result; as in
    arithmetic.mojo's no-validity fast path).
    """
    if not left.validity and not right.validity:
        return result^
    var length = left.length
    var num_bytes = bytes_for_bits(length)
    var vbm = Bitmap.create(length)
    for b in range(num_bytes):
        var lv = _read_validity_byte_pa[dtype](left, b)
        var rv = _read_validity_byte_pa[dtype](right, b)
        # Kleene cmp validity = AND of operand validities.
        vbm.buffer.write_u8_at(b, lv & rv)
    vbm.buffer.set_length(num_bytes)

    # Mask trailing bits in the last byte if the bit-length isn't a
    # byte multiple.
    if num_bytes > 0:
        var trailing = length & 7
        if trailing > 0:
            var tmask = UInt8((1 << trailing) - 1)
            var v = vbm.buffer.read_u8_at(num_bytes - 1)
            vbm.buffer.write_u8_at(num_bytes - 1, v & tmask)
    var nc = vbm.null_count()
    result.validity = vbm^
    result.null_count = nc
    return result^


def eval_col_gt_kleene[
    dtype: DType
](
    left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]
) raises -> BooleanArray:
    """Kleene-correct column-vs-column greater-than.

    Calls the `eval_col_gt` fast path for the bit-packed
    SIMD compare, then attaches `validity = left.validity &
    right.validity` (NULL propagates through both operands).
    """
    var result = eval_col_gt[dtype](left, right)
    return _attach_cmp_kleene_validity[dtype](result^, left, right)


def eval_col_lt_kleene[
    dtype: DType
](
    left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]
) raises -> BooleanArray:
    """Kleene-correct column-vs-column less-than.

    See `eval_col_gt_kleene` for the validity-propagation contract.
    """
    var result = eval_col_lt[dtype](left, right)
    return _attach_cmp_kleene_validity[dtype](result^, left, right)


def eval_col_eq_kleene[
    dtype: DType
](
    left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]
) raises -> BooleanArray:
    """Kleene-correct column-vs-column equals.

    See `eval_col_gt_kleene` for the validity-propagation contract.
    """
    var result = eval_col_eq[dtype](left, right)
    return _attach_cmp_kleene_validity[dtype](result^, left, right)
