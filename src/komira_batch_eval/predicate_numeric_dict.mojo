# =============================================================================
# predicate_numeric_dict: predicates over dictionary-encoded numeric columns
# =============================================================================
#
# A `col OP literal` predicate over a numeric dictionary column is decided once
# per dictionary entry and then mapped over the codes, never by materializing
# the per-row values. `numeric_dict_filter_via_flat` is the materializing
# oracle the tests compare against; `count_numeric_dict_predicate` and
# `survivors_numeric_dict_predicate` fuse the predicate with a count or a
# survivor list.
# =============================================================================

from std.sys import simd_width_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.dict_code_bounds import validate_dict_codes
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.cast_null import eval_cast
from komira_column_kernels.comparison import (
    eval_eq,
    eval_ge,
    eval_gt,
    eval_le,
    eval_lt,
    eval_ne,
)
from komira_plan_expr.expr import (
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
)
from komira_plan_expr.literal_domain import int_literal_fits
from komira_plan_expr.scalar_value import ScalarValue

from .integer_literal_value import read_integer_literal_for_column
from .numeric_dict_lut_scan import numeric_dict_codes_to_mask
from .predicate_compare import _scalar_cmp_i32_widening


# =============================================================================
# Numeric-dict predicate-over-codes LUT
# =============================================================================
#
# STRUCTURAL MIRROR of `dict_filter_eval_bool_mask` (the production STRING-dict
# filter-over-codes path, `komira_column_kernels/dict_filter.mojo`). The string kernel:
#   Phase 1: evaluate the predicate against the D dictionary ENTRIES -> a
#            D-sized keep-bit buffer (`dict_match`).
#   Phase 2: scan the N per-row CODES against the keep-bit buffer, packing one
#            bit per row -> a non-nullable BooleanArray.
#
# This is the NUMERIC analogue. It KILLS the v1 densification band-aid
# (`resolve_numeric_dict_to_flat` + `_resolve_numeric_dict_cols_to_flat`) whose
# own docstring admits it "re-introduces the per-row gather AT FILTER TIME".
# Instead of materializing N flat values then comparing N times, we resolve the
# <= dict_size DISTINCT entries ONCE (`dict_value_i64` / `dict_value_f64`),
# compare each against the encoded literal to build a D-sized keep-bit LUT, then
# scan the N codes against the LUT. Cost: O(D) compares + O(N) int lookups.
#
# BYTE-IDENTICAL to `resolve_numeric_dict_to_flat` then dispatching the flat
# compare kernels (`eval_gt[int64]`, ...): same value resolution per code (the
# SAME `dict_value_*(dict_code_at(r))` gather the flat decode performs), the
# SAME threshold encoding (int dicts compare `lit_val.int_val`; float dicts
# compare `lit_val.float_val`; int32 truncates to the low 32 bits exactly as
# the flat write does), and the SAME non-nullable BooleanArray output shape
# (one data bit per row; the per-row null-collapse is applied separately by the
# caller via the dict column's row-validity bitmap — UNCHANGED).
#
# SILENT-WRONG GUARD (two-distinct-dict): this helper ONLY fires on the
# `col_ref OP literal` shape (the dispatcher's numeric-dict arm). A
# numeric-dict-col vs numeric-dict-col comparison routes to `_eval_col_vs_col`
# (both columns are arrow_type==DICTIONARY), which has NO DICTIONARY arm and
# RAISES — so a meaningless code-vs-code compare across DIFFERENT per-RG
# dictionaries is structurally impossible (it declines to the value domain
# upstream). Do NOT add a DICTIONARY arm to `_eval_col_vs_col`.
# =============================================================================


@always_inline
def _numeric_dict_keep_int(
    col_ptr: Column[HeapRegion], op: UInt8, threshold: Int64
) raises -> List[Bool]:
    """Phase 1 (INT dict): build the per-CODE keep-bit LUT by resolving each
    of the `dict_size` distinct entries to its Int64 value and comparing it
    against `threshold`. Index = dict code; value = does this entry pass."""
    var d = col_ptr.dict_size()
    var keep = List[Bool](capacity=d)
    for code in range(d):
        var v = col_ptr.dict_value_i64(code)
        var pass_: Bool
        if op == BIN_GT:
            pass_ = v > threshold
        elif op == BIN_LT:
            pass_ = v < threshold
        elif op == BIN_EQ:
            pass_ = v == threshold
        elif op == BIN_NE:
            pass_ = v != threshold
        elif op == BIN_GE:
            pass_ = v >= threshold
        elif op == BIN_LE:
            pass_ = v <= threshold
        else:
            raise Error(
                "numeric-dict LUT: unsupported op for int dict: " + String(Int(op))
            )
        keep.append(pass_)
    return keep^


@always_inline
def _numeric_dict_keep_int32(
    col_ptr: Column[HeapRegion], op: UInt8, threshold: Int32
) raises -> List[Bool]:
    """Phase 1 (INT32 dict): as `_numeric_dict_keep_int`, but the entry value
    is truncated to the low 32 bits FIRST (byte-identical to the flat int32
    write `dict_value_i64(code) & 0xFFFFFFFF` then an Int32 compare)."""
    var d = col_ptr.dict_size()
    var keep = List[Bool](capacity=d)
    for code in range(d):
        # Mirror resolve_numeric_dict_to_flat int32 arm: low-32-bit truncation.
        var v = Int32(
            Int((col_ptr.dict_value_i64(code) & Int64(0xFFFFFFFF)))
        )
        var pass_: Bool
        if op == BIN_GT:
            pass_ = v > threshold
        elif op == BIN_LT:
            pass_ = v < threshold
        elif op == BIN_EQ:
            pass_ = v == threshold
        elif op == BIN_NE:
            pass_ = v != threshold
        elif op == BIN_GE:
            pass_ = v >= threshold
        elif op == BIN_LE:
            pass_ = v <= threshold
        else:
            raise Error(
                "numeric-dict LUT: unsupported op for int32 dict: " + String(Int(op))
            )
        keep.append(pass_)
    return keep^


@always_inline
def _numeric_dict_keep_f64(
    col_ptr: Column[HeapRegion], op: UInt8, threshold: Float64
) raises -> List[Bool]:
    """Phase 1 (FLOAT64 dict): build the keep-bit LUT comparing each entry's
    Float64 value against `threshold`."""
    var d = col_ptr.dict_size()
    var keep = List[Bool](capacity=d)
    for code in range(d):
        var v = col_ptr.dict_value_f64(code)
        var pass_: Bool
        if op == BIN_GT:
            pass_ = v > threshold
        elif op == BIN_LT:
            pass_ = v < threshold
        elif op == BIN_EQ:
            pass_ = v == threshold
        elif op == BIN_NE:
            pass_ = v != threshold
        elif op == BIN_GE:
            pass_ = v >= threshold
        elif op == BIN_LE:
            pass_ = v <= threshold
        else:
            raise Error(
                "numeric-dict LUT: unsupported op for float64 dict: " + String(Int(op))
            )
        keep.append(pass_)
    return keep^


@always_inline
def _numeric_dict_keep_f32(
    col_ptr: Column[HeapRegion], op: UInt8, threshold: Float64
) raises -> List[Bool]:
    """Phase 1 (FLOAT32 dict): build the keep-bit LUT comparing each entry's
    Float32 value (down-cast from the f64 accessor, byte-identical to the flat
    float32 write) against `threshold` — IN FLOAT64.

    ⛔ THE THRESHOLD IS NOT NARROWED. Arriving as
    `Float32(lit_val.float_val)` would round a Float64 threshold onto a
    Float32 neighbour and merge two distinct thresholds — the defect the FLAT
    float32 arm (`_eval_float32_col_vs_literal`) documents and avoids by
    widening the COLUMN: `dict<f32> [1.0, 1.0000001192092896]  v > 1.00000006`
    would answer `00` here and `01` on the flat arm; DuckDB compares FLOAT
    against DOUBLE in DOUBLE. Widening the entry
    back to Float64 is exact, so this is the Float32 value compared in the
    domain holding both operands."""
    var d = col_ptr.dict_size()
    var keep = List[Bool](capacity=d)
    for code in range(d):
        var v = col_ptr.dict_value_f64(code).cast[DType.float32]().cast[
            DType.float64
        ]()
        var pass_: Bool
        if op == BIN_GT:
            pass_ = v > threshold
        elif op == BIN_LT:
            pass_ = v < threshold
        elif op == BIN_EQ:
            pass_ = v == threshold
        elif op == BIN_NE:
            pass_ = v != threshold
        elif op == BIN_GE:
            pass_ = v >= threshold
        elif op == BIN_LE:
            pass_ = v <= threshold
        else:
            raise Error(
                "numeric-dict LUT: unsupported op for float32 dict: " + String(Int(op))
            )
        keep.append(pass_)
    return keep^


def numeric_dict_filter_bool_mask(
    col_ptr: Column[HeapRegion], op_in: UInt8, lit_in: ScalarValue
) raises -> BooleanArray:
    """Predicate-over-codes for a NUMERIC dictionary column.

    Mirrors `dict_filter_eval_bool_mask` (string path). Phase 1 builds a
    `dict_size`-element keep-bit LUT (one compare per DISTINCT entry); Phase 2
    scans the N per-row codes (`dict_code_at`) against the LUT, packing one bit
    per row into a non-nullable BooleanArray (the SAME output shape the flat
    compare kernels produce). Byte-identical to
    `resolve_numeric_dict_to_flat` + the flat dispatch.

    Precondition: `col_ptr.is_numeric_dict` is True (the dispatcher gates on
    it). Routes on `dict_value_dtype` for the four numeric value widths.

    ★ THE ONE RULE FIRST (`integer_literal_value.mojo`). The FLOAT arms below read
    `float_val` and the INT arms `int_val`, chosen by the DICTIONARY's value
    type — so an INTEGER literal against a FLOAT dictionary read a well-formed
    ZERO (`dict<f64> [0.5,3,10]  v > 3` answered 111), and a uint64 literal
    above Int64.MAX against an INT dictionary read negative. Both are now read
    by their TAG before any arm sees them. Idempotent, so the dispatcher having
    already applied it costs nothing but a copy.
    """
    var vdt = col_ptr.dict_value_dtype()
    var op = op_in
    var lit_val = lit_in.copy()
    read_integer_literal_for_column(vdt, lit_val, op)

    # Phase 1: resolve each distinct entry ONCE, compare vs the encoded literal.
    var keep: List[Bool]
    if vdt == DType.int64:
        keep = _numeric_dict_keep_int(col_ptr, op, lit_val.int_val)
    elif vdt == DType.int32:
        # an INT64 literal outside int32
        # range cannot be a threshold for the int32 LUT — narrowing it kept the
        # LOW 32 BITS. WIDEN instead: `_numeric_dict_keep_int` compares the
        # entry's own `dict_value_i64(code)` against the FULL-WIDTH literal, and
        # for a well-formed int32 dictionary that value IS the int32 entry
        # sign-extended, so this is the same comparison done in the wider
        # domain. (What it is NOT is a change to the ENTRY-side truncation
        # `_numeric_dict_keep_int32` performs to mirror
        # `resolve_numeric_dict_to_flat` — that is a data-side question about a
        # malformed dictionary and is deliberately untouched.)
        if int_literal_fits[DType.int32](lit_val.int_val):
            keep = _numeric_dict_keep_int32(
                col_ptr, op, lit_val.int_val.cast[DType.int32]()
            )
        else:
            keep = _numeric_dict_keep_int(col_ptr, op, lit_val.int_val)
    elif vdt == DType.float64:
        keep = _numeric_dict_keep_f64(col_ptr, op, lit_val.float_val)
    elif vdt == DType.float32:
        keep = _numeric_dict_keep_f32(col_ptr, op, lit_val.float_val)
    else:
        raise Error(
            "numeric-dict LUT: unsupported dict value dtype: " + String(vdt)
        )

    # Phase 2: scan the N codes against the keep-bit LUT, pack into a Bitmap.
    # A hoisted-width, branch-free byte-LUT scan (`numeric_dict_lut_scan`):
    # the per-row `dict_code_at` + `List[Bool]` loop it replaces was 19.3% of
    # ClickBench Q07's cycles. Same bits, same shape.
    return numeric_dict_codes_to_mask(col_ptr, keep)


def numeric_dict_filter_via_flat(
    col_ptr: Column[HeapRegion], op_in: UInt8, lit_in: ScalarValue
) raises -> BooleanArray:
    """The v1 densification path (RETAINED as the byte-verify oracle + the
    flag-OFF default): resolve the numeric-dict column to FLAT, then dispatch
    the same col-vs-literal compare kernels. This re-introduces the per-row
    gather AT FILTER TIME — the band-aid `numeric_dict_filter_bool_mask`
    replaces. Kept as the LUT's differential oracle.

    ★ THE SAME ONE RULE AS THE LUT, AND IT MUST BE: a literal read differently
    here would make the differential test red on the correct answer.
    """
    var op = op_in
    var lit_val = lit_in.copy()
    read_integer_literal_for_column(col_ptr.dict_value_dtype(), lit_val, op)
    var flat_col = col_ptr.resolve_numeric_dict_to_flat()
    var flat_at = flat_col.arrow_type
    if flat_at == ArrowType.INT64:
        var arr = flat_col.as_primitive[DType.int64]()
        var threshold = Scalar[DType.int64](lit_val.int_val)
        if op == BIN_GT:
            return eval_gt[DType.int64](arr, threshold)
        elif op == BIN_LT:
            return eval_lt[DType.int64](arr, threshold)
        elif op == BIN_EQ:
            return eval_eq[DType.int64](arr, threshold)
        elif op == BIN_NE:
            return eval_ne[DType.int64](arr, threshold)
        elif op == BIN_GE:
            return eval_ge[DType.int64](arr, threshold)
        elif op == BIN_LE:
            return eval_le[DType.int64](arr, threshold)
        else:
            raise Error("PipelineCompiler: unsupported op for numeric-dict int64: " + String(Int(op)))
    elif flat_at == ArrowType.INT32:
        var arr = flat_col.as_primitive[DType.int32]()
        # this is the LUT's byte-verify
        # ORACLE, so it must widen on exactly the same condition the LUT does —
        # a fix that moved only one of the two would make `_VERIFY` mode red on
        # the correct answer. `_scalar_cmp_i32_widening` is the same seam the
        # flat INT32 predicate arm uses.
        #
        # ⚠ THE FLAT COLUMN IS NOT NULLABLE HERE. `resolve_numeric_dict_to_flat`
        # produces the value plane; row validity is carried by the CODES and
        # applied by the caller's null-collapse, which is why this function
        # returns a raw mask and does not finalize. Unchanged by this edit.
        return _scalar_cmp_i32_widening(arr, lit_val.int_val, op)
    elif flat_at == ArrowType.FLOAT64:
        var arr = flat_col.as_primitive[DType.float64]()
        var threshold = Scalar[DType.float64](lit_val.float_val)
        if op == BIN_GT:
            return eval_gt[DType.float64](arr, threshold)
        elif op == BIN_LT:
            return eval_lt[DType.float64](arr, threshold)
        elif op == BIN_EQ:
            return eval_eq[DType.float64](arr, threshold)
        elif op == BIN_NE:
            return eval_ne[DType.float64](arr, threshold)
        elif op == BIN_GE:
            return eval_ge[DType.float64](arr, threshold)
        elif op == BIN_LE:
            return eval_le[DType.float64](arr, threshold)
        else:
            raise Error("PipelineCompiler: unsupported op for numeric-dict float64: " + String(Int(op)))
    else:
        # float32 — compared IN FLOAT64, exactly as the LUT above now does (see
        # `_numeric_dict_keep_f32`): widening the column is exact, narrowing
        # the threshold (`Float32(lit_val.float_val)`, the old spelling here)
        # merged two thresholds. This is the LUT's byte-verify oracle, so the
        # two must move together.
        var arr32 = flat_col.as_primitive[DType.float32]()
        var arr = eval_cast[DType.float32, DType.float64](arr32)
        var threshold = Scalar[DType.float64](lit_val.float_val)
        if op == BIN_GT:
            return eval_gt[DType.float64](arr, threshold)
        elif op == BIN_LT:
            return eval_lt[DType.float64](arr, threshold)
        elif op == BIN_EQ:
            return eval_eq[DType.float64](arr, threshold)
        elif op == BIN_NE:
            return eval_ne[DType.float64](arr, threshold)
        elif op == BIN_GE:
            return eval_ge[DType.float64](arr, threshold)
        elif op == BIN_LE:
            return eval_le[DType.float64](arr, threshold)
        else:
            raise Error("PipelineCompiler: unsupported op for numeric-dict float32: " + String(Int(op)))


def _numeric_dict_filter_dispatch(
    col_ptr: Column[HeapRegion], op: UInt8, lit_val: ScalarValue
) raises -> BooleanArray:
    """Route a numeric-dict `col OP literal` predicate.

    The compute-over-codes LUT `numeric_dict_filter_bool_mask` is the ONLY
    production route. `numeric_dict_filter_via_flat` is retained as the
    DIFFERENTIAL ORACLE: `tests/test_numeric_dict_filter_lut_p3.mojo` calls it
    directly and byte-compares the two.
    """
    return numeric_dict_filter_bool_mask(col_ptr, op, lit_val)


# =============================================================================
# numeric-dict-aware FUSED filter+count.
# =============================================================================
#
# Root cause: a
# numeric (INT32/INT64) PLAIN_DICTIONARY column on the count_only + filter
# path was always (a) gathered to a flat per-row value array, (b) SIMD-
# compared in `_eval_predicate`'s INT64 arm, and (c) popcounted in a separate
# `mask.true_count` pass. For cb02 (`count(*) WHERE good_event=1` over 100M
# rows) that is a ~800MB int64 materialize + two full passes over 100M values.
#
# DuckDB builds a boolean LUT over the FEW distinct dict ENTRIES once
# (evaluate the predicate `dict_size` times), then counts code-matches over
# the narrow int32 codes — never materializing the per-row values.
#
# `count_numeric_dict_predicate` does exactly that and FUSES the predicate
# evaluation with the count into ONE pass over the codes (no intermediate
# BooleanArray mask, no separate popcount). It takes plain primitives (codes
# array + the entry set + op + threshold) rather than the parquet-side
# `NumericDictCodes` struct so this module stays free of any parquet import.


@always_inline
def _eval_int64_cmp(op: UInt8, value: Int64, threshold: Int64) -> Bool:
    """Scalar comparison matching the INT64 predicate arm semantics."""
    if op == BIN_EQ:
        return value == threshold
    if op == BIN_NE:
        return value != threshold
    if op == BIN_LT:
        return value < threshold
    if op == BIN_LE:
        return value <= threshold
    if op == BIN_GT:
        return value > threshold
    # BIN_GE (the comparison ops admitted by the fast-path detector are
    # exactly these six; the caller gates on `_op_is_numeric_comparison`).
    return value >= threshold


@always_inline
def _op_is_numeric_comparison(op: UInt8) -> Bool:
    """True for the six scalar comparison ops the LUT-count path supports."""
    return (
        op == BIN_EQ
        or op == BIN_NE
        or op == BIN_LT
        or op == BIN_LE
        or op == BIN_GT
        or op == BIN_GE
    )


def count_numeric_dict_predicate(
    codes: PrimitiveArray[DType.int32],
    dict_values: List[Int64],
    op: UInt8,
    threshold: Int64,
) raises -> Int:
    """Count the rows whose dict-resolved value satisfies `value <op> threshold`,
    WITHOUT materializing the per-row values.

    Builds a small boolean LUT over `dict_values` (one comparison per distinct
    dict entry), then counts `lut[codes[r]]` over every code in ONE pass — the
    fused replacement for gather + SIMD-compare + popcount.

    `op` MUST be one of the six numeric comparison ops (the caller gates this
    via the fast-path detector).

    Every code must be a dictionary index in `[0, len(dict_values))`. That is
    NOT something the Parquet file can be trusted to have got right — it is
    checked here, once, before the LUT gather. See the gate below.

    Returns the surviving row count.

    Raises:
        Error if `op` is not a comparison, or if any code is out of range for
        `dict_values`.
    """
    if not _op_is_numeric_comparison(op):
        raise Error(
            "count_numeric_dict_predicate: unsupported op "
            + String(Int(op))
        )

    var dict_size = len(dict_values)

    # ROBUSTNESS GATE.
    #
    # ⚠ THIS IS THE SITE A `resolve_*`-ONLY FIX MISSES, and it is the
    # worst of the family. The gather below is `lut[code]` where `lut` is
    # ONE BYTE PER DISTINCT DICT ENTRY — for the cb02 shape (`good_event`)
    # that is a 2-byte heap allocation. A code is a full Int32 off the wire,
    # so essentially ANY corrupt code reads far outside it. `List.__getitem__`
    # guards with `debug_assert`, which is inert at ASSERT=none, so nothing
    # stood between an attacker-authored page and this read.
    #
    # This path exists PRECISELY to avoid `resolve_int32` — it counts over the
    # narrow codes instead of gathering values — so the gate that landed in
    # `dictionary.mojo:resolve_*` can never run on it. The comment here used
    # to read "code in [0, dict_size) by the Parquet dict contract"; the
    # contract is a claim made BY THE FILE BEING PARSED.
    #
    # One bulk min/max pass over the codes, before the LUT is even built —
    # NOT a per-lane branch inside the gather loop, which is the hot loop
    # this whole fused path exists to keep tight.
    validate_dict_codes[DType.int32](
        codes.view_ro(),
        codes.length,
        dict_size,
        "count_numeric_dict_predicate",
    )

    # Build the per-entry LUT (UInt8 0/1). dict_size is the dictionary
    # cardinality — tiny relative to the row count.
    var lut = List[UInt8](capacity=dict_size)
    for e in range(dict_size):
        if _eval_int64_cmp(op, dict_values[e], threshold):
            lut.append(UInt8(1))
        else:
            lut.append(UInt8(0))

    var n = codes.length
    if n == 0:
        return 0

    # One pass over the codes, gathering lut[code] into a SIMD accumulator.
    # codes are int32 dictionary indices; the LUT gather is L1-resident
    # (dict_size tiny). No intermediate mask, no separate popcount.
    var idx_view = codes.view_ro()
    var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    comptime W: Int = simd_width_of[DType.int64]()
    var total: Int = 0
    var i = 0

    comptime if W >= 4:
        var acc = SIMD[DType.int64, W](0)
        var simd_end = (n // W) * W
        while i < simd_end:
            var lanes = SIMD[DType.int64, W](0)

            comptime for k in range(W):
                var code_k = Int((idx_ptr + i + k)[])
                # SAFETY: code in [0, dict_size) — ENFORCED by the
                # `validate_dict_codes` pass at the top of this function.
                # This used to read "by the Parquet dict contract", which
                # was a claim made BY THE FILE BEING PARSED.
                lanes[k] = Int64(Int(lut[code_k]))
            acc += lanes
            i += W
        total = Int(acc.reduce_add())

    # Scalar tail (also the whole loop when W < 4 via comptime DCE).
    while i < n:
        var code = Int((idx_ptr + i)[])
        total += Int(lut[code])
        i += 1

    # Hold the view borrow across the loop.
    _ = idx_view
    return total


def survivors_numeric_dict_predicate(
    codes: PrimitiveArray[DType.int32],
    dict_values: List[Int64],
    op: UInt8,
    threshold: Int64,
) raises -> List[Int]:
    """Late materialization: evaluate `value <op> threshold` over a
    numeric-dict column's CODES, producing the survivor ROW-INDEX list WITHOUT
    materializing the per-row values.

    The survivor-index sibling of `count_numeric_dict_predicate`: builds the
    same per-dict-entry boolean LUT (one comparison per distinct entry), then
    appends `r` for every row where `lut[codes[r]]` in one pass. `codes` MUST be
    row-aligned 1:1 with the output rows (the caller gates on `codes.length ==
    rg.num_rows`, i.e. the column has NO nulls in this RG — a NULL row would
    compact out of `codes` and break the alignment). Resolving
    `dict_values[codes[r]]` reproduces the flat decode of the column
    byte-for-byte, so the returned indices are EXACTLY
    `filter_to_indices(_eval_predicate(col <op> threshold, flat_batch))` — the
    correctness contract verified by test_parquet_dict_code_survivors_byte_equiv.

    Returning primitives (`List[Int]`) keeps the reader-trait method that wraps
    this free of any arrow type dependency. `op` is one of the six numeric
    comparison ops (BIN_EQ..BIN_GE).

    Every code must be a dict index in `[0, len(dict_values))`. That is NOT
    something the Parquet file can be trusted to have got right — it is
    checked here, once, before the LUT gather.

    Raises:
        Error if `op` is not a comparison, or if any code is out of range for
        `dict_values`.
    """
    if not _op_is_numeric_comparison(op):
        raise Error(
            "survivors_numeric_dict_predicate: unsupported op "
            + String(Int(op))
        )

    var dict_size = len(dict_values)

    # ROBUSTNESS GATE.
    #
    # ⚠ FOUND BY GREPPING FOR THE SHAPE, not by reading this file. This is the
    # survivor-index twin of `count_numeric_dict_predicate` — same `lut[code]`
    # gather over a one-byte-per-entry List, same "SAFETY: code in
    # [0, dict_size) by the Parquet dict contract" comment that the file being
    # parsed is under no obligation to honour, same `debug_assert`-only
    # `List.__getitem__` underneath. Fixing only the one someone happened to
    # report is how this defect class has survived three passes.
    validate_dict_codes[DType.int32](
        codes.view_ro(),
        codes.length,
        dict_size,
        "survivors_numeric_dict_predicate",
    )

    var lut = List[UInt8](capacity=dict_size)
    for e in range(dict_size):
        if _eval_int64_cmp(op, dict_values[e], threshold):
            lut.append(UInt8(1))
        else:
            lut.append(UInt8(0))

    var n = codes.length
    var out = List[Int]()
    if n > 0:
        var idx_view = codes.view_ro()
        var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var r = 0
        while r < n:
            var code = Int((idx_ptr + r)[])
            # SAFETY: code in [0, dict_size) — ENFORCED by the
            # `validate_dict_codes` pass at the top of this function. This
            # used to read "by the Parquet dict contract", which was a claim
            # made BY THE FILE BEING PARSED.
            if lut[code] == UInt8(1):
                out.append(r)
            r += 1
        _ = idx_view
    return out^
