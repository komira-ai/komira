# =============================================================================
# The sort and top-N sink kernels: an empty key list, and the tie-break rule
# =============================================================================
#
#   * A sort with no keys has no answer: both kernels raise a catchable
#     `Error` for any row count and any LIMIT, instead of aborting.
#   * `append_deterministic_tiebreak[_schema]` appends every INT64 / INT32 /
#     FLOAT64 column that is not already a key, in schema order, as an
#     ascending key; other column types are left out.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_physical_plan.physical_plan import SortSinkData, TopNSinkData

from komira_op_sort.sort_topn_sink import (
    _execute_sort_sink,
    _execute_topn_sink,
    append_deterministic_tiebreak,
    append_deterministic_tiebreak_schema,
)


def _batch(n: Int) raises -> RecordBatch:
    """`[a INT64]` with `n` rows."""
    var a = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        a.set_typed[Scalar[DType.int64]](i, Int64(n - i))
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(Column.from_primitive[DType.int64](a^))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return builder.build(sb.build())


def _no_keys() -> List[String]:
    return List[String]()


def _no_directions() -> List[Bool]:
    return List[Bool]()


# -----------------------------------------------------------------------------
# Zero keys
# -----------------------------------------------------------------------------


def test_sort_with_no_keys_raises_for_many_rows() raises:
    with assert_raises(contains="ZERO sort keys"):
        _ = _execute_sort_sink(
            _batch(10), SortSinkData(_no_keys(), _no_directions())
        )


def test_sort_with_no_keys_raises_for_one_row() raises:
    """The refusal comes before the one-row early return."""
    with assert_raises(contains="ZERO sort keys"):
        _ = _execute_sort_sink(
            _batch(1), SortSinkData(_no_keys(), _no_directions())
        )


def test_top_n_with_no_keys_raises_for_many_rows() raises:
    with assert_raises(contains="ZERO sort keys"):
        _ = _execute_topn_sink(
            _batch(10), TopNSinkData(_no_keys(), _no_directions(), 3)
        )


def test_top_n_with_no_keys_raises_for_limit_zero() raises:
    """The refusal comes before the LIMIT 0 answer."""
    with assert_raises(contains="ZERO sort keys"):
        _ = _execute_topn_sink(
            _batch(10), TopNSinkData(_no_keys(), _no_directions(), 0)
        )


def test_top_n_with_no_keys_raises_for_one_row() raises:
    with assert_raises(contains="ZERO sort keys"):
        _ = _execute_topn_sink(
            _batch(1), TopNSinkData(_no_keys(), _no_directions(), 3)
        )


def test_the_refusal_names_the_kernel() raises:
    var sort_msg = String("")
    try:
        _ = _execute_sort_sink(
            _batch(3), SortSinkData(_no_keys(), _no_directions())
        )
    except e:
        sort_msg = String(e)
    assert_true("SORT" in sort_msg, "sort refusal: " + sort_msg)
    var topn_msg = String("")
    try:
        _ = _execute_topn_sink(
            _batch(3), TopNSinkData(_no_keys(), _no_directions(), 2)
        )
    except e:
        topn_msg = String(e)
    assert_true("TOP N" in topn_msg, "top-N refusal: " + topn_msg)


def test_one_key_still_sorts() raises:
    """The refusal is about an empty list only."""
    var keys = List[String]()
    keys.append(String("a"))
    var desc = List[Bool]()
    desc.append(False)
    var rb = _execute_sort_sink(_batch(5), SortSinkData(keys^, desc^))
    assert_equal(rb.num_rows(), 5, "row count")
    assert_equal(
        Int(rb.column_as_primitive_int64(0).load[1](0)[0]), 1, "smallest first"
    )


# -----------------------------------------------------------------------------
# Tie-break rule
# -----------------------------------------------------------------------------


def _schema() raises -> Schema:
    """`[a INT64, b STRING, c INT32, d FLOAT64, e INT16, f INT64]`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.STRING, False))
    sb.add_field(Field("c", ArrowType.INT32, False))
    sb.add_field(Field("d", ArrowType.FLOAT64, False))
    sb.add_field(Field("e", ArrowType.INT16, False))
    sb.add_field(Field("f", ArrowType.INT64, False))
    return sb.build()


def _assert_keys(
    keys: List[String],
    desc: List[Bool],
    want_keys: List[String],
    want_desc: List[Bool],
    label: String,
) raises:
    assert_equal(len(keys), len(want_keys), label + ": key count")
    assert_equal(len(desc), len(want_desc), label + ": direction count")
    for i in range(len(want_keys)):
        assert_equal(keys[i], want_keys[i], label + ": key @" + String(i))
        assert_equal(
            desc[i], want_desc[i], label + ": direction @" + String(i)
        )


def test_tiebreak_appends_integer_and_float_columns_ascending() raises:
    var keys = List[String]()
    keys.append(String("c"))
    var desc = List[Bool]()
    desc.append(True)
    append_deterministic_tiebreak_schema(_schema(), keys, desc)

    var want_keys = List[String]()
    want_keys.append(String("c"))
    want_keys.append(String("a"))
    want_keys.append(String("d"))
    want_keys.append(String("f"))
    var want_desc = List[Bool]()
    want_desc.append(True)  # the caller's own key keeps its direction
    want_desc.append(False)
    want_desc.append(False)
    want_desc.append(False)
    _assert_keys(keys, desc, want_keys, want_desc, String("tiebreak after c"))


def test_tiebreak_skips_string_and_narrow_integer_columns() raises:
    var keys = List[String]()
    var desc = List[Bool]()
    append_deterministic_tiebreak_schema(_schema(), keys, desc)
    for i in range(len(keys)):
        assert_true(keys[i] != String("b"), "the STRING column was appended")
        assert_true(keys[i] != String("e"), "the INT16 column was appended")
    assert_equal(len(keys), 4, "a, c, d, f")


def test_tiebreak_does_not_repeat_a_key() raises:
    var keys = List[String]()
    keys.append(String("a"))
    keys.append(String("f"))
    var desc = List[Bool]()
    desc.append(False)
    desc.append(True)
    append_deterministic_tiebreak_schema(_schema(), keys, desc)

    var want_keys = List[String]()
    want_keys.append(String("a"))
    want_keys.append(String("f"))
    want_keys.append(String("c"))
    want_keys.append(String("d"))
    var want_desc = List[Bool]()
    want_desc.append(False)
    want_desc.append(True)
    want_desc.append(False)
    want_desc.append(False)
    _assert_keys(keys, desc, want_keys, want_desc, String("tiebreak after a, f"))


def test_tiebreak_leaves_a_string_only_remainder_untied() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.STRING, False))
    var keys = List[String]()
    keys.append(String("a"))
    var desc = List[Bool]()
    desc.append(False)
    append_deterministic_tiebreak_schema(sb.build(), keys, desc)
    assert_equal(len(keys), 1, "no column was appended")
    assert_equal(len(desc), 1, "no direction was appended")


def test_batch_form_matches_the_schema_form() raises:
    var a = PrimitiveArray[DType.int64].allocate(2)
    var b = PrimitiveArray[DType.int32].allocate(2)
    var s = List[String]()
    s.append(String("x"))
    s.append(String("y"))
    var builder = RecordBatchBuilder.with_capacity(3)
    builder.add_column(Column.from_primitive[DType.int64](a^))
    builder.add_column(Column.from_string(StringArray.from_strings(s)))
    builder.add_column(Column.from_primitive[DType.int32](b^))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("b", ArrowType.INT32, False))
    var rb = builder.build(sb.build())

    var keys = List[String]()
    keys.append(String("b"))
    var desc = List[Bool]()
    desc.append(False)
    append_deterministic_tiebreak(rb, keys, desc)
    assert_equal(len(keys), 2, "key count")
    assert_equal(keys[1], String("a"), "the INT64 column was appended")
    assert_equal(desc[1], False, "ascending")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
