# =============================================================================
# test_typed_schema_or_returns.mojo: the typed_schema functions built on a
# predicate that returns an `or` chain (`is_numeric_type`, `is_float_type`,
# `_is_unsigned_int_type`, `_join_drops_right`) and their callers
# (`agg_output_type`, `join_out_schema`).
#
# They are kept apart from the other typed_schema tests because the branch
# classifier cannot attribute the right operand of a returned `or` and so
# writes no branch records for a test binary that holds one; the other test
# files' records stay readable.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_expr.agg_expr import (
    AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX, AGG_MEAN,
    AGG_COUNT_DISTINCT, AGG_FIRST, AGG_LAST, AGG_STDDEV_SAMP, AGG_VAR_SAMP,
    AGG_COVAR_POP, AGG_COVAR_SAMP, AGG_REGR_AVGX, AGG_REGR_AVGY,
    AGG_REGR_COUNT, AGG_REGR_SXX, AGG_REGR_SXY, AGG_REGR_SYY,
    AGG_REGR_SLOPE, AGG_REGR_INTERCEPT, AGG_REGR_R2,
    AGG_CORR, AGG_MEDIAN, AGG_LARGEST_K,
    AGG_VAR_POP, AGG_STDDEV_POP, AGG_SEM,
    AGG_COUNT_IF, AGG_BOOL_AND, AGG_BOOL_OR, AGG_PRODUCT, AGG_ANY_VALUE,
    AGG_KAHAN_SUM, AGG_KAHAN_AVG,
    AGG_SKEWNESS, AGG_KURTOSIS, AGG_KURTOSIS_POP,
)
from komira_plan_expr.typed_schema import (
    TYPE_UNKNOWN, TYPE_INT8, TYPE_INT16, TYPE_INT32, TYPE_INT64,
    TYPE_UINT8, TYPE_UINT16, TYPE_UINT32, TYPE_UINT64,
    TYPE_FLOAT32, TYPE_FLOAT64, TYPE_BOOL, TYPE_STRING,
    TYPE_DATE32, TYPE_DATE64, TYPE_TIMESTAMP, TYPE_DECIMAL128,
    TYPE_STRUCT, TYPE_MAP,
    Int64Col, Float64Col,
    ColDescriptor, SchemaDescriptor,
    _NN, _NS, _NM,
    schema_of,
    is_numeric_type, is_float_type, _is_unsigned_int_type,
    agg_output_type,
    join_out_schema, join_schema_of,
)


comptime ORDERS = schema_of["order_key", Int64Col, "order_total", Float64Col]()
comptime ITEMS = schema_of["order_key", TYPE_INT32, "item_price", Float64Col]()


def test_is_numeric_type_every_tag() raises:
    """The arithmetic markers: every integer, both floats, the three
    date/time tags and DECIMAL128 are numeric; BOOL, STRING, STRUCT, MAP and
    UNKNOWN are not."""
    var yes: List[Int] = [
        TYPE_INT8, TYPE_INT16, TYPE_INT32, TYPE_INT64,
        TYPE_UINT8, TYPE_UINT16, TYPE_UINT32, TYPE_UINT64,
        TYPE_FLOAT32, TYPE_FLOAT64,
        TYPE_DATE32, TYPE_DATE64, TYPE_TIMESTAMP, TYPE_DECIMAL128,
    ]
    for i in range(len(yes)):
        assert_true(is_numeric_type(yes[i]), String("numeric tag ") + String(yes[i]))
    var no: List[Int] = [TYPE_BOOL, TYPE_STRING, TYPE_STRUCT, TYPE_MAP, TYPE_UNKNOWN, 18]
    for i in range(len(no)):
        assert_false(is_numeric_type(no[i]), String("non-numeric tag ") + String(no[i]))


def test_is_float_type_only_the_two_floats() raises:
    assert_true(is_float_type(TYPE_FLOAT32))
    assert_true(is_float_type(TYPE_FLOAT64))
    assert_false(is_float_type(TYPE_INT64))
    assert_false(is_float_type(TYPE_DECIMAL128))
    assert_false(is_float_type(TYPE_UNKNOWN))


def test_is_unsigned_int_type_only_the_four_unsigned() raises:
    assert_true(_is_unsigned_int_type(TYPE_UINT8))
    assert_true(_is_unsigned_int_type(TYPE_UINT16))
    assert_true(_is_unsigned_int_type(TYPE_UINT32))
    assert_true(_is_unsigned_int_type(TYPE_UINT64))
    assert_false(_is_unsigned_int_type(TYPE_INT8))
    assert_false(_is_unsigned_int_type(TYPE_INT64))
    assert_false(_is_unsigned_int_type(TYPE_FLOAT32))


def test_agg_output_type_counts_are_int64() raises:
    """COUNT, COUNT DISTINCT, COUNT_IF and REGR_COUNT are INT64 tallies
    whatever the input column's type."""
    assert_equal(agg_output_type(AGG_COUNT, TYPE_UNKNOWN), TYPE_INT64)
    assert_equal(agg_output_type(AGG_COUNT, TYPE_STRING), TYPE_INT64)
    assert_equal(agg_output_type(AGG_COUNT_DISTINCT, TYPE_FLOAT64), TYPE_INT64)
    assert_equal(agg_output_type(AGG_COUNT_IF, TYPE_BOOL), TYPE_INT64)
    assert_equal(agg_output_type(AGG_REGR_COUNT, TYPE_FLOAT64), TYPE_INT64)


def test_agg_output_type_sum_promotion() raises:
    """The SUM promotion table of `agg_output_type`'s header, for the rows
    where it agrees with the runtime `_infer_agg_field` (read, not called:
    that function lives in komira_plan_ir, which depends on this package, so
    a test here cannot reach it without a cycle): floats to FLOAT64,
    DECIMAL128 stays, every unsigned width to UINT64, signed integers and BOOL
    to INT64. SUM over the DATE32 / DATE64 / TIMESTAMP and STRING tags is
    left out: the mirror says INT64 there and the runtime keeps the input
    type, a drift tracked separately."""
    assert_equal(agg_output_type(AGG_SUM, TYPE_FLOAT32), TYPE_FLOAT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_FLOAT64), TYPE_FLOAT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_DECIMAL128), TYPE_DECIMAL128)
    assert_equal(agg_output_type(AGG_SUM, TYPE_UINT64), TYPE_UINT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_UINT8), TYPE_UINT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_UINT16), TYPE_UINT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_UINT32), TYPE_UINT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_INT8), TYPE_INT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_INT16), TYPE_INT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_INT32), TYPE_INT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_INT64), TYPE_INT64)
    assert_equal(agg_output_type(AGG_SUM, TYPE_BOOL), TYPE_INT64)


def test_agg_output_type_finalized_statistics_are_float64() raises:
    """Every finalize that divides or multiplies (mean, the sample and
    population moments, CORR, MEDIAN, LARGEST_K, PRODUCT, the ten bivariate
    statistics other than REGR_COUNT, the compensated sums and the
    higher-moment trio) is FLOAT64 even over an integer input."""
    var funcs: List[UInt8] = [
        AGG_MEAN, AGG_STDDEV_SAMP, AGG_VAR_SAMP, AGG_VAR_POP, AGG_STDDEV_POP,
        AGG_SEM, AGG_PRODUCT, AGG_CORR, AGG_MEDIAN, AGG_LARGEST_K,
        AGG_COVAR_POP, AGG_COVAR_SAMP, AGG_REGR_AVGX, AGG_REGR_AVGY,
        AGG_REGR_SXX, AGG_REGR_SXY, AGG_REGR_SYY, AGG_REGR_SLOPE,
        AGG_REGR_INTERCEPT, AGG_REGR_R2,
        AGG_KAHAN_SUM, AGG_KAHAN_AVG, AGG_SKEWNESS, AGG_KURTOSIS,
        AGG_KURTOSIS_POP,
    ]
    for i in range(len(funcs)):
        assert_equal(
            agg_output_type(funcs[i], TYPE_INT64), TYPE_FLOAT64,
            String("agg func ") + String(Int(funcs[i])),
        )


def test_agg_output_type_bool_folds_are_bool() raises:
    assert_equal(agg_output_type(AGG_BOOL_AND, TYPE_BOOL), TYPE_BOOL)
    assert_equal(agg_output_type(AGG_BOOL_OR, TYPE_BOOL), TYPE_BOOL)


def test_agg_output_type_picks_keep_the_input_type() raises:
    """MIN, MAX, FIRST, LAST and ANY_VALUE return one of the input cells, so
    the output type is the input's (an INT16 stays INT16, a STRING stays
    STRING); a function code outside every arm does the same."""
    var picks: List[UInt8] = [AGG_MIN, AGG_MAX, AGG_FIRST, AGG_LAST, AGG_ANY_VALUE]
    for i in range(len(picks)):
        assert_equal(agg_output_type(picks[i], TYPE_INT16), TYPE_INT16)
        assert_equal(agg_output_type(picks[i], TYPE_STRING), TYPE_STRING)
    assert_equal(agg_output_type(UInt8(200), TYPE_DATE64), TYPE_DATE64)


def _left() -> SchemaDescriptor:
    var c: List[ColDescriptor] = [_NN("id", TYPE_INT64), _NN("name", TYPE_STRING)]
    return SchemaDescriptor(c^, True)


def _right() -> SchemaDescriptor:
    var kids: List[ColDescriptor] = [_NN("street", TYPE_STRING)]
    var c: List[ColDescriptor] = [
        ColDescriptor("id", TYPE_INT32, True, List[ColDescriptor](), TYPE_UNKNOWN, TYPE_UNKNOWN),
        _NN("amount", TYPE_FLOAT64),
        _NS("addr", kids^),
        _NM("tags", TYPE_STRING, TYPE_INT64),
    ]
    return SchemaDescriptor(c^, False)


def test_join_out_schema_keeps_right_side() raises:
    """INNER, LEFT, RIGHT, FULL and CROSS (0, 1, 2, 3, 6): left columns
    verbatim, then right's; a right name colliding with a left name gets
    `_right`, the others keep theirs; right types, nullability, children and
    map types copied; never strict."""
    var kinds: List[Int] = [0, 1, 2, 3, 6]
    for k in range(len(kinds)):
        var j = join_out_schema(_left(), _right(), kinds[k])
        assert_equal(j.names_joined(), "id, name, id_right, amount, addr, tags")
        assert_false(j.strict)
        assert_equal(j.cols[0].dtype, TYPE_INT64)
        assert_false(j.cols[0].nullable)
        assert_equal(j.cols[2].dtype, TYPE_INT32)
        assert_true(j.cols[2].nullable)
        assert_equal(j.cols[3].dtype, TYPE_FLOAT64)
        assert_equal(j.cols[4].struct_fields[0].name, "street")
        assert_equal(j.cols[5].map_key_dtype, TYPE_STRING)
        assert_equal(j.cols[5].map_value_dtype, TYPE_INT64)


def test_join_out_schema_semi_anti_drop_right() raises:
    """SEMI (4) and ANTI (5) keep only the left columns."""
    assert_equal(join_out_schema(_left(), _right(), 4).names_joined(), "id, name")
    assert_equal(join_out_schema(_left(), _right(), 5).names_joined(), "id, name")


def test_join_out_schema_collision_is_against_left_only() raises:
    """The collision test is against the LEFT names only: a right column
    whose name collides with nothing on the left keeps its name, even when
    another right column is renamed."""
    var c: List[ColDescriptor] = [_NN("name", TYPE_STRING), _NN("qty", TYPE_INT32)]
    var j = join_out_schema(_left(), SchemaDescriptor(c^, False), 0)
    assert_equal(j.names_joined(), "id, name, name_right, qty")


def test_join_schema_of() raises:
    """The parametric wrapper gives the same schema as `join_out_schema` for
    an INNER join of two `schema_of` brands."""
    var j = join_schema_of[ORDERS, ITEMS, 0]()
    assert_equal(j.num_cols(), 4)
    assert_equal(j.names_joined(), "order_key, order_total, order_key_right, item_price")
    assert_equal(j.cols[2].dtype, TYPE_INT32)
    assert_equal(j.cols[3].dtype, TYPE_FLOAT64)
    var s = join_schema_of[ORDERS, ITEMS, 4]()
    assert_equal(s.num_cols(), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
