# =============================================================================
# test_lower_series_scan: a generate_series / range scan lowered
# =============================================================================
#
# The scans here are built the way the SQL binder builds the leaf of a table
# function in FROM: a `komira.generate_series` binding behind a PLAN_SCAN.
# What each test proves:
#
#   * test_a_series_scan_is_one_segment_carrying_its_spec: the segment is
#     SOURCE_GENERATE_SERIES; its spec holds every field of the series; no
#     operator is added; the sink collects; the render names the kind and
#     every spec field.
#   * test_a_timestamp_series_keeps_its_calendar_step: a timestamp series with
#     a month step carries the step in months and the timestamp flag.
#   * test_two_series_that_differ_in_any_field_render_differently: changing
#     the inclusive flag, the stop or the column name changes the render.
#   * test_a_pushed_filter_and_projection_become_operators: the filter first,
#     then the projection, over the series' one column.
#   * test_a_limit_above_a_series_scan_fuses_into_its_segment: one segment,
#     the limit as its last operator.
#   * test_an_unbounded_series_scan_is_refused: LOWERING_SCAN_NOT_TOTAL.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweredPlan,
    LoweringInputs,
    LOWERING_SCAN_NOT_TOTAL,
)
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import (
    OP_FILTER,
    OP_LIMIT,
    OP_PROJECT,
    SINK_COLLECT,
    SOURCE_GENERATE_SERIES,
)
from plan_expr.expr import Expr, BIN_GT
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import LogicalPlan
from plan_ir.plan_decisions import SCAN_UNBOUNDED
from scan_source.series_scan import SeriesSpec, series_scan_binding
from scan_source.source_variant import SourceVariant


def _ints() -> SeriesSpec:
    return SeriesSpec(String("generate_series"), False, 1, 10, 3, 0, True)


def _series_scan(
    spec: SeriesSpec,
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) raises -> LogicalPlan:
    var source = SourceVariant.from_binding(
        series_scan_binding(spec, String("generate_series"))
    )
    var schema = source.schema()
    return LogicalPlan.scan_from_source(
        source^, schema^, projection^, filter^
    )


def _gt(v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT,
        Expr.col_ref("generate_series"),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _lowered(plan: LogicalPlan) raises -> LoweredPlan:
    var inputs = LoweringInputs()
    inputs.add_scan()
    return lower(plan, reference_host_profile("test-build"), inputs)


def _source_line(lp: LoweredPlan) -> String:
    for line in render_lowered_plan(lp).split("\n"):
        var text = String(line)
        if text.startswith("  source: "):
            return text^
    return String("")


def test_a_series_scan_is_one_segment_carrying_its_spec() raises:
    var lp = _lowered(_series_scan(_ints()))
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_GENERATE_SERIES)
    ref g = seg.source_spec.series_spec
    assert_equal(g.column, "generate_series")
    assert_equal(g.timestamp, False)
    assert_equal(g.start, 1)
    assert_equal(g.stop, 10)
    assert_equal(g.step, 3)
    assert_equal(g.step_months, 0)
    assert_equal(g.inclusive, True)
    assert_equal(len(seg.ops), 0)
    assert_equal(seg.sink_kind, SINK_COLLECT)
    assert_true(seg.morsel_rows > 0)
    assert_equal(
        _source_line(lp),
        "  source: SOURCE_GENERATE_SERIES column=generate_series"
        " timestamp=False start=1 stop=10 step=3 step_months=0 inclusive=True",
    )


def test_a_timestamp_series_keeps_its_calendar_step() raises:
    var spec = SeriesSpec(String("d"), True, 100, 900, 0, 1, False)
    var lp = _lowered(_series_scan(spec))
    ref g = lp.segments[0].source_spec.series_spec
    assert_equal(g.column, "d")
    assert_equal(g.timestamp, True)
    assert_equal(g.step, 0)
    assert_equal(g.step_months, 1)
    assert_equal(g.inclusive, False)
    assert_equal(
        _source_line(lp),
        "  source: SOURCE_GENERATE_SERIES column=d timestamp=True start=100"
        " stop=900 step=0 step_months=1 inclusive=False",
    )


def test_two_series_that_differ_in_any_field_render_differently() raises:
    var base = _source_line(_lowered(_series_scan(_ints())))
    var exclusive = SeriesSpec(String("generate_series"), False, 1, 10, 3, 0, False)
    var longer = SeriesSpec(String("generate_series"), False, 1, 11, 3, 0, True)
    var renamed = SeriesSpec(String("x"), False, 1, 10, 3, 0, True)
    assert_true(_source_line(_lowered(_series_scan(exclusive))) != base)
    assert_true(_source_line(_lowered(_series_scan(longer))) != base)
    assert_true(_source_line(_lowered(_series_scan(renamed))) != base)


def test_a_pushed_filter_and_projection_become_operators() raises:
    var cols = List[String]()
    cols.append(String("generate_series"))
    var lp = _lowered(_series_scan(_ints(), Optional(cols^), Optional(_gt(4))))
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_GENERATE_SERIES)
    assert_equal(len(seg.ops), 2)
    assert_equal(seg.ops[0].tag, OP_FILTER)
    assert_equal(String(seg.ops[0].filter_predicate.value()), String(_gt(4)))
    assert_equal(seg.ops[1].tag, OP_PROJECT)
    ref names = seg.ops[1].project_names.value()
    assert_equal(len(names), 1)
    assert_equal(names[0], "generate_series")


def test_a_limit_above_a_series_scan_fuses_into_its_segment() raises:
    var lp = _lowered(LogicalPlan.limit(5, _series_scan(_ints())))
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_GENERATE_SERIES)
    assert_equal(len(seg.ops), 1)
    assert_equal(seg.ops[0].tag, OP_LIMIT)
    assert_equal(seg.ops[0].limit_count, 5)


def test_an_unbounded_series_scan_is_refused() raises:
    var source = SourceVariant.from_binding(
        series_scan_binding(_ints(), String("generate_series"))
    )
    var schema = source.schema()
    var scan = LogicalPlan.scan_from_source(
        source^, schema^, boundedness=SCAN_UNBOUNDED
    )
    var message = String("")
    try:
        _ = _lowered(scan)
    except e:
        message = String(e)
    assert_true(
        message.startswith(String(LOWERING_SCAN_NOT_TOTAL) + ": "), message
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
