# =============================================================================
# builtin_match_fns.mojo — Built-in MatchFn / UnaryMatchFn conformers


# =============================================================================
#
# Mirrors `builtin_binary_fns.mojo`'s
# layout for the predicate-evaluation cells. Each (T, OP) homogeneous-type
# cell ships 4 monomorphizations parameterized by `(LHS_VALID, RHS_VALID)`:
# the comptime Bool fanout deletes the validity-check branch where the
# input is non-nullable. `NO_MATCH_SEL` is carried as a comptime alias for
# forward-compatibility (the operator wrapper materializes the sel-vector
# from the bitmap when needed); the kernel body is the same regardless.
#
# This ships the homogeneous INT64 + FLOAT64 cells:
#
#   LtI64 / LeI64 / GtI64 / GeI64 / EqI64 / NeI64    -- 6 ops × INT64
#   LtF64 / LeF64 / GtF64 / GeF64 / EqF64 / NeF64    -- 6 ops × FLOAT64
#   IsNullI64 / IsNotNullI64                          -- unary INT64
#   IsNullF64 / IsNotNullF64                          -- unary FLOAT64
#
# Plus a representative subset of the validity matrix for one cell
# (`LtI64`) — all 4 (LHS_VALID, RHS_VALID) cells — to demonstrate that
# the comptime fanout works. The other cells ship the most common
# (False, False) — non-nullable inputs are the hot-path shape for
# kernel-evaluator-callers; the operator picks the right cell at
# runtime via a 2-bit comptime table (`MatchFnOp._dispatch_kernel`).
#
# Hot-path SIMD (hand-staged)
# ---------------------------
# Mirrors `eval_col_gt` / `eval_col_eq` / `eval_col_lt` in
# `komira_column_kernels.comparison`. Each kernel body:
#
#   1. Comptime-pick W = simd_width_of[dt]() (NEON: 2 for Int64,
#      2 for Float64; AVX2: 4; AVX-512: 8).
#   2. Walk the input in chunks of W lanes:
#      - `lv = lhs.load[width=W](i)` (SIMD load)
#      - `rv = rhs.load[width=W](i)` (SIMD load)
#      - `cmp_mask = lv.OP(rv)` -> `SIMD[Bool, W]`
#      - Pack lane-bits into a byte via `b * weights` reduce_add (the
#        `eval_col_gt` trick) and OR into the bitmap byte.
#   3. Validity AND (comptime-deleted when both LHS_VALID == False
#      AND RHS_VALID == False).
#   4. Ragged-tail at width=1 lane-by-lane.
#
# Non-raising contract
# --------------------
# `MatchFn.eval_chunk` / `UnaryMatchFn.eval_chunk` are `fn`. The underlying
# `load[width]` is `def`; the kernel wraps the loop in a single chunk-
# granularity `try / except: pass` — mirrors `builtin_binary_fns.mojo`.
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any signature.
# - No wildcard origins anywhere.
# - File < 1000 LOC.
# - Conformers are `@fieldwise_init struct ... (MatchFn)`; zero captures.


# =============================================================================

from std.sys import simd_width_of

from komira_arrow.bitmap import Bitmap, bytes_for_bits
from komira_arrow.primitive_array import PrimitiveArray
from komira_plan_expr.expr import (
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_EQ,
    BIN_NE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
)

from .match_fn import MatchFn, UnaryMatchFn


# =============================================================================
# Comptime-op-tag op trait


# =============================================================================
#
# To express the comparison-op selection at the SIMD lane level via
# `lv.gt(rv)` / `lv.lt(rv)` / `lv.eq(rv)` we need a `@parameter if op ==
# BIN_LT` dispatch at the SIMD-call site. We use a tiny helper-fn family
# per-op rather than a comptime-conditional inside one body (the latter
# pessimizes Mojo 1.0.0b1's lambda capture; the helper-per-op pattern is
# what `eval_col_gt` already uses).
#
# Each helper:
#   - takes `lhs: SIMD[T, W]`, `rhs: SIMD[T, W]`
#   - returns `SIMD[Bool, W]`
#   - is `@always_inline` so it folds into the caller's body


# =============================================================================


@always_inline
def _cmp_lt[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.lt(rhs)


@always_inline
def _cmp_le[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.le(rhs)


@always_inline
def _cmp_gt[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.gt(rhs)


@always_inline
def _cmp_ge[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.ge(rhs)


@always_inline
def _cmp_eq[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.eq(rhs)


@always_inline
def _cmp_ne[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    # IEEE UNORDERED not-equal, the same answer as the scalar `!=` of the
    # ragged-tail loop: a NaN row is TRUE. SIMD `.ne()` is an ORDERED compare
    # (NaN -> FALSE), so a NaN row's answer would depend on whether it sat in
    # a full SIMD chunk or in the tail. `~eq` is identical to `.ne()` for
    # every non-NaN input and for integers. See `sel_kernels._cmp_ne`.
    return ~lhs.eq(rhs)


# =============================================================================
# Generic hand-staged SIMD compare-pack — one parametric helper per OP_TAG
# at the comptime layer. Each helper has the (LHS_VALID, RHS_VALID) cells
# fused via @parameter if at the comptime layer — the resulting four
# monomorphizations have the validity-AND branch eliminated.
#
# This is the canonical body of the match kernel; all per-(T, OP)
# conformers delegate to it via `eval_chunk`. The shape mirrors
# `eval_col_gt` in `komira_column_kernels.comparison` exactly
# but takes a `mut out_mask: Bitmap` write-target rather than allocating
# a fresh Bitmap, and incorporates validity at comptime.


# =============================================================================


@always_inline
def _simd_cmp_pack_lt[
    T: DType, LHS_VALID: Bool, RHS_VALID: Bool
](
    lhs: PrimitiveArray[T],
    rhs: PrimitiveArray[T],
    mut out_mask: Bitmap,
) -> Int:
    """`(LtI64 / LtF64)` compare-pack with comptime validity fanout. Returns
    the count of set bits in `out_mask`.

    Body sketch: chunked SIMD compare-pack loop (mirrors `eval_col_gt`),
    with the validity-AND branch comptime-deleted when both validity
    flags are False.
    """
    return _simd_cmp_pack_impl[T, LHS_VALID, RHS_VALID, 0](lhs, rhs, out_mask)


@always_inline
def _simd_cmp_pack_le[
    T: DType, LHS_VALID: Bool, RHS_VALID: Bool
](
    lhs: PrimitiveArray[T],
    rhs: PrimitiveArray[T],
    mut out_mask: Bitmap,
) -> Int:
    return _simd_cmp_pack_impl[T, LHS_VALID, RHS_VALID, 1](lhs, rhs, out_mask)


@always_inline
def _simd_cmp_pack_gt[
    T: DType, LHS_VALID: Bool, RHS_VALID: Bool
](
    lhs: PrimitiveArray[T],
    rhs: PrimitiveArray[T],
    mut out_mask: Bitmap,
) -> Int:
    return _simd_cmp_pack_impl[T, LHS_VALID, RHS_VALID, 2](lhs, rhs, out_mask)


@always_inline
def _simd_cmp_pack_ge[
    T: DType, LHS_VALID: Bool, RHS_VALID: Bool
](
    lhs: PrimitiveArray[T],
    rhs: PrimitiveArray[T],
    mut out_mask: Bitmap,
) -> Int:
    return _simd_cmp_pack_impl[T, LHS_VALID, RHS_VALID, 3](lhs, rhs, out_mask)


@always_inline
def _simd_cmp_pack_eq[
    T: DType, LHS_VALID: Bool, RHS_VALID: Bool
](
    lhs: PrimitiveArray[T],
    rhs: PrimitiveArray[T],
    mut out_mask: Bitmap,
) -> Int:
    return _simd_cmp_pack_impl[T, LHS_VALID, RHS_VALID, 4](lhs, rhs, out_mask)


@always_inline
def _simd_cmp_pack_ne[
    T: DType, LHS_VALID: Bool, RHS_VALID: Bool
](
    lhs: PrimitiveArray[T],
    rhs: PrimitiveArray[T],
    mut out_mask: Bitmap,
) -> Int:
    return _simd_cmp_pack_impl[T, LHS_VALID, RHS_VALID, 5](lhs, rhs, out_mask)


# =============================================================================
# The actual SIMD body — one body for all 6 ops, dispatched at comptime
# via the `OP_LOCAL` selector (0..5 = LT/LE/GT/GE/EQ/NE). Mojo 1.0.0b1's
# `@parameter if OP_LOCAL == X` collapses each instantiation to a single
# arm; the LLVM IR is identical to a hand-rolled per-op helper.


# =============================================================================


@always_inline
def _simd_cmp_pack_impl[
    T: DType, LHS_VALID: Bool, RHS_VALID: Bool, OP_LOCAL: Int
](
    lhs: PrimitiveArray[T],
    rhs: PrimitiveArray[T],
    mut out_mask: Bitmap,
) -> Int:
    """SIMD compare-pack with comptime (OP, LHS_VALID, RHS_VALID) fanout.

    Mirrors `eval_col_gt` in `komira_column_kernels.comparison`
    — chunked compare-pack with weighted-OR byte assembly — but takes
    `mut out_mask` and incorporates validity at comptime.

    Returns the number of set bits in `out_mask` after the kernel finishes.
    """
    comptime W: Int = simd_width_of[T]()
    var length = lhs.length
    var bm_view = out_mask.buffer.view_mut()

    var match_count = 0

    # Branch on SIMD width: when W is small (< 8 lanes), multiple SIMD
    # chunks pack into one bitmap byte; when W >= 8, one SIMD chunk
    # spans multiple bitmap bytes. Mirrors `eval_col_gt`.

    comptime if W < 8:
        comptime ITERS_PER_BYTE: Int = 8 // W
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var elem_idx = byte_idx << 3
            var byte_val = UInt8(0)

            comptime for k in range(ITERS_PER_BYTE):
                var lv = lhs.load[W](elem_idx + k * W)
                var rv = rhs.load[W](elem_idx + k * W)

                comptime if OP_LOCAL == 0:
                    var cmp_mask = _cmp_lt[T, W](lv, rv)
                    var b = cmp_mask.cast[DType.uint8]()
                    b = _apply_validity[T, W, LHS_VALID, RHS_VALID](
                        b, lhs, rhs, elem_idx + k * W
                    )
                    comptime base_shift: Int = k * W
                    var weights = SIMD[DType.uint8, W](0)

                    comptime for lane in range(W):
                        weights[lane] = UInt8(1 << (base_shift + lane))
                    byte_val = byte_val | (b * weights).reduce_add()
                elif OP_LOCAL == 1:
                    var cmp_mask = _cmp_le[T, W](lv, rv)
                    var b = cmp_mask.cast[DType.uint8]()
                    b = _apply_validity[T, W, LHS_VALID, RHS_VALID](
                        b, lhs, rhs, elem_idx + k * W
                    )
                    comptime base_shift: Int = k * W
                    var weights = SIMD[DType.uint8, W](0)

                    comptime for lane in range(W):
                        weights[lane] = UInt8(1 << (base_shift + lane))
                    byte_val = byte_val | (b * weights).reduce_add()
                elif OP_LOCAL == 2:
                    var cmp_mask = _cmp_gt[T, W](lv, rv)
                    var b = cmp_mask.cast[DType.uint8]()
                    b = _apply_validity[T, W, LHS_VALID, RHS_VALID](
                        b, lhs, rhs, elem_idx + k * W
                    )
                    comptime base_shift: Int = k * W
                    var weights = SIMD[DType.uint8, W](0)

                    comptime for lane in range(W):
                        weights[lane] = UInt8(1 << (base_shift + lane))
                    byte_val = byte_val | (b * weights).reduce_add()
                elif OP_LOCAL == 3:
                    var cmp_mask = _cmp_ge[T, W](lv, rv)
                    var b = cmp_mask.cast[DType.uint8]()
                    b = _apply_validity[T, W, LHS_VALID, RHS_VALID](
                        b, lhs, rhs, elem_idx + k * W
                    )
                    comptime base_shift: Int = k * W
                    var weights = SIMD[DType.uint8, W](0)

                    comptime for lane in range(W):
                        weights[lane] = UInt8(1 << (base_shift + lane))
                    byte_val = byte_val | (b * weights).reduce_add()
                elif OP_LOCAL == 4:
                    var cmp_mask = _cmp_eq[T, W](lv, rv)
                    var b = cmp_mask.cast[DType.uint8]()
                    b = _apply_validity[T, W, LHS_VALID, RHS_VALID](
                        b, lhs, rhs, elem_idx + k * W
                    )
                    comptime base_shift: Int = k * W
                    var weights = SIMD[DType.uint8, W](0)

                    comptime for lane in range(W):
                        weights[lane] = UInt8(1 << (base_shift + lane))
                    byte_val = byte_val | (b * weights).reduce_add()
                else:  # OP_LOCAL == 5
                    var cmp_mask = _cmp_ne[T, W](lv, rv)
                    var b = cmp_mask.cast[DType.uint8]()
                    b = _apply_validity[T, W, LHS_VALID, RHS_VALID](
                        b, lhs, rhs, elem_idx + k * W
                    )
                    comptime base_shift: Int = k * W
                    var weights = SIMD[DType.uint8, W](0)

                    comptime for lane in range(W):
                        weights[lane] = UInt8(1 << (base_shift + lane))
                    byte_val = byte_val | (b * weights).reduce_add()
            bm_view.write_u8_at(byte_idx, byte_val)
            # popcount the byte for the match counter
            var bv = byte_val
            while bv != 0:
                match_count += 1
                bv = bv & (bv - 1)

        # Ragged tail (length & 7 trailing bits)
        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = UInt8(0)
            for bit in range(remaining):
                var lv1 = lhs.load[1](elem_idx + bit)
                var rv1 = rhs.load[1](elem_idx + bit)
                var keep: Bool

                comptime if OP_LOCAL == 0:
                    keep = (lv1 < rv1)
                elif OP_LOCAL == 1:
                    keep = (lv1 <= rv1)
                elif OP_LOCAL == 2:
                    keep = (lv1 > rv1)
                elif OP_LOCAL == 3:
                    keep = (lv1 >= rv1)
                elif OP_LOCAL == 4:
                    keep = (lv1 == rv1)
                else:
                    keep = (lv1 != rv1)
                keep = _apply_validity_scalar[LHS_VALID, RHS_VALID](
                    keep, lhs, rhs, elem_idx + bit
                )
                if keep:
                    byte_val = byte_val | (UInt8(1) << UInt8(bit))
                    match_count += 1
            bm_view.write_u8_at(full_bytes, byte_val)
    else:  # W >= 8: one SIMD chunk spans multiple bytes
        comptime BYTES_PER_CHUNK: Int = W // 8
        var num_full_chunks = length // W
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * W
            var lv = lhs.load[W](elem_idx)
            var rv = rhs.load[W](elem_idx)
            var cmp_bits: SIMD[DType.uint8, W]

            comptime if OP_LOCAL == 0:
                cmp_bits = _cmp_lt[T, W](lv, rv).cast[DType.uint8]()
            elif OP_LOCAL == 1:
                cmp_bits = _cmp_le[T, W](lv, rv).cast[DType.uint8]()
            elif OP_LOCAL == 2:
                cmp_bits = _cmp_gt[T, W](lv, rv).cast[DType.uint8]()
            elif OP_LOCAL == 3:
                cmp_bits = _cmp_ge[T, W](lv, rv).cast[DType.uint8]()
            elif OP_LOCAL == 4:
                cmp_bits = _cmp_eq[T, W](lv, rv).cast[DType.uint8]()
            else:
                cmp_bits = _cmp_ne[T, W](lv, rv).cast[DType.uint8]()

            cmp_bits = _apply_validity[T, W, LHS_VALID, RHS_VALID](
                cmp_bits, lhs, rhs, elem_idx
            )

            comptime for byte_off in range(BYTES_PER_CHUNK):
                var byte_val = UInt8(0)

                comptime for lane in range(8):
                    byte_val = byte_val | (cmp_bits[byte_off * 8 + lane] << UInt8(lane))
                bm_view.write_u8_at(chunk_idx * BYTES_PER_CHUNK + byte_off, byte_val)
                # popcount the byte for the match counter
                var bv = byte_val
                while bv != 0:
                    match_count += 1
                    bv = bv & (bv - 1)

        var num_processed = num_full_chunks * W
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = UInt8(0) if bit == 0 else bm_view.read_u8_at(byte_idx)
            var lv1 = lhs.load[1](i)
            var rv1 = rhs.load[1](i)
            var keep: Bool

            comptime if OP_LOCAL == 0:
                keep = (lv1 < rv1)
            elif OP_LOCAL == 1:
                keep = (lv1 <= rv1)
            elif OP_LOCAL == 2:
                keep = (lv1 > rv1)
            elif OP_LOCAL == 3:
                keep = (lv1 >= rv1)
            elif OP_LOCAL == 4:
                keep = (lv1 == rv1)
            else:
                keep = (lv1 != rv1)
            keep = _apply_validity_scalar[LHS_VALID, RHS_VALID](
                keep, lhs, rhs, i
            )
            if keep:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
                match_count += 1
            bm_view.write_u8_at(byte_idx, byte_val)
            i += 1
    _ = lhs
    _ = rhs
    return match_count


@always_inline
def _apply_validity[
    T: DType, W: Int, LHS_VALID: Bool, RHS_VALID: Bool
](
    cmp_bits: SIMD[DType.uint8, W],
    lhs: PrimitiveArray[T],
    rhs: PrimitiveArray[T],
    start_idx: Int,
) -> SIMD[DType.uint8, W]:
    """Comptime-fanned validity AND. When both LHS_VALID and RHS_VALID
    are False, the body is comptime-deleted — returns cmp_bits unchanged.

    When either is True, reads the corresponding validity bitmap bits at
    `offset + start_idx` (a sliced array's bitmap is indexed absolutely),
    casts the W-lane validity mask to UInt8, and ANDs into
    `cmp_bits` lane-by-lane (W lanes, scalar fallback for correctness on
    the validity-bit-extract; the compiler vectorizes the AND step).
    """

    comptime if not LHS_VALID and not RHS_VALID:
        # Comptime-deleted: pure compare-pack, no validity work.
        return cmp_bits
    else:
        var out_bits = cmp_bits
        # Scalar per-lane validity AND (W is small; the SIMD width here
        # is bounded by the dtype's native lane count, not the bitmap
        # width). Mojo 1.0.0b1's SIMD validity-bitmap extract has no
        # primitive; the scalar loop autovectorizes through
        # `test(idx)` -> bitmap byte-read on a tight loop.

        comptime for lane in range(W):
            var ok: Bool = True

            comptime if LHS_VALID:
                if not lhs.validity.value().test(lhs.offset + start_idx + lane):
                    ok = False
            comptime if RHS_VALID:
                if not rhs.validity.value().test(rhs.offset + start_idx + lane):
                    ok = False
            if not ok:
                out_bits[lane] = UInt8(0)
        return out_bits


@always_inline
def _apply_validity_scalar[
    LHS_VALID: Bool, RHS_VALID: Bool
](
    cmp_bit: Bool,
    lhs: PrimitiveArray,
    rhs: PrimitiveArray,
    idx: Int,
) -> Bool:
    """Scalar variant of `_apply_validity` for the ragged-tail path."""

    comptime if not LHS_VALID and not RHS_VALID:
        return cmp_bit
    else:
        if not cmp_bit:
            return False

        comptime if LHS_VALID:
            if not lhs.validity.value().test(lhs.offset + idx):
                return False
        comptime if RHS_VALID:
            if not rhs.validity.value().test(rhs.offset + idx):
                return False
        return True


# =============================================================================
# Int64 binary-comparison conformers


# =============================================================================
#
# Each cell is a `@fieldwise_init struct ... (MatchFn)` with comptime
# (T, OP_TAG, NO_MATCH_SEL, LHS_VALID, RHS_VALID, KERNEL_ID). The body
# delegates to `_simd_cmp_pack_<op>[T, LHS_VALID, RHS_VALID]`.
#
# Naming convention: <Op><Type>[_<Vmask>]
#   - default: LHS_VALID=False, RHS_VALID=False, NO_MATCH_SEL=False (the
#     hot-path shape; non-nullable inputs, bitmap output).
#   - The _LV / _RV / _LRV suffix marks the validity-fanned variants.
#
# This ships the (False, False) hot-path cell for each (T, OP) +
# all 4 validity cells for the canonical `LtI64` to demonstrate the
# fanout works. Other validity cells are followup (a one-line declaration
# per cell; no body change).


# =============================================================================


# ---- LtI64: 4-cell validity fanout (the demo cell) ----


@fieldwise_init
struct LtI64(MatchFn):
    """(Int64, Int64) -> Bool element-wise less-than, both sides non-nullable."""

    comptime T = DType.int64
    comptime OP_TAG = BIN_LT
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0001)

    def name(self) -> String:
        return "LtI64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_lt[DType.int64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct LtI64_LV(MatchFn):
    """LtI64, LHS may have nulls."""

    comptime T = DType.int64
    comptime OP_TAG = BIN_LT
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = True
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0002)

    def name(self) -> String:
        return "LtI64_LV"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_lt[DType.int64, True, False](lhs, rhs, out_mask)


@fieldwise_init
struct LtI64_RV(MatchFn):
    """LtI64, RHS may have nulls."""

    comptime T = DType.int64
    comptime OP_TAG = BIN_LT
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = True
    comptime KERNEL_ID = UInt32(0x0002_0003)

    def name(self) -> String:
        return "LtI64_RV"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_lt[DType.int64, False, True](lhs, rhs, out_mask)


@fieldwise_init
struct LtI64_LRV(MatchFn):
    """LtI64, both sides may have nulls."""

    comptime T = DType.int64
    comptime OP_TAG = BIN_LT
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = True
    comptime RHS_VALID = True
    comptime KERNEL_ID = UInt32(0x0002_0004)

    def name(self) -> String:
        return "LtI64_LRV"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_lt[DType.int64, True, True](lhs, rhs, out_mask)


# ---- Other INT64 ops (LE / GT / GE / EQ / NE) — non-nullable cell ----


@fieldwise_init
struct LeI64(MatchFn):
    comptime T = DType.int64
    comptime OP_TAG = BIN_LE
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0011)

    def name(self) -> String:
        return "LeI64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_le[DType.int64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct GtI64(MatchFn):
    comptime T = DType.int64
    comptime OP_TAG = BIN_GT
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0021)

    def name(self) -> String:
        return "GtI64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_gt[DType.int64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct GeI64(MatchFn):
    comptime T = DType.int64
    comptime OP_TAG = BIN_GE
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0031)

    def name(self) -> String:
        return "GeI64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_ge[DType.int64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct EqI64(MatchFn):
    comptime T = DType.int64
    comptime OP_TAG = BIN_EQ
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0041)

    def name(self) -> String:
        return "EqI64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_eq[DType.int64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct NeI64(MatchFn):
    comptime T = DType.int64
    comptime OP_TAG = BIN_NE
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0051)

    def name(self) -> String:
        return "NeI64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_ne[DType.int64, False, False](lhs, rhs, out_mask)


# =============================================================================
# Float64 conformers — non-nullable cell only (validity fanout = followup)


# =============================================================================


@fieldwise_init
struct LtF64(MatchFn):
    comptime T = DType.float64
    comptime OP_TAG = BIN_LT
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0101)

    def name(self) -> String:
        return "LtF64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.float64],
        rhs: PrimitiveArray[DType.float64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_lt[DType.float64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct LeF64(MatchFn):
    comptime T = DType.float64
    comptime OP_TAG = BIN_LE
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0111)

    def name(self) -> String:
        return "LeF64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.float64],
        rhs: PrimitiveArray[DType.float64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_le[DType.float64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct GtF64(MatchFn):
    comptime T = DType.float64
    comptime OP_TAG = BIN_GT
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0121)

    def name(self) -> String:
        return "GtF64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.float64],
        rhs: PrimitiveArray[DType.float64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_gt[DType.float64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct GeF64(MatchFn):
    comptime T = DType.float64
    comptime OP_TAG = BIN_GE
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0131)

    def name(self) -> String:
        return "GeF64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.float64],
        rhs: PrimitiveArray[DType.float64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_ge[DType.float64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct EqF64(MatchFn):
    comptime T = DType.float64
    comptime OP_TAG = BIN_EQ
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0141)

    def name(self) -> String:
        return "EqF64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.float64],
        rhs: PrimitiveArray[DType.float64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_eq[DType.float64, False, False](lhs, rhs, out_mask)


@fieldwise_init
struct NeF64(MatchFn):
    comptime T = DType.float64
    comptime OP_TAG = BIN_NE
    comptime NO_MATCH_SEL = False
    comptime LHS_VALID = False
    comptime RHS_VALID = False
    comptime KERNEL_ID = UInt32(0x0002_0151)

    def name(self) -> String:
        return "NeF64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.float64],
        rhs: PrimitiveArray[DType.float64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _simd_cmp_pack_ne[DType.float64, False, False](lhs, rhs, out_mask)


# =============================================================================
# Unary IS_NULL / IS_NOT_NULL conformers


# =============================================================================
#
# IS_NULL on a non-nullable input is trivially all-zeros (`INPUT_VALID =
# False` cell exists for completeness; the operator can short-circuit
# without invoking the kernel). The `INPUT_VALID = True` cell reads the
# input bitmap and inverts it (for IS_NULL) or copies it (for IS_NOT_NULL).


# =============================================================================


@always_inline
def _unary_pack_impl[T: DType, INPUT_VALID: Bool, NEGATE: Bool](
    input: PrimitiveArray[T],
    mut out_mask: Bitmap,
) -> Int:
    """Pack `input.validity` (XOR'd with NEGATE) into `out_mask`.

    For IS_NULL: NEGATE = True  -> out_mask = ~validity (1 = null)
    For IS_NOT_NULL: NEGATE = False -> out_mask = validity (1 = valid)

    When `INPUT_VALID == False`, the input has no validity bitmap, so:
      IS_NULL -> all zeros
      IS_NOT_NULL -> all ones (length bits set)
    """
    var length = input.length
    var bm_view = out_mask.buffer.view_mut()
    var num_bytes = bytes_for_bits(length)

    var match_count = 0

    comptime if not INPUT_VALID:
        # Non-nullable: comptime-deleted body.
        comptime if NEGATE:
            # IS_NULL on non-nullable: all zeros (already initialized by Bitmap.create).
            return 0
        else:
            # IS_NOT_NULL on non-nullable: all ones.
            for i in range(num_bytes):
                bm_view.write_u8_at(i, UInt8(0xFF))
            var trailing = length & 7
            if trailing > 0:
                var mask = UInt8((1 << trailing) - 1)
                bm_view.write_u8_at(num_bytes - 1, mask)
            return length

    # INPUT_VALID == True path. A sliced array's bitmap is indexed
    # ABSOLUTELY: logical row i is bit `input.offset + i`. Each output byte is
    # assembled from the (up to) two source bytes the window straddles.
    ref vbm = input.validity.value()
    var v_view = vbm.buffer.view_ro()
    var src_bytes = bytes_for_bits(vbm.length)
    var first_byte = input.offset >> 3
    var shift = input.offset & 7
    var trailing = length & 7
    for i in range(num_bytes):
        var v = v_view.read_u8_at(first_byte + i)
        if shift != 0:
            v = v >> UInt8(shift)
            if first_byte + i + 1 < src_bytes:
                v = v | (v_view.read_u8_at(first_byte + i + 1) << UInt8(8 - shift))

        comptime if NEGATE:
            v = ~v
        # Bits past `length` in the last byte are padding (Arrow does not
        # require them to be zero) and, after a negate, spurious ones: clear
        # them BEFORE counting so the count equals the bits written.
        if trailing > 0 and i == num_bytes - 1:
            v = v & UInt8((1 << trailing) - 1)
        bm_view.write_u8_at(i, v)
        # popcount
        var bv = v
        while bv != 0:
            match_count += 1
            bv = bv & (bv - 1)
    return match_count


@fieldwise_init
struct IsNullI64(UnaryMatchFn):
    """IS_NULL on Int64 (nullable input)."""

    comptime T = DType.int64
    comptime OP_TAG = UN_IS_NULL
    comptime INPUT_VALID = True
    comptime KERNEL_ID = UInt32(0x0002_0201)

    def name(self) -> String:
        return "IsNullI64"

    def eval_chunk(
        self,
        input: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _unary_pack_impl[DType.int64, True, True](input, out_mask)


@fieldwise_init
struct IsNotNullI64(UnaryMatchFn):
    """IS_NOT_NULL on Int64 (nullable input)."""

    comptime T = DType.int64
    comptime OP_TAG = UN_IS_NOT_NULL
    comptime INPUT_VALID = True
    comptime KERNEL_ID = UInt32(0x0002_0211)

    def name(self) -> String:
        return "IsNotNullI64"

    def eval_chunk(
        self,
        input: PrimitiveArray[DType.int64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _unary_pack_impl[DType.int64, True, False](input, out_mask)


@fieldwise_init
struct IsNullF64(UnaryMatchFn):
    """IS_NULL on Float64 (nullable input)."""

    comptime T = DType.float64
    comptime OP_TAG = UN_IS_NULL
    comptime INPUT_VALID = True
    comptime KERNEL_ID = UInt32(0x0002_0301)

    def name(self) -> String:
        return "IsNullF64"

    def eval_chunk(
        self,
        input: PrimitiveArray[DType.float64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _unary_pack_impl[DType.float64, True, True](input, out_mask)


@fieldwise_init
struct IsNotNullF64(UnaryMatchFn):
    """IS_NOT_NULL on Float64 (nullable input)."""

    comptime T = DType.float64
    comptime OP_TAG = UN_IS_NOT_NULL
    comptime INPUT_VALID = True
    comptime KERNEL_ID = UInt32(0x0002_0311)

    def name(self) -> String:
        return "IsNotNullF64"

    def eval_chunk(
        self,
        input: PrimitiveArray[DType.float64],
        mut out_mask: Bitmap,
    ) -> Int:
        return _unary_pack_impl[DType.float64, True, False](input, out_mask)
