# =============================================================================
# test_lower_window_refusals: the window nodes lowering refuses, by exact text,
# and the neighbouring windows it cuts
# =============================================================================
#
# Every refusal is LOWERING_WINDOW_UNSERVED followed by the reason, compared
# whole. The refusal is raised before the node's child is walked, and in a
# fixed order: the descending list, then the keys, then each function in the
# node's order. Windows that differ from a refused one only in the refused
# detail lower.
#
#   test_a_descending_list_of_the_wrong_length_is_refused
#   test_a_key_that_is_not_a_column_is_refused_for_each_clause
#   test_a_key_of_a_type_the_window_sort_does_not_order_is_refused
#   test_keys_of_the_types_the_window_sort_orders_are_cut
#   test_an_ntile_or_nth_value_count_below_one_is_refused_and_one_is_cut
#   test_an_argument_type_the_sink_does_not_compute_over_is_refused
#   test_an_argument_that_is_not_a_column_is_refused
#   test_a_lag_or_lead_default_the_column_would_change_is_refused
#   test_a_lag_or_lead_default_the_column_holds_is_cut
#   test_a_frame_other_than_the_two_served_is_refused_for_each_function_that_reads_it
#   test_the_whole_partition_frame_is_cut_in_rows_and_in_range_units
#   test_a_function_tag_the_sink_does_not_compute_is_refused_by_name
#   test_count_star_and_a_count_of_any_type_are_cut
#   test_the_refusal_comes_before_the_child_is_walked
#   test_the_checks_run_in_a_fixed_order
# =============================================================================

from std.testing import TestSuite, assert_equal

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_UNCUTTABLE_NODE,
    LOWERING_WINDOW_UNSERVED,
)
from plan_expr.partition_expr import (
    PartitionExpr,
    PartitionFrame,
    FRAME_UNITS_ROWS,
    FRAME_UNITS_RANGE,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    PF_SUM,
    PF_ROW_NUMBER,
)
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET, PLAN_TOPN, plan_tag_name


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("g", ArrowType.STRING, False))
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("i32", ArrowType.INT32, False))
    sb.add_field(Field("b", ArrowType.BOOL, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    sb.add_field(Field("v", ArrowType.INT64, True))
    sb.add_field(Field("d", ArrowType.DATE32, False))
    sb.add_field(Field.decimal128("dec", 18, 4, False))
    sb.add_field(Field("f32", ArrowType.FLOAT32, False))
    sb.add_field(Field("i16", ArrowType.INT16, False))
    return sb.build()


def _scan() raises -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())


def _names(a: String = "", b: String = "") -> List[String]:
    var out = List[String]()
    if a != "":
        out.append(a)
    if b != "":
        out.append(b)
    return out^


def _flags(count: Int) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(count):
        out.append(False)
    return out^


def _one(var expr: PartitionExpr) -> List[PartitionExpr]:
    var out = List[PartitionExpr]()
    out.append(expr^)
    return out^


def _window(
    partition: List[String],
    order: List[String],
    var exprs: List[PartitionExpr],
    var child: LogicalPlan,
) raises -> LogicalPlan:
    return LogicalPlan.partition_by(
        partition.copy(), order.copy(), _flags(len(order)), exprs^, child^
    )


def _over(var expr: PartitionExpr) raises -> LogicalPlan:
    """A window over a scan, partitioned by `g` and ordered by `k`."""
    return _window(_names("g"), _names("k"), _one(expr^), _scan())


def _message(plan: LogicalPlan) raises -> String:
    """The refusal text, or an empty string when the plan lowers."""
    var inputs = LoweringInputs()
    inputs.add_scan()
    try:
        _ = lower(plan, reference_host_profile("test-build"), inputs)
    except e:
        return String(e)
    return String("")


def _unserved(reason: String) -> String:
    return String(LOWERING_WINDOW_UNSERVED) + ": " + reason


def _range_running() -> PartitionFrame:
    return PartitionFrame.running_range()


def test_a_descending_list_of_the_wrong_length_is_refused() raises:
    var plan = LogicalPlan.partition_by(
        _names("g"), _names("k"), List[Bool](), _one(PartitionExpr.row_number()), _scan()
    )
    assert_equal(_message(plan), _unserved("the node has 1 order keys and 0 descending flags"))
    var two = _flags(2)
    var extra = LogicalPlan.partition_by(
        _names("g"), _names("k"), two^, _one(PartitionExpr.row_number()), _scan()
    )
    assert_equal(_message(extra), _unserved("the node has 1 order keys and 2 descending flags"))
    assert_equal(_message(_over(PartitionExpr.row_number())), "")


def test_a_key_that_is_not_a_column_is_refused_for_each_clause() raises:
    var partition = _over(PartitionExpr.row_number())
    partition._partition_by.value()[].partition_keys[0] = "nope"
    assert_equal(
        _message(partition),
        _unserved("the PARTITION BY key 'nope' is not a column of the input"),
    )
    var order = _over(PartitionExpr.row_number())
    order._partition_by.value()[].order_keys[0] = "gone"
    assert_equal(
        _message(order),
        _unserved("the ORDER BY key 'gone' is not a column of the input"),
    )


def test_a_key_of_a_type_the_window_sort_does_not_order_is_refused() raises:
    var tail = ", which the window's sort does not order"
    var date = _window(_names("d"), _names(), _one(PartitionExpr.row_number()), _scan())
    assert_equal(_message(date), _unserved("the PARTITION BY key 'd' has type date32" + tail))
    var decimal = _window(_names("g"), _names("dec"), _one(PartitionExpr.row_number()), _scan())
    assert_equal(_message(decimal), _unserved("the ORDER BY key 'dec' has type decimal128" + tail))
    var single = _window(_names("f32"), _names(), _one(PartitionExpr.row_number()), _scan())
    assert_equal(_message(single), _unserved("the PARTITION BY key 'f32' has type float32" + tail))
    var narrow = _window(_names(), _names("i16"), _one(PartitionExpr.row_number()), _scan())
    assert_equal(_message(narrow), _unserved("the ORDER BY key 'i16' has type int16" + tail))
    var second = _window(_names("g", "d"), _names(), _one(PartitionExpr.row_number()), _scan())
    assert_equal(_message(second), _unserved("the PARTITION BY key 'd' has type date32" + tail))


def test_keys_of_the_types_the_window_sort_orders_are_cut() raises:
    assert_equal(_message(_window(_names("i32"), _names("k"), _one(PartitionExpr.row_number()), _scan())), "")
    assert_equal(_message(_window(_names("b"), _names("i32"), _one(PartitionExpr.row_number()), _scan())), "")
    assert_equal(_message(_window(_names("g"), _names("b"), _one(PartitionExpr.row_number()), _scan())), "")
    assert_equal(_message(_window(_names("k", "f"), _names("g"), _one(PartitionExpr.row_number()), _scan())), "")
    assert_equal(_message(_window(_names(), _names(), _one(PartitionExpr.row_number()), _scan())), "")


def test_an_ntile_or_nth_value_count_below_one_is_refused_and_one_is_cut() raises:
    assert_equal(
        _message(_over(PartitionExpr.ntile(0))),
        _unserved("NTILE has the bucket count 0; a count above 0 is required"),
    )
    assert_equal(
        _message(_over(PartitionExpr.ntile(-2))),
        _unserved("NTILE has the bucket count -2; a count above 0 is required"),
    )
    assert_equal(
        _message(_over(PartitionExpr.nth_value("v", 0))),
        _unserved("NTH_VALUE has n = 0; an n above 0 is required"),
    )
    assert_equal(_message(_over(PartitionExpr.ntile(1))), "")
    assert_equal(_message(_over(PartitionExpr.nth_value("v", 1))), "")


def test_an_argument_type_the_sink_does_not_compute_over_is_refused() raises:
    var tail = ", which the window sink does not compute over"
    assert_equal(
        _message(_over(PartitionExpr.lag("d"))),
        _unserved("LAG(d) has an argument of type date32" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.lead("b"))),
        _unserved("LEAD(b) has an argument of type bool" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.first_value("i32"))),
        _unserved("FIRST_VALUE(i32) has an argument of type int32" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.last_value("dec"))),
        _unserved("LAST_VALUE(dec) has an argument of type decimal128" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.nth_value("f32", 2))),
        _unserved("NTH_VALUE(f32) has an argument of type float32" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_sum("g").with_frame(_range_running()))),
        _unserved("SUM(g) has an argument of type string" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_avg("i32").with_frame(_range_running()))),
        _unserved("AVG(i32) has an argument of type int32" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_min("g").with_frame(_range_running()))),
        _unserved("MIN(g) has an argument of type string" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_max("d").with_frame(_range_running()))),
        _unserved("MAX(d) has an argument of type date32" + tail),
    )
    assert_equal(_message(_over(PartitionExpr.lag("g"))), "")
    assert_equal(_message(_over(PartitionExpr.lead("f"))), "")
    assert_equal(_message(_over(PartitionExpr.first_value("g"))), "")
    assert_equal(_message(_over(PartitionExpr.running_sum("k").with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.running_max("f").with_frame(_range_running()))), "")


def test_an_argument_that_is_not_a_column_is_refused() raises:
    var tail = ", which is not a column of the input"
    var lag = _over(PartitionExpr.lag("k"))
    lag._partition_by.value()[].partition_exprs[0].column = "nope"
    assert_equal(_message(lag), _unserved("LAG(nope) names the column 'nope'" + tail))
    var total = _over(PartitionExpr.running_sum("k").with_frame(_range_running()))
    total._partition_by.value()[].partition_exprs[0].column = "gone"
    assert_equal(_message(total), _unserved("SUM(gone) names the column 'gone'" + tail))
    var count = _over(PartitionExpr.running_count("k").with_frame(_range_running()))
    count._partition_by.value()[].partition_exprs[0].column = "gone"
    assert_equal(_message(count), _unserved("COUNT(gone) names the column 'gone'" + tail))


def test_a_lag_or_lead_default_the_column_would_change_is_refused() raises:
    var tail = " cannot hold unchanged"
    assert_equal(
        _message(_over(PartitionExpr.lag_default("k", 1, ScalarValue.from_float(1.5)))),
        _unserved("LAG(k) has a default that the int64 column" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.lead_default("k", 1, ScalarValue.from_string("a")))),
        _unserved("LEAD(k) has a default that the int64 column" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.lead_default("f", 1, ScalarValue.date32(Int32(20000))))),
        _unserved("LEAD(f) has a default that the float64 column" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.lag_default("g", 1, ScalarValue.from_int(0)))),
        _unserved("LAG(g) has a default that the string column" + tail),
    )


def test_a_lag_or_lead_default_the_column_holds_is_cut() raises:
    assert_equal(_message(_over(PartitionExpr.lag_default("k", 1, ScalarValue.from_int(0)))), "")
    assert_equal(_message(_over(PartitionExpr.lag_default("f", 1, ScalarValue.from_int(0)))), "")
    assert_equal(_message(_over(PartitionExpr.lead_default("f", 2, ScalarValue.from_float(0.5)))), "")
    assert_equal(_message(_over(PartitionExpr.lead_default("g", 1, ScalarValue.from_string("")))), "")
    # A NULL default is no default: it answers the edge row as no default does.
    assert_equal(_message(_over(PartitionExpr.lag_default("k", 1, ScalarValue.null(DType.int64)))), "")


def _frame(units: UInt8, start: UInt8, start_offset: Int64, end: UInt8, end_offset: Int64) -> PartitionFrame:
    return PartitionFrame(units, start, start_offset, end, end_offset)


def test_a_frame_other_than_the_two_served_is_refused_for_each_function_that_reads_it() raises:
    var tail = "; only RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW and the whole partition are served"
    var rows_running = PartitionFrame.default_ordered()
    assert_equal(
        _message(_over(PartitionExpr.running_sum("k"))),
        _unserved("SUM(k) has the frame ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_avg("f").with_frame(rows_running.copy()))),
        _unserved("AVG(f) has the frame ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_min("k").with_frame(
            _frame(FRAME_UNITS_ROWS, FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0)))),
        _unserved("MIN(k) has the frame ROWS BETWEEN 1 PRECEDING AND CURRENT ROW" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_max("k").with_frame(
            _frame(FRAME_UNITS_RANGE, FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_FOLLOWING, 2)))),
        _unserved("MAX(k) has the frame RANGE BETWEEN UNBOUNDED PRECEDING AND 2 FOLLOWING" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_count("k").with_frame(
            _frame(FRAME_UNITS_ROWS, FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0)))),
        _unserved("COUNT(k) has the frame ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.first_value("k").with_frame(rows_running.copy()))),
        _unserved("FIRST_VALUE(k) has the frame ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.last_value("k").with_frame(rows_running.copy()))),
        _unserved("LAST_VALUE(k) has the frame ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.nth_value("k", 2).with_frame(rows_running.copy()))),
        _unserved("NTH_VALUE(k) has the frame ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" + tail),
    )
    # The default frame of an ordered window is served, and ranking and
    # offset functions ignore the frame.
    assert_equal(_message(_over(PartitionExpr.running_sum("k").with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.first_value("k"))), "")
    assert_equal(_message(_over(PartitionExpr.row_number().with_frame(rows_running.copy()))), "")
    assert_equal(_message(_over(PartitionExpr.lag("k").with_frame(
        _frame(FRAME_UNITS_ROWS, FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0)))), "")


def test_the_whole_partition_frame_is_cut_in_rows_and_in_range_units() raises:
    var rows = PartitionFrame.default_unordered()
    var range = _frame(
        FRAME_UNITS_RANGE, FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0
    )
    assert_equal(_message(_over(PartitionExpr.running_sum("k").with_frame(rows.copy()))), "")
    assert_equal(_message(_over(PartitionExpr.running_sum("k").with_frame(range.copy()))), "")
    assert_equal(_message(_over(PartitionExpr.last_value("g").with_frame(rows.copy()))), "")
    assert_equal(_message(_over(PartitionExpr.last_value("g").with_frame(range.copy()))), "")
    assert_equal(_message(_over(PartitionExpr.running_count().with_frame(range.copy()))), "")


def test_a_function_tag_the_sink_does_not_compute_is_refused_by_name() raises:
    var plan = _over(PartitionExpr.row_number())
    plan._partition_by.value()[].partition_exprs[0].func = UInt8(99)
    assert_equal(_message(plan), _unserved("FUNC_99 is not a window function the sink computes"))


def test_count_star_and_a_count_of_any_type_are_cut() raises:
    assert_equal(_message(_over(PartitionExpr.running_count().with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.running_count("d").with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.running_count("g").with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.running_count("dec").with_frame(_range_running()))), "")


def test_the_refusal_comes_before_the_child_is_walked() raises:
    # The child is a top-n, which lowering refuses on its own account; the
    # window's refusal is the one reported.
    var topn = LogicalPlan.topn(_names("k"), _flags(1), 5, _scan())
    var plan = _window(_names("d"), _names(), _one(PartitionExpr.row_number()), topn^)
    assert_equal(
        _message(plan),
        _unserved("the PARTITION BY key 'd' has type date32, which the window's sort does not order"),
    )
    # With nothing the window refuses, the child's refusal is reported.
    var served = _window(
        _names("g"), _names(), _one(PartitionExpr.row_number()),
        LogicalPlan.topn(_names("k"), _flags(1), 5, _scan()),
    )
    assert_equal(
        _message(served),
        String(LOWERING_UNCUTTABLE_NODE) + ": " + plan_tag_name(PLAN_TOPN) + " (no cutter arm for this node) is not cut",
    )


def test_the_checks_run_in_a_fixed_order() raises:
    # A bad descending list beats a bad key, a bad key beats a bad function,
    # and the first bad function in the node's order is the one named.
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.ntile(0))
    exprs.append(PartitionExpr.lag("d"))
    var plan = LogicalPlan.partition_by(
        _names("d"), _names("k"), List[Bool](), exprs.copy(), _scan()
    )
    assert_equal(_message(plan), _unserved("the node has 1 order keys and 0 descending flags"))
    var bad_key = _window(_names("d"), _names("k"), exprs.copy(), _scan())
    assert_equal(
        _message(bad_key),
        _unserved("the PARTITION BY key 'd' has type date32, which the window's sort does not order"),
    )
    var bad_expr = _window(_names("g"), _names("k"), exprs.copy(), _scan())
    assert_equal(
        _message(bad_expr),
        _unserved("NTILE has the bucket count 0; a count above 0 is required"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
