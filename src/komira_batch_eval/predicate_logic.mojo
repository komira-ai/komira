# =============================================================================
# predicate_logic: AND/OR short-circuit and the shared predicate helpers
# =============================================================================
#
# The inner AND/OR short-circuit evaluators (three-valued: each identity is
# guarded by the left mask's validity), the INT64/FLOAT64 kernel dispatch, the
# null mask of an operand, the UINT64-vs-float literal comparison and the
# fixed-pattern string operators over a column.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.arithmetic import eval_and, eval_or
from komira_column_kernels.comparison import filter_to_indices
from komira_column_kernels.compiler_helpers import gather_batch
from komira_column_kernels.string_comparison import (
    eval_large_string_contains,
    eval_large_string_ends_with,
    eval_large_string_like,
    eval_large_string_starts_with,
    eval_string_contains,
    eval_string_ends_with,
    eval_string_like,
    eval_string_starts_with,
)
from komira_kernels.builtin_match_fns import (
    EqF64,
    EqI64,
    GeF64,
    GeI64,
    GtF64,
    GtI64,
    LeF64,
    LeI64,
    LtF64,
    LtI64,
    NeF64,
    NeI64,
)
from komira_plan_expr.expr import (
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    Expr,
    STR_CONTAINS,
    STR_ENDS_WITH,
    STR_LIKE,
    STR_STARTS_WITH,
)
from komira_scalar_arithmetic.int_overflow import is_int_overflow_error

from .arm_rows import batch_nulled_outside, undecided_rows
from .eval_dict import _materialize_dict_to_string
from .eval_predicate import _eval_predicate
from .predicate_compare import _scalar_cmp
from .string_bytes import string_array_of


# =============================================================================
# Inner-BinaryOp short-circuit AND/OR
#
# Short-circuit is wired per-BinaryOp at the Expr-evaluator layer — distinct
# from the top-level conjunction-narrowing path
# (`conjunction.evaluate_conjunction_select`). The conjunction path only
# fires for top-level AND chains that `flatten_and_conjuncts` flattens; the
# inner short-circuit fires for AND/OR sub-trees that the flattener can't
# reach (e.g. `(A AND B) OR (C AND D)` — the OR opaque to flatten, but each
# AND sub-tree still benefits from selective evaluation).
#
# Four cases per AND:
#   1. left_true == 0          -> all-false; right not evaluated
#   2. left_true == num_rows   -> result == right alone (left implied true)
#   3. left_true < num_rows/2  -> selective: gather batch to survivors,
#                                  eval right on the smaller batch, scatter back
#   4. else                     -> non-selective: eval right on full batch,
#                                  bitwise AND with left
#
# OR mirrors with cases 1/2 inverted (left_true == num_rows -> short-circuit
# all-true; left_true == 0 -> result == right alone). OR does not include
# the selective-filter case because the OR distribution doesn't get the same
# row-reduction benefit (rows where left=true must always pass without right
# evaluation — but the rows where left=false are exactly the ones that need
# right evaluation, so filtering doesn't reduce work; it's still O(num_rows)).
#
# ── ⭐ EVERY ONE OF THEM IS GUARDED BY `not left_mask.validity` ─────────────
#
# THE MECHANISM IN ONE LINE: all five cases branch on `left_true`, which counts
# DATA BITS, and a data bit of 0 means FALSE **or** UNKNOWN. Each identity is
# sound over the first reading and WRONG over the second:
#
#     AND case 1  `FALSE AND r = FALSE`   but `UNKNOWN AND FALSE` is FALSE,
#                 and this returns the left mask, which says UNKNOWN
#     AND case 2  `TRUE AND r = r`        (reachable with unknowns only if the
#                 data-bit-0-on-unknown invariant is broken upstream)
#     AND case 3  gathers to the rows whose data bit is set and scatters into a
#                 fresh array, so every left-UNKNOWN row is reported as a
#                 definite FALSE. (Its RIGHT-side UNKNOWNs are a separate
#                 defect, fixed in the scatter itself: see case 3's body.)
#     OR  case 2  `FALSE OR r = r`        but `UNKNOWN OR FALSE` is UNKNOWN
#
# ⛔ AND THE DIFFERENCE IS INVISIBLE AT A FILTER BOUNDARY AND INVERTED BY A
# NEGATION, which is why it survived: FALSE and UNKNOWN both fail a `WHERE`, so
# nothing that only ever looks at a top-level row set can see it. Put a `NOT`
# around the same node and FALSE becomes a selected row while UNKNOWN stays
# dropped. MEASURED against DuckDB 1.5.3 without the guard, over a null-pattern
# sweep: `NOT (tag='y3' AND note='zzz')` was
# CORRECT at all 18 sweep lengths and `NOT (note='zzz' AND tag='y3')` — the
# same predicate, operands swapped — was WRONG at 17 of them, because only the
# second spelling puts the nullable column on the left.
#
# ⚠ THIS IS THE TWIN OF A GUARD THAT ALREADY EXISTED. `conjunction.
# _predicate_3vl` reproduces three of these four identities and guards each
# with the same `if not l.validity`, and the block above `_normalize_3vl` there
# states the reason. These were the un-guarded copies; the two funnels now
# agree.
#
# ⚠ IT IS NOT A PERF REGRESSION ON A NON-NULLABLE COLUMN. `_apply_validity` and
# `kleene_cmp_finalize_scalar` attach a validity bitmap only when the input
# column HAS one, so an all-valid column reaches this function with
# `left_mask.validity` empty and takes exactly the path it took before. What
# pays is a predicate whose left arm is a nullable column, and what it pays is
# one full-batch evaluation of the right arm — the correct answer's price.
# =============================================================================


def _eval_short_circuit_and(
    left: Expr, right: Expr, batch: RecordBatch
) raises -> BooleanArray:
    """Short-circuit AND evaluation.
    """
    var left_mask = _eval_predicate(left, batch)
    var num_rows = batch.num_rows()
    var left_true = left_mask.true_count()

    # ⭐ ALL THREE SHORT-CIRCUITS ARE FULLY-KNOWN-ONLY.
    # See the block above this function for the measurement; the one-line
    # reason is that each of them reads `left_true`, a count over DATA BITS,
    # and a data bit of 0 means FALSE *or* UNKNOWN. Every identity below is
    # sound over the first reading and wrong over the second. A left mask
    # carrying validity falls through to case 4, whose `eval_and` is Kleene.
    if not left_mask.validity:
        # Case 1: all-false on left -> short-circuit, right never evaluated.
        if left_true == 0:
            return left_mask^

        # Case 2: all-true on left -> result is right alone.
        if left_true == num_rows:
            return _eval_predicate(right, batch)

        # Case 3: selective left (<50% pass) -> gather to survivors,
        #         eval right on smaller batch, scatter back.
        # The row-filter form is `compute::filter_record_batch` + a scatter loop;
        # the Mojo equivalent is `filter_to_indices` -> `gather_batch` ->
        # eval -> bit-by-bit scatter into a fresh full-width BooleanArray.
        if left_true < (num_rows >> 1):
            var indices = filter_to_indices(left_mask)
            var sub_batch = gather_batch(batch, indices)
            var right_filtered = _eval_predicate(right, sub_batch)
            # Scatter back. A row left made FALSE stays FALSE: `FALSE AND r`
            # is FALSE even when r is UNKNOWN. A survivor takes the RIGHT's
            # value, `TRUE AND r = r`, and that INCLUDES an UNKNOWN r.
            #
            # ⛔ THE SCATTER USED TO COPY ONLY THE RIGHT'S DATA BITS into a
            # non-nullable array, so `TRUE AND UNKNOWN` came back FALSE and an
            # enclosing NOT turned it into a SELECTED row: `NOT (k < 3 AND
            # flag)` selected the rows where `flag` is NULL. The guard above
            # covers an UNKNOWN on the LEFT only. So the result is nullable
            # exactly when the right mask is (as `eval_and` in case 4 does),
            # and a fully-known right still yields a non-nullable result at no
            # extra cost. Falsifier: `test_and_case3_*` in
            # `komira_batch_eval/tests/test_short_circuit_inner_binop.mojo`.
            var right_nullable = Bool(right_filtered.validity)
            var result = BooleanArray.allocate_nullable(
                num_rows
            ) if right_nullable else BooleanArray.allocate(num_rows)
            var fi = 0
            for i in range(num_rows):
                if left_mask.data.test(i):
                    var right_known = (
                        not right_nullable
                        or right_filtered.validity.value().test(fi)
                    )
                    if not right_known:
                        # TRUE AND UNKNOWN = UNKNOWN. The data bit stays 0,
                        # this repo's encoding of an UNKNOWN row.
                        result._set_null(i)
                    elif right_filtered.data.test(fi):
                        result.data.set(i)
                    fi += 1
            return result^

    # Case 4: non-selective (or a left mask carrying UNKNOWN) -> eval right on
    # the full batch and combine with the Kleene AND. ⛔ Right is asked only of
    # the rows left has not already made FALSE if it OVERFLOWS
    # (`_eval_right_over_undecided`).
    var right_mask = _eval_right_over_undecided(right, batch, left_mask, False)
    return eval_and(left_mask, right_mask)


def _eval_short_circuit_or(
    left: Expr, right: Expr, batch: RecordBatch
) raises -> BooleanArray:
    """Short-circuit OR evaluation.
    """
    var left_mask = _eval_predicate(left, batch)
    var num_rows = batch.num_rows()
    var left_true = left_mask.true_count()

    # ⭐ FULLY-KNOWN-ONLY, same guard and same reason as the AND above. Case 2
    # is the one that is actually wrong without it: `UNKNOWN OR FALSE` is
    # UNKNOWN, not FALSE, so returning the right mask alone reports a definite
    # FALSE that an enclosing `NOT` then turns into a selected row. Case 1 is
    # sound today only because of an invariant this function does not own (a
    # data bit of 1 on an unknown row would make `left_true == num_rows`
    # reachable with unknowns present); it is guarded rather than left resting
    # on a property established elsewhere.
    if not left_mask.validity:
        # Case 1: all-true on left -> short-circuit, right never evaluated.
        if left_true == num_rows:
            return left_mask^

        # Case 2: all-false on left -> result is right alone.
        if left_true == 0:
            return _eval_predicate(right, batch)

    # Case 3 (no equivalent of AND's selective case here — see module
    # comment): eval right on full batch, Kleene OR.
    var right_mask = _eval_right_over_undecided(right, batch, left_mask, True)
    return eval_or(left_mask, right_mask)


def _eval_right_over_undecided(
    right: Expr, batch: RecordBatch, imm left_mask: BooleanArray, is_or: Bool
) raises -> BooleanArray:
    """The right side of an AND (`is_or=False`) / OR (`is_or=True`) over the
    whole batch — and, if THAT raises an integer OVERFLOW, over only the rows
    the left side has NOT decided (AND: left TRUE or UNKNOWN; OR: left FALSE or
    UNKNOWN), every other row NULL. DuckDB never evaluates the right side on a
    decided row, so `WHERE a < 100 AND a + b > 0` answers where `a + b`
    overflows only on a row `a < 100` rejects. The Kleene
    combine reads a NULL right only where left already decided the row: FALSE
    AND NULL is FALSE, TRUE OR NULL is TRUE. See `arm_rows.mojo`."""
    try:
        return _eval_predicate(right, batch)
    except err:
        if not is_int_overflow_error(String(err)):
            raise err^
    return _eval_predicate(
        right, batch_nulled_outside(batch, undecided_rows(left_mask, is_or))
    )


# =============================================================================
# comptime kernel-dispatch gate
# =============================================================================
#
# This gate decides whether routing the 12 cells (BIN_LT/LE/GT/GE/EQ/NE x
# INT64+FLOAT64) at `_eval_predicate` goes through the standalone `MatchFn`
# kernels instead of the existing path. The existing path (the
# `komira_column_kernels/comparison.mojo` kernels) is ALREADY hand-staged SIMD
# compare-pack (`_eval_cmp_lt[si64]` emits `cmgt.2d` NEON SIMD, the same opcode
# as the MatchFn `LtI64` cell), so the gate exists to quantify the rewire's delta.
#
# Default OFF. Toggling the flag to True at experiment time activates the
# kernel path for the 12 cells; everything else (decimals, strings, NULL,
# IN_LIST, regex, etc.) stays on the existing path unchanged.
# =============================================================================


comptime USE_KERNEL_COMPTIME_FILTER: Bool = False


def _broadcast_to_array_int64(value: Int64, n: Int) -> PrimitiveArray[DType.int64]:
    """Allocate a length-N PrimitiveArray[Int64] filled with `value`.

    Used only when `USE_KERNEL_COMPTIME_FILTER=True` to construct a synthetic
    column-shaped RHS for MatchFn (which is col-vs-col by design). The
    allocate + fill loop is an inherent cost of routing col-vs-literal
    through a col-vs-col kernel; the existing scalar path avoids this.
    """
    var arr = PrimitiveArray[DType.int64].allocate(n)
    # Origin-tied via
    # the function-scope view_mut local; the view borrow is released
    # by NLL at last-use (the `ptr.store` loop tail) so the trailing
    # `return arr^` move compiles cleanly.
    var arr_view = arr.view_mut()
    var ptr = arr_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    for i in range(n):
        ptr.store[width=1](i, value)
    return arr^


def _broadcast_to_array_float64(value: Float64, n: Int) -> PrimitiveArray[DType.float64]:
    """Float64 sibling of `_broadcast_to_array_int64`."""
    var arr = PrimitiveArray[DType.float64].allocate(n)
    # See sibling above.
    var arr_view = arr.view_mut()
    var ptr = arr_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    for i in range(n):
        ptr.store[width=1](i, value)
    return arr^


# NOTE: Mojo 1.0.0b1 does NOT widen `F.T` to a concrete `DType` via
# `constrained[F.T == DType.int64]` at the call site — the kernel body
# still sees `PrimitiveArray[F.T]` and rejects a `PrimitiveArray[Int64]`
# passed in. Same compiler limitation as the sub-trait widening rejected
# through `@parameter if conforms_to(F, <sub-trait>)`.
# Workaround: inline the kernel call per cell instead of factoring
# through a `[F: MatchFn]`-parametric helper.
#
# Each kernel cell is a `Movable + Copyable` POD struct with one method
# `eval_chunk(self, lhs, rhs, mut out_mask) -> Int`. Direct call: avoids
# the F-widening problem entirely.


def _dispatch_int64_via_kernel(
    op: UInt8,
    lhs: PrimitiveArray[DType.int64],
    rhs: PrimitiveArray[DType.int64],
) raises -> BooleanArray:
    """Dispatch the 6 Int64 op cells through the matching `MatchFn`
    kernel from `builtin_match_fns`. Returns a packed `BooleanArray`.

    `op` is a runtime tag from `komira_plan_expr.expr` (BIN_LT/LE/...).
    The per-op branch is a comptime-known dispatch at the matched
    arm — each arm invokes a distinct kernel monomorphization.
    """
    var n = lhs.length
    var mask = Bitmap.create(n)
    if op == BIN_LT:
        var f = LtI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_LE:
        var f = LeI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_GT:
        var f = GtI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_GE:
        var f = GeI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_EQ:
        var f = EqI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_NE:
        var f = NeI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    else:
        raise Error("PipelineCompiler[KERNEL]: unsupported comparison op for int64: " + String(Int(op)))
    return BooleanArray.from_bitmap(mask^)


def _dispatch_float64_via_kernel(
    op: UInt8,
    lhs: PrimitiveArray[DType.float64],
    rhs: PrimitiveArray[DType.float64],
) raises -> BooleanArray:
    """Float64 sibling of `_dispatch_int64_via_kernel`."""
    var n = lhs.length
    var mask = Bitmap.create(n)
    if op == BIN_LT:
        var f = LtF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_LE:
        var f = LeF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_GT:
        var f = GtF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_GE:
        var f = GeF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_EQ:
        var f = EqF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_NE:
        var f = NeF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    else:
        raise Error("PipelineCompiler[KERNEL]: unsupported comparison op for float64: " + String(Int(op)))
    return BooleanArray.from_bitmap(mask^)


# =============================================================================
# Predicate evaluation — Expr tree -> BooleanArray
# =============================================================================


@always_inline
def _is_comparison_op(op: UInt8) -> Bool:
    """True iff `op` is one of the six SQL relational comparison operators
    (`<`, `<=`, `>`, `>=`, `=`, `<>`), i.e. an op whose result is a boolean
    mask. Guards the computed-LHS materialization path so a non-comparison
    binary op (e.g. arithmetic mistakenly reaching the predicate arm) falls
    through to the existing dispatch rather than into `_eval_col_vs_col_promoted`.
    """
    return (
        op == BIN_LT
        or op == BIN_LE
        or op == BIN_GT
        or op == BIN_GE
        or op == BIN_EQ
        or op == BIN_NE
    )


# =============================================================================
# ⚠ THE DISPATCHER NULL CONTRACT — every DType arm below, no exceptions
# =============================================================================
#
# `_eval_predicate` is not a comparison
# implementation; it is the per-DType DISPATCHER that chooses one. It chose
# INCONSISTENTLY: the DECIMAL128 and temporal arms finalized
# through `kleene_cmp_finalize*`, while the INT64 / INT32 / FLOAT64 arms
# `return`ed the raw SIMD compare-pack kernel (`eval_lt[...]`, `eval_col_gt[...]`)
# — which reads the VALUE buffer and never the validity bitmap.
#
# THE CONTRACT, stated by `eval_not`'s header (`komira_column_kernels/arithmetic.mojo`):
#
#     A row whose predicate value is UNKNOWN carries DATA BIT 0.
#     The validity bitmap says WHY it is 0 — unknown, not false.
#
# BOTH halves are load-bearing and they serve different consumers:
#   * data bit 0 — `SelectionVector.from_bool_mask` and `filter_to_indices`
#     walk the DATA bitmap 64 bits at a time and never read validity. Data bit
#     0 is the only reason they drop an UNKNOWN row.
#   * the validity bitmap — `residual_mask_eval._residual_pass_mask` asks
#     `ba.is_null(i)`. With no bitmap that question is unconditionally False,
#     so its NULL handling was unreachable code, not a bug it could hit.
#
# WHY THE VIOLATION SURVIVED: `conjunction._collapse_nulls_to_false` repairs
# the mask, at exactly TWO call sites (both in `evaluate_predicate_selected`).
# Every other `_eval_predicate` consumer — `StreamingFilterOp`, the streaming
# and columnar agg consumers, the parquet pushed-filter paths, CASE/WHEN,
# `residual_mask_eval` — got the raw mask. Measured through the production
# `StreamingFilterOp`: `a < 100` over a nullable INT64 column SELECTED the NULL
# row, and with a zero-filled null slot (what a zero-filling decoder leaves)
# `a = 0` returned ONLY the NULL row — a row that logically does not exist.
#
# HOW TO ADD AN ARM: compute the raw data bits on every lane, then finalize —
# `kleene_cmp_finalize_scalar(raw^, arr.validity, ...)` for col-vs-literal,
# `kleene_cmp_finalize(raw^, l.validity, r.validity, ...)` for col-vs-col (or
# the `_scalar_cmp` / `_col_cmp_nullable` helpers above, which pair them).
# Never `return` a bare kernel result.
#
# INSIDE THE CONTRACT: `_eval_col_vs_col_promoted` (`eval_column.mojo`) —
# the mixed-type / computed-operand path, reached from THIS function's
# computed-LHS arm, general-RHS arm, and INT-col-vs-FLOAT-literal promotion.
# All nine of its arms returned raw `eval_col_*`, and four of them destroyed
# the narrow operand's validity even earlier, in a hand-rolled widening loop
# with no `clone_array_validity`. It now widens through validity-preserving
# helpers and finalizes through `_col_cmp_nullable` — the SAME helper
# `_eval_col_vs_col` below uses, which is why that helper now LIVES in
# `eval_column` and is imported here.
#
# STILL OUTSIDE THIS CONTRACT (deliberately named, not silently omitted):
#   * `_numeric_dict_filter_dispatch` / `dict_filter_eval_bool_mask` — the
#     dict arms, whose comments assert the caller applies the row-validity
#     collapse. That is the same assumption that proved false for the int
#     arms; it has not been re-checked here.
#   * ~~`_eval_short_circuit_and` case 3 — scatters into a fresh
#     `BooleanArray.allocate`, so the merged result is data-correct (UNKNOWN
#     stays 0) but loses the WHY.~~ and
#     "loses the WHY" understated it: losing the why IS a wrong answer one
#     `NOT` away, and that is how it was found. Case 3 — and the other three
#     short-circuits — are now unreachable with a validity-bearing left mask.
#     ⚠ That closed the LEFT half only. The scatter still dropped an UNKNOWN
#     from the RIGHT side until (found by the batch-1 merge review,
#     after the bare-BOOLEAN arm made `NOT (p AND flag)` a new spelling of it);
#     it now carries the right mask's validity.
# =============================================================================


def _null_mask_of(
    ref col: Column[HeapRegion], num_rows: Int, want_null: Bool
) raises -> BooleanArray:
    """The `IS NULL` / `IS NOT NULL` mask of an ALREADY-MATERIALIZED column.

    `data[r] = 1` iff row `r` is null (`want_null=True`) or non-null
    (`want_null=False`); validity all-ones, because the answer to "is this
    null" is itself never unknown.

    ⚠ THE NO-VALIDITY-BITMAP CASE IS ASYMMETRIC and that is why the two
    polarities cannot be one body with a `~` toggled. Arrow's "no validity
    bitmap" means EVERY ROW IS VALID, so `IS NULL` is all-zero (which is what
    `allocate_nullable`'s zero-fill already gives) and `IS NOT NULL` is
    all-ONES (which it does not). Getting that backwards is a silent
    all-rows/no-rows answer, never an error.

    Extracted so the COL_REF fast path and the general-child
    fallback in `_eval_predicate`'s `EXPR_UNARY_OP` arm share one
    bit-twiddle. Module-internal: the raw pointers never leave this function.
    """
    var ba = BooleanArray.allocate_nullable(num_rows)
    var n_bytes = (num_rows + 7) >> 3
    var trailing = num_rows & 7
    # SAFETY: `d_view` / `v_view` are function-scope ByteView locals that pin
    # their buffers alive across the loop below; both pointers die here.
    var d_view = ba.data.buffer.view_mut()
    var d_ptr = d_view._unsafe_ptr()
    if col._validity:
        var v_view = col._validity.value().buffer.view_ro()
        var v_ptr = v_view._unsafe_ptr()
        if want_null:
            for b in range(n_bytes):
                (d_ptr + b)[] = ~(v_ptr + b)[]
        else:
            for b in range(n_bytes):
                (d_ptr + b)[] = (v_ptr + b)[]
    else:
        var fill = UInt8(0x00) if want_null else UInt8(0xFF)
        for b in range(n_bytes):
            (d_ptr + b)[] = fill
    # Clear the bits past `num_rows` in the last byte so they cannot read as
    # phantom set rows downstream.
    if trailing > 0 and n_bytes > 0:
        var mask = UInt8((1 << trailing) - 1)
        (d_ptr + n_bytes - 1)[] = (d_ptr + n_bytes - 1)[] & mask
    return ba^


def _u64_cmp_vs_float_literal(
    arr: PrimitiveArray[DType.uint64], lit: Float64, op: UInt8
) raises -> BooleanArray:
    """`uint64 column OP float literal`, decided EXACTLY, with the column left
    in the unsigned domain.

    ⛔ THE OBVIOUS SPELLING IS WRONG TWICE OVER. Casting the COLUMN to Float64
    (what the INT64/INT32 arm does) collapses every value above `2**53` onto a
    neighbour — `2**64-1` and `2**64-2` are one Float64 — and casting the
    LITERAL to UInt64 is undefined for a negative or `>= 2**64` argument and
    silently drops the fractional part, which changes the answer for four of
    the six operators.

    THE REDUCTION: a float threshold `f` splits the unsigned line at
    `floor(f)`, so each comparison becomes an INTEGER comparison against
    `u = floor(f)` — with the operator adjusted when `f` has a fraction, since
    no integer can sit strictly between `u` and `f`:

        f fractional:  v <  f  ==  v <= u        v >  f  ==  v >  u
                       v <= f  ==  v <= u        v >= f  ==  v >  u
                       v == f  ==  never         v != f  ==  always

    Out of range is answered on its own terms: every unsigned value is above a
    NEGATIVE threshold and below one at or past `2**64` (which includes `+inf`,
    and is where a float spelling of `18446744073709551615` lands — that
    literal IS `2**64` in Float64, so `= 18446744073709551615.0` is correctly
    EMPTY rather than the top row). NaN orders against nothing, so only `!=`
    holds.

    ⚠ EVERY CONSTANT ANSWER IS SPELLED AS A REAL COMPARE IN THE UNSIGNED
    DOMAIN (`v >= 0` / `v < 0`) rather than a synthesized mask, so the raw
    bits, the lane order and the offset handling stay the kernel's own and this
    file grows no second way to build a mask."""
    var all_rows = BIN_GE  # `v >= 0` — true for every row
    var no_rows = BIN_LT  # `v <  0` — true for none
    var zero = Scalar[DType.uint64](UInt64(0))

    if lit != lit:  # NaN
        return _scalar_cmp[DType.uint64](
            arr, zero, all_rows if op == BIN_NE else no_rows
        )
    if lit < 0.0:
        var above = op == BIN_GT or op == BIN_GE or op == BIN_NE
        return _scalar_cmp[DType.uint64](
            arr, zero, all_rows if above else no_rows
        )
    if lit >= 18446744073709551616.0:  # 2**64, and +inf
        var below = op == BIN_LT or op == BIN_LE or op == BIN_NE
        return _scalar_cmp[DType.uint64](
            arr, zero, all_rows if below else no_rows
        )

    # In range: truncation toward zero IS floor for a non-negative argument.
    var u = Scalar[DType.float64](lit).cast[DType.uint64]()
    var frac = u.cast[DType.float64]() != lit

    var kop = op
    if frac:
        if op == BIN_LT or op == BIN_LE:
            kop = BIN_LE
        elif op == BIN_GT or op == BIN_GE:
            kop = BIN_GT
        elif op == BIN_EQ:
            return _scalar_cmp[DType.uint64](arr, zero, no_rows)
        else:  # BIN_NE
            return _scalar_cmp[DType.uint64](arr, zero, all_rows)
    return _scalar_cmp[DType.uint64](arr, u, kop)


def _eval_string_op_on_column(
    col_ptr: Column[HeapRegion], str_op: UInt8, pattern: String
) raises -> BooleanArray:
    """The `EXPR_STRING_OP` pattern kernels over ONE string column — a scan
    column or a computed one (`_eval_predicate`'s EXPR_STRING_OP arm and the
    projection arm in `eval_column` both call it, so the two contexts
    cannot disagree about which rows match)."""
    var col_at = col_ptr.arrow_type
    if col_at != ArrowType.STRING and col_at != ArrowType.DICTIONARY and col_at != ArrowType.LARGE_STRING:
        raise Error("PipelineCompiler: string operations require STRING / LARGE_STRING / DICTIONARY column, got " + String(col_at))

    # LARGE_STRING
    # pattern-op parity.  Routes to the Int64-offset siblings of the
    # eval_string_* pattern kernels.  Same shared `@parameter
    # fn _string_*_kernel[OffsetType]` body; byte-identical results.
    if col_at == ArrowType.LARGE_STRING:
        var arr_l = col_ptr.as_large_string()
        if str_op == STR_CONTAINS:
            return eval_large_string_contains(arr_l, pattern)
        elif str_op == STR_STARTS_WITH:
            return eval_large_string_starts_with(arr_l, pattern)
        elif str_op == STR_ENDS_WITH:
            return eval_large_string_ends_with(arr_l, pattern)
        elif str_op == STR_LIKE:
            return eval_large_string_like(arr_l, pattern)
        else:
            raise Error("PipelineCompiler: unsupported string operation on LARGE_STRING: " + String(Int(str_op)))

    # For DICTIONARY columns, resolve to StringArray for string ops.
    # Dict-aware CONTAINS/STARTS_WITH/ENDS_WITH/LIKE is a future optimization.
    var arr: StringArray[HeapRegion]
    if col_at == ArrowType.DICTIONARY:
        arr = _materialize_dict_to_string(col_ptr)
    else:
        # Lane G L1: read in place, as the comparison arm above does.
        arr = string_array_of(col_ptr)
    if str_op == STR_CONTAINS:
        return eval_string_contains(arr, pattern)
    elif str_op == STR_STARTS_WITH:
        return eval_string_starts_with(arr, pattern)
    elif str_op == STR_ENDS_WITH:
        return eval_string_ends_with(arr, pattern)
    elif str_op == STR_LIKE:
        return eval_string_like(arr, pattern)
    else:
        raise Error("PipelineCompiler: unsupported string operation: " + String(Int(str_op)))
