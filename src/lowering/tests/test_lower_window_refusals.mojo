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
#   test_sum_avg_min_max_over_narrow_integer_columns_are_cut
#   test_an_argument_type_the_sink_does_not_compute_over_is_refused
#   test_an_argument_that_is_not_a_column_is_refused
#   test_a_lag_or_lead_default_the_column_would_change_is_refused
#   test_a_lag_or_lead_default_the_column_holds_is_cut
#   test_every_frame_sql_allows_is_cut_for_each_function_that_reads_it
#   test_a_frame_shape_sql_refuses_is_refused_with_duckdbs_reason
#   test_a_range_offset_needs_one_order_key_of_a_type_it_measures
#   test_a_negative_offset_is_refused
#   test_frame_units_that_are_neither_rows_nor_range_are_refused
#   test_ranking_and_offset_functions_ignore_their_frame
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
from plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET, PLAN_LIMIT, plan_tag_name


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


def test_a_null_placement_list_of_the_wrong_length_is_refused() raises:
    var long = LogicalPlan.partition_by(
        _names("g"), _names("k"), _flags(1), _one(PartitionExpr.row_number()),
        _scan(), Optional(_flags(2)),
    )
    assert_equal(_message(long), _unserved("the node has 1 order keys and 2 nulls_first flags"))
    var short = LogicalPlan.partition_by(
        _names("g"), _names("k", "v"), _flags(2), _one(PartitionExpr.row_number()),
        _scan(), Optional(_flags(1)),
    )
    assert_equal(_message(short), _unserved("the node has 2 order keys and 1 nulls_first flags"))
    var placed = LogicalPlan.partition_by(
        _names("g"), _names("k"), _flags(1), _one(PartitionExpr.row_number()),
        _scan(), Optional(_flags(1)),
    )
    assert_equal(_message(placed), "")


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


def test_sum_avg_min_max_over_narrow_integer_columns_are_cut() raises:
    assert_equal(_message(_over(PartitionExpr.running_sum("i32").with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.running_avg("i32").with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.running_min("i16").with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.running_max("i32").with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.running_avg("i16"))), "")


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
        _message(_over(PartitionExpr.running_avg("f32").with_frame(_range_running()))),
        _unserved("AVG(f32) has an argument of type float32" + tail),
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


def _framed(frame: PartitionFrame) -> List[PartitionExpr]:
    """Every function that reads its frame, over `frame`."""
    var out = List[PartitionExpr]()
    out.append(PartitionExpr.agg_with_frame(PF_SUM, "k", frame.copy()))
    out.append(PartitionExpr.running_avg("f").with_frame(frame.copy()))
    out.append(PartitionExpr.running_min("v").with_frame(frame.copy()))
    out.append(PartitionExpr.running_max("f").with_frame(frame.copy()))
    out.append(PartitionExpr.running_count("g").with_frame(frame.copy()))
    out.append(PartitionExpr.running_count().with_frame(frame.copy()))
    out.append(PartitionExpr.first_value("g").with_frame(frame.copy()))
    out.append(PartitionExpr.last_value("k").with_frame(frame.copy()))
    out.append(PartitionExpr.nth_value("f", 2).with_frame(frame.copy()))
    return out^


def _allowed_frames() -> List[PartitionFrame]:
    """A frame of each bound pair SQL allows, in ROWS and RANGE units."""
    var pairs = List[PartitionFrame]()
    for units in range(2):
        var u = UInt8(units)
        pairs.append(_frame(u, FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_PRECEDING, 1))
        pairs.append(_frame(u, FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_CURRENT_ROW, 0))
        pairs.append(_frame(u, FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_FOLLOWING, 2))
        pairs.append(_frame(u, FRAME_BOUND_PRECEDING, 3, FRAME_BOUND_PRECEDING, 1))
        pairs.append(_frame(u, FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0))
        pairs.append(_frame(u, FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_FOLLOWING, 1))
        pairs.append(_frame(u, FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0))
        pairs.append(_frame(u, FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_CURRENT_ROW, 0))
        pairs.append(_frame(u, FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_FOLLOWING, 4))
        pairs.append(_frame(u, FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0))
        pairs.append(_frame(u, FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_FOLLOWING, 3))
        pairs.append(_frame(u, FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0))
    return pairs^


def test_every_frame_sql_allows_is_cut_for_each_function_that_reads_it() raises:
    var frames = _allowed_frames()
    for i in range(len(frames)):
        var plan = _window(_names("g"), _names("k"), _framed(frames[i]), _scan())
        assert_equal(_message(plan), "", "frame " + String(frames[i]))
    # A RANGE offset over an INT32 and a FLOAT64 key, descending too.
    var offset = _frame(FRAME_UNITS_RANGE, FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_FOLLOWING, 1)
    assert_equal(_message(_window(_names("g"), _names("i32"), _framed(offset), _scan())), "")
    assert_equal(_message(_window(_names("g"), _names("f"), _framed(offset), _scan())), "")
    var desc = List[Bool]()
    desc.append(True)
    var descending = LogicalPlan.partition_by(
        _names("g"), _names("k"), desc^, _framed(offset), _scan()
    )
    assert_equal(_message(descending), "")
    # A RANGE frame without an offset reads peers, so it takes any number of
    # order keys of any sortable type.
    var peers = _frame(FRAME_UNITS_RANGE, FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0)
    assert_equal(_message(_window(_names(), _names("g", "b"), _framed(peers), _scan())), "")
    assert_equal(_message(_window(_names("g"), _names(), _framed(peers), _scan())), "")


def test_a_frame_shape_sql_refuses_is_refused_with_duckdbs_reason() raises:
    var tail = ", which SQL does not allow: "
    assert_equal(
        _message(_over(PartitionExpr.agg_with_frame(PF_SUM, "k", _frame(
            FRAME_UNITS_ROWS, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0)))),
        _unserved("SUM(k) has the frame ROWS BETWEEN UNBOUNDED FOLLOWING AND UNBOUNDED FOLLOWING"
            + tail + "frame start cannot be UNBOUNDED FOLLOWING"),
    )
    assert_equal(
        _message(_over(PartitionExpr.first_value("k").with_frame(_frame(
            FRAME_UNITS_RANGE, FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_UNBOUNDED_PRECEDING, 0)))),
        _unserved("FIRST_VALUE(k) has the frame RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED PRECEDING"
            + tail + "frame end cannot be UNBOUNDED PRECEDING"),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_count().with_frame(_frame(
            FRAME_UNITS_ROWS, FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_PRECEDING, 1)))),
        _unserved("COUNT() has the frame ROWS BETWEEN 1 FOLLOWING AND 1 PRECEDING"
            + tail + "frame starting from following row cannot have preceding rows"),
    )
    assert_equal(
        _message(_over(PartitionExpr.running_max("k").with_frame(_frame(
            FRAME_UNITS_ROWS, FRAME_BOUND_FOLLOWING, 2, FRAME_BOUND_CURRENT_ROW, 0)))),
        _unserved("MAX(k) has the frame ROWS BETWEEN 2 FOLLOWING AND CURRENT ROW"
            + tail + "frame starting from following row cannot have preceding rows"),
    )
    assert_equal(
        _message(_over(PartitionExpr.nth_value("k", 2).with_frame(_frame(
            FRAME_UNITS_RANGE, FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_PRECEDING, 1)))),
        _unserved("NTH_VALUE(k) has the frame RANGE BETWEEN CURRENT ROW AND 1 PRECEDING"
            + tail + "frame starting from current row cannot have preceding rows"),
    )


def test_a_range_offset_needs_one_order_key_of_a_type_it_measures() raises:
    var offset = _frame(FRAME_UNITS_RANGE, FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0)
    var head = "SUM(k) has the frame RANGE BETWEEN 1 PRECEDING AND CURRENT ROW; a RANGE frame with an offset needs "
    var sum = _one(PartitionExpr.agg_with_frame(PF_SUM, "k", offset.copy()))
    assert_equal(
        _message(_window(_names("g"), _names(), sum.copy(), _scan())),
        _unserved(head + "exactly one ORDER BY key, and the window has 0"),
    )
    assert_equal(
        _message(_window(_names("g"), _names("k", "f"), sum.copy(), _scan())),
        _unserved(head + "exactly one ORDER BY key, and the window has 2"),
    )
    assert_equal(
        _message(_window(_names(), _names("g"), sum.copy(), _scan())),
        _unserved(head + "an INT64, INT32 or FLOAT64 ORDER BY key, and 'g' has type string"),
    )
    assert_equal(
        _message(_window(_names(), _names("b"), sum.copy(), _scan())),
        _unserved(head + "an INT64, INT32 or FLOAT64 ORDER BY key, and 'b' has type bool"),
    )
    # The end bound alone carries the offset.
    var end_only = _one(PartitionExpr.running_count().with_frame(_frame(
        FRAME_UNITS_RANGE, FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_FOLLOWING, 2)))
    assert_equal(
        _message(_window(_names("g"), _names(), end_only^, _scan())),
        _unserved("COUNT() has the frame RANGE BETWEEN CURRENT ROW AND 2 FOLLOWING;"
            " a RANGE frame with an offset needs exactly one ORDER BY key, and the window has 0"),
    )
    # The same frame in ROWS units counts rows, and needs no key.
    var rows = _one(PartitionExpr.agg_with_frame(PF_SUM, "k", _frame(
        FRAME_UNITS_ROWS, FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0)))
    assert_equal(_message(_window(_names("g"), _names(), rows^, _scan())), "")


def test_a_negative_offset_is_refused() raises:
    var tail = "; an offset below 0 is not served"
    assert_equal(
        _message(_over(PartitionExpr.agg_with_frame(PF_SUM, "k", _frame(
            FRAME_UNITS_ROWS, FRAME_BOUND_PRECEDING, -1, FRAME_BOUND_CURRENT_ROW, 0)))),
        _unserved("SUM(k) has the frame ROWS BETWEEN -1 PRECEDING AND CURRENT ROW" + tail),
    )
    assert_equal(
        _message(_over(PartitionExpr.last_value("k").with_frame(_frame(
            FRAME_UNITS_RANGE, FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_FOLLOWING, -3)))),
        _unserved("LAST_VALUE(k) has the frame RANGE BETWEEN CURRENT ROW AND -3 FOLLOWING" + tail),
    )
    # 0 is an offset like any other.
    assert_equal(
        _message(_over(PartitionExpr.agg_with_frame(PF_SUM, "k", _frame(
            FRAME_UNITS_ROWS, FRAME_BOUND_PRECEDING, 0, FRAME_BOUND_FOLLOWING, 0)))),
        "",
    )


def test_frame_units_that_are_neither_rows_nor_range_are_refused() raises:
    assert_equal(
        _message(_over(PartitionExpr.agg_with_frame(PF_SUM, "k", _frame(
            UInt8(2), FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0)))),
        _unserved("SUM(k) has the frame units 2, which are neither ROWS nor RANGE"),
    )


def test_ranking_and_offset_functions_ignore_their_frame() raises:
    # A frame SQL would refuse, and a RANGE offset over two keys: the ranking
    # and offset functions do not read it.
    var shape = _frame(FRAME_UNITS_ROWS, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0, FRAME_BOUND_PRECEDING, 1)
    var keys = _frame(FRAME_UNITS_RANGE, FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0)
    assert_equal(_message(_over(PartitionExpr.row_number().with_frame(shape.copy()))), "")
    assert_equal(_message(_over(PartitionExpr.ntile(2).with_frame(shape.copy()))), "")
    assert_equal(_message(_over(PartitionExpr.lag("k").with_frame(shape.copy()))), "")
    assert_equal(
        _message(_window(_names("g"), _names("k", "f"), _one(PartitionExpr.lead("k").with_frame(keys.copy())), _scan())),
        "",
    )
    # The default frame of an ordered window is served.
    assert_equal(_message(_over(PartitionExpr.running_sum("k").with_frame(_range_running()))), "")
    assert_equal(_message(_over(PartitionExpr.first_value("k"))), "")


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
    # The child is a limit with a negative count, which lowering refuses on
    # its own account; the window's refusal is the one reported.
    var refused = LogicalPlan.limit(-1, _scan())
    var plan = _window(_names("d"), _names(), _one(PartitionExpr.row_number()), refused^)
    assert_equal(
        _message(plan),
        _unserved("the PARTITION BY key 'd' has type date32, which the window's sort does not order"),
    )
    # With nothing the window refuses, the child's refusal is reported.
    var served = _window(
        _names("g"), _names(), _one(PartitionExpr.row_number()),
        LogicalPlan.limit(-1, _scan()),
    )
    assert_equal(
        _message(served),
        String(LOWERING_UNCUTTABLE_NODE) + ": " + plan_tag_name(PLAN_LIMIT) + " (a limit with a negative count) is not cut",
    )


def test_the_checks_run_in_a_fixed_order() raises:
    # A bad descending list beats a bad NULL placement list, a bad NULL
    # placement list beats a bad key, a bad key beats a bad function, and the
    # first bad function in the node's order is the one named.
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.ntile(0))
    exprs.append(PartitionExpr.lag("d"))
    var plan = LogicalPlan.partition_by(
        _names("d"), _names("k"), List[Bool](), exprs.copy(), _scan()
    )
    assert_equal(_message(plan), _unserved("the node has 1 order keys and 0 descending flags"))
    var bad_placement = LogicalPlan.partition_by(
        _names("d"), _names("k"), _flags(1), exprs.copy(), _scan(),
        Optional(_flags(2)),
    )
    assert_equal(
        _message(bad_placement),
        _unserved("the node has 1 order keys and 2 nulls_first flags"),
    )
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
