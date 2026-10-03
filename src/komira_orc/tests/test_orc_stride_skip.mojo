# =============================================================================
# test_orc_stride_skip.mojo — ORC row-index stride decode + skip.
# =============================================================================
#
# Acceptance:
#   - Stride-skip count > 0 on a selective range predicate
#     (`col >= lo AND col < hi`).
#   - Correctness: the surviving rows are byte-equal to a full-scan reference
#     read of the same file (no over- or under-production / no false-skip).
#
# Fixture is self-emitted via the writer with ROW_INDEX emission
# turned ON and a multi-stride stripe (stripe_size_rows > row_index_stride):
# 30 rows in ONE stripe, 3 strides of 10 rows each. A monotone int column means
# each stride's [min,max] is disjoint from the others, so a 1-stride-wide range
# predicate skips exactly 2 of 3 strides.
#
# This test FAILS without stride skip (read_orc_bytes_filtered + ROW_INDEX
# emission).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Schema, SchemaBuilder, Field

from komira_core.plan.expr import (
    Expr,
    BIN_AND,
    BIN_GE,
    BIN_LT,
)
from komira_core.plan.scalar_value import ScalarValue

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    read_orc_bytes_filtered,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)


def _build_batch(n: Int) raises -> RecordBatch:
    """A monotone int64 column `key` (= row index) + a payload `name`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, True))
    sb.add_field(Field("name", ArrowType.STRING, True))

    var a = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        a.set(i, Int64(i))
    var ss = List[String]()
    for i in range(n):
        ss.append(String("row") + String(i))
    var s = StringArray.from_strings(ss)

    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64)
    )
    builder.add_column(Column.from_string(s^))
    return builder.build(sb.build())


def _range_predicate(col: String, lo: Int64, hi: Int64) raises -> Expr:
    """`col >= lo AND col < hi` (half-open, Q6-shaped)."""
    var ge = Expr.binary(
        BIN_GE,
        Expr.col_ref(col),
        Expr.literal(ScalarValue.from_int64(lo)),
    )
    var lt = Expr.binary(
        BIN_LT,
        Expr.col_ref(col),
        Expr.literal(ScalarValue.from_int64(hi)),
    )
    return Expr.binary(BIN_AND, ge^, lt^)


def _run_for_codec(codec: Int, label: String) raises:
    var n = 30
    var rb = _build_batch(n)
    # One stripe of 30 rows, 3 strides of 10. emit_row_index=True.
    var opts = OrcWriterOptions.with_stride(codec, 10, 30, True)
    var bytes = write_orc_bytes(rb, opts)

    # Full-scan reference (no predicate). 30 rows.
    var full = read_orc_bytes(Span(bytes))
    assert_equal(full.num_rows(), n, label + ": full-scan 30 rows")

    # Selective range that lands ENTIRELY in stride 2 (rows 20..29):
    #   key >= 20 AND key < 30.
    var pred = _range_predicate(String("key"), Int64(20), Int64(30))
    var res = read_orc_bytes_filtered(Span(bytes), pred)

    # Acceptance gate 1: stride-skip count > 0 (strides 0 and 1 skipped).
    assert_equal(res.strides_total, 3, label + ": 3 strides total")
    assert_true(
        res.strides_skipped >= 2,
        label + ": >= 2 strides skipped (got " + String(res.strides_skipped) + ")",
    )

    # Acceptance gate 2: surviving rows == full-scan rows matching the predicate.
    var fa = full.column_as_primitive_int64(0)
    var fs = full.column_as_string(1)
    var ref_keys = List[Int64]()
    var ref_names = List[String]()
    for i in range(full.num_rows()):
        var k = fa.get(i)
        if k >= 20 and k < 30:
            ref_keys.append(k)
            ref_names.append(fs.get(i))

    assert_equal(
        res.batch.num_rows(),
        len(ref_keys),
        label + ": filtered row count matches reference",
    )
    var ra = res.batch.column_as_primitive_int64(0)
    var rn = res.batch.column_as_string(1)
    for i in range(res.batch.num_rows()):
        assert_equal(
            Int(ra.get(i)), Int(ref_keys[i]), label + ": key row " + String(i)
        )
        assert_equal(
            rn.get(i), ref_names[i], label + ": name row " + String(i)
        )


def test_orc_stride_skip_none() raises:
    _run_for_codec(ORC_COMPRESSION_NONE, String("NONE"))


def test_orc_stride_skip_zstd() raises:
    _run_for_codec(ORC_COMPRESSION_ZSTD, String("ZSTD"))


def test_orc_stride_skip_no_prune_when_all_match() raises:
    """A predicate that every stride satisfies => 0 strides skipped, all rows."""
    var n = 30
    var rb = _build_batch(n)
    var opts = OrcWriterOptions.with_stride(ORC_COMPRESSION_NONE, 10, 30, True)
    var bytes = write_orc_bytes(rb, opts)
    # key >= 0 AND key < 1000 — covers every stride.
    var pred = _range_predicate(String("key"), Int64(0), Int64(1000))
    var res = read_orc_bytes_filtered(Span(bytes), pred)
    assert_equal(res.strides_skipped, 0, "all-match: 0 strides skipped")
    assert_equal(res.batch.num_rows(), n, "all-match: all 30 rows survive")


def main() raises:
    test_orc_stride_skip_none()
    test_orc_stride_skip_zstd()
    test_orc_stride_skip_no_prune_when_all_match()
    print("test_orc_stride_skip: ALL PASS")
