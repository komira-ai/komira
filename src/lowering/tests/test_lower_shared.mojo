# =============================================================================
# test_lower_shared: how a shared subplan is cut, and what about one is refused
# =============================================================================
#
# A plan holds a shared subtree once, its canonical occurrence, and every later
# occurrence as a PLAN_CSE_REF leaf carrying the canonical subtree's
# `structural_hash()`, the shape `optimizer.plan_cse` produces. Each test
# builds such a plan by hand, lowers it under the reference host profile and
# checks the segments, their sources and edges, the scan facts they use, or
# the refusal text.
#
#   * A subtree with a breaker or a limit is cut once: the canonical position
#     and every reference read its segment over an E3 edge, a union naming it
#     once per branch; operators fused after the breaker end it in a collect;
#     a sort's and a top-n's readers are sorted inputs, so a limit above one
#     is refused; a limit over a sort that is not itself shared (it may
#     read a reference) is still one range of it (SINK_TOPN), and one whose
#     sort is shared is refused.
#   * A subtree of scans, filters, projections and unions is cut again at
#     every reference over the same scan facts (statistics and dictionary
#     encoded keys), also when it holds a reference itself, and the
#     references take no facts of their own.
#   * In a join the right child is walked first, as the producer visits it:
#     a self-join cuts the right scan and recuts it on the left, each child's
#     scans keep their facts (under a left child of every kind the cutter
#     cuts, a top-n and a nested join included), and a shared join is cut
#     once.
#   * A window is a breaker like a sort: one read twice is cut once and its
#     readers are sorted inputs, a reference under one is found, a left child
#     that is one keeps its scans' facts, and a canonical subtree holding one
#     over a reference is found by its unfolded hash.
#   * References under every node kind the cutter cuts are found; a shared
#     subtree holding a reference, and a second inline subtree of a named hash,
#     are cut as the rules say.
#   * Refused: a reference with no canonical subtree, one reached before it,
#     one of another layout; a view reference, with the reason.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweredPlan,
    LoweringInputs,
    LOWERING_INPUTS_SCAN_COUNT,
    LOWERING_UNCUTTABLE_NODE,
)
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    KEY_DTYPE_STRING,
    OP_FILTER,
    OP_JOIN_PROBE,
    SINK_AGG,
    SINK_COLLECT,
    SINK_HASH_BUILD,
    SINK_ORIENT_DICT_ENCODED,
    SINK_PARTITION_BY,
    SINK_SORT,
    SINK_TOPN,
    SOURCE_CONCAT,
    SOURCE_PARQUET as SEG_SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr, BIN_GT
from plan_expr.partition_expr import PartitionExpr, PartitionFrame
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_RIGHT,
    PLAN_CSE_REF,
    PLAN_VIEW_REF,
    plan_tag_name,
)
from plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    return sb.build()


def _string_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    return sb.build()


def _scan(path: String = "a.parquet") -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema())


def _ref_to(canonical: LogicalPlan) -> LogicalPlan:
    """The reference `plan_cse` leaves for a later occurrence of `canonical`,
    which is the subtree as it stood before any repeat inside it was folded:
    `plan_cse` hashes every subtree before it rewrites one."""
    return LogicalPlan.cse_ref(
        canonical.structural_hash(), canonical.output_schema.copy()
    )


def _union(var branches: List[LogicalPlan]) -> LogicalPlan:
    var schema = branches[0].output_schema.copy()
    var children = List[OwnedPointer[LogicalPlan]]()
    for i in range(len(branches)):
        children.append(OwnedPointer(branches[i].copy()))
    return LogicalPlan.union(children^, schema^)


def _two(var a: LogicalPlan, var b: LogicalPlan) -> List[LogicalPlan]:
    var out = List[LogicalPlan]()
    out.append(a^)
    out.append(b^)
    return out^


def _count_by(var child: LogicalPlan, key: String = "k") -> LogicalPlan:
    var group_by = ExprArray()
    group_by.append(Expr.col_ref(key))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    return LogicalPlan.aggregate(group_by^, aggs^, child^)


def _k_gt(v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("k"), Expr.literal(ScalarValue.from_int64(v))
    )


def _keys(name: String) -> List[String]:
    var out = List[String]()
    out.append(name)
    return out^


def _ascending() -> List[Bool]:
    var out = List[Bool]()
    out.append(False)
    return out^


def _sorted(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.sort(_keys("k"), _ascending(), child^)


def _windowed(var child: LogicalPlan) raises -> LogicalPlan:
    """ROW_NUMBER() OVER (PARTITION BY s ORDER BY k) AS rn over `child`, which
    has the columns k and s."""
    var exprs = List[PartitionExpr]()
    exprs.append(
        PartitionExpr.row_number()
        .with_frame(PartitionFrame.running_range())
        .with_alias("rn")
    )
    var order = List[Bool]()
    order.append(False)
    return LogicalPlan.partition_by(
        _keys("s"), _keys("k"), order^, exprs^, child^
    )


def _windowed_by_k(var child: LogicalPlan) raises -> LogicalPlan:
    """ROW_NUMBER() OVER (ORDER BY k) AS rn over `child`, whose columns are k
    and one more."""
    var exprs = List[PartitionExpr]()
    exprs.append(
        PartitionExpr.row_number()
        .with_frame(PartitionFrame.running_range())
        .with_alias("rn")
    )
    var order = List[Bool]()
    order.append(False)
    return LogicalPlan.partition_by(
        List[String](), _keys("k"), order^, exprs^, child^
    )


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows, List[String](), List[ColumnStats](), STATS_SOURCE_PARQUET_METADATA
    )


def _inputs(scans: Int) -> LoweringInputs:
    var inputs = LoweringInputs()
    for _ in range(scans):
        inputs.add_scan()
    return inputs^


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, reference_host_profile("test-build"), inputs)


def _message(plan: LogicalPlan, inputs: LoweringInputs) raises -> String:
    """The refusal text, or an empty string when the plan lowers."""
    try:
        _ = _lowered(plan, inputs)
    except e:
        return String(e)
    return String("")


def _refused_with(message: String, token: String, why: String) raises:
    assert_true(message.startswith(token + ": "), "no token: " + message)
    assert_true(why in message, "does not say " + why + ": " + message)


def _expect_reads(lp: LoweredPlan, seg: Int, producer: Int) raises:
    """Segment `seg` reads the output of `producer` over one E3 edge."""
    ref s = lp.segments[seg]
    assert_equal(s.source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(len(s.source_spec.dep_seg_ids), 1)
    assert_equal(s.source_spec.dep_seg_ids[0], producer)
    assert_equal(len(s.deps), 1)
    assert_equal(s.deps[0], producer)
    assert_equal(s.edge_tags[0], EDGE_E3_PUBLISH_WAIT)


def _expect_concat(lp: LoweredPlan, seg: Int, want: List[Int]) raises:
    """Segment `seg` concatenates `want`, in that order, one E3 edge each."""
    ref s = lp.segments[seg]
    assert_equal(s.source_kind, SOURCE_CONCAT)
    assert_equal(len(s.source_spec.dep_seg_ids), len(want))
    assert_equal(len(s.deps), len(want))
    for i in range(len(want)):
        assert_equal(s.source_spec.dep_seg_ids[i], want[i])
        assert_equal(s.deps[i], want[i])
        assert_equal(s.edge_tags[i], EDGE_E3_PUBLISH_WAIT)


def _inner_join(var left: LogicalPlan, var right: LogicalPlan) -> LogicalPlan:
    """left JOIN right ON k = k, the right child building."""
    return LogicalPlan.join(
        left^, right^, _keys("k"), _keys("k"), JOIN_INNER, JOIN_ALGO_AUTO,
        None, JOIN_BUILD_SIDE_RIGHT,
    )


def _join_on(
    var left: LogicalPlan, var right: LogicalPlan, lk: String, rk: String
) -> LogicalPlan:
    """left JOIN right ON lk = rk, the right child building."""
    return LogicalPlan.join(
        left^, right^, _keys(lk), _keys(rk), JOIN_INNER, JOIN_ALGO_AUTO,
        None, JOIN_BUILD_SIDE_RIGHT,
    )


def _expect_parquet_cards(
    lp: LoweredPlan, paths: List[String], rows: List[Int]
) raises:
    """Every segment that reads `paths[i]` estimates `rows[i]` rows: the facts
    of that scan, and no other's, reached it. Each path is read at least
    once."""
    for i in range(len(paths)):
        var seen = 0
        for s in range(len(lp.segments)):
            ref seg = lp.segments[s]
            if (
                seg.source_kind == SEG_SOURCE_PARQUET
                and seg.source_spec.parquet_path == paths[i]
            ):
                seen += 1
                assert_equal(
                    seg.card_estimate_rows, rows[i], paths[i] + " in segment " + String(s)
                )
        assert_true(seen > 0, paths[i] + " is read by no segment")


def _ids(a: Int, b: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    return out^


# =============================================================================
# A subtree with a breaker or a limit: cut once, read by every reference
# =============================================================================


def test_an_aggregation_read_twice_is_cut_once_and_named_by_both_branches() raises:
    var canonical = _count_by(_scan())
    var plan = _union(_two(canonical.copy(), _ref_to(canonical)))
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(40)))
    var lp = _lowered(plan, inputs)
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].source_kind, SEG_SOURCE_PARQUET)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    assert_equal(lp.segments[0].card_estimate_rows, 40)
    _expect_concat(lp, 1, _ids(0, 0))
    assert_equal(lp.segments[1].sink_kind, SINK_COLLECT)
    assert_equal(lp.result_seg_id, 1)
    assert_equal(len(lp.params.agg), 1)
    var text = render_lowered_plan(lp)
    assert_true("  source: SOURCE_CONCAT from=0,0\n" in text, text)
    assert_true("  deps: 0/E3 0/E3\n" in text, text)


def test_every_reference_reads_the_shared_segment_under_its_own_operators() raises:
    var canonical = _count_by(_scan())
    var plan = _union(
        _two(
            LogicalPlan.filter(_k_gt(1), canonical.copy()),
            LogicalPlan.filter(_k_gt(5), _ref_to(canonical)),
        )
    )
    var lp = _lowered(plan, _inputs(1))
    assert_equal(len(lp.segments), 4)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    _expect_reads(lp, 1, 0)
    assert_equal(len(lp.segments[1].ops), 1)
    assert_equal(lp.segments[1].ops[0].tag, OP_FILTER)
    _expect_reads(lp, 2, 0)
    assert_equal(len(lp.segments[2].ops), 1)
    _expect_concat(lp, 3, _ids(1, 2))


def test_a_shared_subtree_with_an_operator_after_its_breaker_ends_in_a_collect() raises:
    var canonical = LogicalPlan.filter(_k_gt(1), _count_by(_scan()))
    var plan = _union(_two(canonical.copy(), _ref_to(canonical)))
    var lp = _lowered(plan, _inputs(1))
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    _expect_reads(lp, 1, 0)
    assert_equal(lp.segments[1].sink_kind, SINK_COLLECT)
    assert_equal(len(lp.segments[1].ops), 1)
    _expect_concat(lp, 2, _ids(1, 1))


def test_a_shared_limit_is_cut_once_into_a_collect() raises:
    var canonical = LogicalPlan.limit(3, _scan())
    var plan = _union(_two(canonical.copy(), _ref_to(canonical)))
    var lp = _lowered(plan, _inputs(1))
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].source_kind, SEG_SOURCE_PARQUET)
    assert_equal(lp.segments[0].sink_kind, SINK_COLLECT)
    _expect_concat(lp, 1, _ids(0, 0))


def test_a_shared_sort_is_a_sorted_input_for_every_reader() raises:
    var canonical = _sorted(_scan())
    var plan = _union(_two(canonical.copy(), _ref_to(canonical)))
    var lp = _lowered(plan, _inputs(1))
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].sink_kind, SINK_SORT)
    _expect_concat(lp, 1, _ids(0, 0))
    # A limit above a reference to the sort is a limit over its sorted stream,
    # as one above the sort itself is.
    var limited = _union(
        _two(canonical.copy(), LogicalPlan.limit(2, _ref_to(canonical)))
    )
    _refused_with(
        _message(limited, _inputs(1)),
        LOWERING_UNCUTTABLE_NODE,
        "a limit over a sorted stream",
    )
    # And the canonical position's own reader is one too.
    var first_limited = _union(
        _two(LogicalPlan.limit(2, canonical.copy()), _ref_to(canonical))
    )
    _refused_with(
        _message(first_limited, _inputs(1)),
        LOWERING_UNCUTTABLE_NODE,
        "a limit over a sorted stream",
    )


def _top3(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.topn(_keys("k"), _ascending(), 3, child^)


def _count_sinks(lp: LoweredPlan, kind: UInt8) -> Int:
    var n = 0
    for i in range(len(lp.segments)):
        if lp.segments[i].sink_kind == kind:
            n += 1
    return n


def test_a_shared_top_n_is_cut_once_and_read_by_both_branches() raises:
    var canonical = _top3(_scan())
    var plan = _union(_two(canonical.copy(), _ref_to(canonical)))
    var lp = _lowered(plan, _inputs(1))
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].sink_kind, SINK_TOPN)
    assert_equal(len(lp.params.topn), 1)
    assert_equal(lp.params.topn[0].n, 3)
    assert_equal(lp.params.topn[0].offset, 0)
    _expect_concat(lp, 1, _ids(0, 0))
    # Its readers are sorted inputs, as a shared sort's are: a limit above
    # the reference, or above the canonical position, is refused, and the
    # top-n is still the segment both read.
    var limited = _union(
        _two(canonical.copy(), LogicalPlan.limit(2, _ref_to(canonical)))
    )
    _refused_with(
        _message(limited, _inputs(1)),
        LOWERING_UNCUTTABLE_NODE,
        "a limit over a sorted stream",
    )
    var first_limited = _union(
        _two(LogicalPlan.limit(2, canonical.copy(), 1), _ref_to(canonical))
    )
    _refused_with(
        _message(first_limited, _inputs(1)),
        LOWERING_UNCUTTABLE_NODE,
        "a limit over a sorted stream",
    )


def test_a_limit_over_a_sort_beside_a_shared_subtree_is_still_a_range() raises:
    # The plan shares a sort over b; the limit with an offset over the sort
    # of a is no shared subtree, so it is a range.
    var shared = _sorted(_scan("b.parquet"))
    var branches = List[LogicalPlan]()
    branches.append(LogicalPlan.limit(2, _sorted(_scan("a.parquet")), 1))
    branches.append(shared.copy())
    branches.append(_ref_to(shared))
    var lp = _lowered(_union(branches^), _inputs(2))
    assert_equal(_count_sinks(lp, SINK_TOPN), 1)
    assert_equal(_count_sinks(lp, SINK_SORT), 1)
    assert_equal(len(lp.params.topn), 1)
    assert_equal(lp.params.topn[0].n, 2)
    assert_equal(lp.params.topn[0].offset, 1)


def _kn(var child: LogicalPlan) -> LogicalPlan:
    """`child`'s columns k and n, as a projection over it."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("k"))
    exprs.append(Expr.col_ref("n"))
    return LogicalPlan.project(exprs^, child^)


def test_a_limit_over_a_sort_that_holds_a_reference_is_a_range() raises:
    # X = count by k, shared. The sort reads a reference to X, but neither it
    # nor the projection and the limit above it is itself shared, so the
    # chain is one range: (offset 1, 2 rows) of the inner limit's 5.
    var x = _count_by(_scan("x.parquet"))
    var chain = LogicalPlan.limit(
        2, _kn(LogicalPlan.limit(5, _sorted(_ref_to(x)))), 1
    )
    var plan = _union(_two(_union(_two(x.copy(), _ref_to(x))), chain^))
    var lp = _lowered(plan, _inputs(1))
    assert_equal(_count_sinks(lp, SINK_TOPN), 1)
    assert_equal(_count_sinks(lp, SINK_SORT), 0)
    assert_equal(len(lp.params.topn), 1)
    assert_equal(lp.params.topn[0].n, 2)
    assert_equal(lp.params.topn[0].offset, 1)


def test_a_limit_over_a_shared_sort_that_holds_a_reference_is_refused() raises:
    # The sort over a reference to X is itself shared: its reference carries
    # the hash of the sort over X, as the producer saw it before folding X.
    # Its other reader reads it whole, so a limit over it, directly or
    # through a projection, keeps rows of a sorted stream and is refused.
    var x = _count_by(_scan("x.parquet"))
    var shared_sort = _sorted(_ref_to(x))
    var limits = List[LogicalPlan]()
    limits.append(LogicalPlan.limit(2, shared_sort.copy(), 1))
    limits.append(LogicalPlan.limit(2, _kn(shared_sort.copy())))
    for i in range(len(limits)):
        var branches = List[LogicalPlan]()
        branches.append(_union(_two(x.copy(), _ref_to(x))))
        branches.append(limits[i].copy())
        branches.append(_ref_to(_sorted(x.copy())))
        _refused_with(
            _message(_union(branches^), _inputs(1)),
            LOWERING_UNCUTTABLE_NODE,
            "a limit over a sorted stream that is not one range of its sort",
        )


def test_a_left_child_with_a_top_n_keeps_its_scans_facts() raises:
    # Left: a top-n over l0 (scan 0) and a limit with an offset over a sort
    # of l1 (scan 1). Right: X UNION ALL ref(X) (scan 2), walked first from
    # scan 2, which counts the top-n's scan.
    var branches = List[LogicalPlan]()
    branches.append(_top3(_scan("l0.parquet")))
    branches.append(LogicalPlan.limit(2, _sorted(_scan("l1.parquet")), 1))
    var x = _scan("x.parquet")
    var plan = _inner_join(_union(branches^), _union(_two(x.copy(), _ref_to(x))))
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(1)))
    inputs.add_scan(Optional[TableStats](_stats(2)))
    inputs.add_scan(Optional[TableStats](_stats(99)))
    var lp = _lowered(plan, inputs)
    var paths = List[String]()
    paths.append("l0.parquet")
    paths.append("l1.parquet")
    paths.append("x.parquet")
    var rows = List[Int]()
    rows.append(1)
    rows.append(2)
    rows.append(99)
    _expect_parquet_cards(lp, paths, rows)
    assert_equal(_count_sinks(lp, SINK_TOPN), 2)


def test_a_shared_subtree_that_holds_a_reference_is_cut_once() raises:
    # The producer saw inner = count by k, outer = inner UNION ALL inner, and
    # the plan outer UNION ALL outer. It keeps the first outer, folds the
    # second inner inside it and the second outer, each reference carrying
    # the hash of the subtree as it stood before folding.
    var inner = _count_by(_scan())
    var outer_seen = _union(_two(inner.copy(), inner.copy()))
    var outer = _union(_two(inner.copy(), _ref_to(inner)))
    var plan = _union(_two(outer^, _ref_to(outer_seen)))
    var lp = _lowered(plan, _inputs(1))
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    _expect_concat(lp, 1, _ids(0, 0))
    assert_equal(lp.segments[1].sink_kind, SINK_COLLECT)
    _expect_concat(lp, 2, _ids(1, 1))


def test_a_shared_subtree_over_an_earlier_one_is_found_by_its_unfolded_hash() raises:
    # The producer saw X, sort(X), sort(X) with X = the first 3 rows: X is
    # kept, the X inside the first sort and the second sort are references.
    var x = LogicalPlan.limit(3, _scan())
    var sorted_seen = _sorted(x.copy())
    var branches = List[LogicalPlan]()
    branches.append(x.copy())
    branches.append(_sorted(_ref_to(x)))
    branches.append(_ref_to(sorted_seen))
    var lp = _lowered(_union(branches^), _inputs(1))
    # 0: X's collect. 1: the sort over a reader of 0. 2: 0, then 1 twice.
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].sink_kind, SINK_COLLECT)
    _expect_reads(lp, 1, 0)
    assert_equal(lp.segments[1].sink_kind, SINK_SORT)
    var want = List[Int]()
    want.append(0)
    want.append(1)
    want.append(1)
    _expect_concat(lp, 2, want)


def test_a_reference_hashed_over_folded_text_names_no_subtree() raises:
    # A hash taken over the plan after folding (the reference left in the
    # text) is not the hash of any subtree as the producer saw it.
    var inner = _count_by(_scan())
    var outer = _union(_two(inner.copy(), _ref_to(inner)))
    var plan = _union(_two(outer.copy(), _ref_to(outer)))
    _refused_with(
        _message(plan, _inputs(1)),
        LOWERING_UNCUTTABLE_NODE,
        "which is not cut before it",
    )


def test_three_references_name_the_segment_three_times() raises:
    var canonical = _count_by(_scan())
    var branches = List[LogicalPlan]()
    branches.append(canonical.copy())
    branches.append(_ref_to(canonical))
    branches.append(_ref_to(canonical))
    var lp = _lowered(_union(branches^), _inputs(1))
    assert_equal(len(lp.segments), 2)
    var want = List[Int]()
    want.append(0)
    want.append(0)
    want.append(0)
    _expect_concat(lp, 1, want)


def test_a_second_inline_subtree_of_a_named_hash_is_cut_as_itself() raises:
    # The producer replaces every later occurrence it can prove equal; one it
    # leaves whole is cut where it stands, and the reference still reads the
    # first.
    var canonical = _count_by(_scan())
    var branches = List[LogicalPlan]()
    branches.append(canonical.copy())
    branches.append(canonical.copy())
    branches.append(_ref_to(canonical))
    var lp = _lowered(_union(branches^), _inputs(2))
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    assert_equal(lp.segments[1].sink_kind, SINK_AGG)
    var want = List[Int]()
    want.append(0)
    want.append(1)
    want.append(0)
    _expect_concat(lp, 2, want)


# =============================================================================
# References under each node kind the cutter cuts
# =============================================================================


def test_references_under_every_cut_node_kind_read_the_shared_segment() raises:
    var canonical = LogicalPlan.limit(4, _scan())
    var branches = List[LogicalPlan]()
    branches.append(canonical.copy())
    branches.append(LogicalPlan.filter(_k_gt(0), _ref_to(canonical)))
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("k"))
    exprs.append(Expr.col_ref("s"))
    branches.append(LogicalPlan.project(exprs^, _ref_to(canonical)))
    branches.append(LogicalPlan.limit(1, _ref_to(canonical)))
    branches.append(_sorted(_ref_to(canonical)))
    var lp = _lowered(_union(branches^), _inputs(1))
    # 0: the limit's collect. 1..3: a reader of 0 under a filter, a projection
    # and a limit. 4: a sort over a reader of 0. 5: the concatenation. (A
    # reference under a distinct is `test_a_recut_scan_keeps_its_dictionary_
    # encoded_key`, one under an aggregation the test below.)
    assert_equal(len(lp.segments), 6)
    assert_equal(lp.segments[0].sink_kind, SINK_COLLECT)
    for seg in range(1, 5):
        _expect_reads(lp, seg, 0)
    assert_equal(lp.segments[3].sink_kind, SINK_COLLECT)
    assert_equal(lp.segments[4].sink_kind, SINK_SORT)
    var want = List[Int]()
    for seg in range(5):
        want.append(seg)
    _expect_concat(lp, 5, want)


def test_a_reference_under_an_aggregation_reads_the_shared_segment() raises:
    var canonical = LogicalPlan.limit(4, _scan())
    var plan = _union(
        _two(_count_by(canonical.copy()), _count_by(_ref_to(canonical)))
    )
    var lp = _lowered(plan, _inputs(1))
    # 0: the limit's collect. 1: count over a reader of 0 (the canonical
    # position). 2: count over a reader of 0 (the reference). 3: 1 then 2.
    assert_equal(len(lp.segments), 4)
    assert_equal(lp.segments[0].sink_kind, SINK_COLLECT)
    _expect_reads(lp, 1, 0)
    assert_equal(lp.segments[1].sink_kind, SINK_AGG)
    _expect_reads(lp, 2, 0)
    assert_equal(lp.segments[2].sink_kind, SINK_AGG)
    _expect_concat(lp, 3, _ids(1, 2))


# =============================================================================
# A subtree of scans, filters, projections and unions: cut again
# =============================================================================


def test_a_filtered_scan_is_cut_again_at_each_reference_over_its_scan() raises:
    var canonical = LogicalPlan.filter(_k_gt(1), _scan())
    var plan = _union(_two(canonical.copy(), _ref_to(canonical)))
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(25)))
    var lp = _lowered(plan, inputs)
    assert_equal(len(lp.segments), 3)
    for seg in range(2):
        assert_equal(lp.segments[seg].source_kind, SEG_SOURCE_PARQUET)
        assert_equal(lp.segments[seg].source_spec.parquet_path, "a.parquet")
        assert_equal(lp.segments[seg].card_estimate_rows, 25)
        assert_equal(len(lp.segments[seg].ops), 1)
        assert_equal(lp.segments[seg].ops[0].tag, OP_FILTER)
        assert_equal(len(lp.segments[seg].deps), 0)
    _expect_concat(lp, 2, _ids(0, 1))
    # The reference takes no scan facts of its own.
    _refused_with(
        _message(plan, _inputs(2)),
        LOWERING_INPUTS_SCAN_COUNT,
        "the plan has 1 scans and the inputs hold 2",
    )


def test_a_streaming_subtree_that_holds_a_reference_is_recut_over_its_scans() raises:
    # The producer saw U = D UNION ALL D (D a filtered scan) and the plan
    # U UNION ALL U: it keeps the first U with the second D inside it folded,
    # and folds the second U. One scan stands in the plan.
    var d = LogicalPlan.filter(_k_gt(1), _scan())
    var u_seen = _union(_two(d.copy(), d.copy()))
    var u = _union(_two(d.copy(), _ref_to(d)))
    var plan = _union(_two(u^, _ref_to(u_seen)))
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(12)))
    var lp = _lowered(plan, inputs)
    # 0, 1: D and its recut. 2: their concatenation. 3, 4: D and its recut
    # again, in the recut of U. 5: their concatenation. 6: 2 then 5.
    assert_equal(len(lp.segments), 7)
    var scans = _ids(0, 1)
    scans.extend(_ids(3, 4))
    for i in range(len(scans)):
        assert_equal(lp.segments[scans[i]].source_kind, SEG_SOURCE_PARQUET)
        assert_equal(lp.segments[scans[i]].card_estimate_rows, 12)
    _expect_concat(lp, 2, _ids(0, 1))
    _expect_concat(lp, 5, _ids(3, 4))
    _expect_concat(lp, 6, _ids(2, 5))


def test_a_recut_scan_keeps_its_dictionary_encoded_key() raises:
    var canonical = LogicalPlan.scan("a.parquet", SOURCE_PARQUET, _string_schema())
    var plan = _union(
        _two(
            LogicalPlan.distinct(None, canonical.copy()),
            LogicalPlan.distinct(None, _ref_to(canonical)),
        )
    )
    var inputs = LoweringInputs()
    inputs.add_scan(None, _keys("s"))
    var lp = _lowered(plan, inputs)
    assert_equal(len(lp.segments), 3)
    for seg in range(2):
        assert_equal(lp.segments[seg].source_kind, SEG_SOURCE_PARQUET)
        assert_equal(lp.segments[seg].sink_kind, SINK_AGG)
        assert_equal(lp.segments[seg].sink_key_dtype, KEY_DTYPE_STRING)
        assert_equal(lp.segments[seg].sink_orientation, SINK_ORIENT_DICT_ENCODED)
    _expect_concat(lp, 2, _ids(0, 1))


def test_a_projected_scan_and_a_union_of_scans_are_cut_again() raises:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("k"))
    exprs.append(Expr.col_ref("s"))
    var projected = LogicalPlan.project(exprs^, _scan())
    var lp = _lowered(
        _union(_two(projected.copy(), _ref_to(projected))), _inputs(1)
    )
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[1].source_kind, SEG_SOURCE_PARQUET)
    _expect_concat(lp, 2, _ids(0, 1))
    # A union of two scans, read again: each branch of each copy is a segment.
    var both = _union(_two(_scan("a.parquet"), _scan("b.parquet")))
    var lp2 = _lowered(_union(_two(both.copy(), _ref_to(both))), _inputs(2))
    # 0, 1: the branches. 2: their concatenation. 3, 4: the branches again
    # over the same two scans. 5: their concatenation. 6: 2 then 5.
    assert_equal(len(lp2.segments), 7)
    assert_equal(lp2.segments[3].source_spec.parquet_path, "a.parquet")
    assert_equal(lp2.segments[4].source_spec.parquet_path, "b.parquet")
    _expect_concat(lp2, 5, _ids(3, 4))
    _expect_concat(lp2, 6, _ids(2, 5))


def test_a_union_with_a_breaker_in_a_branch_is_cut_once() raises:
    var limited = LogicalPlan.limit(2, _scan("a.parquet"))
    var mixed = _union(_two(limited^, _scan("b.parquet")))
    var lp = _lowered(_union(_two(mixed.copy(), _ref_to(mixed))), _inputs(2))
    # 0: the limit. 1: the scan of b. 2: their concatenation, collected as the
    # shared segment. 3: 2 then 2.
    assert_equal(len(lp.segments), 4)
    assert_equal(lp.segments[2].sink_kind, SINK_COLLECT)
    _expect_concat(lp, 2, _ids(0, 1))
    _expect_concat(lp, 3, _ids(2, 2))


# =============================================================================
# Joins: the producer visits the right child first
# =============================================================================


def test_a_self_join_cuts_the_right_scan_and_recuts_it_on_the_left() raises:
    # The producer saw X JOIN X; it visits the right child first, so the right
    # X is the canonical subtree and the left one the reference.
    var x = LogicalPlan.filter(_k_gt(1), _scan())
    var plan = _inner_join(_ref_to(x), x.copy())
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(50)))
    var lp = _lowered(plan, inputs)
    assert_equal(len(lp.segments), 2)
    # 0: the right X builds. 1: the left X, cut again over the same scan,
    # probes it.
    assert_equal(lp.segments[0].source_kind, SEG_SOURCE_PARQUET)
    assert_equal(lp.segments[0].sink_kind, SINK_HASH_BUILD)
    assert_equal(lp.segments[0].card_estimate_rows, 50)
    assert_equal(lp.segments[1].source_kind, SEG_SOURCE_PARQUET)
    assert_equal(lp.segments[1].source_spec.parquet_path, "a.parquet")
    assert_equal(len(lp.segments[1].deps), 1)
    assert_equal(lp.segments[1].deps[0], 0)
    var probes = 0
    for i in range(len(lp.segments[1].ops)):
        if lp.segments[1].ops[i].tag == OP_JOIN_PROBE:
            probes += 1
    assert_equal(probes, 1)


def test_a_join_keeps_each_scans_facts_when_its_right_child_is_walked_first() raises:
    # Left: b.parquet (scan 0, 7 rows). Right: X UNION ALL ref(X) with X a
    # scan of a.parquet (scan 1, 50 rows).
    var x = _scan("a.parquet")
    var right = _union(_two(x.copy(), _ref_to(x)))
    var plan = _inner_join(_scan("b.parquet"), right^)
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(7)))
    inputs.add_scan(Optional[TableStats](_stats(50)))
    var lp = _lowered(plan, inputs)
    # 0, 1: X and its recut, each with scan 1's rows. 2: their concatenation,
    # which builds. 3: b.parquet with scan 0's facts, which probes.
    assert_equal(len(lp.segments), 4)
    for seg in range(2):
        assert_equal(lp.segments[seg].source_spec.parquet_path, "a.parquet")
        assert_equal(lp.segments[seg].card_estimate_rows, 50)
    _expect_concat(lp, 2, _ids(0, 1))
    assert_equal(lp.segments[2].sink_kind, SINK_HASH_BUILD)
    assert_equal(lp.segments[3].source_spec.parquet_path, "b.parquet")
    assert_equal(lp.segments[3].deps[0], 2)


def test_a_left_child_of_every_cut_kind_keeps_its_scans_facts() raises:
    # Left: a union of a filter, a projection, a limit, a sort and a distinct,
    # each over its own file (scans 0 to 4). Right: X UNION ALL ref(X) (scan
    # 5). The right child is walked first, from scan 5.
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("k"))
    exprs.append(Expr.col_ref("s"))
    var branches = List[LogicalPlan]()
    branches.append(LogicalPlan.filter(_k_gt(0), _scan("l0.parquet")))
    branches.append(LogicalPlan.project(exprs^, _scan("l1.parquet")))
    branches.append(LogicalPlan.limit(3, _scan("l2.parquet")))
    branches.append(_sorted(_scan("l3.parquet")))
    branches.append(LogicalPlan.distinct(None, _scan("l4.parquet")))
    var x = _scan("x.parquet")
    var plan = _inner_join(_union(branches^), _union(_two(x.copy(), _ref_to(x))))
    var inputs = LoweringInputs()
    var paths = List[String]()
    var rows = List[Int]()
    for i in range(5):
        paths.append("l" + String(i) + ".parquet")
        rows.append(i + 1)
        inputs.add_scan(Optional[TableStats](_stats(i + 1)))
    paths.append("x.parquet")
    rows.append(99)
    inputs.add_scan(Optional[TableStats](_stats(99)))
    var lp = _lowered(plan, inputs)
    _expect_parquet_cards(lp, paths, rows)


def test_a_left_child_with_an_aggregation_and_a_join_keeps_its_scans_facts() raises:
    # Left: count by k over l0 (scan 0) JOIN l1 (scan 1, columns j and t) on
    # k = j. Right: X UNION ALL ref(X) (scan 2). Both joins walk their right
    # child first.
    var sb = SchemaBuilder()
    sb.add_field(Field("j", ArrowType.INT64, False))
    sb.add_field(Field("t", ArrowType.STRING, False))
    var l1 = LogicalPlan.scan("l1.parquet", SOURCE_PARQUET, sb.build())
    var left = _join_on(_count_by(_scan("l0.parquet")), l1^, "k", "j")
    var x = _scan("x.parquet")
    var plan = _inner_join(left^, _union(_two(x.copy(), _ref_to(x))))
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(10)))
    inputs.add_scan(Optional[TableStats](_stats(20)))
    inputs.add_scan(Optional[TableStats](_stats(99)))
    var lp = _lowered(plan, inputs)
    var paths = List[String]()
    paths.append("l0.parquet")
    paths.append("l1.parquet")
    paths.append("x.parquet")
    var rows = List[Int]()
    rows.append(10)
    rows.append(20)
    rows.append(99)
    _expect_parquet_cards(lp, paths, rows)


def test_a_shared_join_is_cut_once() raises:
    # The producer saw J UNION ALL J with J = X JOIN Y; it keeps the first J
    # and folds the second.
    var j = _inner_join(_scan("a.parquet"), _scan("b.parquet"))
    var plan = _union(_two(j.copy(), _ref_to(j)))
    var lp = _lowered(plan, _inputs(2))
    # 0: b builds. 1: a probes, collected as the shared segment. 2: 1 twice.
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].sink_kind, SINK_HASH_BUILD)
    assert_equal(lp.segments[1].source_spec.parquet_path, "a.parquet")
    assert_equal(lp.segments[1].sink_kind, SINK_COLLECT)
    _expect_concat(lp, 2, _ids(1, 1))


# =============================================================================
# A window in a shared subplan
# =============================================================================


def test_a_window_read_twice_is_cut_once_and_a_keyed_window_is_a_sorted_input() raises:
    var canonical = _windowed(_scan())
    var plan = _union(_two(canonical.copy(), _ref_to(canonical)))
    var lp = _lowered(plan, _inputs(1))
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].sink_kind, SINK_PARTITION_BY)
    _expect_concat(lp, 1, _ids(0, 0))
    assert_equal(len(lp.params.window), 1)
    var text = render_lowered_plan(lp)
    assert_true("  source: SOURCE_CONCAT from=0,0\n" in text, text)
    assert_true("  deps: 0/E3 0/E3\n" in text, text)
    # The reader of a keyed window's output is a sorted input, as a sort's is.
    var limited = _union(
        _two(canonical.copy(), LogicalPlan.limit(2, _ref_to(canonical)))
    )
    _refused_with(
        _message(limited, _inputs(1)),
        LOWERING_UNCUTTABLE_NODE,
        "a limit over a sorted stream",
    )


def test_a_reference_below_a_window_is_found_and_read_over_e3() raises:
    # count by k over a (columns k, n), UNION ALL (k and n of ROW_NUMBER()
    # OVER (ORDER BY k) over a reference to that count).
    var canonical = _count_by(_scan())
    var kept = ExprArray()
    kept.append(Expr.col_ref("k"))
    kept.append(Expr.col_ref("n"))
    var plan = _union(
        _two(
            canonical.copy(),
            LogicalPlan.project(kept^, _windowed_by_k(_ref_to(canonical))),
        )
    )
    var lp = _lowered(plan, _inputs(1))
    # 0: the count. 1: the window sink over 0's output. 2: the projection
    # over 1's output, collected as the union's branch. 3: 0 and 2.
    assert_equal(len(lp.segments), 4)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    assert_equal(lp.segments[1].sink_kind, SINK_PARTITION_BY)
    _expect_reads(lp, 1, 0)
    assert_equal(lp.segments[2].sink_kind, SINK_COLLECT)
    _expect_reads(lp, 2, 1)
    _expect_concat(lp, 3, _ids(0, 2))


def test_a_left_child_that_is_a_window_keeps_its_scans_facts_beside_a_reference() raises:
    # Left: a window over l (scan 0). Right: X UNION ALL ref(X) (scan 1). The
    # right child is walked first, from scan 1, so the window's scan is
    # counted when the left child's scans are skipped.
    var x = _scan("x.parquet")
    var plan = _inner_join(
        _windowed(_scan("l.parquet")), _union(_two(x.copy(), _ref_to(x)))
    )
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(10)))
    inputs.add_scan(Optional[TableStats](_stats(99)))
    var lp = _lowered(plan, inputs)
    var paths = List[String]()
    paths.append("l.parquet")
    paths.append("x.parquet")
    var rows = List[Int]()
    rows.append(10)
    rows.append(99)
    _expect_parquet_cards(lp, paths, rows)
    var windows = 0
    for i in range(len(lp.segments)):
        if lp.segments[i].sink_kind == SINK_PARTITION_BY:
            windows += 1
            assert_equal(lp.segments[i].source_spec.parquet_path, "l.parquet")
    assert_equal(windows, 1)


def test_a_shared_subtree_that_holds_a_window_over_a_reference_is_found_by_its_unfolded_hash() raises:
    # The producer saw inner = count by k and W = ROW_NUMBER() OVER (ORDER BY
    # k) over inner UNION ALL inner, and the plan W UNION ALL W. It keeps the
    # first W, folds the second inner inside it and the second W, each
    # reference carrying the hash of the subtree as it stood before folding.
    var inner = _count_by(_scan())
    var seen = _windowed_by_k(_union(_two(inner.copy(), inner.copy())))
    var kept = _windowed_by_k(_union(_two(inner.copy(), _ref_to(inner))))
    var plan = _union(_two(kept^, _ref_to(seen)))
    var lp = _lowered(plan, _inputs(1))
    # 0: the count. 1: the two reads of it, concatenated into the window
    # sink. 2: the window's output twice.
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    _expect_concat(lp, 1, _ids(0, 0))
    assert_equal(lp.segments[1].sink_kind, SINK_PARTITION_BY)
    _expect_concat(lp, 2, _ids(1, 1))


# =============================================================================
# Refusals
# =============================================================================


def test_a_reference_with_no_canonical_subtree_is_refused() raises:
    var plan = _union(_two(_scan(), LogicalPlan.cse_ref(UInt64(7), _schema())))
    _refused_with(
        _message(plan, _inputs(1)),
        LOWERING_UNCUTTABLE_NODE,
        plan_tag_name(PLAN_CSE_REF)
        + " (a reference to shared subplan 7, which is not cut before it)",
    )


def test_a_reference_before_its_canonical_subtree_is_refused() raises:
    var canonical = _count_by(_scan())
    var plan = _union(_two(_ref_to(canonical), canonical.copy()))
    _refused_with(
        _message(plan, _inputs(1)),
        LOWERING_UNCUTTABLE_NODE,
        "which is not cut before it",
    )


def test_a_reference_of_another_layout_is_refused() raises:
    # The union compares its branches, so each reference stands under a count
    # by `s`, whose output is the same over either layout; the reference
    # itself is what differs from the shared subplan.
    var canonical = LogicalPlan.limit(3, _scan())
    var h = canonical.structural_hash()
    # One column, where the shared subplan has two.
    var narrow = LogicalPlan.cse_ref(h, _string_schema())
    var plan = _union(
        _two(_count_by(canonical.copy(), "s"), _count_by(narrow^, "s"))
    )
    _refused_with(
        _message(plan, _inputs(1)),
        LOWERING_UNCUTTABLE_NODE,
        "a reference to shared subplan "
        + String(h)
        + " that has 1 columns and the shared subplan 2",
    )
    # Two columns, the first of another type.
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT32, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    var retyped = LogicalPlan.cse_ref(h, sb.build())
    var plan2 = _union(
        _two(_count_by(canonical.copy(), "s"), _count_by(retyped^, "s"))
    )
    var m = _message(plan2, _inputs(1))
    _refused_with(m, LOWERING_UNCUTTABLE_NODE, "that column 1 is `k` ")
    assert_true("and the shared subplan's is `k` " in m, m)
    # A difference in nullability alone is not one.
    var nb = SchemaBuilder()
    nb.add_field(Field("k", ArrowType.INT64, True))
    nb.add_field(Field("s", ArrowType.STRING, True))
    var nullable = LogicalPlan.cse_ref(h, nb.build())
    var plan3 = _union(
        _two(_count_by(canonical.copy(), "s"), _count_by(nullable^, "s"))
    )
    assert_equal(_message(plan3, _inputs(1)), "")


def test_a_view_reference_is_refused_as_resolved_before_lowering() raises:
    _refused_with(
        _message(LogicalPlan.view_ref(String("v"), _schema()), _inputs(0)),
        LOWERING_UNCUTTABLE_NODE,
        plan_tag_name(PLAN_VIEW_REF)
        + " (a view reference; views are resolved before lowering)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
