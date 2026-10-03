# =============================================================================
# komira_kernels.sel_kernels — Templated primitive comparison kernels that
# operate on `RowSelectionVector` (NOT bitmaps).
#
# The leaf primitives ExpressionExecutor
# dispatches into for `BOUND_COMPARISON` nodes. Mirrors DuckDB's `BinaryExecutor::Select<LHS, RHS, OP>` family
# in `src/execution/expression_executor/execute_comparison.cpp` —
#
#     result_count = Select(left, right, sel, count, true_sel, false_sel)
#
# Two callsite shapes (matching DuckDB's overloads):
#   * binary_select_col_lit  — column vs broadcast scalar
#   * binary_select_col_col  — column vs column (both same DType)
#
# Six comparison ops (comptime UInt8 fanout):
#   * BIN_OP_GT (>), BIN_OP_GE (>=), BIN_OP_LT (<), BIN_OP_LE (<=),
#   * BIN_OP_EQ (==), BIN_OP_NE (!=)
#
# Five DType families:
#   * Float32 / Float64 — IEEE 754 NaN semantics. ⚠ KNOWN DIVERGENCE from
#     DuckDB/Postgres/Spark on NaN; see `_cmp_ne`.
#   * Int32 / Int64 — signed integer
#   * Date32 — DType.int32 physical (days since epoch, signed)
#
# String is not covered (BinaryArray / DictionaryArray need their own access
# patterns).
#
# Two execution paths per kernel:
#   1. Identity-sel-in fast path: `sel_in.len() == col.length`. Unit-stride
#      SIMD compare. Hand-staged using
#      `array.load[W]` + `lv.gt(rv)` family; NO autovectorizer reliance.
#   2. Gather path: variable `sel_in`. Per-row scalar gather via
#      `load_via_sel` — the DICTIONARY_VECTOR slow path; cannot be
#      unit-stride SIMD. Gather is the dominant
#      cost characteristic for any conjunct except the first.
#
# Sel-pair contract:
#   * `true_sel` accumulates surviving indices (the count returned).
#   * `false_sel` accumulates rejected indices (used by conjunction
#     siblings when needed; otherwise dropped by the caller).
#   * Both are ALWAYS written. Caller passes disjoint buffers.
#   * NO boolean array is ever materialized — direct sel-vector write.
#
# Encapsulation: no UnsafePointer in any public signature and no wildcard
# origins. All pointer arithmetic is internal to
# `PrimitiveArray.load[W]` and `RowSelectionVector.append`; this module
# stays at the typed-ref / typed-scalar / Int boundary.
#
# This is the SIMD compare kernel for every BOUND_COMPARISON
# node in the row-mode executor (Hierarchy B) and every PhysicalFilter
# leaf (Hierarchy A). A refactor that "simplifies" the @parameter if op
# fanout into a runtime branch will regress every WHERE clause in the
# product. The hand-staged SIMD body follows the lockstep correctness
# pattern.
# =============================================================================

from std.sys import simd_width_of, size_of

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.simd.compress import compress_u32xW
from komira_core.eval.selection_vector_row import (
    RowSelectionVector,
    load_via_sel,
)
from komira_core.io.heap_region import HeapRegion


# -----------------------------------------------------------------------------
# Op tags (comptime UInt8).
# -----------------------------------------------------------------------------

comptime BIN_OP_GT: UInt8 = 0
comptime BIN_OP_GE: UInt8 = 1
comptime BIN_OP_LT: UInt8 = 2
comptime BIN_OP_LE: UInt8 = 3
comptime BIN_OP_EQ: UInt8 = 4
comptime BIN_OP_NE: UInt8 = 5


# -----------------------------------------------------------------------------
# Op helpers — SIMD lane-level comparison (mirrors builtin_match_fns.mojo
# `_cmp_lt`/`_cmp_le`/...). Each helper is `@always_inline` so the body
# folds into the caller's @parameter-if arm.
# -----------------------------------------------------------------------------


@always_inline
def _cmp_gt[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.gt(rhs)


@always_inline
def _cmp_ge[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.ge(rhs)


@always_inline
def _cmp_lt[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.lt(rhs)


@always_inline
def _cmp_le[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.le(rhs)


@always_inline
def _cmp_eq[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    return lhs.eq(rhs)


@always_inline
def _cmp_ne[T: DType, W: Int](lhs: SIMD[T, W], rhs: SIMD[T, W]) -> SIMD[DType.bool, W]:
    # IEEE UNORDERED not-equal: NaN != anything → true. Mojo's SIMD
    # `.ne(rhs)` lowers to LLVM `fcmp one` (ORDERED not-equal) where
    # NaN != NaN → false; `~eq` gives the unordered form instead
    # (`NaN.eq(NaN) → false`, then `~false → true`). For non-NaN inputs this
    # is bit-identical to `.ne`. For integer types the distinction is moot.
    #
    # ⚠ KNOWN DIVERGENCE from DuckDB / PostgreSQL / Spark SQL, all of which
    # return FALSE for `NaN <> NaN`: in DuckDB v1.5.3
    # `SELECT 'nan'::DOUBLE <> 'nan'::DOUBLE` is false, because DuckDB's float
    # comparison specialisation makes NaN equal itself. The SQL standard does
    # not define NaN for approximate numerics at all, so "per SQL" decides
    # nothing. Resolving this needs one shared NaN comparison semantics.
    return ~lhs.eq(rhs)


# Scalar (single-lane) form for the SIMD tail loop / gather path. Mojo's
# scalar `<` / `<=` / `>` / `>=` / `==` / `!=` are overloaded on Scalar[T]
# (unlike SIMD, which needs `.gt`/`.lt`/etc).
@always_inline
def _cmp_scalar[T: DType, op: UInt8](lv: Scalar[T], rv: Scalar[T]) -> Bool:
    comptime if op == BIN_OP_GT:
        return lv > rv
    elif op == BIN_OP_GE:
        return lv >= rv
    elif op == BIN_OP_LT:
        return lv < rv
    elif op == BIN_OP_LE:
        return lv <= rv
    elif op == BIN_OP_EQ:
        return lv == rv
    else:  # op == BIN_OP_NE
        # IEEE UNORDERED not-equal: NaN != x → true. Mojo Scalar `!=`
        # lowers to `fcmp one` (ordered: NaN != NaN → false), so use
        # `not (lv == rv)`. Bit-identical to `lv != rv` for non-NaN inputs.
        # ⚠ KNOWN DIVERGENCE from DuckDB/Postgres/Spark (this said "to match
        # SQL / DuckDB"; it does not — see `_cmp_ne` above).
        return not (lv == rv)


@always_inline
def _cmp_simd[T: DType, W: Int, op: UInt8](
    lv: SIMD[T, W], rv: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Comptime-op SIMD compare. One arm survives per instantiation."""
    comptime if op == BIN_OP_GT:
        return _cmp_gt[T, W](lv, rv)
    elif op == BIN_OP_GE:
        return _cmp_ge[T, W](lv, rv)
    elif op == BIN_OP_LT:
        return _cmp_lt[T, W](lv, rv)
    elif op == BIN_OP_LE:
        return _cmp_le[T, W](lv, rv)
    elif op == BIN_OP_EQ:
        return _cmp_eq[T, W](lv, rv)
    else:  # op == BIN_OP_NE
        return _cmp_ne[T, W](lv, rv)


# -----------------------------------------------------------------------------
# binary_select_col_lit — Column-vs-Literal sel-pair kernel
# -----------------------------------------------------------------------------
#
# Returns the count of surviving (passing) rows = `true_sel.len()` AFTER
# the kernel completes. `false_sel` is also written; its length =
# total_count - returned_count.
#
# Identity-sel-in fast path: when `sel_in.len() == col.length`, we KNOW
# `sel_in` represents [0, 1, 2, ..., col.length-1] (the identity selection
# from `RowSelectionVector.identity_selection(n)` or an equivalent
# pass-through). The kernel walks `col` in unit-stride and processes W
# elements per SIMD compare. This is the only SIMD-eligible path.
#
# Gather path: when `sel_in.len() != col.length`, we cannot assume
# `sel_in` is identity — there may be prior filters narrowing it. The
# kernel iterates over `sel_in` and per-row gathers `col[sel_in[k]]`
# via `load_via_sel`. Per-row scalar compare + conditional append.
# Cannot be unit-stride SIMD (DuckDB DICTIONARY_VECTOR shape).
# -----------------------------------------------------------------------------


@always_inline
def _build_iota_plus_base[W: Int](base_idx: Int) -> SIMD[DType.uint32, W]:
    """Build the W-lane vector `[base_idx, base_idx+1, ..., base_idx+W-1]`.

    Used by `_emit_lane_writes[W]` to construct the input-relative lane-id
    vector for the dual-compress sel-pair emission shape. The comptime-for
    body folds to a constant initializer at every W; LLVM hoists the
    iota broadcast outside the inner loop when called from a hot kernel.
    """
    var lanes = SIMD[DType.uint32, W](0)
    comptime for lane in range(W):
        lanes[lane] = UInt32(lane)
    return lanes + UInt32(base_idx)


@always_inline
def _emit_lane_writes[W: Int](
    mask: SIMD[DType.bool, W],
    base_idx: Int,
    mut true_sel: RowSelectionVector,
    mut false_sel: RowSelectionVector,
):
    """Compact-write W mask lanes to true_sel / false_sel via dual compress.

    A `comptime for lane in range(W)` per-lane scatter lowers on AVX-512
    to 8 unrolled `kshiftrb/kmovd/test/je/mov` blocks per W=8 chunk (~56
    `kshiftrb` instructions across 8 inlined kernels).
    `compress_u32xW(mask, lanes)` + `append_vec_first_k` drives that to a single `vpcompressd zmm0{k1}{z}, zmm0` (1 cycle) +
    1 masked store, mirroring the DuckDB
    `vector_operations/comparison_operators.cpp` `templated_select_loop`
    hand-staged path.

    NEON: `compress_u32xW` falls through to `_scalar_compress`, which does
    the comptime-unrolled lane scatter — but to a stack-local SIMD register.
    The `append_vec_first_k` bulk-store then issues a single tail store
    instead of W per-lane `append()` calls, so the cost is comparable to a
    per-lane scatter.
    """
    var lanes = _build_iota_plus_base[W](base_idx)

    # Survivors → true_sel: `vpcompressd` on AVX-512, scalar scatter on NEON.
    var pos = compress_u32xW(mask, lanes)
    true_sel.append_vec_first_k[W](pos.compacted, Int(pos.count))

    # Rejects → false_sel: invert mask; same shape.
    var neg = compress_u32xW(~mask, lanes)
    false_sel.append_vec_first_k[W](neg.compacted, Int(neg.count))


def binary_select_col_lit[
    T: DType, op: UInt8
](
    ref col: PrimitiveArray[T],
    lit: Scalar[T],
    ref sel_in: RowSelectionVector,
    mut true_sel: RowSelectionVector,
    mut false_sel: RowSelectionVector,
) -> Int:
    """Column-vs-Literal sel-pair kernel.

    Evaluates `col[i] OP lit` for each row in `sel_in`, appending
    surviving (OP-passing) row indices to `true_sel` and rejected
    indices to `false_sel`. Returns the count of surviving rows.

    Identity-sel-in (`sel_in.len() == col.length`) takes the unit-stride
    SIMD fast path. Other selections take the per-row gather path.

    Args:
        col: Source column. Origin tied to the caller's borrow.
        lit: Broadcast scalar literal (RHS of the comparison).
        sel_in: Input selection vector. `sel_in.len()` rows are processed.
        true_sel: Output selection vector for OP-passing rows.
        false_sel: Output selection vector for OP-rejected rows. Caller
            must pass a DISJOINT buffer from `true_sel`.

    Returns:
        Surviving (OP-passing) row count = `true_sel.len()` after the call.
    """
    # Reset outputs — caller may have re-used the buffers across morsels.
    true_sel.reset()
    false_sel.reset()

    var n_in = sel_in.len()
    var col_len = col.length

    # Identity-sel-in fast path: SIMD unit-stride compare-and-emit.
    # Detection contract: `sel_in.len() == col.length` AND the kernel
    # ENTRY contract is "sel_in is identity when len matches col len".
    # callers must construct identity-shape sel_in
    # via `RowSelectionVector.identity_selection(n)` for the first
    # conjunct in an AND chain.
    if n_in == col_len:
        return _select_col_lit_identity[T, op](col, lit, true_sel, false_sel)

    # Gather path: per-row scalar via `load_via_sel`.
    return _select_col_lit_gather[T, op](
        col, lit, sel_in, true_sel, false_sel
    )


@always_inline
def _select_col_lit_identity[
    T: DType, op: UInt8
](
    ref col: PrimitiveArray[T],
    lit: Scalar[T],
    mut true_sel: RowSelectionVector,
    mut false_sel: RowSelectionVector,
) -> Int:
    """Unit-stride SIMD path. `col` is walked [0, col.length).

    This is the SIMD compare path for the first conjunct
    in every WHERE clause (sel_in == identity). The hand-staged SIMD
    body emits native NEON `fcmgt.2d` / AVX-512 `vcmppd`.
    """
    comptime W: Int = simd_width_of[T]()
    var length = col.length

    # Broadcast literal once outside the loop (hoist).
    var lit_vec = SIMD[T, W](lit)

    var simd_end = (length // W) * W
    var i = 0
    while i < simd_end:
        var v = col.load[W](i)
        var mask = _cmp_simd[T, W, op](v, lit_vec)
        _emit_lane_writes[W](mask, i, true_sel, false_sel)
        i += W

    # Scalar tail (length % W elements left).
    while i < length:
        var v = col.load[1](i)
        var keep = _cmp_scalar[T, op](v, lit)
        if keep:
            true_sel.append(UInt32(i))
        else:
            false_sel.append(UInt32(i))
        i += 1

    return true_sel.len()


@always_inline
def _select_col_lit_gather[
    T: DType, op: UInt8
](
    ref col: PrimitiveArray[T],
    lit: Scalar[T],
    ref sel_in: RowSelectionVector,
    mut true_sel: RowSelectionVector,
    mut false_sel: RowSelectionVector,
) -> Int:
    """Gather path. `sel_in` provides logical-to-physical indirection.

    Per-row scalar gather via `load_via_sel`. Cannot be unit-stride
    SIMD (DuckDB DICTIONARY_VECTOR slow path). Each iteration:
    - Read physical row index `phys = sel_in[k]`.
    - Gather `col[phys]` via `load_via_sel`.
    - Scalar compare vs `lit`.
    - Conditional append `phys` to `true_sel` or `false_sel`.
    """
    var n_in = sel_in.len()
    var k = 0
    while k < n_in:
        var phys = sel_in.get(k)
        var v = load_via_sel[T](col, sel_in, k)
        var keep = _cmp_scalar[T, op](v, lit)
        if keep:
            true_sel.append(phys)
        else:
            false_sel.append(phys)
        k += 1

    return true_sel.len()


# -----------------------------------------------------------------------------
# binary_select_col_col — Column-vs-Column sel-pair kernel
# -----------------------------------------------------------------------------


def binary_select_col_col[
    T: DType, op: UInt8
](
    ref left: PrimitiveArray[T],
    ref right: PrimitiveArray[T],
    ref sel_in: RowSelectionVector,
    mut true_sel: RowSelectionVector,
    mut false_sel: RowSelectionVector,
) -> Int:
    """Column-vs-Column sel-pair kernel.

    Evaluates `left[i] OP right[i]` for each row in `sel_in`. Both
    columns must have the same length and DType. Returns surviving
    (OP-passing) row count.

    Args:
        left: LHS column.
        right: RHS column. Must have `right.length == left.length`.
        sel_in: Input selection vector.
        true_sel: Output sel for OP-passing rows.
        false_sel: Output sel for OP-rejected rows. Disjoint from true_sel.

    Returns:
        Surviving row count.
    """
    true_sel.reset()
    false_sel.reset()

    var n_in = sel_in.len()
    var left_len = left.length

    # debug-assert (compiles to a branch in debug, elided release).
    debug_assert(
        left.length == right.length,
        "binary_select_col_col: left/right length mismatch",
    )

    if n_in == left_len:
        return _select_col_col_identity[T, op](
            left, right, true_sel, false_sel
        )

    return _select_col_col_gather[T, op](
        left, right, sel_in, true_sel, false_sel
    )


@always_inline
def _select_col_col_identity[
    T: DType, op: UInt8
](
    ref left: PrimitiveArray[T],
    ref right: PrimitiveArray[T],
    mut true_sel: RowSelectionVector,
    mut false_sel: RowSelectionVector,
) -> Int:
    """Unit-stride SIMD col-vs-col path. NEON `fcmgt.2d` / AVX `vcmppd`."""
    comptime W: Int = simd_width_of[T]()
    var length = left.length

    var simd_end = (length // W) * W
    var i = 0
    while i < simd_end:
        var lv = left.load[W](i)
        var rv = right.load[W](i)
        var mask = _cmp_simd[T, W, op](lv, rv)
        _emit_lane_writes[W](mask, i, true_sel, false_sel)
        i += W

    # Scalar tail.
    while i < length:
        var lv = left.load[1](i)
        var rv = right.load[1](i)
        var keep = _cmp_scalar[T, op](lv, rv)
        if keep:
            true_sel.append(UInt32(i))
        else:
            false_sel.append(UInt32(i))
        i += 1

    return true_sel.len()


@always_inline
def _select_col_col_gather[
    T: DType, op: UInt8
](
    ref left: PrimitiveArray[T],
    ref right: PrimitiveArray[T],
    ref sel_in: RowSelectionVector,
    mut true_sel: RowSelectionVector,
    mut false_sel: RowSelectionVector,
) -> Int:
    """Gather path. Per-row scalar via `load_via_sel`."""
    var n_in = sel_in.len()
    var k = 0
    while k < n_in:
        var phys = sel_in.get(k)
        var lv = load_via_sel[T](left, sel_in, k)
        var rv = load_via_sel[T](right, sel_in, k)
        var keep = _cmp_scalar[T, op](lv, rv)
        if keep:
            true_sel.append(phys)
        else:
            false_sel.append(phys)
        k += 1

    return true_sel.len()
