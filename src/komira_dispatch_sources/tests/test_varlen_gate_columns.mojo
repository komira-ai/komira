# =============================================================================
# test_varlen_gate_columns.mojo -- `predicate_reads_varlen_column` over the
#   columns a predicate names.
# =============================================================================
#
# SUBJECT: which column references make a predicate variable-width.
#   1. a name the batch does not carry is skipped, not an error, and does not
#      count as variable-width;
#   2. a predicate over a fixed-width column and a string column together is
#      variable-width;
#   3. a predicate with no column reference is not;
#   4. each of STRING, LARGE_STRING, BINARY and LARGE_BINARY makes a predicate
#      variable-width, and a fixed-width column beside them does not.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_arrow.binary_array import BinaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.large_binary_array import LargeBinaryArray
from komira_plan_expr.expr import Expr, BIN_AND, BIN_GT, STR_LIKE
from komira_plan_expr.scalar_value import ScalarValue

from komira_dispatch_sources.inmem_filter_varlen_gate import (
    inmem_filter_rows_admit_fanout,
    predicate_reads_varlen_column,
)


def _batch() raises -> RecordBatch:
    var keys = PrimitiveArray[DType.int64].allocate(2)
    keys.store[1](0, SIMD[DType.int64, 1](Int64(1)))
    keys.store[1](1, SIMD[DType.int64, 1](Int64(2)))
    var names: List[String] = [String("a"), String("b")]
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("name"), ArrowType.STRING, False))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](keys))
    rbb.add_column(Column.from_string(StringArray.from_strings(names)))
    return rbb.build(sb.build())


def _gt(col: String) -> Expr:
    return Expr.binary(
        BIN_GT,
        Expr.col_ref(col),
        Expr.literal(ScalarValue.from_int64(Int64(0))),
    )


def test_an_unknown_column_is_skipped() raises:
    var b = _batch()
    assert_false(predicate_reads_varlen_column(b, _gt(String("missing"))))
    assert_true(
        predicate_reads_varlen_column(
            b,
            Expr.binary(
                BIN_AND,
                _gt(String("missing")),
                Expr.string_op(STR_LIKE, Expr.col_ref(String("name")), "%a%"),
            ),
        ),
        "the string column still counts beside an unknown one",
    )


def test_mixed_columns_are_variable_width() raises:
    var b = _batch()
    var pred = Expr.binary(
        BIN_AND,
        _gt(String("k")),
        Expr.string_op(STR_LIKE, Expr.col_ref(String("name")), "%a%"),
    )
    assert_true(predicate_reads_varlen_column(b, pred))


def test_no_column_reference_is_fixed_width() raises:
    var b = _batch()
    var lit = Expr.literal(ScalarValue.from_bool(True))
    assert_false(predicate_reads_varlen_column(b, lit))
    assert_false(
        inmem_filter_rows_admit_fanout(b, lit, 1_000_000),
        "two rows are below every floor",
    )


def _all_types_batch() raises -> RecordBatch:
    var keys = PrimitiveArray[DType.int64].allocate(2)
    keys.store[1](0, SIMD[DType.int64, 1](Int64(1)))
    keys.store[1](1, SIMD[DType.int64, 1](Int64(2)))
    var names: List[String] = [String("a"), String("b")]
    var one: List[UInt8] = [UInt8(1)]
    var two: List[UInt8] = [UInt8(2)]
    var bytes: List[List[UInt8]] = [one^, two^]
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    sb.add_field(Field(String("ls"), ArrowType.LARGE_STRING, False))
    sb.add_field(Field(String("b"), ArrowType.BINARY, False))
    sb.add_field(Field(String("lb"), ArrowType.LARGE_BINARY, False))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](keys))
    rbb.add_column(Column.from_string(StringArray.from_strings(names)))
    rbb.add_column(
        Column.from_large_string(LargeStringArray.from_strings(names))
    )
    rbb.add_column(Column.from_binary(BinaryArray.from_bytes_list(bytes)))
    rbb.add_column(
        Column.from_large_binary(LargeBinaryArray.from_bytes_list(bytes))
    )
    return rbb.build(sb.build())


def test_every_variable_width_type_counts() raises:
    var b = _all_types_batch()
    assert_false(predicate_reads_varlen_column(b, _gt(String("k"))))
    assert_true(predicate_reads_varlen_column(b, _gt(String("s"))), "STRING")
    assert_true(
        predicate_reads_varlen_column(b, _gt(String("ls"))), "LARGE_STRING"
    )
    assert_true(predicate_reads_varlen_column(b, _gt(String("b"))), "BINARY")
    assert_true(
        predicate_reads_varlen_column(b, _gt(String("lb"))), "LARGE_BINARY"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
