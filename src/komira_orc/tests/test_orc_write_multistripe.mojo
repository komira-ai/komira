# =============================================================================
# test_orc_write_multistripe.mojo — ORC writer multi-stripe emit + read-back.
# =============================================================================
#
# Acceptance: input exceeding one stripe (row_index_stride threshold) ->
# the writer emits multiple stripes -> the reader accumulates them
# across stripes into one column -> assert all rows round-trip in order. Also
# asserts the Footer records >1 stripe.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Schema, SchemaBuilder, Field

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    OrcFileTail,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)


def _build_batch(n: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("name", ArrowType.STRING, True))

    var a = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        a.set(i, Int64(i * 7 - 3))
    var ss = List[String]()
    for i in range(n):
        ss.append(String("row") + String(i))
    var s = StringArray.from_strings(ss)

    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64))
    builder.add_column(Column.from_string(s^))
    return builder.build(sb.build())


def test_orc_write_multistripe_none() raises:
    var n = 25
    var rb = _build_batch(n)
    # stride = 10 -> 25 rows => 3 stripes (10 + 10 + 5).
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 10, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)

    # OrcFileTail.parse only accepts the NONE codec (it rejects compressed
    # footers) — so the direct stripe-count assertion runs on NONE.
    var tail = OrcFileTail.parse(Span(bytes))
    assert_true(tail.num_stripes() >= 3, "NONE: >= 3 stripes")
    assert_equal(tail.num_rows(), n, "NONE: footer num_rows = 25")

    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_rows(), n, "NONE: read back 25 rows")
    var a = back.column_as_primitive_int64(0)
    var s = back.column_as_string(1)
    for i in range(n):
        assert_equal(Int(a.get(i)), i * 7 - 3, "NONE: id row " + String(i))
        assert_equal(s.get(i), String("row") + String(i), "NONE: name row " + String(i))


def test_orc_write_multistripe_zstd() raises:
    # For ZSTD, OrcFileTail.parse rejects (NONE-only); verify via read_orc_bytes.
    var n = 25
    var rb = _build_batch(n)
    var opts = OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_rows(), n, "ZSTD: read back 25 rows")
    var a = back.column_as_primitive_int64(0)
    for i in range(n):
        assert_equal(Int(a.get(i)), i * 7 - 3, "ZSTD: id row " + String(i))


def main() raises:
    test_orc_write_multistripe_none()
    test_orc_write_multistripe_zstd()
    print("test_orc_write_multistripe: ALL PASS")
