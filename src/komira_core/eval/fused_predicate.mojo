# =============================================================================
# Fused multi-conjunct predicate evaluator
# =============================================================================
#
# Filters with 1-3 INT64-equality-or-range conjuncts AND-combined at parquet
# decode-time spend a large share of their time evaluating the predicate
# (TPC-H q11 / q15 / q17 shapes). Evaluated per conjunct, each conjunct
# allocates a fresh BooleanArray and runs a SIMD compare-pack, then a
# separate `eval_and` allocates another BooleanArray to combine; a
# 3-conjunct filter costs 3 BooleanArrays + 3 SIMD passes for what should
# be one fused pass.
#
# Approach: walk the column data once at byte granularity (8 elements per
# output byte) and AND the conjunct results inline before emitting the
# byte. Eliminates:
#   * (N-1) intermediate BooleanArray allocations (where N = #conjuncts)
#   * (N-1) eval_and bitmap-AND passes
#   * The corresponding bitmap memory-bandwidth overhead
#
# Supported shapes (INT64 OR FLOAT64 column, scalar literal RHS):
#   * BIN_EQ  -- column == literal
#   * BIN_NE  -- column != literal
#   * BIN_LT  -- column <  literal
#   * BIN_LE  -- column <= literal
#   * BIN_GT  -- column >  literal
#   * BIN_GE  -- column >= literal
#
# FLOAT64 extension:
#   * `fused_eval_and_float64` mirrors the INT64 kernel for Float64
#     columns. Same byte-walking shape, same SIMD-compare-pack +
#     AND-combine, same tail handling.
#   * `fused_eval_and_mixed` AND-combines an INT64 conjunct list with
#     a FLOAT64 conjunct list against a single batch (e.g. TPC-H q6:
#     2 INT64 + 3 FLOAT64 conjuncts).
#   * NaN handling: IEEE-754 — NaN < x, NaN > x, NaN == NaN are all
#     False. ⚠ KNOWN DIVERGENCE from DuckDB/Postgres/Spark, where
#     `NaN = NaN` is TRUE and NaN sorts above +inf (DuckDB v1.5.3).
#     Result: a row whose value is NaN fails every numeric
#     comparison and is excluded from the output mask, as in
#     parquet-rs's default semantics.
#
# Fallback: if any conjunct is not in the supported shape (logical
# AND/OR/NOT, string compare, INT32, etc.), the caller takes the
# scalar `_eval_predicate` per-stage path. This keeps the encoder/
# decoder discipline: one fused kernel handles the hot path; everything
# else falls through to the per-conjunct path with no perf impact.
#
# Encapsulation: this module exports only safe types
# (PrimitiveArray, BooleanArray, ConjunctDescI64, ConjunctDescF64). The
# internal kernel is private and uses only PrimitiveArray.load[W] +
# Bitmap byte writes. No UnsafePointer crosses the boundary.
# =============================================================================

from std.sys import simd_width_of, size_of

from ..arrow.primitive_array import PrimitiveArray
from ..arrow.boolean_array import BooleanArray
from ..arrow.bitmap import Bitmap
from ..arrow.record_batch import RecordBatch
from ..arrow.column import Column
from ..collections.slab import Slab


# Supported op codes -- numerically aligned with komira_core.plan.expr
# (BIN_EQ=10, BIN_NE=11, BIN_LT=12, BIN_LE=13, BIN_GT=14, BIN_GE=15). The
# caller (parquet_morsel_source) translates Expr op tags into these.
comptime FUSED_OP_EQ: UInt8 = 0
comptime FUSED_OP_NE: UInt8 = 1
comptime FUSED_OP_LT: UInt8 = 2
comptime FUSED_OP_LE: UInt8 = 3
comptime FUSED_OP_GT: UInt8 = 4
comptime FUSED_OP_GE: UInt8 = 5

# Maximum number of conjuncts the fused path supports in a single call.
# Typical analytic predicates top out at 3-4 conjuncts.
comptime FUSED_MAX_CONJUNCTS: Int = 8


struct ConjunctDescI64(Copyable, Movable):
    """Descriptor for one INT64 col-vs-literal conjunct in a fused chain.

    Fields:
        col_idx: Index of the column inside the source RecordBatch.
        op:      One of FUSED_OP_*.
        thresh:  Literal value to compare against (int64).
    """
    var col_idx: Int
    var op: UInt8
    var thresh: Int64

    @always_inline
    def __init__(out self, col_idx: Int, op: UInt8, thresh: Int64):
        self.col_idx = col_idx
        self.op = op
        self.thresh = thresh

    @always_inline
    def copy(self) -> Self:
        return Self(self.col_idx, self.op, self.thresh)


# =============================================================================
# Internal SIMD compare-pack -- byte-wise INT64
# =============================================================================
#
# Returns the 8-bit packed compare result for elements [elem_idx, elem_idx+8)
# of `col` against `t_vec`, with op selected at runtime via `op`. We cannot
# comptime-specialize over `op` because the op varies per conjunct in the
# fused chain.
#
# SAFETY: `col.load[W]` returns a SIMD vector by value; no UnsafePointer
# escapes. `len(col) >= elem_idx + 8` is the caller's responsibility (we
# only call this for full bytes).
# =============================================================================


@always_inline
def _simd_cmp_byte_int64[W: Int](
    v: SIMD[DType.int64, W], t_vec: SIMD[DType.int64, W], op: UInt8
) -> SIMD[DType.uint8, W]:
    """Run `op` between `v` and `t_vec`, return cast-to-u8 lane mask."""
    if op == FUSED_OP_EQ:
        return v.eq(t_vec).cast[DType.uint8]()
    elif op == FUSED_OP_NE:
        return v.ne(t_vec).cast[DType.uint8]()
    elif op == FUSED_OP_LT:
        return v.lt(t_vec).cast[DType.uint8]()
    elif op == FUSED_OP_LE:
        return v.le(t_vec).cast[DType.uint8]()
    elif op == FUSED_OP_GT:
        return v.gt(t_vec).cast[DType.uint8]()
    else:  # FUSED_OP_GE
        return v.ge(t_vec).cast[DType.uint8]()


@always_inline
def _cmp_byte_int64(
    col: PrimitiveArray[DType.int64], elem_idx: Int, op: UInt8, thresh: Int64
) -> UInt8:
    """Produce one packed bitmap byte for 8 elements of an INT64 column.

    Bit `i` of the result = 1 iff `col[elem_idx + i] OP thresh`.
    Bit ordering follows Arrow bitmap convention (LSB = element 0).
    """
    comptime W: Int = simd_width_of[DType.int64]()
    var t_vec = SIMD[DType.int64, W](thresh)

    # Hand-unroll 8 elements via ceil(8/W) SIMD compares + weighted pack.
    # Mojo doesn't let us comptime-branch on `W >= 8` cleanly because
    # PrimitiveArray.load is parameterized on width and `8//W` would be 0.
    # Instead we always do (8 // W) sub-loads + weighted pack, with
    # comptime expansion for the loop counts.
    comptime ITERS_PER_BYTE: Int = (8 + W - 1) // W
    var byte_val = UInt8(0)
    comptime for k in range(ITERS_PER_BYTE):
        comptime base_shift: Int = k * W
        comptime lanes_remaining: Int = 8 - base_shift
        comptime active_lanes: Int = lanes_remaining if lanes_remaining < W else W
        var v = col.load[W](elem_idx + k * W)
        var b = _simd_cmp_byte_int64[W](v, t_vec, op)
        comptime for lane in range(active_lanes):
            byte_val = byte_val | (b[lane] << UInt8(base_shift + lane))
    return byte_val


@always_inline
def _cmp_scalar_int64(val: Int64, op: UInt8, thresh: Int64) -> Bool:
    if op == FUSED_OP_EQ:
        return val == thresh
    elif op == FUSED_OP_NE:
        return val != thresh
    elif op == FUSED_OP_LT:
        return val < thresh
    elif op == FUSED_OP_LE:
        return val <= thresh
    elif op == FUSED_OP_GT:
        return val > thresh
    else:  # FUSED_OP_GE
        return val >= thresh


# =============================================================================
# Public API: fused multi-conjunct evaluator
# =============================================================================
#
# Produces a BooleanArray = AND_i(cols[c_i.col_idx] OP_i c_i.thresh) for
# each conjunct in `conjuncts`. The output is bit-identical to repeatedly
# calling `eval_eq/lt/.../gt` per conjunct followed by `eval_and`.
#
# All conjuncts must reference INT64 columns. The caller is responsible
# for verifying the shape; we debug_assert here but the perf-critical
# release path skips the check.
#
# Length contract: every column in `conjuncts` must have `length >= n_rows`.
# The caller passes `n_rows = batch.num_rows()`.
# =============================================================================


def fused_eval_and_int64(
    batch: RecordBatch,
    conjuncts: List[ConjunctDescI64],
    n_rows: Int,
) raises -> BooleanArray:
    """Fused AND-combine of INT64 col-vs-literal conjuncts.

    Walks the columns once at byte granularity (8 elements per output
    byte). For each byte:
      1. Compute the 8-bit packed compare result per conjunct.
      2. AND across conjuncts.
      3. Write the resulting byte into the output bitmap.

    Args:
        batch:     The decoded filter columns. Conjunct descriptors index
                   into `batch._columns` by `col_idx`.
        conjuncts: 1..FUSED_MAX_CONJUNCTS conjunct descriptors. AND-combined.
        n_rows:    Logical length of every column. Output BooleanArray is
                   bit-packed to this length.

    Returns:
        BooleanArray of length `n_rows`. Bit i = AND over all conjuncts.
    """
    var n_conj = len(conjuncts)
    debug_assert(
        n_conj > 0 and n_conj <= FUSED_MAX_CONJUNCTS,
        "fused_eval_and_int64: conjunct count out of range",
    )

    var bm = Bitmap.create(n_rows)
    var bm_view = bm.buffer.view_mut()

    var full_bytes = n_rows >> 3

    # Pre-extract PrimitiveArray views for each conjunct ONCE (this copies
    # the MmapAlignedBuffer one time per conjunct -- N copies up front instead
    # of N copies per byte). For N=2 conjuncts and 1M-row batches this is
    # 2 * 8MB = 16MB of data movement vs the per-conjunct path's 2 * 8MB +
    # 1 * 8MB (eval_and). Net: roughly equivalent allocation cost; the
    # win comes from eliminating the (N-1) intermediate BooleanArrays
    # plus the eval_and bitmap-AND passes.
    #
    # NOTE: this duplicates the existing `_eval_predicate` per-stage
    # `as_primitive[]` cost. The follow-up optimization is to thread an
    # MmapAlignedBuffer view-only path into the kernel so the column data
    # stays in place.
    # `Slab[PrimitiveArray]` carries Movable-only T; `List[T]` would require
    # T: Copyable which PrimitiveArray is not.
    var col_views = Slab[PrimitiveArray[DType.int64]].with_capacity(n_conj)
    for ci in range(n_conj):
        ref col = batch.column_at(conjuncts[ci].col_idx)
        col_views.append(col.as_primitive[DType.int64]())

    # Hot loop: one full byte per iteration. Inner loop runs N=#conjuncts
    # SIMD compares, AND-combined into one output byte. Zero allocations
    # inside the loop.
    for byte_idx in range(full_bytes):
        var elem_idx = byte_idx << 3
        # Initialise to all-ones; AND clears bits as conjuncts fail.
        var combined = UInt8(0xFF)
        for ci in range(n_conj):
            ref c = conjuncts[ci]
            var cmp = _cmp_byte_int64(
                col_views[ci], elem_idx, c.op, c.thresh
            )
            combined = combined & cmp
            # Early-exit when the byte is already all-zero. For very
            # selective filters this saves the rest of the conjunct work.
            if combined == UInt8(0):
                break
        bm_view.write_u8_at(byte_idx, combined)

    # Tail: residual elements [full_bytes*8, n_rows). Up to 7 elements.
    var remaining = n_rows & 7
    if remaining > 0:
        var elem_idx = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var ok = True
            for ci in range(n_conj):
                ref c = conjuncts[ci]
                var v = col_views[ci].load[1](elem_idx + bit)
                if not _cmp_scalar_int64(Int64(v), c.op, c.thresh):
                    ok = False
                    break
            if ok:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# Op-tag translation helper -- maps Expr BinaryOp tags to FUSED_OP_*.
# Returns -1 (as Int) if the op is not supported (caller should fall back).
# We keep this in this module so all Expr-tag knowledge stays here.
# =============================================================================


@always_inline
def fused_op_from_bin_op(bin_op: UInt8) -> Int:
    """Translate Expr BIN_* tag to FUSED_OP_* tag.

    Per `komira_core.plan.expr`:
      BIN_EQ=10, BIN_NE=11, BIN_LT=12, BIN_LE=13, BIN_GT=14, BIN_GE=15.
    Returns -1 for unsupported (logical AND/OR/arithmetic).
    """
    if bin_op == UInt8(10):
        return Int(FUSED_OP_EQ)
    elif bin_op == UInt8(11):
        return Int(FUSED_OP_NE)
    elif bin_op == UInt8(12):
        return Int(FUSED_OP_LT)
    elif bin_op == UInt8(13):
        return Int(FUSED_OP_LE)
    elif bin_op == UInt8(14):
        return Int(FUSED_OP_GT)
    elif bin_op == UInt8(15):
        return Int(FUSED_OP_GE)
    else:
        return -1


# =============================================================================
# FLOAT64 mirror
# =============================================================================
#
# A filter mixing INT64 and FLOAT64 conjuncts (TPC-H q6: an l_shipdate
# range plus l_discount BETWEEN 0.05 AND 0.07 plus l_quantity < 24) would
# otherwise disable the INT64-only fused kernel and fall back to a
# per-conjunct loop with 5 BooleanArray allocations + 4 eval_and combines,
# where predicate evaluation dominates the query.
#
# Solution: mirror the INT64 kernel for FLOAT64, plus a mixed-kernel
# entry point that handles "K INT64 + M FLOAT64" chains in one pass.
#
# IEEE-754 semantics: NaN comparisons (lt / le / gt / ge / eq) all
# return False. ne(NaN, x) returns True. The AND-combine then excludes
# any NaN row (or includes it if the chain is purely a single ne
# conjunct). DuckDB and parquet-rs both follow
# IEEE-754 here; we match by using the SIMD compare ops directly with
# no NaN-special-case branch.
# =============================================================================


struct ConjunctDescF64(Copyable, Movable):
    """Descriptor for one FLOAT64 col-vs-literal conjunct in a fused chain.

    Mirrors `ConjunctDescI64` but with `Float64` threshold.

    Fields:
        col_idx: Index of the column inside the source RecordBatch.
        op:      One of FUSED_OP_*.
        thresh:  Literal value to compare against (float64).
    """
    var col_idx: Int
    var op: UInt8
    var thresh: Float64

    @always_inline
    def __init__(out self, col_idx: Int, op: UInt8, thresh: Float64):
        self.col_idx = col_idx
        self.op = op
        self.thresh = thresh

    @always_inline
    def copy(self) -> Self:
        return Self(self.col_idx, self.op, self.thresh)


@always_inline
def _simd_cmp_byte_float64[W: Int](
    v: SIMD[DType.float64, W], t_vec: SIMD[DType.float64, W], op: UInt8
) -> SIMD[DType.uint8, W]:
    """Run `op` between `v` and `t_vec`, return cast-to-u8 lane mask.

    NaN handling (IEEE-754): every numeric compare with a NaN operand
    returns False; ne returns True. SIMD ops inherit this directly.
    """
    if op == FUSED_OP_EQ:
        return v.eq(t_vec).cast[DType.uint8]()
    elif op == FUSED_OP_NE:
        return v.ne(t_vec).cast[DType.uint8]()
    elif op == FUSED_OP_LT:
        return v.lt(t_vec).cast[DType.uint8]()
    elif op == FUSED_OP_LE:
        return v.le(t_vec).cast[DType.uint8]()
    elif op == FUSED_OP_GT:
        return v.gt(t_vec).cast[DType.uint8]()
    else:  # FUSED_OP_GE
        return v.ge(t_vec).cast[DType.uint8]()


@always_inline
def _cmp_byte_float64(
    col: PrimitiveArray[DType.float64], elem_idx: Int, op: UInt8, thresh: Float64
) -> UInt8:
    """Produce one packed bitmap byte for 8 elements of a FLOAT64 column.

    Mirror of `_cmp_byte_int64`. Bit `i` of the result = 1 iff
    `col[elem_idx + i] OP thresh`. Bit ordering follows Arrow bitmap
    convention (LSB = element 0).
    """
    comptime W: Int = simd_width_of[DType.float64]()
    var t_vec = SIMD[DType.float64, W](thresh)

    # Hand-unroll 8 elements via ceil(8/W) SIMD compares + weighted pack.
    # Same shape as the INT64 path; on AVX2 W=4, on AVX-512 W=8.
    comptime ITERS_PER_BYTE: Int = (8 + W - 1) // W
    var byte_val = UInt8(0)
    comptime for k in range(ITERS_PER_BYTE):
        comptime base_shift: Int = k * W
        comptime lanes_remaining: Int = 8 - base_shift
        comptime active_lanes: Int = lanes_remaining if lanes_remaining < W else W
        var v = col.load[W](elem_idx + k * W)
        var b = _simd_cmp_byte_float64[W](v, t_vec, op)
        comptime for lane in range(active_lanes):
            byte_val = byte_val | (b[lane] << UInt8(base_shift + lane))
    return byte_val


@always_inline
def _cmp_scalar_float64(val: Float64, op: UInt8, thresh: Float64) -> Bool:
    """Scalar fallback used in the tail loop. NaN ops follow IEEE-754."""
    if op == FUSED_OP_EQ:
        return val == thresh
    elif op == FUSED_OP_NE:
        return val != thresh
    elif op == FUSED_OP_LT:
        return val < thresh
    elif op == FUSED_OP_LE:
        return val <= thresh
    elif op == FUSED_OP_GT:
        return val > thresh
    else:  # FUSED_OP_GE
        return val >= thresh


def fused_eval_and_float64(
    batch: RecordBatch,
    conjuncts: List[ConjunctDescF64],
    n_rows: Int,
) raises -> BooleanArray:
    """Fused AND-combine of FLOAT64 col-vs-literal conjuncts.

    Mirror of `fused_eval_and_int64`. See that function's docstring for
    the algorithm and rationale; this function differs only in DType.

    NaN handling: any FLOAT64 element that is NaN evaluates False under
    every numeric compare op (EQ/LT/LE/GT/GE) and True under NE. The
    SIMD compare ops inherit this directly, so NaN rows are naturally
    excluded from the output mask (unless the chain is a single NE).
    Matches DuckDB / parquet-rs.

    Args:
        batch:     The decoded filter columns.
        conjuncts: 1..FUSED_MAX_CONJUNCTS conjunct descriptors. AND-combined.
        n_rows:    Logical length of every column.

    Returns:
        BooleanArray of length `n_rows`. Bit i = AND over all conjuncts.
    """
    var n_conj = len(conjuncts)
    debug_assert(
        n_conj > 0 and n_conj <= FUSED_MAX_CONJUNCTS,
        "fused_eval_and_float64: conjunct count out of range",
    )

    var bm = Bitmap.create(n_rows)
    var bm_view = bm.buffer.view_mut()

    var full_bytes = n_rows >> 3

    var col_views = Slab[PrimitiveArray[DType.float64]].with_capacity(n_conj)
    for ci in range(n_conj):
        ref col = batch.column_at(conjuncts[ci].col_idx)
        col_views.append(col.as_primitive[DType.float64]())

    for byte_idx in range(full_bytes):
        var elem_idx = byte_idx << 3
        var combined = UInt8(0xFF)
        for ci in range(n_conj):
            ref c = conjuncts[ci]
            var cmp = _cmp_byte_float64(
                col_views[ci], elem_idx, c.op, c.thresh
            )
            combined = combined & cmp
            if combined == UInt8(0):
                break
        bm_view.write_u8_at(byte_idx, combined)

    var remaining = n_rows & 7
    if remaining > 0:
        var elem_idx = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var ok = True
            for ci in range(n_conj):
                ref c = conjuncts[ci]
                var v = col_views[ci].load[1](elem_idx + bit)
                if not _cmp_scalar_float64(Float64(v), c.op, c.thresh):
                    ok = False
                    break
            if ok:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


def fused_eval_and_mixed(
    batch: RecordBatch,
    int_conjuncts: List[ConjunctDescI64],
    float_conjuncts: List[ConjunctDescF64],
    n_rows: Int,
) raises -> BooleanArray:
    """Fused AND-combine of mixed INT64 + FLOAT64 conjunct chains.

    AND-combines K INT64 conjuncts and M FLOAT64
    conjuncts in one byte-walking pass. Replaces (K + M) BooleanArray
    allocations + (K + M - 1) eval_and combines with one fused pass.

    The byte-loop layout interleaves the per-byte per-conjunct work:
      for each byte:
        for each int_conjunct: byte_val &= _cmp_byte_int64(...)
        for each float_conjunct: byte_val &= _cmp_byte_float64(...)
        early-exit when combined == 0
        emit byte

    Constraint: K + M <= FUSED_MAX_CONJUNCTS (8). TPC-H q6 has K=2, M=3 = 5
    conjuncts -- well under the bound.

    Args:
        batch:           The decoded filter columns.
        int_conjuncts:   List of INT64 conjuncts (any length, possibly empty).
        float_conjuncts: List of FLOAT64 conjuncts (any length, possibly empty).
        n_rows:          Logical length of every column.

    Returns:
        BooleanArray of length `n_rows`. Bit i = AND over all conjuncts
        (both int and float).
    """
    var n_int = len(int_conjuncts)
    var n_flt = len(float_conjuncts)
    var total = n_int + n_flt
    debug_assert(
        total > 0 and total <= FUSED_MAX_CONJUNCTS,
        "fused_eval_and_mixed: conjunct count out of range",
    )

    # Pure-type fast paths skip the slab for the absent type.
    if n_flt == 0:
        return fused_eval_and_int64(batch, int_conjuncts, n_rows)
    if n_int == 0:
        return fused_eval_and_float64(batch, float_conjuncts, n_rows)

    var bm = Bitmap.create(n_rows)
    var bm_view = bm.buffer.view_mut()

    var full_bytes = n_rows >> 3

    var int_views = Slab[PrimitiveArray[DType.int64]].with_capacity(n_int)
    for ci in range(n_int):
        ref col = batch.column_at(int_conjuncts[ci].col_idx)
        int_views.append(col.as_primitive[DType.int64]())

    var flt_views = Slab[PrimitiveArray[DType.float64]].with_capacity(n_flt)
    for ci in range(n_flt):
        ref col = batch.column_at(float_conjuncts[ci].col_idx)
        flt_views.append(col.as_primitive[DType.float64]())

    for byte_idx in range(full_bytes):
        var elem_idx = byte_idx << 3
        var combined = UInt8(0xFF)
        for ci in range(n_int):
            ref c = int_conjuncts[ci]
            var cmp = _cmp_byte_int64(
                int_views[ci], elem_idx, c.op, c.thresh
            )
            combined = combined & cmp
            if combined == UInt8(0):
                break
        if combined != UInt8(0):
            for ci in range(n_flt):
                ref c = float_conjuncts[ci]
                var cmp = _cmp_byte_float64(
                    flt_views[ci], elem_idx, c.op, c.thresh
                )
                combined = combined & cmp
                if combined == UInt8(0):
                    break
        bm_view.write_u8_at(byte_idx, combined)

    var remaining = n_rows & 7
    if remaining > 0:
        var elem_idx = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var ok = True
            for ci in range(n_int):
                ref c = int_conjuncts[ci]
                var v = int_views[ci].load[1](elem_idx + bit)
                if not _cmp_scalar_int64(Int64(v), c.op, c.thresh):
                    ok = False
                    break
            if ok:
                for ci in range(n_flt):
                    ref c = float_conjuncts[ci]
                    var v = flt_views[ci].load[1](elem_idx + bit)
                    if not _cmp_scalar_float64(Float64(v), c.op, c.thresh):
                        ok = False
                        break
            if ok:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)
