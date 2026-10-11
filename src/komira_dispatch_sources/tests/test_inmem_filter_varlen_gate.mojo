# =============================================================================
# test_inmem_filter_varlen_gate.mojo -- the resident-filter fan-out's row gate
#   admits a variable-width predicate from 65,536 rows, and nothing else moved.
# =============================================================================
#
# SUBJECT: `inmem_filter_rows_admit_fanout`, the row half of the in-memory
# leaf's filter fan-out admission. The fan-out's output is the same rows in the
# same order whether it fires or not, so what this pins is who is admitted:
#   1. a STRING predicate in the band [65,536, 262,144) is admitted;
#   2. a fixed-width predicate in the same band is not (its floor is
#      unchanged);
#   3. below 65,536 nothing is admitted; at 262,144 everything is;
#   4. `varlen_on=False` restores the row-count-only gate (the A/B arm must
#      really be off, or an A/B compares on with on), and the default is on.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import Expr, BIN_GT, STR_LIKE
from komira_plan_expr.scalar_value import ScalarValue

from komira_dispatch_sources.inmem_filter_varlen_gate import (
    inmem_filter_rows_admit_fanout,
    predicate_reads_varlen_column,
    INMEM_FILTER_PARALLEL_MIN_ROWS_VARLEN,
)


comptime _FLOOR: Int = 262_144  # the in-memory leaf's fixed-width floor


def _batch(n: Int) raises -> RecordBatch:
    """`k` INT64 and `name` STRING, `n` rows."""
    var names = List[String](capacity=n)
    var keys = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        names.append(String("x"))
        keys.store[1](i, SIMD[DType.int64, 1](Int64(i)))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("name"), ArrowType.STRING, False))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](keys))
    rbb.add_column(Column.from_string(StringArray.from_strings(names)))
    return rbb.build(sb.build())


def _like_green() -> Expr:
    return Expr.string_op(
        STR_LIKE, Expr.col_ref(String("name")), String("%green%")
    )


def _k_gt() -> Expr:
    return Expr.binary(
        BIN_GT,
        Expr.col_ref(String("k")),
        Expr.literal(ScalarValue.from_int64(Int64(10))),
    )


def test_a_string_predicate_in_the_new_band_is_admitted() raises:
    var b = _batch(200_000)
    assert_true(
        predicate_reads_varlen_column(b, _like_green()),
        "LIKE over `name` reads a STRING column",
    )
    assert_true(
        inmem_filter_rows_admit_fanout(b, _like_green(), _FLOOR),
        "a 200,000-row STRING predicate is admitted",
    )


def test_a_fixed_width_predicate_keeps_its_floor() raises:
    var b = _batch(200_000)
    assert_false(
        predicate_reads_varlen_column(b, _k_gt()),
        "k > 10 reads only an INT64 column",
    )
    assert_false(
        inmem_filter_rows_admit_fanout(b, _k_gt(), _FLOOR),
        "a fixed-width predicate under 262,144 rows stays serial",
    )


def test_the_band_edges() raises:
    var below = _batch(INMEM_FILTER_PARALLEL_MIN_ROWS_VARLEN - 1)
    assert_false(
        inmem_filter_rows_admit_fanout(below, _like_green(), _FLOOR),
        "one row under the varlen floor stays serial",
    )
    var at = _batch(INMEM_FILTER_PARALLEL_MIN_ROWS_VARLEN)
    assert_true(
        inmem_filter_rows_admit_fanout(at, _like_green(), _FLOOR),
        "exactly the varlen floor is admitted",
    )
    var big = _batch(_FLOOR)
    assert_true(
        inmem_filter_rows_admit_fanout(big, _k_gt(), _FLOOR),
        "the 262,144 floor still admits any predicate",
    )


def test_the_off_flag_restores_the_row_only_gate() raises:
    var b = _batch(200_000)
    var big = _batch(_FLOOR)
    assert_false(
        inmem_filter_rows_admit_fanout(
            b, _like_green(), _FLOOR, varlen_on=False
        ),
        "varlen_on=False is the row-count-only gate: 200,000 < 262,144",
    )
    assert_true(
        inmem_filter_rows_admit_fanout(
            big, _like_green(), _FLOOR, varlen_on=False
        ),
        "varlen_on=False does not touch the 262,144 floor",
    )
    assert_true(
        inmem_filter_rows_admit_fanout(b, _like_green(), _FLOOR),
        "the default is on: admitted",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
