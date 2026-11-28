# =============================================================================
# test_lower_join_refusals: the joins lowering refuses, by reason, and the
# neighbouring joins it cuts
# =============================================================================
#
# Every case checks that the message starts with LOWERING_JOIN_UNSERVED and
# says why, and that a join differing only in the refused detail lowers.
#
#   test_every_join_type_the_ir_defines_lowers_and_an_undefined_one_is_refused
#   test_a_semi_or_anti_join_that_builds_its_left_side_is_refused
#   test_a_cross_join_that_names_a_key_is_refused
#   test_a_join_with_no_equi_key_is_refused
#   test_key_lists_of_different_lengths_are_refused
#   test_more_than_eight_keys_are_refused_and_eight_are_cut
#   test_a_join_with_a_residual_predicate_is_refused
#   test_the_sort_merge_hint_is_refused_and_the_hash_hint_is_cut
#   test_a_build_side_the_plan_does_not_define_is_refused
#   test_a_key_that_is_not_a_column_of_its_side_is_refused
#   test_a_key_pair_the_probe_does_not_compare_is_refused
#   test_date_and_timestamp_keys_pair_as_duckdb_compares_them
#   test_an_output_naming_a_column_twice_is_refused
#   test_a_join_is_refused_before_any_scan_is_counted
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_INPUTS_SCAN_COUNT,
    LOWERING_JOIN_UNSERVED,
)
from plan_expr.expr import Expr
from plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_ALGO_AUTO,
    JOIN_ALGO_HASH,
    JOIN_ALGO_SORT_MERGE,
    JOIN_BUILD_SIDE_LEFT,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_BUILD_SIDE_UNSET,
)


def _table1(path: String, a: String, at: ArrowType) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, at, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _table2(
    path: String, a: String, at: ArrowType, b: String, bt: ArrowType
) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, at, False))
    sb.add_field(Field(b, bt, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _left() -> LogicalPlan:
    return _table2("l.parquet", "k", ArrowType.INT64, "v", ArrowType.INT64)


def _right() -> LogicalPlan:
    return _table2("r.parquet", "k2", ArrowType.INT64, "w", ArrowType.INT64)


def _names(a: String = "", b: String = "") -> List[String]:
    var out = List[String]()
    if a != "":
        out.append(a)
    if b != "":
        out.append(b)
    return out^


def _wide(path: String, prefix: String, n: Int) -> LogicalPlan:
    var sb = SchemaBuilder()
    for i in range(n):
        sb.add_field(Field(prefix + String(i), ArrowType.INT64, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _wide_names(prefix: String, n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(prefix + String(i))
    return out^


def _inputs(scans: Int = 2) -> LoweringInputs:
    var inputs = LoweringInputs()
    for _ in range(scans):
        inputs.add_scan()
    return inputs^


def _message(plan: LogicalPlan, inputs: LoweringInputs) raises -> String:
    """The refusal text, or an empty string when the plan lowers."""
    try:
        _ = lower(plan, reference_host_profile("test-build"), inputs)
    except e:
        return String(e)
    return String("")


def _refused_with(message: String, why: String) raises:
    var token = String(LOWERING_JOIN_UNSERVED)
    assert_true(message.startswith(token + ": "), String("message does not start with the token: ") + message)
    assert_true(why in message, String("message does not say why (") + why + "): " + message)


def _join_of_type(join_type: UInt8) -> LogicalPlan:
    return LogicalPlan.join(_left(), _right(), _names("k"), _names("k2"), join_type)


def _cross() -> LogicalPlan:
    return LogicalPlan.join(_left(), _right(), _names(), _names(), JOIN_CROSS)


def test_every_join_type_the_ir_defines_lowers_and_an_undefined_one_is_refused() raises:
    assert_equal(_message(_join_of_type(JOIN_INNER), _inputs()), "")
    assert_equal(_message(_join_of_type(JOIN_LEFT), _inputs()), "")
    assert_equal(_message(_join_of_type(JOIN_RIGHT), _inputs()), "")
    assert_equal(_message(_join_of_type(JOIN_FULL), _inputs()), "")
    assert_equal(_message(_join_of_type(JOIN_SEMI), _inputs()), "")
    assert_equal(_message(_join_of_type(JOIN_ANTI), _inputs()), "")
    assert_equal(_message(_cross(), _inputs()), "")
    _refused_with(_message(_join_of_type(UInt8(9)), _inputs()), "a type 9 join")
    _refused_with(
        _message(_join_of_type(UInt8(9)), _inputs()), ") is not served by the hash join"
    )


def _join_building(join_type: UInt8, side: UInt8) -> LogicalPlan:
    return LogicalPlan.join(
        _left(), _right(), _names("k"), _names("k2"), join_type, JOIN_ALGO_AUTO, None, side
    )


def test_a_semi_or_anti_join_that_builds_its_left_side_is_refused() raises:
    _refused_with(
        _message(_join_building(JOIN_SEMI, JOIN_BUILD_SIDE_LEFT), _inputs()),
        "a SEMI join that builds its left side",
    )
    _refused_with(
        _message(_join_building(JOIN_ANTI, JOIN_BUILD_SIDE_LEFT), _inputs()),
        "a ANTI join that builds its left side",
    )
    # The same joins building the right child, or with no recorded side, lower;
    # so does an outer join that builds its left child.
    assert_equal(_message(_join_building(JOIN_SEMI, JOIN_BUILD_SIDE_RIGHT), _inputs()), "")
    assert_equal(_message(_join_building(JOIN_ANTI, JOIN_BUILD_SIDE_UNSET), _inputs()), "")
    assert_equal(_message(_join_building(JOIN_LEFT, JOIN_BUILD_SIDE_LEFT), _inputs()), "")


def test_a_cross_join_that_names_a_key_is_refused() raises:
    var keyed = LogicalPlan.join(_left(), _right(), _names("k"), _names("k2"), JOIN_CROSS)
    _refused_with(_message(keyed, _inputs()), "a CROSS join that names a key")
    var one_side = LogicalPlan.join(_left(), _right(), _names("k"), _names(), JOIN_CROSS)
    _refused_with(_message(one_side, _inputs()), "a CROSS join that names a key")
    assert_equal(_message(_cross(), _inputs()), "")


def test_a_join_with_no_equi_key_is_refused() raises:
    var keyless = LogicalPlan.join(_left(), _right(), _names(), _names(), JOIN_INNER)
    _refused_with(_message(keyless, _inputs()), "a join with no equi key")
    assert_equal(_message(_join_of_type(JOIN_INNER), _inputs()), "")


def test_key_lists_of_different_lengths_are_refused() raises:
    var uneven = LogicalPlan.join(_left(), _right(), _names("k", "v"), _names("k2"), JOIN_INNER)
    _refused_with(_message(uneven, _inputs()), "2 left keys against 1 right keys")
    var evened = LogicalPlan.join(_left(), _right(), _names("k", "v"), _names("k2", "w"), JOIN_INNER)
    assert_equal(_message(evened, _inputs()), "")


def test_more_than_eight_keys_are_refused_and_eight_are_cut() raises:
    var nine = LogicalPlan.join(
        _wide("l.parquet", "l", 9), _wide("r.parquet", "r", 9), _wide_names("l", 9), _wide_names("r", 9), JOIN_INNER
    )
    _refused_with(_message(nine, _inputs()), "9 keys; the probe takes at most 8")
    var eight = LogicalPlan.join(
        _wide("l.parquet", "l", 8), _wide("r.parquet", "r", 8), _wide_names("l", 8), _wide_names("r", 8), JOIN_INNER
    )
    assert_equal(_message(eight, _inputs()), "")


def test_a_join_with_a_residual_predicate_is_refused() raises:
    var residual = LogicalPlan.join(
        _left(),
        _right(),
        _names("k"),
        _names("k2"),
        JOIN_INNER,
        JOIN_ALGO_AUTO,
        Optional[OwnedPointer[Expr]](OwnedPointer(Expr.col_ref("v"))),
    )
    _refused_with(_message(residual, _inputs()), "a residual predicate")
    assert_equal(_message(_join_of_type(JOIN_INNER), _inputs()), "")


def test_the_sort_merge_hint_is_refused_and_the_hash_hint_is_cut() raises:
    var merge = LogicalPlan.join(_left(), _right(), _names("k"), _names("k2"), JOIN_INNER, JOIN_ALGO_SORT_MERGE)
    _refused_with(_message(merge, _inputs()), "the sort-merge algorithm hint")
    var hash = LogicalPlan.join(_left(), _right(), _names("k"), _names("k2"), JOIN_INNER, JOIN_ALGO_HASH)
    assert_equal(_message(hash, _inputs()), "")


def _with_build_side(side: UInt8) -> LogicalPlan:
    return LogicalPlan.join(
        _left(),
        _right(),
        _names("k"),
        _names("k2"),
        JOIN_INNER,
        JOIN_ALGO_AUTO,
        None,
        side,
    )


def test_a_build_side_the_plan_does_not_define_is_refused() raises:
    _refused_with(_message(_with_build_side(UInt8(7)), _inputs()), "build side 7")
    assert_equal(_message(_with_build_side(JOIN_BUILD_SIDE_LEFT), _inputs()), "")
    assert_equal(_message(_with_build_side(JOIN_BUILD_SIDE_RIGHT), _inputs()), "")
    assert_equal(_message(_with_build_side(JOIN_BUILD_SIDE_UNSET), _inputs()), "")


def test_a_key_that_is_not_a_column_of_its_side_is_refused() raises:
    var no_left = LogicalPlan.join(_left(), _right(), _names("zz"), _names("k2"), JOIN_INNER)
    _refused_with(_message(no_left, _inputs()), "the key 'zz' is not a column of the left side")
    var no_right = LogicalPlan.join(_left(), _right(), _names("k"), _names("zz"), JOIN_INNER)
    _refused_with(_message(no_right, _inputs()), "the key 'zz' is not a column of the right side")
    # A key named for the other side's column is not a column of its own side.
    var swapped = LogicalPlan.join(_left(), _right(), _names("k2"), _names("k"), JOIN_INNER)
    _refused_with(_message(swapped, _inputs()), "the key 'k2' is not a column of the left side")
    assert_equal(_message(_join_of_type(JOIN_INNER), _inputs()), "")


def _pair_message(lt: ArrowType, rt: ArrowType) raises -> String:
    var plan = LogicalPlan.join(
        _table1("l.parquet", "k", lt),
        _table1("r.parquet", "k2", rt),
        _names("k"),
        _names("k2"),
        JOIN_INNER,
    )
    return _message(plan, _inputs())


def test_a_key_pair_the_probe_does_not_compare_is_refused() raises:
    _refused_with(_pair_message(ArrowType.INT64, ArrowType.STRING), "the key pair k (")
    _refused_with(_pair_message(ArrowType.INT64, ArrowType.STRING), ") = k2 (")
    _refused_with(_pair_message(ArrowType.FLOAT64, ArrowType.INT64), "the key pair k (")
    _refused_with(_pair_message(ArrowType.STRING, ArrowType.FLOAT64), "the key pair k (")
    # A type the probe has no key family for is refused even against itself.
    _refused_with(_pair_message(ArrowType.BOOL, ArrowType.BOOL), "the key pair k (")
    # The integers compare in any pairing; floats and strings with their own.
    assert_equal(_pair_message(ArrowType.INT32, ArrowType.INT64), "")
    assert_equal(_pair_message(ArrowType.INT64, ArrowType.INT32), "")
    assert_equal(_pair_message(ArrowType.INT32, ArrowType.INT32), "")
    assert_equal(_pair_message(ArrowType.FLOAT64, ArrowType.FLOAT64), "")
    assert_equal(_pair_message(ArrowType.STRING, ArrowType.STRING), "")


def _timestamp_table(path: String, a: String, at: ArrowType, tz: String) raises -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field.timestamp(a, at, tz, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _temporal_pair_message(
    lt: ArrowType, ltz: String, rt: ArrowType, rtz: String
) raises -> String:
    var left = _table1("l.parquet", "k", lt)
    if lt != ArrowType.DATE32:
        left = _timestamp_table("l.parquet", "k", lt, ltz)
    var right = _table1("r.parquet", "k2", rt)
    if rt != ArrowType.DATE32:
        right = _timestamp_table("r.parquet", "k2", rt, rtz)
    var plan = LogicalPlan.join(
        left^, right^, _names("k"), _names("k2"), JOIN_INNER
    )
    return _message(plan, _inputs())


def test_date_and_timestamp_keys_pair_as_duckdb_compares_them() raises:
    var us = ArrowType.TIMESTAMP_US
    var d = ArrowType.DATE32
    # A DATE meets a naive microsecond TIMESTAMP (at its midnight), either way.
    assert_equal(_temporal_pair_message(d, "", d, ""), "")
    assert_equal(_temporal_pair_message(d, "", us, ""), "")
    assert_equal(_temporal_pair_message(us, "", d, ""), "")
    assert_equal(_temporal_pair_message(us, "", us, ""), "")
    assert_equal(_temporal_pair_message(ArrowType.TIMESTAMP, "", us, ""), "")
    # Two zoned timestamps are instants, whatever their zones' names.
    assert_equal(_temporal_pair_message(us, "UTC", us, "Europe/Paris"), "")
    # A naive value against a zoned one, a DATE against a zoned one, and two
    # different units are refused.
    _refused_with(_temporal_pair_message(us, "", us, "UTC"), "the key pair k (")
    _refused_with(_temporal_pair_message(d, "", us, "UTC"), "the key pair k (")
    _refused_with(
        _temporal_pair_message(us, "", ArrowType.TIMESTAMP_MS, ""), "the key pair k ("
    )
    _refused_with(
        _temporal_pair_message(d, "", ArrowType.TIMESTAMP_NS, ""), "the key pair k ("
    )
    # The other units compare with their own unit and zone presence only.
    assert_equal(_temporal_pair_message(ArrowType.TIMESTAMP_S, "", ArrowType.TIMESTAMP_S, ""), "")
    assert_equal(_temporal_pair_message(ArrowType.TIMESTAMP_MS, "UTC", ArrowType.TIMESTAMP_MS, "UTC"), "")
    assert_equal(_temporal_pair_message(ArrowType.TIMESTAMP_NS, "", ArrowType.TIMESTAMP_NS, ""), "")
    _refused_with(
        _temporal_pair_message(ArrowType.TIMESTAMP_S, "", ArrowType.TIMESTAMP_S, "UTC"),
        "the key pair k (",
    )
    _refused_with(
        _temporal_pair_message(ArrowType.TIMESTAMP_MS, "", ArrowType.TIMESTAMP_MS, "UTC"),
        "the key pair k (",
    )
    _refused_with(
        _temporal_pair_message(ArrowType.TIMESTAMP_NS, "UTC", ArrowType.TIMESTAMP_NS, ""),
        "the key pair k (",
    )
    # DATE64 with DATE64 only.
    assert_equal(_pair_message(ArrowType.DATE64, ArrowType.DATE64), "")
    _refused_with(_pair_message(ArrowType.DATE64, ArrowType.DATE32), "the key pair k (")
    # A temporal key never meets a number or a string.
    _refused_with(_pair_message(ArrowType.DATE32, ArrowType.INT32), "the key pair k (")
    _refused_with(_pair_message(ArrowType.TIMESTAMP_US, ArrowType.INT64), "the key pair k (")
    _refused_with(_pair_message(ArrowType.DATE32, ArrowType.STRING), "the key pair k (")


def test_an_output_naming_a_column_twice_is_refused() raises:
    # The left side has `a` and `a_right`; the right side's `a` is renamed
    # `a_right` by the join, which the left side already holds.
    var left = _table2("l.parquet", "a", ArrowType.INT64, "a_right", ArrowType.INT64)
    var sb = SchemaBuilder()
    sb.add_field(Field("k2", ArrowType.INT64, False))
    sb.add_field(Field("a", ArrowType.INT64, False))
    var right = LogicalPlan.scan(String("r.parquet"), SOURCE_PARQUET, sb.build())
    var twice = LogicalPlan.join(left^, right^, _names("a"), _names("k2"), JOIN_INNER)
    _refused_with(_message(twice, _inputs()), "an output that names 'a_right' twice")
    # Without the right side's `a` the output names every column once.
    var left_ok = _table2("l.parquet", "a", ArrowType.INT64, "a_right", ArrowType.INT64)
    var once = LogicalPlan.join(
        left_ok^, _table1("r.parquet", "k2", ArrowType.INT64), _names("a"), _names("k2"), JOIN_INNER
    )
    assert_equal(_message(once, _inputs(2)), "")


def test_a_join_is_refused_before_any_scan_is_counted() raises:
    # No scan facts at all: the refusal is the join's, not the scan count's.
    _refused_with(_message(_join_of_type(UInt8(9)), _inputs(0)), "a type 9 join")
    var message = _message(_join_of_type(JOIN_INNER), _inputs(0))
    assert_true(message.startswith(String(LOWERING_INPUTS_SCAN_COUNT) + ": "), message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
