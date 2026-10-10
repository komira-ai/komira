# =============================================================================
# MIN/MAX OVER AN ORDERED-BUT-NOT-ARITHMETIC INPUT — the 0-key fold's reader,
# its comparator and its ONE emitter.
# =============================================================================
#
# ★ WHY THIS IS ITS OWN MODULE. It is the whole of what a MIN/MAX needs that
# SUM and MEAN do not have a use for, and keeping it apart from the arithmetic
# folds in `agg_scalar_fold.mojo` keeps the two requirements from being
# conflated. Every function here is DType-driven and stateless; the
# aggregate plumbing (name resolution, the decline contract, the streaming
# entries) stays in `agg_scalar_fold.mojo` and calls in.
#
# Encapsulation (pointer rules): no `UnsafePointer` in any signature
# here; the readers go through `RecordBatch`'s own typed accessors.
# =============================================================================

from std.collections import List

from komira_arrow.schema import (
    ArrowType, Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.large_string_array import LargeStringArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import AGG_MIN

# =============================================================================
# ★ MIN/MAX OVER AN ORDERED-BUT-NOT-ARITHMETIC INPUT.
# =============================================================================
#
# THE ONLY THING MIN/MAX NEEDS IS A TOTAL ORDER. SUM and MEAN need an
# accumulator whose family and width the kernel has to know — that is what
# `_is_int_family_arrow` / `_is_float_family_arrow` are FOR, and for those four
# ops the requirement is real. MIN/MAX never add anything: they keep the
# smallest (largest) value they have seen, which needs `<` and nothing else.
#
# Sweeping MIN/MAX into the numeric gate with its arithmetic siblings would
# make `SELECT min(order_date) FROM orders` and `SELECT max(name) FROM t` —
# both ordinary SQL — fail with
#
#     agg_node_exec: out-of-envelope 0-key scalar agg ... with an int/float
#     input DType
#
# `count(<col>)` is gated the same way (it needs no order at all, only the
# validity bitmap); MIN/MAX's real requirement is one notch stronger.
#
# ⚠⚠ THE OUTPUT TYPE IS HALF OF IT, AND IT IS THE HALF THAT GOES SILENTLY
# WRONG. `min(<date>)` is a DATE. Draining the fold's int32 cell as an INT64
# column would hand the caller 18000 with a schema that says BIGINT, and the
# C Data Interface would export that verbatim — a wrong answer no value
# assertion written against the cell can see. Every arm below emits the INPUT's
# OWN ArrowType. (The int/float arms widen to INT64/FLOAT64; several tests pin
# that contract.)
#
# ⛔ NOT SERVED HERE, AND EACH FOR A STATED REASON rather than by omission:
#   * DECIMAL128 / DECIMAL256 — ordered, but the compare is 128/256-bit and
#     `_scalar_null_*` has no cell for the result. A real gap; it declines
#     loudly.
#   * BOOL — ordered (false < true), but `Column.as_boolean` returns a
#     bit-packed `BooleanArray`, a third reader shape. Nothing asks for
#     `min(<bool>)`; it declines.
#   * INTERVAL_* — Arrow's intervals are not totally ordered (a month is not a
#     fixed number of days), so "the smallest one" is not defined. This is the
#     one member of the int32/int64-storage families deliberately EXCLUDED
#     rather than merely unimplemented.
#   * LIST / STRUCT / MAP / UNION — no total order.
# =============================================================================

comptime _MINMAX_ORD_NONE: Int = 0
"""`at` has no order this fold can use — DECLINE."""
comptime _MINMAX_ORD_I32: Int = 1
"""Ordered by its INT32 storage word (DATE32, TIME32_*)."""
comptime _MINMAX_ORD_I64: Int = 2
"""Ordered by its INT64 storage word (DATE64, TIMESTAMP*, TIME64_*, DURATION_*)."""
comptime _MINMAX_ORD_STR: Int = 3
"""Ordered lexicographically over UTF-8 bytes (STRING)."""
comptime _MINMAX_ORD_LSTR: Int = 4
"""As `_MINMAX_ORD_STR`, with int64 offsets (LARGE_STRING)."""


def _minmax_ordered_storage(at: ArrowType) -> Int:
    """Which READER a 0-key MIN/MAX over `at` folds through, or
    `_MINMAX_ORD_NONE` when this fold has no order for `at`.

    ⚠ THE INT AND FLOAT FAMILIES ARE DELIBERATELY *NOT* MEMBERS. They already
    have an arm (`_fold_int_family` / `_fold_float_family`), whose I64/F64
    output-widening contract predates this function; routing them here as well
    would change `min(<int32>)`'s output type from INT64 to INT32 as a side
    effect of a widening that is supposed to be additive. The two dispatches
    are disjoint by construction and the caller checks this one SECOND."""
    if at == ArrowType.DATE32 or at == ArrowType.TIME32_S or at == ArrowType.TIME32_MS:
        return _MINMAX_ORD_I32
    if (
        at == ArrowType.DATE64
        or at == ArrowType.TIME64_US
        or at == ArrowType.TIME64_NS
        or at.is_timestamp()
        or at.is_duration()
    ):
        return _MINMAX_ORD_I64
    if at == ArrowType.STRING:
        return _MINMAX_ORD_STR
    if at == ArrowType.LARGE_STRING:
        return _MINMAX_ORD_LSTR
    return _MINMAX_ORD_NONE


def _fold_minmax_ordered_int[
    dt: DType
](
    imm batch: RecordBatch, ci: Int, op: UInt8, mut have: Bool
) raises -> Scalar[dt]:
    """MIN/MAX over the NON-NULL rows of column `ci`, read at its own storage
    width `dt` and compared AS THAT WIDTH (never widened first). `have` is set
    True iff at least one non-null row contributed; when it stays False the
    caller emits NULL, because min/max over an EMPTY multiset is NULL and not
    the zero date."""
    var col = batch.column_as_primitive[dt](ci)
    var n = batch.num_rows()
    var best = Scalar[dt](0)
    for r in range(n):
        if col.is_null(r):
            continue
        var v = col.get(r)
        if not have:
            best = v
            have = True
        elif op == AGG_MIN:
            if v < best:
                best = v
        else:
            if v > best:
                best = v
    return best


def _fold_minmax_ordered_string(
    imm batch: RecordBatch,
    ci: Int,
    op: UInt8,
    ord_kind: Int,
    mut have: Bool,
) raises -> String:
    """MIN/MAX over the NON-NULL rows of a STRING / LARGE_STRING column `ci`.

    ⚠ THE COMPARE IS Mojo `String` `<` / `>`, I.E. THE LEXICOGRAPHIC UTF-8
    BYTE ORDER — the SAME compare `cd_grouped_fold.
    fold_grouped_string_minmax_over_batch` performs at n_keys >= 1, and the
    same one the column `ACC_MIN_UTF8` / `ACC_MAX_UTF8` accumulators compute.
    This is the 0-key sibling of that fold, NOT a second ordering: the grouped
    route is gated on `>= 1` group key, so a 0-key string min/max is served
    here and nowhere else.

    `have` stays False iff no row contributed, which the caller must drain as
    NULL rather than `""` — see `_emit_minmax_ordered`."""
    var best = String("")
    var n = batch.num_rows()
    if ord_kind == _MINMAX_ORD_STR:
        var sa = batch.column_as_string(ci)
        for r in range(n):
            if sa.is_null(r):
                continue
            var v = sa.get(r)
            if not have:
                best = v
                have = True
            elif op == AGG_MIN:
                if v < best:
                    best = v
            else:
                if v > best:
                    best = v
        return best
    var la = batch.column_as_large_string(ci)
    for r in range(n):
        if la.is_null(r):
            continue
        var v = la.get(r)
        if not have:
            best = v
            have = True
        elif op == AGG_MIN:
            if v < best:
                best = v
        else:
            if v > best:
                best = v
    return best


def _emit_minmax_ordered(
    mut rbb: RecordBatchBuilder,
    mut out_sb: SchemaBuilder,
    out_name: String,
    at: ArrowType,
    ord_kind: Int,
    have: Bool,
    v32: Int32,
    v64: Int64,
    vstr: String,
) raises:
    """Append the (column, field) pair for ONE ordered-type MIN/MAX result.

    ★ ONE EMITTER, TWO CALLERS, SO THE OUTPUT TYPE CANNOT DISAGREE WITH
    ITSELF. `fold_scalar_agg_over_batch` calls it with the folded value and
    `build_empty_scalar_agg_identity` calls it with `have = False`. Those two
    sites decide the output dtype for the SAME query depending only on whether
    the scan produced rows, and a query whose result TYPE changes with its row
    count is a wrong answer at the C Data Interface — and two separate
    emitters for the identity row and the folded value could drift apart.

    ⚠ `have == False` DRAINS NULL, NOT `""` AND NOT THE ZERO DATE. An empty
    multiset's min/max is NULL; `''` and day 0 are both legitimate VALUES this
    fold can return, so only a nullable output column can tell them apart.
    `nullable` is set from `not have` for the same reason the sibling numeric
    arms set it: a result carrying no NULL keeps the exact non-nullable field
    it had, so no currently-green byte-equivalence fixture moves."""
    if ord_kind == _MINMAX_ORD_I32:
        var a32 = PrimitiveArray[DType.int32].allocate_nullable(1)
        if have:
            a32.set(0, v32)
        else:
            a32._set_null(0)
        rbb.add_column(
            Column.from_primitive_with_arrow_type[DType.int32](a32^, at)
        )
        out_sb.add_field(Field(out_name, at, not have))
        return
    if ord_kind == _MINMAX_ORD_I64:
        var a64 = PrimitiveArray[DType.int64].allocate_nullable(1)
        if have:
            a64.set(0, v64)
        else:
            a64._set_null(0)
        rbb.add_column(
            Column.from_primitive_with_arrow_type[DType.int64](a64^, at)
        )
        out_sb.add_field(Field(out_name, at, not have))
        return
    var svals = List[String]()
    svals.append(vstr)
    var svalid = List[Bool]()
    svalid.append(have)
    if ord_kind == _MINMAX_ORD_STR:
        var out_sa = StringArray.from_strings_with_validity(svals, svalid)
        rbb.add_column(Column.from_string(out_sa^))
        out_sb.add_field(Field(out_name, ArrowType.STRING, not have))
        return
    if ord_kind == _MINMAX_ORD_LSTR:
        var out_la = LargeStringArray.from_strings_with_validity(svals, svalid)
        rbb.add_column(Column.from_large_string(out_la^))
        out_sb.add_field(Field(out_name, ArrowType.LARGE_STRING, not have))
        return
    raise Error(
        "agg_minmax_ordered._emit_minmax_ordered: no emitter for ord_kind "
        + String(ord_kind)
        + " — `_minmax_ordered_storage` and this emitter must name the SAME"
        " set."
    )
