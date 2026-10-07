# =============================================================================
# auto_schema: the fallback arm and the shape of every derived descriptor.
# =============================================================================
#
# `test_auto_schema` covers every mapped field type. This file covers what it
# does not: a field type with no arm derives TYPE_UNKNOWN (the fallback
# returning another tag, or the arm list growing a catch-all, fails here), and
# every derived column is non-nullable with no struct fields and no map types,
# in a non-strict descriptor (a flag or a slot set wrongly fails here).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_expr.typed_schema import (
    TYPE_FLOAT64,
    TYPE_INT64,
    TYPE_STRING,
    TYPE_UNKNOWN,
)

from komira_sdk.auto_schema import DerivedSchemaRow, _dtype_tag_for, derive_schema


@fieldwise_init
struct Odd(DerivedSchemaRow):
    var half: Float16
    var id: Int64
    var label: String


@fieldwise_init
struct Plain(Copyable, Movable):
    var x: Float64


def test_unmapped_field_type_is_unknown() raises:
    assert_equal(_dtype_tag_for[Float16](), TYPE_UNKNOWN)
    assert_equal(_dtype_tag_for[Plain](), TYPE_UNKNOWN, "a struct type")
    assert_equal(_dtype_tag_for[Int64](), TYPE_INT64)
    var s = Odd.schema()
    assert_equal(s.num_cols(), 3)
    assert_equal(s.cols[0].name, String("half"))
    assert_equal(s.cols[0].dtype, TYPE_UNKNOWN)
    assert_equal(s.cols[1].dtype, TYPE_INT64)
    assert_equal(s.cols[2].dtype, TYPE_STRING)


def test_descriptor_shape() raises:
    var s = derive_schema[Odd]()
    assert_false(s.strict, "subset semantics")
    for i in range(s.num_cols()):
        assert_false(s.cols[i].nullable, "non-nullable")
        assert_equal(len(s.cols[i].struct_fields), 0)
        assert_equal(s.cols[i].map_key_dtype, TYPE_UNKNOWN)
        assert_equal(s.cols[i].map_value_dtype, TYPE_UNKNOWN)
    var p = derive_schema[Plain]()
    assert_equal(p.num_cols(), 1)
    assert_equal(p.cols[0].dtype, TYPE_FLOAT64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
