# =============================================================================
# THE MIXED COUNT(DISTINCT) + FIXED-CELL FOLD'S ROW CEILING IS DERIVED, NOT
# INHERITED.
# =============================================================================
#
# ★ WHAT THIS GUARDS, AND IT IS NOT WHAT THE SHAPE SUGGESTS. The mixed fold in
#   `agg_mixed_cd_fold` computes this shape's values; the value tests pin its
#   values, its NULL contract and its arm boundaries. What a value test at
#   small scale cannot see is whether it ANSWERS at benchmark scale. A query
#   such as ClickBench Q9 (the shape §1 is named for)
#
#     SELECT region_id, sum(adv_engine_id), count(*) AS c,
#            avg(resolution_width), count(DISTINCT user_id)
#     FROM hits GROUP BY region_id ORDER BY c DESC LIMIT 10
#
#   is refused by a row ceiling that is too low, with an unsupported
#   grouped-agg shape error, while the SAME query at a few hundred thousand
#   rows runs, and `count(DISTINCT user_id)` ALONE over the SAME column runs at
#   full scale. Neither the shape nor the column nor the type explains such a
#   refusal — only the ROW COUNT does, and because the ceiling is checked after
#   the collect, the whole leaf is decoded before the refusal.
#
#   Two constants elsewhere are NOT sized for this arm:
#     * `_CD_FOLD_MAX_ROWS` (8,000,000) — the ALL-CD fold's constant. For arm 1
#       that number is a ROUTING choice: an all-CD node it declines is picked
#       up by the PARALLEL `CountDistinctAggSink`, which answers at benchmark
#       scale. NOTHING stands behind the mixed arm, so the same number would
#       mean REFUSE THE QUERY.
#     * `_EXT_FOLD_COLLECT_MAX_ROWS` (64,000,000) — the extended-fold collect
#       driver's constant, shared by three drivers.
#
# ⭐ WHY A DERIVATION RATHER THAN A BIGGER CONSTANT. The ceiling is a MEMORY
#   bound stated in rows, derived in `agg_mixed_cd_fold` from what the fold
#   allocates per row and per group. Its two OFF-CELL accumulators have no
#   per-row term the other lacks — a COUNT(DISTINCT) pre-extracts 9 B/row (an
#   Int64 key + a null flag) and a STRING MIN/MAX adopts the Arrow column and
#   keeps a per-(group, aggregate) ROW INDEX — so there is ONE ceiling for
#   every node. §2's two STRING cases assert that, and each says why in its own
#   docstring. The falsifier for the claim they rest on is a MEMORY test,
#   `test_mixed_fold_string_minmax_is_flat_in_rows` §1; a ceiling assertion
#   cannot tell a real per-row cost from an imagined one.
#
# ============================ WHAT PROVES WHAT ===============================
#
# ⚠ THE FALSIFIER FOR THE CEILING IS §2, NOT A BIG FIXTURE. An end-to-end
#   "the fold answers 8,000,001 rows" test costs tens of minutes on a test
#   worker (building the fixture and folding it), against a fraction of a
#   second for the whole of §2, and buys nothing §2 does not already state:
#   with only three groups it never even reaches the group table's growth
#   path. Do not add it.
#
#   * §2 is the RED→GREEN pair: `test_a_CD_ONLY_node_resolves_to_a_ceiling_
#     above_ClickBench_scale` FAILS if the mixed fold inherits the all-CD
#     fold's ceiling ("a CD-only node must NOT inherit the all-CD fold's
#     ceiling") and passes on the derived one.
#   * §1 covers what "at scale" STRUCTURALLY means for this fold and what 12
#     rows cannot reach: 6,000 groups, so the open-address group table GROWS
#     AND REHASHES four times mid-fold. Cheap, because the cost that matters
#     there is the group count, not the row count.
#   * The full-scale proof is the benchmark query itself, value-checked
#     against a DuckDB oracle, not a unit test.
#
# ============================ THE ORACLE =====================================
#
# NOT this engine. §1's expected values are CLOSED FORMS keyed on the GROUP, so
# a row that lands in the wrong group changes the answer rather than hiding in
# a uniform fixture. N = 24,000 rows, G = 6,000 groups, 4 rows per group;
# for row r: g = r % G (the key) and i = r // G (the row's index within g).
#
#   g = 0     : v NULL on all 4 rows      -> count(DISTINCT v) = 0
#               w = 1  on all 4 rows      -> sum(w) = 4,  avg(w) = 1.0
#   g = 1     : v = 10 + i, i in 0..3     -> count(DISTINCT v) = 4
#               w NULL on all 4 rows      -> sum(w) = NULL, avg(w) = NULL
#   g >= 2    : v = g*10 + i for i<3, NULL at i=3
#                                         -> count(DISTINCT v) = 3
#               w = g+1 for i != 2, NULL at i=2
#                                         -> sum(w) = 3*(g+1), avg(w) = g+1
#   every g                               -> count(*) = 4
#
# ⚠⚠ g=0 AND g=1 ARE A CROSS, NOT A PAIR. `count(DISTINCT x)` does not count
#   NULL (g=0 answers 0 — not NULL, not 4) while the OTHER aggregates over the
#   SAME rows still see them (g=0's count(*) is 4 and its sum(w) is a real
#   number); and symmetrically a group with ZERO contributing rows for SUM/AVG
#   emits NULL while its distinct set is NOT empty (g=1). A fold that shared one
#   contributing-row set between the distinct sets and the cells cannot produce
#   both rows.
#
# ⚠ EVERY NULL ROW CARRIES A PLAUSIBLE PAYLOAD chosen so that counting it
#   CHANGES THE ANSWER. Arrow leaves a null slot's data word unspecified and
#   every writer here stores something, so a fold whose null guard is true by
#   construction reads it. The payloads are 7 (g=0) and g*10+9 (g>=2), neither
#   of which is in its own group's distinct set.
#
# ============================ WHICH MUTANT TURNS IT RED ======================
#
# Put back a bare `if n_rows > _CD_FOLD_MAX_ROWS: return None` in
# `fold_mixed_count_distinct_over_batch` (and drop
# `mixed_offcell_row_ceiling_for_schema`) and §2's CD-only case goes RED, and
# so do §2's STRING cases: they assert the ONE ceiling, and that mutant puts
# the 8M number on every arm alike. §1 stays GREEN under it BY CONSTRUCTION —
# it guards the half that must NOT move.
#
# Encapsulation (pointer rules): NO UnsafePointer crossing any boundary,
#   no wildcard origins, no unsafe_from_address, no take_pointee in THIS test.
# =============================================================================

from std.collections import List, Optional
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder,
)
from komira_plan_expr.expr import Expr
from komira_plan_expr.agg_expr import (
    AggExpr, AGG_COUNT, AGG_COUNT_DISTINCT, AGG_MEAN, AGG_MIN, AGG_SUM,
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
from komira_dispatch_agg_folds.cd_grouped_fold import _CD_FOLD_MAX_ROWS


# 6,000 groups crosses the group table's load-factor-0.7 growth threshold four
# times (it starts at 1024 slots and doubles at 717 / 1434 / 2867 / 5734
# groups), so the fold rehashes MID-FOLD four times with live accumulators.
# ⛔ Do not lower `_G` below 5,734 without re-deriving that sentence — under it
# the table never grows and §1 silently stops covering the rehash.
comptime _G: Int = 6_000
comptime _ROWS_PER_GROUP: Int = 4
comptime _N: Int = _G * _ROWS_PER_GROUP


# =============================================================================
# THE FIXTURE — three INT64 columns, 6,000 groups, and a NULL cross.
# =============================================================================


def _fixture_many_groups() raises -> RecordBatch:
    """INT64 key `k` (non-null), nullable INT64 `v` (the CD input), nullable
    INT64 `w` (the SUM/AVG input). See THE ORACLE above for the closed forms.

    ⚠ The accessor calls are hoisted out of the row loops on purpose:
    `_typed_ptr_mut()` and `Optional.value()` are real calls in a fastbuild
    test binary, and per-row they dominated this function's wall."""
    var karr = PrimitiveArray[DType.int64].allocate(_N)
    var varr = PrimitiveArray[DType.int64].allocate_nullable(_N)
    var warr = PrimitiveArray[DType.int64].allocate_nullable(_N)
    var v_nulls = 0
    var w_nulls = 0

    # --- Pass 1: the VALUES. ---------------------------------------------
    # SAFETY: three pointers into three DISTINCT arrays, each of length `_N`,
    # each array alive for the whole of this function, every index below `_N`.
    # They never leave this scope, so no module boundary is crossed, and the
    # validity pass below runs only after their last use.
    if True:
        var kptr = karr._typed_ptr_mut()
        var vptr = varr._typed_ptr_mut()
        var wptr = warr._typed_ptr_mut()
        for r in range(_N):
            var g = r % _G
            var i = r // _G
            kptr[r] = Int64(g)
            if g == 0:
                # v is NULL on every row of g=0 (bit cleared below) -> CD is 0,
                # while count(*) and sum(w) still see all four rows. 7 is NOT in
                # this group's distinct set, so a fold that read a null row's
                # raw word would answer 1 instead of 0.
                vptr[r] = Int64(7)
                wptr[r] = Int64(1)
            elif g == 1:
                # The mirror: every v is a real value, every w is NULL.
                vptr[r] = Int64(10 + i)
                wptr[r] = Int64(555)
            else:
                if i == 3:
                    vptr[r] = Int64(g * 10 + 9)
                else:
                    vptr[r] = Int64(g * 10 + i)
                if i == 2:
                    wptr[r] = Int64(-1)
                else:
                    wptr[r] = Int64(g + 1)

    # --- Pass 2: the VALIDITY bits. --------------------------------------
    if True:
        ref vbits = varr.validity.value()
        for r in range(_N):
            var g = r % _G
            var i = r // _G
            if g == 0 or (g >= 2 and i == 3):
                vbits.clear(r)
                v_nulls += 1
    if True:
        ref wbits = warr.validity.value()
        for r in range(_N):
            var g = r % _G
            var i = r // _G
            if g == 1 or (g >= 2 and i == 2):
                wbits.clear(r)
                w_nulls += 1

    varr.null_count = v_nulls
    warr.null_count = w_nulls

    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    rbb.add_column(Column.from_primitive[DType.int64](varr^))
    rbb.add_column(Column.from_primitive[DType.int64](warr^))

    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    sb.add_field(Field(String("w"), ArrowType.INT64, True))
    return rbb.build(sb.build())


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


def _q9_shape_aggs() raises -> AggExprArray:
    """Q9's aggregate list, in Q9's order: SUM, COUNT(*), AVG, COUNT(DISTINCT).
    The interleave is deliberate — the off-cell aggregate is LAST, so a fold
    that keyed its accumulator slots off POSITION rather than off KIND would be
    caught here rather than at full scale."""
    var aggs = AggExprArray()
    aggs.append(_one(AGG_SUM, String("w"), String("sum_w")))
    aggs.append(_count_star(String("c")))
    aggs.append(_one(AGG_MEAN, String("w"), String("avg_w")))
    aggs.append(_one(AGG_COUNT_DISTINCT, String("v"), String("cd_v")))
    return aggs^


def _row_of_key(imm out: RecordBatch, key: Int) raises -> Int:
    """Locate a group by its KEY VALUE. The fold emits groups in first-
    occurrence order; reading by slot index would pass for the wrong reason,
    and after four rehashes "the order I expected" is exactly the assumption
    under test."""
    var kc = out.column_as_primitive_int64(0)
    for g in range(out.num_rows()):
        if Int(kc.get(g)) == key:
            return g
    raise Error("group key not found in the fold output: " + String(key))


def _assert_i64(
    imm out: RecordBatch, col: Int, row: Int, want: Int, msg: String
) raises:
    var c = out.column_as_primitive_int64(col)
    assert_false(c.is_null(row), msg + " — must not be NULL")
    assert_equal(Int(c.get(row)), want, msg)


def _assert_f64(
    imm out: RecordBatch, col: Int, row: Int, want: Float64, msg: String
) raises:
    var c = out.column_as_primitive_float64(col)
    assert_false(c.is_null(row), msg + " — must not be NULL")
    assert_equal(c.get(row), want, msg)


def _assert_ordinary_group(imm out: RecordBatch, g: Int) raises:
    """Every `g >= 2` group's four closed forms, checked together."""
    var row = _row_of_key(out, g)
    var tag = String("g=") + String(g) + String(" ")
    _assert_i64(out, 2, row, _ROWS_PER_GROUP, tag + "count(*)")
    _assert_i64(out, 4, row, 3, tag + "count(DISTINCT v) skips the i=3 NULL")
    _assert_i64(out, 1, row, 3 * (g + 1), tag + "sum(w) skips the i=2 NULL")
    _assert_f64(out, 3, row, Float64(g + 1), tag + "avg(w) = sum/3, not sum/4")


# =============================================================================
# §1 — THE Q9 SHAPE OVER 6,000 GROUPS: the group table grows and rehashes four
#      times MID-FOLD, with live distinct sets and live cells in every slot.
# =============================================================================


def test_Q9_shape_over_enough_groups_to_rehash_the_group_table() raises:
    """`SELECT k, sum(w), count(*), avg(w), count(DISTINCT v) GROUP BY k` over
    6,000 groups. Every group must survive the rehashes with its own values."""
    var batch = _fixture_many_groups()
    assert_equal(batch.num_rows(), _N, "precondition: 24,000 rows")

    var ad = _agg(_q9_shape_aggs(), batch.schema)
    var out_opt = fold_mixed_count_distinct_over_batch(ad, batch)
    assert_true(
        out_opt.__bool__(), "the mixed off-cell fold must SERVE the Q9 shape"
    )
    var out = out_opt.take()
    assert_equal(
        out.num_rows(),
        _G,
        (
            "every group must appear exactly once — a rehash that dropped or"
            " merged a slot shows up here as a row count, before any value is"
            " read"
        ),
    )
    assert_equal(out.num_columns(), 5, "k + four aggregates")

    # --- g = 0: the distinct set is EMPTY while the cells are not. -----------
    var r0 = _row_of_key(out, 0)
    _assert_i64(out, 2, r0, _ROWS_PER_GROUP, "g=0 count(*) counts NULL-v rows")
    _assert_i64(
        out,
        4,
        r0,
        0,
        (
            "g=0 count(DISTINCT v) over an ALL-NULL column is 0 — not NULL, not"
            " the row count, and not 1 from the null rows' payload"
        ),
    )
    _assert_i64(out, 1, r0, 4, "g=0 sum(w) still sees all four rows")
    _assert_f64(out, 3, r0, Float64(1.0), "g=0 avg(w)")

    # --- g = 1: the cells are EMPTY while the distinct set is not. -----------
    var r1 = _row_of_key(out, 1)
    _assert_i64(out, 2, r1, _ROWS_PER_GROUP, "g=1 count(*) counts NULL-w rows")
    _assert_i64(out, 4, r1, 4, "g=1 count(DISTINCT v) = |{10,11,12,13}|")
    var sw = out.column_as_primitive_int64(1)
    assert_true(
        sw.is_null(r1),
        "g=1 sum(w) over a group with ZERO contributing rows is NULL, not 0",
    )
    var aw = out.column_as_primitive_float64(3)
    assert_true(
        aw.is_null(r1),
        "g=1 avg(w) over a group with ZERO contributing rows is NULL",
    )

    # --- The ordinary groups, sampled across the whole key range. ------------
    # First-occurrence order is key order here, so these four sit on either
    # side of every one of the four rehash points (717 / 1434 / 2867 / 5734).
    _assert_ordinary_group(out, 2)
    _assert_ordinary_group(out, 1_433)
    _assert_ordinary_group(out, 2_867)
    _assert_ordinary_group(out, _G - 1)


def test_every_ordinary_group_holds_its_own_closed_form() raises:
    """⚠ THE SAMPLE IN §1 IS A SAMPLE. This sweeps all 5,998 ordinary groups,
    because "the rehash lost one group's accumulator" is exactly the failure a
    four-point sample can miss."""
    var batch = _fixture_many_groups()
    var ad = _agg(_q9_shape_aggs(), batch.schema)
    var out_opt = fold_mixed_count_distinct_over_batch(ad, batch)
    assert_true(out_opt.__bool__(), "the fold must SERVE the Q9 shape")
    var out = out_opt.take()

    var kc = out.column_as_primitive_int64(0)
    var sumc = out.column_as_primitive_int64(1)
    var cntc = out.column_as_primitive_int64(2)
    var avgc = out.column_as_primitive_float64(3)
    var cdc = out.column_as_primitive_int64(4)

    var seen = 0
    for row in range(out.num_rows()):
        var g = Int(kc.get(row))
        if g < 2:
            continue
        seen += 1
        if Int(cntc.get(row)) != _ROWS_PER_GROUP:
            raise Error("count(*) wrong at g=" + String(g))
        if Int(cdc.get(row)) != 3:
            raise Error("count(DISTINCT v) wrong at g=" + String(g))
        if sumc.is_null(row) or Int(sumc.get(row)) != 3 * (g + 1):
            raise Error("sum(w) wrong at g=" + String(g))
        if avgc.is_null(row) or avgc.get(row) != Float64(g + 1):
            raise Error("avg(w) wrong at g=" + String(g))
    assert_equal(seen, _G - 2, "all 5,998 ordinary groups were checked")


# =============================================================================
# §2 — ⭐ THE CEILING DERIVATION. The CD-only case is the RED→GREEN pair; the
#      two STRING cases pin that every off-cell kind resolves to the SAME
#      ceiling.
# =============================================================================


def _string_fixture() raises -> RecordBatch:
    """Four rows: INT64 key `k`, STRING `s`, INT64 `w`. Small on purpose — §2
    asks what ceiling a NODE resolves to, which is a property of the node and
    the schema and never of the batch in hand."""
    var karr = PrimitiveArray[DType.int64].allocate(4)
    var warr = PrimitiveArray[DType.int64].allocate(4)
    if True:
        var kptr = karr._typed_ptr_mut()
        var wptr = warr._typed_ptr_mut()
        # SAFETY: two pointers into two distinct 4-element arrays that outlive
        # this scope; indices 0..3 only; neither escapes the function.
        for i in range(4):
            kptr[i] = Int64(i % 2)
            wptr[i] = Int64(i)
    var svals: List[String] = [
        String("b"), String("a"), String("d"), String("c"),
    ]
    var sarr = StringArray.from_strings(svals)

    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    rbb.add_column(Column.from_string(sarr^))
    rbb.add_column(Column.from_primitive[DType.int64](warr^))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    sb.add_field(Field(String("w"), ArrowType.INT64, False))
    return rbb.build(sb.build())


def test_a_CD_ONLY_node_resolves_to_a_ceiling_above_ClickBench_scale() raises:
    """⭐ THE RED. A mixed fold that applied arm 1's `_CD_FOLD_MAX_ROWS` to
    itself would return 8,000,000 here, and a benchmark-scale leaf of this
    shape would be refused after being fully decoded."""
    var batch = _string_fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_SUM, String("w"), String("sum_w")))
    aggs.append(_count_star(String("c")))
    aggs.append(_one(AGG_MEAN, String("w"), String("avg_w")))
    aggs.append(_one(AGG_COUNT_DISTINCT, String("w"), String("cd_w")))
    var ad = _agg(aggs^, batch.schema)
    assert_true(
        mixed_offcell_servable_for_schema(ad, batch.schema),
        "precondition: this shape IS one this fold serves",
    )
    var ceiling = mixed_offcell_row_ceiling_for_schema(ad, batch.schema)
    assert_true(
        ceiling > _CD_FOLD_MAX_ROWS,
        "a CD-only node must NOT inherit the all-CD fold's ceiling",
    )
    assert_true(
        ceiling >= 99_997_497,
        (
            "and it must clear the ClickBench wide table, or a benchmark-scale"
            " leaf is refused"
        ),
    )


def test_a_STRING_offcell_node_no_longer_keeps_the_LOW_ceiling() raises:
    """⭐ A STRING MIN/MAX node does NOT get the all-CD fold's low ceiling.
    `_MIX_KIND_STR` does not pre-extract a heap `String` PER ROW: the fold
    adopts the Arrow `StringArray` and keeps a per-(group, aggregate) ROW
    INDEX, so the string arm costs ZERO bytes per row on a shareable column —
    there is no per-row term for a second, lower ceiling to price.

    ⚠ THE FALSIFIER FOR THE CLAIM THIS RESTS ON IS A MEMORY TEST, NOT THIS
    ONE: `test_mixed_fold_string_minmax_is_flat_in_rows` §1. A ceiling
    assertion cannot tell a real per-row cost from an imagined one."""
    var batch = _string_fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("s"), String("min_s")))
    aggs.append(_count_star(String("c")))
    var ad = _agg(aggs^, batch.schema)
    assert_true(
        mixed_offcell_servable_for_schema(ad, batch.schema),
        "precondition: the STRING MIN/MAX node IS one this fold serves",
    )
    assert_true(
        mixed_offcell_row_ceiling_for_schema(ad, batch.schema)
        > _CD_FOLD_MAX_ROWS,
        (
            "a STRING off-cell accumulator does not inherit the ALL-CD fold's"
            " row ceiling — it stages nothing per row"
        ),
    )


def test_a_node_carrying_BOTH_takes_THE_SAME_ceiling() raises:
    """⭐ A node carrying BOTH off-cell kinds takes the same ceiling as either
    half. There is no String per-row cost and there is no second ceiling, so
    the property worth pinning is that the MIXTURE is indistinguishable from
    either half — a node that took the LOWER of two ceilings would fail."""
    var batch = _string_fixture()
    var both = AggExprArray()
    both.append(_one(AGG_COUNT_DISTINCT, String("w"), String("cd_w")))
    both.append(_one(AGG_MIN, String("s"), String("min_s")))
    both.append(_count_star(String("c")))
    var both_ad = _agg(both^, batch.schema)

    var cd_only = AggExprArray()
    cd_only.append(_one(AGG_COUNT_DISTINCT, String("w"), String("cd_w")))
    cd_only.append(_count_star(String("c")))
    var cd_ad = _agg(cd_only^, batch.schema)

    assert_equal(
        mixed_offcell_row_ceiling_for_schema(both_ad, batch.schema),
        mixed_offcell_row_ceiling_for_schema(cd_ad, batch.schema),
        "a CD beside a STRING MIN/MAX pays no extra per-row cost for it",
    )
    assert_true(
        mixed_offcell_row_ceiling_for_schema(both_ad, batch.schema)
        >= 99_997_497,
        "and the mixture still clears the ClickBench wide table",
    )


def test_a_NUMERIC_minmax_node_is_still_not_this_folds_business() raises:
    """⛔ THE NUMERIC MIN/MAX STAYS WITH THE PARALLEL KERNEL, restated at the
    ceiling. `min(<bigint>), count(*)` is an ordinary fixed-cell aggregate the
    PARALLEL kernel serves. A high ceiling must not make it reachable here —
    the DType gate, not the ceiling, is what keeps it out, and this asserts the
    gate answers."""
    var batch = _string_fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("w"), String("min_w")))
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


# =============================================================================
# §3 — NON-VACUOUSNESS.
# =============================================================================


def test_the_group_count_really_does_force_a_rehash() raises:
    """§1 only covers the growth path while `_G` exceeds the last doubling
    threshold. The open-address table starts at 1024 slots and doubles when
    `n_groups * 10 >= cap * 7`; at cap 8192 that is 5,734 groups. If either
    number moves, §1 stops covering what it says it covers — silently. This
    makes that RED instead."""
    assert_true(
        _G > 5_734,
        (
            "6,000 groups must stay above the cap-8192 growth threshold, or"
            " the fold never rehashes and §1 is a 12-row test wearing a bigger"
            " fixture"
        ),
    )
    assert_equal(_G * _ROWS_PER_GROUP, _N, "the fixture arithmetic is exact")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
