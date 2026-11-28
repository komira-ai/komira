# =============================================================================
# test_lower_asof: the as-of join lowered, its render, its refusals, and the
# shared-subplan walk through it
# =============================================================================
#
# Each test lowers a PLAN_ASOF_JOIN under the constant reference host profile.
# The right child ends in a SINK_COLLECT segment, the left child in a
# SINK_ASOF_JOIN segment that names the next `asof` row of the ParamTable and
# depends on the right segment over an E3 edge; the row names that segment.
#
#   test_a_keyed_backward_join_renders_two_segments_and_its_param_row
#   test_a_node_under_an_aggregation_is_read_over_e3
#   test_the_param_row_names_the_direction_type_tolerance_and_sorted_sides
#     (forward, nearest; INT32, FLOAT64 and TIMESTAMP ASOF columns; INT64 and
#     FLOAT64 tolerances; no key; sides the plan calls sorted)
#   test_each_childs_scans_keep_their_facts
#   test_a_string_key_against_a_dictionary_key_lowers
#   test_the_node_itself_is_refused_before_its_children (each refusal:
#     strategy, key counts, a missing key or ASOF column on either side, key
#     pairs the walker does not compare, ASOF column types, a tolerance of the
#     other family, an output naming one column twice)
#   test_a_self_asof_join_cuts_the_right_scan_and_recuts_it_on_the_left
#   test_a_reference_under_an_asof_join_in_a_union_is_found
#   test_an_asof_join_left_of_a_join_keeps_its_scans_facts_in_a_shared_plan
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import HostProfile, reference_host_profile
from host_profile.morsel_sizing_policy import MorselSizingPolicy
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweredPlan,
    LoweringInputs,
    LOWERING_ASOF_UNSERVED,
)
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    PHYSICAL_PLAN_IR_VERSION,
    SINK_AGG,
    SINK_ASOF_JOIN,
    SINK_COLLECT,
    SINK_HASH_BUILD,
    SOURCE_PARQUET as SEG_SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr, BIN_GT
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
    AggExprArray,
    AsofTolerance,
    ExprArray,
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_INNER,
    LogicalPlan,
    SOURCE_PARQUET,
)
from plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema2(
    a: String, at: ArrowType, b: String, bt: ArrowType
) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, at, False))
    sb.add_field(Field(b, bt, False))
    return sb.build()


def _trades(ts: ArrowType = ArrowType.INT64) -> LogicalPlan:
    return LogicalPlan.scan(
        "t.parquet", SOURCE_PARQUET, _schema2("sym", ArrowType.STRING, "ts", ts)
    )


def _quotes(ts: ArrowType = ArrowType.INT64) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("sym", ArrowType.STRING, False))
    sb.add_field(Field("ts", ts, False))
    sb.add_field(Field("px", ArrowType.INT64, False))
    return LogicalPlan.scan("q.parquet", SOURCE_PARQUET, sb.build())


def _names(a: String = "", b: String = "") -> List[String]:
    var out = List[String]()
    if a != "":
        out.append(a)
    if b != "":
        out.append(b)
    return out^


def _asof(
    var left: LogicalPlan,
    var right: LogicalPlan,
    var lkeys: List[String],
    var rkeys: List[String],
    on: String = "ts",
    strategy: UInt8 = ASOF_BACKWARD,
    tolerance: AsofTolerance = AsofTolerance.none(),
) -> LogicalPlan:
    return LogicalPlan.asof_join(
        left^, right^, lkeys^, rkeys^, on, on, strategy, tolerance
    )


def _by_sym(var left: LogicalPlan, var right: LogicalPlan) -> LogicalPlan:
    return _asof(left^, right^, _names("sym"), _names("sym"))


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows, List[String](), List[ColumnStats](), STATS_SOURCE_PARQUET_METADATA
    )


def _inputs(a: Int, b: Int, c: Int = -1) -> LoweringInputs:
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(a)))
    inputs.add_scan(Optional[TableStats](_stats(b)))
    if c >= 0:
        inputs.add_scan(Optional[TableStats](_stats(c)))
    return inputs^


def _host() raises -> HostProfile:
    return reference_host_profile("test-build")


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, _host(), inputs)


def _policy() raises -> MorselSizingPolicy:
    return MorselSizingPolicy.for_host(_host())


def _segment(
    seg_id: Int,
    source: String,
    sink: String,
    param: Int,
    deps: String,
    morsel_rows: Int,
    card_rows: Int,
) -> String:
    var out = String("segment ") + String(seg_id) + "\n"
    out += "  source: " + source + "\n"
    out += "  sink: " + sink + " param=" + String(param) + " state=" + String(seg_id) + "\n"
    out += "  deps: " + deps + "\n"
    out += "  order: ORDER_NONE partitions=1\n"
    out += "  estimates: morsel_rows=" + String(morsel_rows) + " card_rows=" + String(card_rows) + " mem_bytes=0\n"
    return out^


comptime _ASOF = "(SINK_ASOF_JOIN, NONE, COLUMNAR)"
comptime _COLLECT = "(SINK_COLLECT, NONE, COLUMNAR)"
comptime _NO_PARAMS = "params: agg=0 sort=0 topn=0 window=0 batches=0\n"


def _param_line(plan: LogicalPlan, inputs: LoweringInputs) raises -> String:
    """The `asof` lines of the render of `plan`."""
    var out = String("")
    for line in render_lowered_plan(_lowered(plan, inputs)).split("\n"):
        if String(line).startswith("  asof "):
            out += String(line) + "\n"
    return out^


def _message(plan: LogicalPlan, inputs: LoweringInputs) raises -> String:
    """The refusal text, or an empty string when the plan lowers."""
    try:
        _ = _lowered(plan, inputs)
    except e:
        return String(e)
    return String("")


def _refused(plan: LogicalPlan, why: String) raises:
    var m = _message(plan, _inputs(1, 1))
    assert_true(
        m.startswith(String(LOWERING_ASOF_UNSERVED) + ": AsofJoin ("),
        "no token: " + m,
    )
    assert_true(why in m, "does not say " + why + ": " + m)
    assert_true(m.endswith(") is not served by the as-of join"), m)


# =============================================================================
# The two segments and the param row
# =============================================================================


def test_a_keyed_backward_join_renders_two_segments_and_its_param_row() raises:
    var plan = _by_sym(_trades(), _quotes())
    var segments = _segment(
        0, "SOURCE_PARQUET path=q.parquet total=True", _COLLECT, -1, "none",
        _policy().bulk_scan_morsel_rows(_quotes().output_schema), 222,
    )
    segments += _segment(
        1, "SOURCE_PARQUET path=t.parquet total=True", _ASOF, 0, "0/E3",
        _policy().default_morsel_rows(_trades().output_schema), 111,
    )
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += segments + _NO_PARAMS
    expected += "  asof 0: keys=[sym=sym] on=ts~ts strategy=backward"
    expected += " dtype=int64 tolerance=none right_seg=0\n"
    expected += "result: segment 1\n"
    var lp = _lowered(plan, _inputs(111, 222))
    assert_equal(render_lowered_plan(lp), expected)
    # The row carries the node's columns: the right ones renamed and nullable.
    ref row = lp.params.asof[0]
    assert_equal(row.output_schema.num_columns(), 5)
    assert_equal(row.output_schema.field_name(2), "sym_right")
    assert_equal(row.output_schema.field_name(4), "px")
    assert_true(row.output_schema.field_nullable(4), "right columns are nullable")
    assert_equal(lp.segments[1].edge_tags[0], EDGE_E3_PUBLISH_WAIT)


def test_a_node_under_an_aggregation_is_read_over_e3() raises:
    var group_by = ExprArray()
    group_by.append(Expr.col_ref("sym"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var plan = LogicalPlan.aggregate(
        group_by^, aggs^, _by_sym(_trades(), _quotes())
    )
    var lp = _lowered(plan, _inputs(1, 2))
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].sink_kind, SINK_COLLECT)
    assert_equal(lp.segments[1].sink_kind, SINK_ASOF_JOIN)
    assert_equal(lp.segments[2].source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(lp.segments[2].source_spec.dep_seg_ids[0], 1)
    assert_equal(lp.segments[2].deps[0], 1)
    assert_equal(lp.segments[2].sink_kind, SINK_AGG)
    assert_equal(lp.result_seg_id, 2)


def test_the_param_row_names_the_direction_type_tolerance_and_sorted_sides() raises:
    assert_equal(
        _param_line(
            _asof(_trades(), _quotes(), _names(), _names(), "ts", ASOF_FORWARD),
            _inputs(1, 1),
        ),
        "  asof 0: keys=[] on=ts~ts strategy=forward dtype=int64"
        " tolerance=none right_seg=0\n",
    )
    assert_equal(
        _param_line(
            _asof(
                _trades(ArrowType.INT32), _quotes(ArrowType.INT32),
                _names("sym"), _names("sym"), "ts", ASOF_NEAREST,
                AsofTolerance.int64(5),
            ),
            _inputs(1, 1),
        ),
        "  asof 0: keys=[sym=sym] on=ts~ts strategy=nearest dtype=int32"
        " tolerance=5 right_seg=0\n",
    )
    assert_equal(
        _param_line(
            _asof(
                _trades(ArrowType.FLOAT64), _quotes(ArrowType.FLOAT64),
                _names("sym"), _names("sym"), "ts", ASOF_BACKWARD,
                AsofTolerance.float64(0.5),
            ),
            _inputs(1, 1),
        ),
        "  asof 0: keys=[sym=sym] on=ts~ts strategy=backward dtype=float64"
        " tolerance=0.5 right_seg=0\n",
    )
    assert_equal(
        _param_line(
            _by_sym(_trades(ArrowType.TIMESTAMP_US), _quotes(ArrowType.TIMESTAMP_US)),
            _inputs(1, 1),
        ),
        "  asof 0: keys=[sym=sym] on=ts~ts strategy=backward dtype=int64"
        " tolerance=none right_seg=0\n",
    )
    var sorted_both = LogicalPlan.asof_join(
        _trades(), _quotes(), _names("sym"), _names("sym"), "ts", "ts",
        ASOF_BACKWARD, AsofTolerance.none(),
        _names("sym", "ts"), [False, False], _names("sym", "ts"), [False, False],
    )
    assert_equal(
        _param_line(sorted_both, _inputs(1, 1)),
        "  asof 0: keys=[sym=sym] on=ts~ts strategy=backward dtype=int64"
        " tolerance=none left_sorted right_sorted right_seg=0\n",
    )
    var sorted_right = LogicalPlan.asof_join(
        _trades(), _quotes(), _names("sym"), _names("sym"), "ts", "ts",
        ASOF_BACKWARD, AsofTolerance.none(),
        List[String](), List[Bool](), _names("sym", "ts"), [False, False],
    )
    assert_equal(
        _param_line(sorted_right, _inputs(1, 1)),
        "  asof 0: keys=[sym=sym] on=ts~ts strategy=backward dtype=int64"
        " tolerance=none right_sorted right_seg=0\n",
    )


def test_each_childs_scans_keep_their_facts() raises:
    # Scan 0 is the left child's, scan 1 the right child's: the right segment
    # estimates 70 rows; the ASOF segment its left scan's 30, one row per left
    # row.
    var lp = _lowered(_by_sym(_trades(), _quotes()), _inputs(30, 70))
    assert_equal(lp.segments[0].source_spec.parquet_path, "q.parquet")
    assert_equal(lp.segments[0].card_estimate_rows, 70)
    assert_equal(lp.segments[1].source_spec.parquet_path, "t.parquet")
    assert_equal(lp.segments[1].card_estimate_rows, 30)


def test_a_string_key_against_a_dictionary_key_lowers() raises:
    var dict_quotes = LogicalPlan.scan(
        "q.parquet", SOURCE_PARQUET,
        _schema2("sym", ArrowType.DICTIONARY, "ts", ArrowType.INT64),
    )
    var lp = _lowered(_by_sym(_trades(), dict_quotes^), _inputs(1, 1))
    assert_equal(lp.segments[1].sink_kind, SINK_ASOF_JOIN)


# =============================================================================
# Refusals of the node itself
# =============================================================================


def test_the_node_itself_is_refused_before_its_children() raises:
    _refused(
        _asof(_trades(), _quotes(), _names("sym"), _names("sym"), "ts", UInt8(7)),
        "strategy 7",
    )
    _refused(
        _asof(_trades(), _quotes(), _names("sym"), _names()),
        "1 left keys and 0 right keys",
    )
    _refused(
        _asof(_trades(), _quotes(), _names("nope"), _names("sym")),
        "left key column 'nope' is not a column of its side",
    )
    _refused(
        _asof(_trades(), _quotes(), _names("sym"), _names("nope")),
        "right key column 'nope' is not a column of its side",
    )
    _refused(
        LogicalPlan.asof_join(
            _trades(), _quotes(), _names(), _names(), "nope", "ts",
            ASOF_BACKWARD, AsofTolerance.none(),
        ),
        "left ASOF column 'nope'",
    )
    _refused(
        LogicalPlan.asof_join(
            _trades(), _quotes(), _names(), _names(), "ts", "nope",
            ASOF_BACKWARD, AsofTolerance.none(),
        ),
        "right ASOF column 'nope'",
    )
    # Keys: INT64 with INT32, STRING with INT64, and a type the walker does
    # not compare at all.
    _refused(
        _asof(
            LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema2("k", ArrowType.INT64, "ts", ArrowType.INT64)),
            LogicalPlan.scan("q.parquet", SOURCE_PARQUET, _schema2("k", ArrowType.INT32, "ts", ArrowType.INT64)),
            _names("k"), _names("k"),
        ),
        "key 0 compares int64 with int32",
    )
    _refused(
        _asof(_trades(), _quotes(), _names("sym"), _names("px")),
        "key 0 compares string with int64",
    )
    _refused(
        _asof(
            LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema2("d", ArrowType.DATE32, "ts", ArrowType.INT64)),
            LogicalPlan.scan("q.parquet", SOURCE_PARQUET, _schema2("d", ArrowType.DATE32, "ts", ArrowType.INT64)),
            _names("d"), _names("d"),
        ),
        "key 0 compares date32 with date32",
    )
    # ASOF columns: of two types, and of a type neither the walker nor the
    # sort takes.
    _refused(
        _by_sym(_trades(ArrowType.INT64), _quotes(ArrowType.INT32)),
        "the ASOF columns are int64 and int32",
    )
    _refused(
        _by_sym(_trades(ArrowType.STRING), _quotes(ArrowType.STRING)),
        "the ASOF columns are string and string",
    )
    # A tolerance of the other family.
    _refused(
        _asof(
            _trades(ArrowType.FLOAT64), _quotes(ArrowType.FLOAT64),
            _names("sym"), _names("sym"), "ts", ASOF_BACKWARD,
            AsofTolerance.int64(1),
        ),
        "a tolerance of the other family than its float64 ASOF column",
    )
    _refused(
        _asof(
            _trades(), _quotes(), _names("sym"), _names("sym"), "ts",
            ASOF_BACKWARD, AsofTolerance.float64(1.0),
        ),
        "a tolerance of the other family than its int64 ASOF column",
    )
    # A left column `px_right` beside a right `px`: the node names px_right
    # twice.
    var sb = SchemaBuilder()
    sb.add_field(Field("sym", ArrowType.STRING, False))
    sb.add_field(Field("ts", ArrowType.INT64, False))
    sb.add_field(Field("px", ArrowType.INT64, False))
    sb.add_field(Field("px_right", ArrowType.INT64, False))
    var wide = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())
    _refused(_by_sym(wide^, _quotes()), "names the column 'px_right' twice")


# =============================================================================
# Shared subplans
# =============================================================================


def _ref_to(canonical: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.cse_ref(
        canonical.structural_hash(), canonical.output_schema.copy()
    )


def _ts_gt(v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("ts"), Expr.literal(ScalarValue.from_int64(v))
    )


def test_a_self_asof_join_cuts_the_right_scan_and_recuts_it_on_the_left() raises:
    # The producer saw X ASOF JOIN X and visited the right child first, so
    # the right X is the canonical subtree and the left one the reference.
    var x = LogicalPlan.filter(_ts_gt(1), _trades())
    var plan = _by_sym(_ref_to(x), x.copy())
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(50)))
    var lp = _lowered(plan, inputs)
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].source_kind, SEG_SOURCE_PARQUET)
    assert_equal(lp.segments[0].sink_kind, SINK_COLLECT)
    assert_equal(lp.segments[0].card_estimate_rows, 50)
    assert_equal(lp.segments[1].source_kind, SEG_SOURCE_PARQUET)
    assert_equal(lp.segments[1].source_spec.parquet_path, "t.parquet")
    assert_equal(lp.segments[1].sink_kind, SINK_ASOF_JOIN)
    assert_equal(lp.segments[1].deps[0], 0)
    assert_equal(lp.params.asof[0].right_seg_id, 0)


def _union2(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(a^))
    children.append(OwnedPointer(b^))
    return LogicalPlan.union(children^, schema^)


def test_a_reference_under_an_asof_join_in_a_union_is_found() raises:
    # Branch 1 is an as-of join of t with X (a scan of q); branch 2 the same
    # join over a reference to X. The reference under the as-of join is
    # found, and X, cut again at it, reads scan 1's facts.
    var x = _quotes()
    var first = _by_sym(_trades(), x.copy())
    var second = _by_sym(LogicalPlan.scan("u.parquet", SOURCE_PARQUET, _trades().output_schema.copy()), _ref_to(x))
    var plan = _union2(first^, second^)
    var lp = _lowered(plan, _inputs(10, 20, 30))
    var seen_q = 0
    for s in range(len(lp.segments)):
        ref seg = lp.segments[s]
        if seg.source_kind == SEG_SOURCE_PARQUET and seg.source_spec.parquet_path == "q.parquet":
            seen_q += 1
            assert_equal(seg.card_estimate_rows, 20)
    assert_equal(seen_q, 2)
    assert_equal(len(lp.params.asof), 2)


def test_an_asof_join_left_of_a_join_keeps_its_scans_facts_in_a_shared_plan() raises:
    # Left of the join: t ASOF JOIN q (scans 0 and 1). Right: X UNION ALL
    # ref(X), X a scan of x.parquet (scan 2). The join's right child is walked
    # first, from scan 2, past the as-of join's two scans.
    var x = LogicalPlan.scan(
        "x.parquet", SOURCE_PARQUET, _schema2("xs", ArrowType.STRING, "n", ArrowType.INT64)
    )
    var right = _union2(x.copy(), _ref_to(x))
    var plan = LogicalPlan.join(
        _by_sym(_trades(), _quotes()), right^, _names("sym"), _names("xs"),
        JOIN_INNER, JOIN_ALGO_AUTO, None, JOIN_BUILD_SIDE_RIGHT,
    )
    var lp = _lowered(plan, _inputs(10, 20, 30))
    for s in range(len(lp.segments)):
        ref seg = lp.segments[s]
        if seg.source_kind != SEG_SOURCE_PARQUET:
            continue
        var p = seg.source_spec.parquet_path
        if p == "x.parquet":
            assert_equal(seg.card_estimate_rows, 30)
        elif p == "q.parquet":
            assert_equal(seg.card_estimate_rows, 20)
    var builds = 0
    for s in range(len(lp.segments)):
        if lp.segments[s].sink_kind == SINK_HASH_BUILD:
            builds += 1
    assert_equal(builds, 1)
    assert_equal(len(lp.params.asof), 1)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_keyed_backward_join_renders_two_segments_and_its_param_row]()
    suite.test[test_a_node_under_an_aggregation_is_read_over_e3]()
    suite.test[test_the_param_row_names_the_direction_type_tolerance_and_sorted_sides]()
    suite.test[test_each_childs_scans_keep_their_facts]()
    suite.test[test_a_string_key_against_a_dictionary_key_lowers]()
    suite.test[test_the_node_itself_is_refused_before_its_children]()
    suite.test[test_a_self_asof_join_cuts_the_right_scan_and_recuts_it_on_the_left]()
    suite.test[test_a_reference_under_an_asof_join_in_a_union_is_found]()
    suite.test[test_an_asof_join_left_of_a_join_keeps_its_scans_facts_in_a_shared_plan]()
    suite^.run()
