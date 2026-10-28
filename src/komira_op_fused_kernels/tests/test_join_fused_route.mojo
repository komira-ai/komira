# =============================================================================
# Which inputs the fused and chunked join kernels carry.
#
# Each predicate is checked on a column that must route to the gather
# (an offsets type, BOOL, a column holding a NULL) and on one that must not
# (fixed width and NULL-free, including a nullable field with no NULL in it).
# The NULL cases are the reason the predicates read the column and not only
# the schema: the kernels emit no validity bitmap, so a NULL cell routed to
# them would come out as the value under it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder

from komira_op_fused_kernels.join_fused_route import (
    fused_join_cannot_carry_batches,
    fused_join_cannot_carry_column,
    fused_join_cannot_carry_output,
    fused_join_cannot_carry_type,
    is_offsets_or_dictionary_type,
    require_null_free_column,
)


def _i64(n: Int, null_row: Int) -> PrimitiveArray[DType.int64]:
    """`n` values 0..n-1; row `null_row` NULL when it is in range. A
    `null_row` of -2 gives a nullable array with no NULL in it; -1 a
    non-nullable one."""
    if null_row == -1:
        var a = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            a.store[1](i, SIMD[DType.int64, 1](Int64(i)))
        return a^
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        a.store[1](i, SIMD[DType.int64, 1](Int64(i)))
    if null_row >= 0:
        a._set_null(null_row)
    return a^


def _batch(
    names: List[String], null_rows: List[Int], string_col: Int = -1
) raises -> RecordBatch:
    """INT64 columns named `names` (column `c`'s NULL row is `null_rows[c]`,
    see `_i64`), except column `string_col`, a STRING column."""
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    for c in range(len(names)):
        if c == string_col:
            sb.add_field(Field(names[c], ArrowType.STRING, False))
            var s: List[String] = ["p", "q", "r"]
            rb.add_column(Column.from_strings_promoting(s))
        else:
            sb.add_field(Field(names[c], ArrowType.INT64, null_rows[c] != -1))
            rb.add_column(Column.from_primitive[DType.int64](_i64(3, null_rows[c])))
    return rb.build(sb.build())


def test_type_predicates() raises:
    var offsets: List[ArrowType] = [
        ArrowType.STRING,
        ArrowType.BINARY,
        ArrowType.LARGE_STRING,
        ArrowType.LARGE_BINARY,
        ArrowType.DICTIONARY,
    ]
    for i in range(len(offsets)):
        assert_true(is_offsets_or_dictionary_type(offsets[i]))
        assert_true(fused_join_cannot_carry_type(offsets[i]))
    assert_false(is_offsets_or_dictionary_type(ArrowType.BOOL))
    assert_true(fused_join_cannot_carry_type(ArrowType.BOOL))
    var fixed: List[ArrowType] = [
        ArrowType.INT64,
        ArrowType.INT32,
        ArrowType.INT16,
        ArrowType.FLOAT64,
        ArrowType.DATE32,
    ]
    for i in range(len(fixed)):
        assert_false(is_offsets_or_dictionary_type(fixed[i]))
        assert_false(fused_join_cannot_carry_type(fixed[i]))


def test_column_with_a_null_cannot_be_carried() raises:
    var b = _batch(["k", "v", "w"], [-1, 1, -2])
    assert_false(fused_join_cannot_carry_column(b, 0))
    assert_true(fused_join_cannot_carry_column(b, 1))
    # Nullable, but no NULL in it: carried.
    assert_false(fused_join_cannot_carry_column(b, 2))


def test_output_question_reads_only_the_selected_columns() raises:
    var left = _batch(["id", "a", "s"], [-1, 2, -1], string_col=2)
    var right = _batch(["id", "c"], [-1, -1])
    var ok: List[String] = ["id", "c", "id_right"]
    assert_false(fused_join_cannot_carry_output(left, right, ok))
    var with_null: List[String] = ["c", "a"]
    assert_true(fused_join_cannot_carry_output(left, right, with_null))
    var with_string: List[String] = ["s"]
    assert_true(fused_join_cannot_carry_output(left, right, with_string))


def test_output_question_resolves_right_suffix_to_the_right_side() raises:
    """`id_right` names the right side's `id`; only that one holds a NULL."""
    var left = _batch(["id"], [-1])
    var right = _batch(["id"], [0])
    var left_id: List[String] = ["id"]
    assert_false(fused_join_cannot_carry_output(left, right, left_id))
    var right_id: List[String] = ["id_right"]
    assert_true(fused_join_cannot_carry_output(left, right, right_id))
    var unknown: List[String] = ["nope"]
    var raised = False
    try:
        _ = fused_join_cannot_carry_output(left, right, unknown)
    except:
        raised = True
    assert_true(raised)


def test_batches_question_reads_every_column() raises:
    var clean = _batch(["a", "b"], [-1, -2])
    assert_false(fused_join_cannot_carry_batches(clean, clean))
    var right_null = _batch(["c", "d"], [-1, 0])
    assert_true(fused_join_cannot_carry_batches(clean, right_null))
    assert_true(fused_join_cannot_carry_batches(right_null, clean))
    var string_left = _batch(["a", "s"], [-1, -1], string_col=1)
    assert_true(fused_join_cannot_carry_batches(string_left, clean))


def test_require_null_free_column_names_the_column() raises:
    var b = _batch(["k", "v"], [-1, 2])
    require_null_free_column(b, 0, "kernel_x")
    var raised = False
    try:
        require_null_free_column(b, 1, "kernel_x")
    except e:
        raised = True
        var msg = String(e)
        assert_true("kernel_x" in msg, msg)
        assert_true("'v'" in msg, msg)
        assert_true("1 NULL" in msg, msg)
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
