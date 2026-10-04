# =============================================================================
# compiler_eval_in_list -- engine evaluator for `EXPR_IN_LIST` predicates
# =============================================================================
#
# Implements the runtime branch of the IN-list
# canonicalization pipeline:
#
#   SDK side:
#     - `Expr.in_list_node(child, values)` is the canonical factory.
#     - `optimizer_expr.rewrite_in_clauses` recognizes OR-of-eq-on-same-col
#       chains in user predicates (incl. the pre-existing `Expr.in_list`
#       factory's OR-fold output) and rewrites them to `EXPR_IN_LIST`.
#
#   Engine side (this file):
#     - `_eval_in_list(expr, batch)` is dispatched from
#       `compiler_eval_predicate._eval_predicate` when `expr.tag == EXPR_IN_LIST`.
#     - Per-batch shape: pre-extract the value table (Int64 / Float64 /
#       Int32 / String / Bool) ONCE, scan the column ONCE, probe per row
#       against the inline value table.
#
# DuckDB reference: `execute_operator.cpp:18-62`. DuckDB does NOT use a
# hash-set either -- it walks the value list and ORs `Equals` results.
# Mojo's advantage here is that we fuse the column scan with the value
# probe into a single pass (DuckDB does N batch sweeps), which saves
# ~N-1 batch allocations + ~N-1 OR fold passes for K-element lists.
# =============================================================================

from komira_core.arrow.schema import RecordBatch
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.expr import Expr
from komira_core.plan.scalar_value import ScalarValue
from komira_core.helpers.compiler_helpers import resolve_col_index
from komira_core.eval.string_comparison import _string_bytes_equal
from komira_core.plan.literal_domain import int_literal_fits
from .temporal_literal_value import _comparable_literal_i64
from .literal_arm_domain import check_literal_against_column
from .integer_literal_value import (
    INT64_MAX,
    integer_literal_as_float64,
    integer_literal_value,
)


# =============================================================================
# Public dispatcher
# =============================================================================


def _eval_in_list(expr: Expr, batch: RecordBatch) raises -> BooleanArray:
    """Evaluate `EXPR_IN_LIST` against a batch.

    Resolves the child expr to a column index, then dispatches per Arrow
    type to a typed kernel. Falls back loudly on unsupported types so a
    silent miss surfaces as a clear error (mirrors the `_eval_predicate`
    "unsupported column type" idiom).

    ★ THE ANSWER IS THREE-VALUED, AND IT IS DECIDED HERE — ONCE, FOR BOTH
    CALLERS (the FILTER ladder in `compiler_eval_predicate` and the PROJECTION
    arm in `compiler_eval_column`). Three-valued logic:

      * a NULL ROW answers NULL (data bit 0, validity bit 0), whatever its raw
        payload is. The typed kernels below probe the PAYLOAD and never read
        validity, so before this a NULL row whose stored value equalled a member
        was SELECTED (`WHERE k IN (0, 1)` over the parquet decode's 0-filled NULL
        slot), and every other NULL row answered FALSE, which `NOT` turns into a
        selected row (`WHERE NOT (k IN (1, 2))`: DuckDB 1 row, komira 2).
      * a NULL MEMBER never matches, and makes every row that matched nothing
        NULL (`x IN (1, NULL)` is `x = 1 OR x = NULL`). The kernels read a NULL
        member's unpopulated field as a well-formed 0 / 0.0 / "" and probed it,
        so it MATCHED those rows. It is removed from the probe table here.

    Falsifier: `komira_compiler/tests/test_in_list_null_contract.mojo`.
    """
    var col_idx = resolve_col_index(expr.in_list_child_ref(), batch.schema)
    ref values = expr.in_list_values_ref()
    var k = len(values)
    ref col_ptr = batch.column_at(col_idx)
    var col_at = col_ptr.arrow_type

    # K=0 short-circuit: SQL `IN ` is always FALSE. The SDK factory
    # already folds this away (`Expr.in_list([])` -> `literal(False)`),
    # but defend the engine path against any future construction route.
    if k == 0:
        var n = batch.num_rows()
        var bm = Bitmap.create(n)
        return BooleanArray.from_bitmap(bm^)

    # =========================================================================
    # ★★ EVAL_INCOMPARABLE_LITERAL — THE SAME
    #    DEFECT AS THE COMPARISON LADDER'S, ONE MEMBER AT A TIME.
    # =========================================================================
    #
    # Each kernel below pre-extracts a typed value table by reading ONE field
    # of every `ScalarValue` — `int_val`, `float_val`, `string_val`,
    # `bool_val` — chosen from the COLUMN's type alone. An unpopulated field
    # reads as a well-formed zero, so `text_col IN (1, 2)` builds the value
    # table `["", ""]` and selects exactly the EMPTY-STRING rows instead of
    # refusing. That is the IN-list spelling of the `l_shipmode > 5` wrong
    # answer measured on the comparison ladder; the shared rule and the DuckDB
    # oracle are in `literal_arm_domain.mojo`.
    #
    # ⚠ PER MEMBER, NOT PER LIST. A list may legitimately mix INT and FLOAT
    # against a numeric column, and a NULL member is admitted by the shared
    # rule because the kernels already have a value-model for it.
    for i in range(k):
        check_literal_against_column(
            col_at,
            values[i],
            col_ptr.is_numeric_dict(),
            String("IN-list predicate"),
        )

    var has_null_member = False
    for i in range(k):
        if values[i].is_null():
            has_null_member = True
            break
    var hits: BooleanArray
    if has_null_member:
        var members = List[ScalarValue](capacity=k)
        for i in range(k):
            if not values[i].is_null():
                members.append(values[i].copy())
        if len(members) == 0:
            hits = BooleanArray.from_bitmap(Bitmap.create(batch.num_rows()))
        else:
            hits = _eval_in_list_members(batch, col_idx, members)
    else:
        hits = _eval_in_list_members(batch, col_idx, values)
    return _impose_in_list_nulls(hits^, batch, col_idx, has_null_member)


def _impose_in_list_nulls(
    var hits: BooleanArray,
    batch: RecordBatch,
    col_idx: Int,
    has_null_member: Bool,
) -> BooleanArray:
    """Turn the kernels' two-valued MATCH bitmap into the three-valued answer.

    A NULL row -> NULL; with a NULL member present, a valid row that matched
    nothing -> NULL too. Both use the repo-wide UNKNOWN encoding (data bit 0
    under a cleared validity bit, `eval_not`'s docstring), so a data-only
    consumer (`filter_to_indices`) never selects one and `eval_not` / `eval_and`
    / `eval_or` read it as UNKNOWN. `_set_null` is idempotent on the count.

    The all-valid, no-NULL-member case returns the kernel's bitmap untouched —
    no validity is grown, so a column without nulls pays one test."""
    ref col = batch.column_at(col_idx)
    # The BITMAP's presence, not `null_count`: the projection arm this
    # replaces keyed on the bitmap, and a count is a cache of it.
    var col_has_nulls = col.has_validity_buffer()
    if not col_has_nulls and not has_null_member:
        return hits^
    for r in range(hits.length):
        if col_has_nulls and col.is_null_at(r):
            hits.data.clear(r)
            hits._set_null(r)
        elif has_null_member and not hits.data.test(r):
            hits._set_null(r)
    return hits^


def _eval_in_list_members(
    batch: RecordBatch, col_idx: Int, values: List[ScalarValue]
) raises -> BooleanArray:
    """The per-type probe over NON-NULL members: TRUE where the row's PAYLOAD
    equals a member, FALSE elsewhere — two-valued and validity-blind on purpose;
    `_eval_in_list` imposes the NULL contract on the result."""
    ref col_ptr = batch.column_at(col_idx)
    var col_at = col_ptr.arrow_type
    if col_at == ArrowType.INT64:
        return _eval_in_list_int64(col_ptr.as_primitive[DType.int64](), values, col_at)
    elif col_at == ArrowType.INT32:
        return _eval_in_list_int32(col_ptr.as_primitive[DType.int32](), values, col_at)
    # TEMPORAL LOGICAL-vs-PHYSICAL: a temporal column is
    # physically an int at runtime (Arrow DATE32 == int32; DATE64 / TIMESTAMP* /
    # TIME64* == int64), so route it to the physical int kernel — the value-table
    # build reads a temporal literal (e.g. SQL `DATE 'x'`) from its correct field
    # via `_comparable_literal_i64`. Mirrors `_eval_temporal_col_vs_literal` in
    # compiler_eval_predicate.mojo (the converged temporal comparison mechanism).
    # NOTE: an INT32-stamped date column (the live parquet-decode shape) already
    # hits the INT32 arm above; these arms cover the temporally-STAMPED shape
    # (CAST(x AS DATE) / a DATE64 / TIMESTAMP column) that would otherwise
    # else-RAISE.
    elif col_at == ArrowType.DATE32 or col_at == ArrowType.TIME32_S or col_at == ArrowType.TIME32_MS:
        return _eval_in_list_int32(col_ptr.as_primitive[DType.int32](), values, col_at)
    elif (
        col_at == ArrowType.DATE64
        or col_at == ArrowType.TIMESTAMP_NS
        or col_at == ArrowType.TIMESTAMP_US
        or col_at == ArrowType.TIMESTAMP_MS
        or col_at == ArrowType.TIMESTAMP_S
        or col_at == ArrowType.TIME64_US
        or col_at == ArrowType.TIME64_NS
    ):
        return _eval_in_list_int64(col_ptr.as_primitive[DType.int64](), values, col_at)
    elif col_at == ArrowType.FLOAT64:
        return _eval_in_list_float64(col_ptr.as_primitive[DType.float64](), values)
    elif col_at == ArrowType.STRING:
        return _eval_in_list_string(col_ptr.as_string(), values)
    elif col_at == ArrowType.DICTIONARY:
        return _eval_in_list_dictionary(col_ptr.as_dictionary(), values)
    elif col_at == ArrowType.BOOL:
        # Unlikely but cheap to support.
        return _eval_in_list_bool(col_ptr.as_boolean(), values)
    else:
        raise Error(
            "PipelineCompiler: EXPR_IN_LIST unsupported column type: "
            + String(col_at)
        )


# =============================================================================
# Typed kernels — one batch sweep, K-element value table inline probe
# =============================================================================


def _eval_in_list_int64(
    arr: PrimitiveArray[DType.int64],
    values: List[ScalarValue],
    col_at: ArrowType,
) raises -> BooleanArray:
    """Int64 IN-list kernel. K probes per row, single column scan."""
    var k = len(values)
    # Pre-extract typed value table to avoid per-row Variant unpacking.
    # TEMPORAL: read each literal via `_comparable_literal_i64` so a date32 /
    # timestamp literal (value in `date32_val` / `ts_micros`, `int_val == 0`)
    # is read from its correct field. An INTEGER member is NOT read through
    # `int_val` alone any more — for every tag but uint64 the value is the same
    # (byte-identical to the prior path), and for uint64 it is not:
    #
    # ★ THE ONE RULE (`integer_literal_value.mojo`): an INTEGER member is read by
    # its TAG, never through `int_val` alone. `from_uint64(2**64-1)` carries
    # `int_val == -1`, so this table used to hold -1 and `v IN (2**64-1)`
    # selected the `-1` row — MEASURED `int64 [-1,0,3] -> 100`, want 000. No
    # Int64 equals a value above Int64.MAX, so such a member CONTRIBUTES NOTHING
    # and is DROPPED — the same definition-of-the-set argument the int32 kernel
    # below makes for a member outside int32.
    var vt = List[Int64](capacity=k)
    for i in range(k):
        if values[i].is_any_integer():
            var exact = integer_literal_value(values[i])
            if exact > INT64_MAX.cast[DType.int128]():
                continue
            vt.append(exact.cast[DType.int64]())
        else:
            vt.append(_comparable_literal_i64(values[i], col_at))
    # The probe loops below iterate `vt`; `k` is now only its length.
    k = len(vt)

    var n = arr.length
    var bm = Bitmap.create(n)
    # Direct bit-packing into the bitmap (mirrors `_eval_string_eq_impl`).
    # origin-tied view_ro pattern (drop-in for retired BANNED
    # `_typed_ptr_ro` accessor). ByteView local pins arr.data borrow
    # across the per-row IN-list probe loop.
    #
    # ★ OFFSET: this MUST be
    # `arr.view_ro` (the PrimitiveArray accessor, which starts at
    # `arr.offset` and spans `arr.length` elements), NOT `arr.data.view_ro`
    # (the whole backing buffer from byte 0). Every other PrimitiveArray VALUE
    # accessor indexes `self.offset + i`; reading from the buffer base is a
    # SILENT-WRONG-ANSWER on any array with `offset > 0`.
    #
    # ⚠ WHERE `offset > 0` COMES FROM. The D4 zero-copy share does NOT
    # preserve the offset — that arm shares the WINDOW and rebases to 0,
    # exactly like its copy path (see the D4 block in `column.mojo`). The
    # REASON STANDS ANYWAY and the code must not be reverted: an
    # `offset > 0` array still reaches here from `Column.share_as_primitive`
    # (which deliberately carries the offset) and from `PrimitiveArray.slice`.
    # The offset is resolved ONCE here, outside both probe loops. Guarded by
    # `tests/test_in_list_offset_honoring.mojo`.
    var data_view = arr.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.int64]]().as_imm()
    var bm_view = bm.buffer.view_mut()

    var full_bytes = n >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var x = (data_ptr + idx)[]
            var hit = False
            for j in range(k):
                if x == vt[j]:
                    hit = True
                    break
            if hit:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = n & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var x = (data_ptr + idx)[]
            var hit = False
            for j in range(k):
                if x == vt[j]:
                    hit = True
                    break
            if hit:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


def _eval_in_list_int32(
    arr: PrimitiveArray[DType.int32],
    values: List[ScalarValue],
    col_at: ArrowType,
) raises -> BooleanArray:
    """Int32 IN-list kernel."""
    var k = len(values)
    # TEMPORAL: `_comparable_literal_i64` reads a date32 literal from
    # `date32_val` (not `int_val == 0`); plain ints still read `int_val`.
    #
    # the pre-fix
    # `Int32(Int(...))` here kept the LOW 32 BITS of an out-of-range member, so
    # `x IN (4294967296)` matched every row whose value is 0. Membership makes
    # the correct handling exact and cheap: `x IN S` holds iff some s in S
    # equals x, and NO int32 value equals a member outside the int32 domain, so
    # such a member CONTRIBUTES NOTHING and is DROPPED from the probe table.
    # This is not a special case — it is the definition of the set. Dropping
    # every member leaves an empty table, whose probe is all-false, which is the
    # right answer for `IN` (and, negated upstream, for `NOT IN`).
    #
    # ★ AND THE MEMBER IS READ BY ITS TAG FIRST (`integer_literal_value.mojo`).
    # `_comparable_literal_i64` returns `int_val`, which for `from_uint64(2**64-1)`
    # is -1 — a value that FITS int32 and so was kept, selecting the `-1` row
    # (MEASURED `int32 [-1,0,3]  v IN (2**64-1) -> 100`, want 000). A member
    # above Int64.MAX is outside int32 a fortiori and is dropped with the rest.
    var vt = List[Int32](capacity=k)
    for i in range(k):
        var v64: Int64
        if values[i].is_any_integer():
            var exact = integer_literal_value(values[i])
            if exact > INT64_MAX.cast[DType.int128]():
                continue
            v64 = exact.cast[DType.int64]()
        else:
            v64 = _comparable_literal_i64(values[i], col_at)
        if not int_literal_fits[DType.int32](v64):
            continue
        vt.append(v64.cast[DType.int32]())
    # The probe loops below iterate `vt`, not `values` — `k` is now only a
    # capacity hint.
    k = len(vt)

    var n = arr.length
    var bm = Bitmap.create(n)
    # origin-tied view_ro pattern.
    # ★ OFFSET: `arr.view_ro`, not `arr.data.view_ro` — see the int64
    # kernel above for the full rationale. This arm also serves DATE32 /
    # TIME32_* columns.
    var data_view = arr.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.int32]]().as_imm()
    var bm_view = bm.buffer.view_mut()

    var full_bytes = n >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var x = (data_ptr + idx)[]
            var hit = False
            for j in range(k):
                if x == vt[j]:
                    hit = True
                    break
            if hit:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = n & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var x = (data_ptr + idx)[]
            var hit = False
            for j in range(k):
                if x == vt[j]:
                    hit = True
                    break
            if hit:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


def _eval_in_list_float64(
    arr: PrimitiveArray[DType.float64],
    values: List[ScalarValue],
) raises -> BooleanArray:
    """Float64 IN-list kernel. Bit-exact float equality (matches `eval_eq`)."""
    var k = len(values)
    var vt = List[Float64](capacity=k)
    for i in range(k):
        # ★ THE ONE RULE (`integer_literal_value.mojo`): an INTEGER member of
        # ANY tag is DuckDB's `CAST(<member> AS DOUBLE)` (measured: over DOUBLE,
        # `v IN (18446744073709551615::UBIGINT)` selects 1.8446744073709552e19).
        # This used to test `is_int` — int64/int32 only — so a uint8 `3` fell
        # to the `else` and probed for 0.0: MEASURED `f64 [0,3,10]  v IN (3u8)
        # -> 100`, want 010.
        if values[i].is_float():
            vt.append(values[i].float_val)
        elif values[i].is_any_integer():
            vt.append(integer_literal_as_float64(values[i]))
        else:
            # ⚠ UNCHANGED, AND NOT CORRECT: a DATE / TIMESTAMP member lands
            # here and probes for 0.0. Measured, out of this repair's scope, and
            # reported rather than papered over. (A NULL member NO LONGER
            # reaches this kernel: `_eval_in_list` removes it before any value
            # table is built and answers it three-valued — "fix(engine):
            # three-valued IN / NOT IN over NULL, a SQL NULL literal, and
            # LIKE's `_` is one CHARACTER", falsifier
            # `test_in_list_null_contract.mojo`'s
            # `test_float_null_member_is_not_zero`.)
            vt.append(0.0)

    var n = arr.length
    var bm = Bitmap.create(n)
    # origin-tied view_ro pattern.
    # ★ OFFSET: `arr.view_ro`, not `arr.data.view_ro` — see the int64
    # kernel above for the full rationale.
    var data_view = arr.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.float64]]().as_imm()
    var bm_view = bm.buffer.view_mut()

    var full_bytes = n >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var x = (data_ptr + idx)[]
            var hit = False
            for j in range(k):
                if x == vt[j]:
                    hit = True
                    break
            if hit:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = n & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var x = (data_ptr + idx)[]
            var hit = False
            for j in range(k):
                if x == vt[j]:
                    hit = True
                    break
            if hit:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


def _eval_in_list_bool(
    arr: BooleanArray,
    values: List[ScalarValue],
) raises -> BooleanArray:
    """Bool IN-list kernel. K is at most 2 (true/false), but support
    duplicates and unknown types via simple linear scan."""
    var k = len(values)
    var has_true = False
    var has_false = False
    for i in range(k):
        if values[i].is_bool():
            if values[i].bool_val:
                has_true = True
            else:
                has_false = True

    var n = arr.length
    var bm = Bitmap.create(n)
    var bm_view = bm.buffer.view_mut()
    # Fast paths for the common cases.
    if has_true and has_false:
        # IN (TRUE, FALSE) is always TRUE for non-null rows.
        var full_bytes = (n + 7) >> 3
        for byte_idx in range(full_bytes):
            bm_view.write_u8_at(byte_idx, UInt8(0xFF))
        # Mask trailing bits.
        var trailing = n & 7
        if trailing > 0 and full_bytes > 0:
            var mask = UInt8((1 << trailing) - 1)
            bm_view.write_u8_at(
                full_bytes - 1, bm_view.get_typed[UInt8](full_bytes - 1) & mask
            )
        return BooleanArray.from_bitmap(bm^)

    # Single-target case: scan and match.
    for i in range(n):
        var v = arr.data.test(i)
        var hit = (v and has_true) or ((not v) and has_false)
        if hit:
            var byte_idx = i >> 3
            var bit = i & 7
            var prev = bm_view.get_typed[UInt8](byte_idx)
            bm_view.write_u8_at(byte_idx, prev | (UInt8(1) << UInt8(bit)))

    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# String IN-list kernel — pre-extract value byte ptr/len, single sweep
# =============================================================================


def _eval_in_list_string(
    col: StringArray,
    values: List[ScalarValue],
) raises -> BooleanArray:
    """STRING IN-list kernel. Pre-extracts each value's byte pointer +
    length, sweeps the column once, probes against all K values inline.

    Per-row cost: K * memcmp. Mirrors `_eval_string_eq_impl` byte-extract
    pattern; lifetime tied to `col` (data buffer) and `values` (each
    ScalarValue holds an owned String, alive through this borrowed-by-
    read function body).

    ⛔⛔ THIS IS THE UNCOVERED TWIN OF THE `sdk/f4_string_eq` NEEDLE-WIDTH
    HOIST. DO NOT CREDIT AN IN-LIST CELL TO THAT WORK.

    `komira_core/eval/string_comparison.mojo` hoisted the per-row runtime
    width ladder out of the scalar `col = 'lit'` kernels. The blast radius of
    that change is SIX call sites, ALL of them in
    `komira_compiler/compiler_eval_predicate.mojo` (1382, 1384, 1641, 1643,
    1666, 1668 — re-derive, do not quote):

        grep -rnE 'eval_(large_)?string_(eq|ne)[(]' src/ --include='*.mojo' |
          grep -v /tests/

    **This loop is not one of them.** It reaches the identical ladder by its
    own route — `_string_bytes_equal` -> `_bytes_eq` -> `bytes_equal`'s
    `i + W <= n` / `rem >= 16 / 8 / 4 / 2` — so `WHERE col IN ('a','b')`
    still pays the per-row dispatch in full, and pays it once per
    LENGTH-MATCHING (row, needle) pair. `_eval_in_list_dictionary` below
    calls the same helper but O(D*K), once per DICTIONARY ENTRY, so it is
    second-order and not part of this.

    ⚠ WHY THE HOIST WAS NOT JUST APPLIED HERE, PRECISELY. The scalar hoist
    works because there is exactly ONE needle, so `W` is a single compile-time
    constant for the whole loop and the ladder collapses to nothing. Here
    there are K needles of K different byte lengths, so no single comptime `W`
    exists. Making `W` comptime requires BUCKETING the needles by rung and
    instantiating the per-row body once per rung — which replaces ONE runtime
    dispatch per (row, needle) with up to `_EQ_HOIST_MAX_BLOCK_LOG2 + 1` loop
    preambles per ROW. Whether that is a win depends on K and on the length
    distribution, and **neither is measured**: `_eval_in_list_string` has not
    shown up in a microarchitecture profile yet. So
    the hoist is NOT transferable by inspection, and this file gets a
    MEASUREMENT before it gets a rewrite, not the other way round.

    ⭐ THE CHEAPEST CANDIDATE TO MEASURE FIRST IS NOT THE LADDER. It is the
    unconditional `values[j].string_val.unsafe_ptr` in the probe below,
    evaluated for EVERY (row, needle) pair — including the overwhelming
    majority that `_string_bytes_equal` then rejects on length in its first
    statement. Hoisting the needle pointers out of the row loop (the NOTE
    below says Mojo 0.26 blocked it; the pin is now 1.0.0b2), or simply
    testing `elem_len != val_lens[j]` before the call, is a smaller and
    provably value-identical change than the rung buckets. It is deliberately
    NOT landed blind here — LLVM may already sink the fetch past the inlined
    length check, which is exactly the kind of thing only a measurement
    settles.

    ✅ AND A SEPARATE DEFECT FOUND WHILE ESTABLISHING THE ABOVE — FIXED
    AT THE DISPATCHER, NOT HERE: a NULL string row is an Arrow
    `(offset, length = 0)` slot, so `_string_bytes_equal(.., elem_len = 0, "",
    0)` returns TRUE and every NULL row matched `IN ('')` (the SQ07 `NULL = ''`
    defect at a kernel the SQ07 fix never touched). This kernel stays
    validity-blind; `_eval_in_list._impose_in_list_nulls` answers NULL for that
    row (`test_in_list_null_contract.mojo`).
    """
    var k = len(values)
    var length = col.length
    var bm = Bitmap.create(length)
    var offsets_view = col.offsets.view_ro()

    # SAFETY: `col.data` is alive through this function body; typed-origin
    # pointer flips via `.as_immutable` keep the lifetime tag.
    # origin-tied view_ro pattern; ByteView local pins
    # col.data borrow across the per-row sweep.
    var data_view = col.data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var bm_view = bm.buffer.view_mut()

    # Pre-extract each value's UTF-8 byte view. Each ScalarValue's
    # `string_val` is owned by the value list (`values`) which is
    # borrowed by this function — pointer + length are stable for the
    # duration of the per-row loop.
    # NOTE: Mojo 0.26 does not let us hold UnsafePointer + Int in a
    # parallel List easily across origins; instead we keep the Lists
    # of (start, length) and re-probe `values[j]` byte ptr per branch.
    var val_lens = List[Int](capacity=k)
    for i in range(k):
        val_lens.append(values[i].string_val.byte_length())

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Int32](idx))
            var end = Int(offsets_view.get_typed[Int32](idx + 1))
            var elem_len = end - start
            var hit = False
            for j in range(k):
                # `values[j].string_val` is a borrowed view into the
                # value-list slot; re-extracting `unsafe_ptr` per
                # branch is cheap and keeps the borrow tracker happy.
                if _string_bytes_equal(
                    data_ptr,
                    start,
                    elem_len,
                    values[j].string_val.unsafe_ptr(),
                    val_lens[j],
                ):
                    hit = True
                    break
            if hit:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Int32](idx))
            var end = Int(offsets_view.get_typed[Int32](idx + 1))
            var elem_len = end - start
            var hit = False
            for j in range(k):
                if _string_bytes_equal(
                    data_ptr,
                    start,
                    elem_len,
                    values[j].string_val.unsafe_ptr(),
                    val_lens[j],
                ):
                    hit = True
                    break
            if hit:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# Dictionary IN-list kernel — match against K dict entries, then scatter
# =============================================================================


def _eval_in_list_dictionary(
    dict_arr: StringDictionaryArray,
    values: List[ScalarValue],
) raises -> BooleanArray:
    """DICTIONARY IN-list kernel. For low-cardinality string columns
    (e.g. ClickBench cb18-cb22 categorical fields), we match each
    dictionary entry against all K values ONCE, build a dict-index ->
    bool table of size D, then scatter to the row-level mask.

    Cost: O(D * K) string compares + O(N) dict-index probes. For
    Q13/Q19 shapes (N ~ 1M, D ~ 5, K ~ 3) this is 200,000x fewer
    string compares than the row-major path.
    """
    var k = len(values)
    var n = dict_arr.length
    var d = len(dict_arr.dictionary)
    var bm = Bitmap.create(n)
    var bm_view = bm.buffer.view_mut()

    # Pre-extract the dictionary's data pointer + per-entry start/end.
    # SAFETY: `dict_arr` is borrowed for this function body, so the
    # underlying StringArray's offsets + data buffers stay alive
    # through the per-row scan.
    # origin-tied view_ro pattern (drop-in for retired BANNED
    # accessor). ByteView local pins dictionary.data borrow.
    var dict_offsets = dict_arr.dictionary.offsets.view_ro()
    var dict_data_view = dict_arr.dictionary.data.view_ro()
    var dict_data_ptr = dict_data_view._unsafe_ptr().as_imm()

    var val_lens = List[Int](capacity=k)
    for i in range(k):
        val_lens.append(values[i].string_val.byte_length())

    # Dict membership table: dict_match[d_idx] = True iff dict entry is
    # in the value list.
    var dict_match = List[Bool](capacity=d)
    for d_idx in range(d):
        var dstart = Int(dict_offsets.get_typed[Int32](d_idx))
        var dend = Int(dict_offsets.get_typed[Int32](d_idx + 1))
        var dlen = dend - dstart
        var hit = False
        for j in range(k):
            if _string_bytes_equal(
                dict_data_ptr,
                dstart,
                dlen,
                values[j].string_val.unsafe_ptr(),
                val_lens[j],
            ):
                hit = True
                break
        dict_match.append(hit)

    # Scatter: scan indices, probe dict_match[idx].
    # origin-tied view_ro pattern.
    var indices_view = dict_arr.indices.data.view_ro()
    var indices_ptr = indices_view._unsafe_ptr().bitcast[Scalar[DType.int32]]().as_imm()

    var full_bytes = n >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var d_idx = Int((indices_ptr + idx)[])
            if d_idx >= 0 and d_idx < d and dict_match[d_idx]:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = n & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var d_idx = Int((indices_ptr + idx)[])
            if d_idx >= 0 and d_idx < d and dict_match[d_idx]:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


