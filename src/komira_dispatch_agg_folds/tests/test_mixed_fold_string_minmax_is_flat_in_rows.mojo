# =============================================================================
# THE MIXED FOLD'S STRING MIN/MAX COSTS NOTHING PER ROW.
# =============================================================================
#
# ★ WHAT THIS GUARDS IS A MEMORY PROPERTY — A VALUE TEST CANNOT SEE IT. The
#   mixed off-cell fold (`agg_mixed_cd_fold.fold_mixed_count_distinct_over_batch`)
#   answers a `min(<varchar>)` beside another aggregate. A fold that took a
#   STAGING COPY before folding,
#
#       var svals = List[String](capacity=max(n_rows, 1))
#       for r in range(n_rows): svals.append(sa_in.get(r))
#
#   would give the same answers and would not answer at benchmark scale:
#   `StringArray.get` returns an OWNED `String` — 24 B of struct (Mojo 1.0.0 has
#   no small-string optimisation) plus its own heap allocation — so it would
#   materialise ONE HEAP STRING PER INPUT ROW, per string aggregate, before
#   folding down to the groups it needs: tens of millions of Strings for a few
#   million groups on a large leaf. On top of it,
#   `RecordBatch.column_as_string` COPIES the column's offsets and data buffers
#   (`Column.as_string`: "The data is COPIED"), a second full copy of a column
#   that is read once.
#
#   The per-GROUP accumulator is the cheap half, and it is all the fold keeps:
#   a RETAINED ROW INDEX per (group, agg), 8 B, rendered to a `String` exactly
#   once per group at emit. That is the same shape `_cd_extract_native_key_col`
#   uses for the GROUP KEY column (keep the Arrow `StringArray`, reach each
#   cell through the zero-copy `get_span`, keep one representative ROW per
#   group).
#
# ============================ WHAT PROVES WHAT ===============================
#
# ⭐ §1 IS THE ONE THAT SEES PER-ROW STAGING, AND IT IS A MEMORY ASSERTION.
#   Every value in §2 is answered identically by a staging fold; the only
#   observable that separates them is peak RSS. §1 holds the ROW COUNT and the
#   GROUP COUNT fixed and varies ONLY whether the node carries a STRING
#   MIN/MAX, then asserts that adding it costs a small fraction of what a
#   single known-9-B/row accumulator costs.
#
# ⛔ ORDER IS THE MEASUREMENT. `getrusage`'s `ru_maxrss` is a MONOTONE
#   high-water mark, so an arm's growth is visible only if nothing before it
#   already raised the mark past it. §1 therefore runs the arms CHEAPEST FIRST
#   and the CONTROL LAST. Reversed, the subject arm would read a growth of zero
#   for the wrong reason and the test would pass having measured nothing.
#
# ⛔ AND `0 < 0` IS A PASSING COMPARISON, so the control's OWN growth is
#   asserted separately. If the fixture is ever shrunk below what this platform's
#   allocator makes visible, THAT assertion fails — §1 does not quietly degrade
#   into a vacuous pass. A mis-sized fixture turns this test RED, never green.
#
# ⚠ §2 IS NOT A DUPLICATE OF THE VALUE COVERAGE. It pins the four cases a
#   BYTE-SPAN compare gets wrong if written carelessly, which a
#   `String`-to-`String` compare could not get wrong:
#     * an EMPTY STRING is a VALUE — it is the min of any group holding it, and
#       "best is empty" may never stand in for "nothing was seen";
#     * a NULL and a `''` are THE SAME ZERO-LENGTH SPAN in Arrow, told apart
#       only by the validity bitmap, so the null test must precede the compare;
#     * a strict PREFIX (`"abc"` vs `"abcd"`), IN BOTH ARRIVAL ORDERS — a
#       length-blind memcmp over the shorter length calls them EQUAL and keeps
#       whichever it saw first, and a tie-break with the wrong SENSE is correct
#       in one order and wrong in the other, so one ordering cannot see it;
#     * UNSIGNED byte order — `"z"` (0x7A) sorts BEFORE `"\xC3\xA9"` (U+00E9).
#       Read as SIGNED bytes 0xC3 is -61 and the answer inverts.
#
# ⚠ §3 is the CEILING: `mixed_offcell_row_ceiling_for_schema` must not give a
#   node whose MIN/MAX reads a STRING column a lower number (such as the
#   all-CD fold's 8,000,000), because the only thing that would justify one is
#   the per-row staging this fold does not do.
#
# ⛔ WHAT THIS TEST DOES NOT CLAIM. It does not run any benchmark query, at any
#   scale, and it makes no statement about a benchmark corpus or its coverage
#   verdict. It measures ONE process's peak RSS over in-memory batches.
#
# ============================ WHICH MUTANT TURNS IT RED ======================
#
# This file names no symbol a staging fold would lack. Put the per-row
# `List[String]` staging (and an 8,000,000 ceiling for a string node) back in
# the fold and §1's flatness assertion and §3 both go RED; §2 stays green by
# construction, because staging never changes an answer.
#
# Encapsulation (pointer rules): the ONE `UnsafePointer` here is the
#   `getrusage` FFI scratch buffer in `_peak_rss_units`, module-internal, never
#   in a public signature, with its own SAFETY comment. No wildcard-origin
#   FIELD, no `unsafe_from_address`, no `take_pointee`.
# =============================================================================

from std.collections import List, Optional
from std.ffi import external_call
from std.time import perf_counter_ns
from std.memory import UnsafePointer, alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder,
)
from komira_plan_expr.expr import Expr
from komira_plan_expr.agg_expr import (
    AggExpr, AGG_COUNT, AGG_COUNT_DISTINCT, AGG_MAX, AGG_MIN,
)
from komira_plan_ir.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan, SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import AggregateData

from komira_dispatch_agg_folds.agg_mixed_cd_fold import (
    fold_mixed_count_distinct_over_batch,
    mixed_offcell_row_ceiling_for_schema,
    mixed_offcell_servable_for_schema,
)


# =============================================================================
# Peak RSS — `getrusage(RUSAGE_SELF).ru_maxrss`.
# =============================================================================
def _peak_rss_units() -> Int:
    """The process's peak resident-set high-water mark, in whatever unit this
    platform's `ru_maxrss` uses (BYTES on Darwin, KILOBYTES on Linux).

    ⭐ THE UNIT IS DELIBERATELY NOT NORMALISED: every assertion built on it is a
    COMPARISON BETWEEN TWO READINGS TAKEN IN ONE PROCESS, and a ratio does not
    care what the unit is. A normalisation constant is one more thing that can
    be wrong on the platform nobody ran.

    Field offset: `struct rusage` opens with two `struct timeval` (two 64-bit
    words each on every 64-bit target here), so `ru_maxrss` — a `long` — sits at
    byte offset 32 on both glibc/x86-64 and Darwin/arm64.

    Returns:
        `ru_maxrss`, or 0 if the call failed — which §1 treats as a REFUSAL, not
        as a passing measurement.
    """
    # SAFETY: FFI carve-out. A 256-byte scratch buffer (`struct rusage` is 144 B
    # on both platforms) owned for the duration of this call, written only by
    # the kernel, read at ONE fixed offset, and freed before return. The pointer
    # does not escape and appears in no signature.
    var buf = alloc[UInt8](256)
    for i in range(256):
        buf[i] = UInt8(0)
    var rc = external_call["getrusage", Int32](
        Int32(0), buf.unsafe_bitcast[Int64]()
    )
    var out = 0
    if Int(rc) == 0:
        out = Int(buf.unsafe_bitcast[Int64]()[4])
    buf.unsafe_free()
    return out


# =============================================================================
# Plan helpers.
# =============================================================================
def _placeholder_child(imm schema: Schema) raises -> LogicalPlan:
    return LogicalPlan.scan(
        String("dummy.parquet"), SOURCE_PARQUET, schema.copy()
    )


def _agg(var aggs: AggExprArray, imm schema: Schema) raises -> AggregateData:
    """`SELECT k, <aggs...> FROM t GROUP BY k` over a schema."""
    var keys = ExprArray()
    keys.append(Expr.col_ref(String("k")))
    var child = _placeholder_child(schema)
    return AggregateData(keys^, aggs^, child^)


def _one(func: UInt8, column: String, name: String) raises -> AggExpr:
    return AggExpr(
        func, Optional[Expr](Expr.col_ref(column)), Optional[String](name)
    )


def _count_star(name: String) raises -> AggExpr:
    return AggExpr(AGG_COUNT, Optional[Expr](None), Optional[String](name))


# =============================================================================
# §1 — THE MEMORY OBSERVABLE.
# =============================================================================
#
# ⚠ NONE OF THESE THREE CONSTANTS IS ARBITRARY, AND SHRINKING ANY OF THEM
# WEAKENS THE MEASUREMENT RATHER THAN SPEEDING IT UP.
#
#   `_BIG_ROWS`  — the per-row terms are what §1 measures, so the control arm's
#      side tables must clear the high-water mark the FIXTURE's own construction
#      leaves behind. The control's 16 COUNT(DISTINCT) pre-extractions alone
#      are 16 x 9 B per row, ~72 MB at 500,000 rows, against ~26 MB of
#      fixture buffers (`k`, `w`, the string offsets and data).
#   `_BIG_GROUPS` — deliberately TINY. §1 is about the per-ROW cost; a large
#      group count would add a per-GROUP term to every arm alike and only blur
#      the comparison. The group-table growth path is covered by
#      `test_mixed_cd_fold_row_ceiling_is_derived` §1 (6,000 groups).
#   `_CONTROL_CDS` — the control arm's aggregate count. Each COUNT(DISTINCT)
#      pre-extracts an Int64 key + a null flag per row = 9 B/row, which is the
#      known, small, per-row cost the string aggregate is compared AGAINST.
comptime _BIG_ROWS: Int = 500_000
comptime _BIG_GROUPS: Int = 64
comptime _BASELINE_CDS: Int = 2
comptime _CONTROL_CDS: Int = 16

# 32 ASCII bytes per value. ⚠ NOT SHORTER: the per-row cost a staging fold pays
# is `size_of[String]()` (24 B, no small-string optimisation on Mojo 1.0.0) PLUS
# the value's own heap payload PLUS the column copy, so a very short value makes
# the cost it is aimed at small enough to hide inside allocator noise.
comptime _STR_LEN: Int = 32


def _big_fixture() raises -> RecordBatch:
    """`k` INT64 (non-null, `_BIG_GROUPS` groups), `s` STRING (non-null,
    `_STR_LEN` bytes per value, varied so a per-group min/max is a real fold),
    `w` INT64 nullable.

    ⛔ THE STRING COLUMN IS BUILT THROUGH `StringArray.from_buffers`, NOT
    `from_strings`, AND THAT IS PART OF THE INSTRUMENT. `from_strings` takes a
    `List[String]` of N owned Strings and then frees it — leaving the allocator
    holding exactly N String-shaped free chunks. A staging fold's per-row
    Strings would then be satisfied out of that free list WITHOUT growing RSS,
    and §1 would measure only a fraction of the real cost. The offsets+data
    form allocates two flat buffers and nothing String-shaped.

    ⚠ `w` IS NULL ON 999 ROWS IN 1,000. The control arm's cost that §1 measures
    is its per-row PRE-EXTRACTION (`cd_distinct_keys_for_column` — 9 B/row, and
    allocated whether or not the row is null), NOT its per-group `Set[Int64]`.
    Keeping the sets near-empty removes tens of millions of hash inserts from
    the wall without touching the byte count the assertion reads."""
    var karr = PrimitiveArray[DType.int64].allocate(_BIG_ROWS)
    var warr = PrimitiveArray[DType.int64].allocate_nullable(_BIG_ROWS)
    if True:
        # SAFETY: two pointers into two DISTINCT arrays of length `_BIG_ROWS`,
        # both alive for the whole of this function, every index below
        # `_BIG_ROWS`. Neither leaves this scope.
        var kptr = karr._typed_ptr_mut()
        var wptr = warr._typed_ptr_mut()
        for r in range(_BIG_ROWS):
            kptr[r] = Int64(r % _BIG_GROUPS)
            wptr[r] = Int64(r % 97)
    var w_nulls = 0
    if True:
        ref wbits = warr.validity.value()
        for r in range(_BIG_ROWS):
            if r % 1000 != 0:
                wbits.clear(r)
                w_nulls += 1
    warr.null_count = w_nulls

    # Arrow-native (offsets, data): `_STR_LEN` bytes per value — 'v', 7 decimal
    # digits of a scrambled row index, then a constant tail. The digits make the
    # per-group min/max a real fold rather than a constant.
    var offs = List[Int32](capacity=_BIG_ROWS + 1)
    var data = List[UInt8](capacity=_BIG_ROWS * _STR_LEN)
    offs.append(Int32(0))
    for r in range(_BIG_ROWS):
        data.append(UInt8(118))  # 'v'
        var x = (r * 7919) % 10_000_000
        var d = 1_000_000
        for _p in range(7):
            data.append(UInt8(48 + (x // d) % 10))
            d //= 10
        for _q in range(_STR_LEN - 8):
            data.append(UInt8(46))  # '.'
        offs.append(Int32((r + 1) * _STR_LEN))
    var sarr = StringArray.from_buffers(
        offs, data, Optional[Bitmap[HeapRegion]](None), 0
    )

    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    rbb.add_column(Column.from_string(sarr^))
    rbb.add_column(Column.from_primitive[DType.int64](warr^))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    sb.add_field(Field(String("w"), ArrowType.INT64, True))
    return rbb.build(sb.build())


def _cd_node(imm schema: Schema, n_cds: Int) raises -> AggregateData:
    """`count(*)` plus `n_cds` COUNT(DISTINCT w) — no string aggregate at all."""
    var aggs = AggExprArray()
    aggs.append(_count_star(String("c")))
    for i in range(n_cds):
        aggs.append(_one(AGG_COUNT_DISTINCT, String("w"), String("cd") + String(i)))
    return _agg(aggs^, schema)


def _cd_plus_string_node(imm schema: Schema, n_cds: Int) raises -> AggregateData:
    """`_cd_node` EXACTLY, plus one `min(s)` over the STRING column. The only
    difference between this node and `_cd_node(n_cds)` is the string
    aggregate — which is what makes the growth between the two arms attributable
    to it and to nothing else."""
    var aggs = AggExprArray()
    aggs.append(_count_star(String("c")))
    for i in range(n_cds):
        aggs.append(_one(AGG_COUNT_DISTINCT, String("w"), String("cd") + String(i)))
    aggs.append(_one(AGG_MIN, String("s"), String("min_s")))
    return _agg(aggs^, schema)


def test_peak_rss_of_a_string_minmax_is_flat_in_rows() raises:
    """⭐ THE RED. Adding a `min(<varchar>)` to a node must not multiply the
    fold's peak RSS — it stages NOTHING per row, so its marginal cost is a small
    fraction of ONE 9-B/row accumulator's.

    A string arm that staged an owned `String` per row plus a full copy of the
    column fails this assertion by a wide margin.

    ⛔ ORDER: `ru_maxrss` is a monotone high-water, so the arms run
    cheapest-first and the control LAST. ⛔ The control's own growth is asserted
    separately, so a fixture too small to be visible REDS rather than passing
    `0 < 0`."""
    var t0 = perf_counter_ns()
    var batch = _big_fixture()
    var t_fix = perf_counter_ns()

    var rss0 = _peak_rss_units()
    assert_true(rss0 > 0, "the getrusage read must work on this platform")

    # ARM A — the BASELINE: no string aggregate at all. Establishes the mark a
    # node of this shape reaches without one.
    var base_node = _cd_node(batch.schema, _BASELINE_CDS)
    var base_out = fold_mixed_count_distinct_over_batch(base_node, batch)
    assert_true(base_out.__bool__(), "the baseline node must be served")
    var base_rows = base_out.value().num_rows()
    _ = base_out^
    var rss1 = _peak_rss_units()
    var t_a = perf_counter_ns()

    # ARM B — THE SUBJECT: the SAME node plus `min(s)`. Its growth above ARM A's
    # mark is the marginal peak cost of the string aggregate, and nothing else
    # differs between the two nodes.
    var str_node = _cd_plus_string_node(batch.schema, _BASELINE_CDS)
    var str_out = fold_mixed_count_distinct_over_batch(str_node, batch)
    assert_true(str_out.__bool__(), "the string node must be served")
    var str_rows = str_out.value().num_rows()
    _ = str_out^
    var rss2 = _peak_rss_units()
    var t_b = perf_counter_ns()

    # ARM C — THE CONTROL, and the most expensive arm, so it runs last. 14 MORE
    # COUNT(DISTINCT)s over the same rows: a KNOWN 9 B/row/aggregate of
    # pre-extracted side table, i.e. the scale at which this instrument can see
    # a per-row allocation on this platform.
    var ctl_node = _cd_node(batch.schema, _CONTROL_CDS)
    var ctl_out = fold_mixed_count_distinct_over_batch(ctl_node, batch)
    assert_true(ctl_out.__bool__(), "the control node must be served")
    var ctl_rows = ctl_out.value().num_rows()
    _ = ctl_out^
    var rss3 = _peak_rss_units()
    var t_c = perf_counter_ns()

    print(
        "[string-minmax-flat] phase ms: fixture=", (t_fix - t0) // 1_000_000,
        " armA=", (t_a - t_fix) // 1_000_000,
        " armB=", (t_b - t_a) // 1_000_000,
        " armC=", (t_c - t_b) // 1_000_000,
        sep="",
    )

    var g_base = rss1 - rss0
    var g_str = rss2 - rss1
    var g_ctl = rss3 - rss2

    print(
        "[string-minmax-flat] rows=", _BIG_ROWS, " groups=", _BIG_GROUPS,
        " ru_maxrss units: base0=", rss0,
        " after_baseline=", rss1, " after_string=", rss2,
        " after_control=", rss3,
        " | growth baseline=", g_base, " string=", g_str, " control=", g_ctl,
        sep="",
    )

    # Every arm actually folded the same groups — a declined arm would have
    # measured nothing.
    assert_equal(base_rows, _BIG_GROUPS)
    assert_equal(str_rows, _BIG_GROUPS)
    assert_equal(ctl_rows, _BIG_GROUPS)

    # ⭐ THE FLATNESS ASSERTION — the one a staging fold fails. The string
    # aggregate's marginal peak must be under a QUARTER of what 14 additional
    # 9-B/row accumulators cost. Generous on purpose: this is a live allocator
    # on a shared box, not a calibrated instrument, and the staging cost it is
    # aimed at is on the order of 100 B/row against 0.
    assert_true(
        g_str * 4 < g_ctl,
        (
            "a STRING MIN/MAX must not stage per-row state: its marginal peak"
            " RSS must stay far under a known 9-B/row/aggregate control"
        ),
    )

    # ⭐ THE ANTI-VACUITY GUARD. The control MUST move the high-water mark, or
    # the assertion above discriminates nothing. `0 < 0` passes; this does not.
    assert_true(
        g_ctl > 0,
        (
            "the control arm must raise the peak, or the fixture is too small"
            " for this platform's allocator and §1 measured nothing"
        ),
    )


# =============================================================================
# §2 — THE VALUES A BYTE-SPAN COMPARE CAN GET WRONG.
# =============================================================================
#
# THE ORACLE IS NOT THIS ENGINE. Each group's answer is written out below by
# hand from SQL's own rules; the fixture is 14 rows so every expectation is
# readable in full.
#
#   g=0  : "",  "abc", "abcd"        -> min "",    max "abcd"   (EMPTY is a VALUE)
#   g=1  : NULL, NULL                -> min NULL,  max NULL     (no value seen)
#   g=2  : "abc", NULL, "abcd"       -> min "abc", max "abcd"   (PREFIX)
#   g=3  : "", NULL                  -> min "",    max ""       (NULL != '')
#   g=4  : "z", "\xC3\xA9" (U+00E9)  -> min "z",   max "é"      (UNSIGNED bytes)
#   g=5  : "abcd", "abc"           -> min "abc", max "abcd"   (PREFIX, REVERSED)
#
# ⚠ g=5 IS NOT A DUPLICATE OF g=2, AND THE ASYMMETRY IS THE POINT. The length
# tie-break is consulted in a DIFFERENT DIRECTION depending on which operand the
# group met first: at g=2 the prefix arrives before its extension, at g=5 after
# it. A `_mix_str_row_is_before` that returned `la > lb` on the tie — or that
# dropped the tie-break only in the `else` arm — answers ONE of these two
# correctly and the other wrong, so a single ordering cannot see it.
# =============================================================================


def _value_fixture() raises -> RecordBatch:
    """14 rows, 6 groups, in FIRST-OCCURRENCE key order 0,1,2,3,4,5."""
    var keys: List[Int64] = [
        Int64(0), Int64(0), Int64(0),
        Int64(1), Int64(1),
        Int64(2), Int64(2), Int64(2),
        Int64(3), Int64(3),
        Int64(4), Int64(4),
        Int64(5), Int64(5),
    ]
    var vals: List[String] = [
        String(""), String("abc"), String("abcd"),
        String("X"), String("Y"),          # both NULL (see the note below)
        String("abc"), String("Z"), String("abcd"),
        String(""), String("Q"),
        String("z"), String("é"),
        String("abcd"), String("abc"),
    ]
    # ⚠ THE NULL ROWS' PAYLOADS ARE NOT STORED, AND THAT IS THE POINT.
    # `StringArray.from_strings_with_validity` gives a null row an
    # `(offset, length=0)` slot per Arrow's contract, so on the wire a NULL and
    # a genuine `''` ARE THE SAME ZERO-LENGTH SPAN — the validity bitmap is the
    # only thing that separates them. A fold that compares spans before testing
    # validity answers `''` for g=1 (whose values are all NULL) and cannot tell
    # g=3's real `''` from a null at all.
    var valid: List[Bool] = [
        True, True, True,
        False, False,
        True, False, True,
        True, False,
        True, True,
        True, True,
    ]
    var n = len(keys)
    var karr = PrimitiveArray[DType.int64].allocate(n)
    if True:
        # SAFETY: one pointer into an array of length `n`, alive for this
        # function, every index below `n`; it does not leave this scope.
        var kptr = karr._typed_ptr_mut()
        for r in range(n):
            kptr[r] = keys[r]
    var sarr = StringArray.from_strings_with_validity(vals, valid)

    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    rbb.add_column(Column.from_string(sarr^))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    return rbb.build(sb.build())


def test_string_minmax_values_empty_null_prefix_and_unsigned_order() raises:
    """`SELECT k, min(s), max(s), count(*) FROM t GROUP BY k` — every case a
    span compare gets wrong if the null test, the length tie-break or the byte
    signedness is written carelessly."""
    var batch = _value_fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("s"), String("mn")))
    aggs.append(_one(AGG_MAX, String("s"), String("mx")))
    aggs.append(_count_star(String("c")))
    var ad = _agg(aggs^, batch.schema)
    assert_true(
        mixed_offcell_servable_for_schema(ad, batch.schema),
        "precondition: a STRING MIN/MAX beside count(*) IS served here",
    )

    var out_opt = fold_mixed_count_distinct_over_batch(ad, batch)
    assert_true(out_opt.__bool__(), "the fold must serve this node")
    var out = out_opt.take()
    assert_equal(out.num_rows(), 6)
    assert_equal(out.num_columns(), 4)

    # ⭐ THE GROUP-ORDER CONTRACT: slots are assigned in FIRST-OCCURRENCE ROW
    # ORDER so a mixed node's group order matches the all-CD node's. A parallel
    # combine is exactly what would break this.
    var kc = out.column_as_primitive_int64(0)
    for g in range(6):
        assert_equal(Int64(kc.get(g)), Int64(g), "group order is first-occurrence")

    var mn = out.column_as_string(1)
    var mx = out.column_as_string(2)
    var cc = out.column_as_primitive_int64(3)

    # g=0 — the EMPTY STRING is a VALUE and it is the min.
    assert_false(mn.is_null(0), "g0 saw values, so min is not NULL")
    assert_equal(mn.get(0), String(""), "'' is a value and is the minimum")
    assert_equal(mx.get(0), String("abcd"))
    assert_equal(Int64(cc.get(0)), Int64(3))

    # g=1 — every value NULL: min and max are NULL, count(*) still counts.
    assert_true(mn.is_null(1), "a group with no non-null value emits NULL min")
    assert_true(mx.is_null(1), "a group with no non-null value emits NULL max")
    assert_equal(Int64(cc.get(1)), Int64(2))

    # g=2 — a strict PREFIX. A length-blind memcmp over min(len_a, len_b) calls
    # "abc" and "abcd" EQUAL and keeps whichever it met first.
    assert_equal(mn.get(2), String("abc"), "a prefix sorts BEFORE its extension")
    assert_equal(mx.get(2), String("abcd"))
    assert_equal(Int64(cc.get(2)), Int64(3))

    # g=3 — NULL vs ''. In Arrow both are the SAME zero-length span; only the
    # validity bitmap separates them. The group saw ONE value, and it is ''.
    assert_false(mn.is_null(3), "'' was seen, so the group is not NULL")
    assert_equal(mn.get(3), String(""))
    assert_false(mx.is_null(3))
    assert_equal(mx.get(3), String(""))
    assert_equal(Int64(cc.get(3)), Int64(2))

    # g=4 — UNSIGNED byte order. 'z' is 0x7A, 'é' (U+00E9) is 0xC3 0xA9. Read as
    # SIGNED bytes 0xC3 is -61 and both answers invert.
    assert_equal(mn.get(4), String("z"), "0x7A < 0xC3 under UNSIGNED byte order")
    assert_equal(mx.get(4), String("é"))
    assert_equal(Int64(cc.get(4)), Int64(2))

    # g=5 — the PREFIX again, with the operands met in the OPPOSITE order. The
    # group sees "abcd" FIRST, so MIN must be improved DOWN to "abc" by the
    # length tie-break and MAX must NOT be improved off "abcd" by it. g=2
    # exercises the other direction; neither ordering alone covers both arms.
    assert_equal(mn.get(5), String("abc"), "a later prefix still wins MIN")
    assert_equal(mx.get(5), String("abcd"), "a later prefix must not take MAX")
    assert_equal(Int64(cc.get(5)), Int64(2))


def test_string_min_and_max_disagree_on_the_same_column() raises:
    """⚠ A FOLD THAT KEPT ONE BEST PER (group, COLUMN) rather than per (group,
    AGGREGATE) answers this with min == max. Cheap, and it is the one structural
    property the retained-row representation could plausibly lose."""
    var batch = _value_fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MAX, String("s"), String("mx")))
    aggs.append(_one(AGG_MIN, String("s"), String("mn")))
    aggs.append(_count_star(String("c")))
    var ad = _agg(aggs^, batch.schema)
    var out_opt = fold_mixed_count_distinct_over_batch(ad, batch)
    assert_true(out_opt.__bool__(), "the fold must serve this node")
    var out = out_opt.take()
    var mx = out.column_as_string(1)
    var mn = out.column_as_string(2)
    assert_equal(mx.get(0), String("abcd"))
    assert_equal(mn.get(0), String(""))
    assert_equal(mx.get(2), String("abcd"))
    assert_equal(mn.get(2), String("abc"))


# =============================================================================
# §3 — ONE CEILING FOR A STRING NODE AND A CD-ONLY NODE.
# =============================================================================


def test_a_string_offcell_node_clears_the_ClickBench_Q28_leaf() raises:
    """⭐ THE SECOND RED. A `mixed_offcell_row_ceiling_for_schema` that gave
    ANY node whose MIN/MAX reads a STRING column `_CD_FOLD_MAX_ROWS`
    (8,000,000) would fail here. Only per-row staging would justify that
    number, and the fold does none: the string aggregate costs nothing per row,
    so a node carrying one is bounded by exactly what the same node without it
    is bounded by.

    81,032,736 is the row count of ClickBench Q28's leaf (after `referer <>
    ''`). ⛔ This asserts the CEILING admits that row count. It does not run
    the query."""
    var batch = _value_fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("s"), String("mn")))
    aggs.append(_count_star(String("c")))
    var ad = _agg(aggs^, batch.schema)
    assert_true(
        mixed_offcell_servable_for_schema(ad, batch.schema),
        "precondition: the STRING MIN/MAX node IS one this fold serves",
    )
    assert_true(
        mixed_offcell_row_ceiling_for_schema(ad, batch.schema) >= 81_032_736,
        (
            "a STRING off-cell node must clear ClickBench Q28's 81,032,736-row"
            " leaf — it stages no per-row String that would justify an 8M"
            " cap"
        ),
    )


def test_a_string_node_and_a_cd_only_node_now_share_one_ceiling() raises:
    """⭐ AND THEY SHARE IT FOR A REASON, not by coincidence: NEITHER off-cell
    accumulator has a per-row term the other lacks. A CD
    pre-extracts 9 B/row; a STRING MIN/MAX pre-extracts nothing at all. Two
    numbers here would mean one of them is not derived from what it bounds."""
    var batch = _value_fixture()

    var s_aggs = AggExprArray()
    s_aggs.append(_one(AGG_MIN, String("s"), String("mn")))
    s_aggs.append(_count_star(String("c")))
    var s_ad = _agg(s_aggs^, batch.schema)

    var c_aggs = AggExprArray()
    c_aggs.append(_one(AGG_COUNT_DISTINCT, String("k"), String("cdk")))
    c_aggs.append(_count_star(String("c")))
    var c_ad = _agg(c_aggs^, batch.schema)

    assert_equal(
        mixed_offcell_row_ceiling_for_schema(s_ad, batch.schema),
        mixed_offcell_row_ceiling_for_schema(c_ad, batch.schema),
        (
            "the STRING arm stages no more per row than the CD-only arm, so"
            " one ceiling bounds both"
        ),
    )


def test_a_NUMERIC_minmax_node_is_still_not_this_folds_business() raises:
    """⛔ THE NUMERIC MIN/MAX STAYS WITH THE PARALLEL KERNEL, restated beside
    the ceiling. `min(<bigint>), count(*)` is an ordinary fixed-cell aggregate
    the PARALLEL kernel serves; the DType gate, not the ceiling, is what keeps
    it out, and a high ceiling must not make it reachable."""
    var batch = _value_fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("k"), String("min_k")))
    aggs.append(_count_star(String("c")))
    var ad = _agg(aggs^, batch.schema)
    assert_false(
        mixed_offcell_servable_for_schema(ad, batch.schema),
        "a numeric-only MIN/MAX node is NOT servable here",
    )
    assert_false(
        fold_mixed_count_distinct_over_batch(ad, batch).__bool__(),
        "and the fold itself — the last word — still refuses it",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
