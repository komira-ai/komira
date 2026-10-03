# =============================================================================
# _concat_variable_width_batches -- multi-way fast path unit tests
# =============================================================================
#
# Validates the single-pass multi-way variable-width concat in
# arrow_helpers/streaming_concat.mojo. Targets:
#
#   * STRING-only: concat 4 batches of 250 rows -> 1000 rows, payload
#     bytes match expected, offsets monotonic & match per-batch slices.
#   * STRING + FLOAT64: mixed fixed + variable widths in the same batch.
#   * None slots: empty Optional[RecordBatch] slots in the middle of
#     the staging buffer are skipped.
#   * Empty input: returns an empty RecordBatch.
#
# A pairwise fold would be O(N^2) over payload bytes. These tests do NOT
# measure perf; they guard correctness of the single-pass fast path.
# =============================================================================

from std.memory import alloc, UnsafePointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import (
    Field,
    RecordBatch,
    Schema,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_arrow.streaming_concat import _concat_variable_width_batches


def _make_strings(start: Int, n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        var k = start + i
        if k % 5 == 0:
            out.append(String(""))
        else:
            out.append(String("v") + String(k) + String("_abc"))
    return out^


def _string_batch(start: Int, n: Int) raises -> RecordBatch:
    var vals = _make_strings(start, n)
    var col = Column.from_string(StringArray.from_strings(vals)^)
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    return RecordBatch.from_typed_columns_1(sb.build()^, col^)


def _string_f64_batch(start: Int, n: Int) raises -> RecordBatch:
    # STRING column.
    var svals = _make_strings(start, n)
    var scol = Column.from_string(StringArray.from_strings(svals)^)

    # FLOAT64 column -- values start + 0.5 ... start + n - 0.5.
    comptime width = 8
    var buf = OwnedAlignedBuffer(max(n * width, 1))
    var ptr = buf.view_typed_ro[DType.float64]()
    for i in range(n):
        ptr[i] = Float64(start + i) + 0.5
    buf.set_length(Int64(n * width))

    var fcol = Column(
        arrow_type=ArrowType.FLOAT64,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )

    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    return RecordBatch.from_typed_columns_2(sb.build()^, scol^, fcol^)


def test_multi_way_string_concat() raises:
    """Concat 4 STRING batches of 250 rows -> 1000 rows, row-by-row."""
    var b0 = _string_batch(0, 250)
    var b1 = _string_batch(250, 250)
    var b2 = _string_batch(500, 250)
    var b3 = _string_batch(750, 250)

    var staging = alloc[Optional[RecordBatch]](4)
    (staging + 0).unsafe_write(Optional[RecordBatch](b0^))
    (staging + 1).unsafe_write(Optional[RecordBatch](b1^))
    (staging + 2).unsafe_write(Optional[RecordBatch](b2^))
    (staging + 3).unsafe_write(Optional[RecordBatch](b3^))

    var out = _concat_variable_width_batches(staging, 4)
    staging.free()

    assert_equal(out.num_rows(), 1000, "concat of 4x250 -> 1000 rows")
    assert_equal(out.num_columns(), 1, "one column")

    # Row-by-row comparison against reconstructed expected.
    var expected = _make_strings(0, 1000)
    ref col_ref = out.column_at(0)
    var sa = col_ref.as_string()
    for i in range(1000):
        var got = sa.get(i)
        var want = expected[i]
        if String(got) != want:
            raise Error(
                "mismatch row=" + String(i)
                + " got='" + String(got)
                + "' want='" + want + "'"
            )


def test_multi_way_mixed_string_f64() raises:
    """STRING + FLOAT64 concat of 3 batches of 100 rows."""
    var b0 = _string_f64_batch(0, 100)
    var b1 = _string_f64_batch(100, 100)
    var b2 = _string_f64_batch(200, 100)

    var staging = alloc[Optional[RecordBatch]](3)
    (staging + 0).unsafe_write(Optional[RecordBatch](b0^))
    (staging + 1).unsafe_write(Optional[RecordBatch](b1^))
    (staging + 2).unsafe_write(Optional[RecordBatch](b2^))

    var out = _concat_variable_width_batches(staging, 3)
    staging.free()

    assert_equal(out.num_rows(), 300, "concat of 3x100 -> 300")
    assert_equal(out.num_columns(), 2, "two columns")

    # STRING column.
    var expected_s = _make_strings(0, 300)
    ref col_s = out.column_at(0)
    var sa = col_s.as_string()
    for i in range(300):
        var got = sa.get(i)
        var want = expected_s[i]
        if String(got) != want:
            raise Error(
                "string mismatch row=" + String(i)
                + " got='" + String(got)
                + "' want='" + want + "'"
            )

    # FLOAT64 column.
    ref col_f = out.column_at(1)
    var fa = col_f.as_primitive[DType.float64]()
    var ptr = fa.data.view_typed_ro[DType.float64]()
    for i in range(300):
        var got = ptr[fa.offset + i]
        var want = Float64(i) + 0.5
        if got != want:
            raise Error(
                "f64 mismatch row=" + String(i)
                + " got=" + String(got) + " want=" + String(want)
            )


def test_multi_way_skips_none_slots() raises:
    """Middle slot = None -> concat skips it."""
    var b0 = _string_batch(0, 50)
    var b2 = _string_batch(50, 50)

    var staging = alloc[Optional[RecordBatch]](3)
    (staging + 0).unsafe_write(Optional[RecordBatch](b0^))
    (staging + 1).unsafe_write(Optional[RecordBatch](None))
    (staging + 2).unsafe_write(Optional[RecordBatch](b2^))

    var out = _concat_variable_width_batches(staging, 3)
    staging.free()

    assert_equal(out.num_rows(), 100, "50 + 0 + 50 = 100 rows")
    var expected = _make_strings(0, 100)
    ref col_ref = out.column_at(0)
    var sa = col_ref.as_string()
    for i in range(100):
        if String(sa.get(i)) != expected[i]:
            raise Error("None-skip mismatch at row " + String(i))


def test_multi_way_all_empty() raises:
    """All slots None -> empty RecordBatch."""
    var staging = alloc[Optional[RecordBatch]](2)
    (staging + 0).unsafe_write(Optional[RecordBatch](None))
    (staging + 1).unsafe_write(Optional[RecordBatch](None))
    var out = _concat_variable_width_batches(staging, 2)
    staging.free()
    assert_equal(out.num_rows(), 0, "empty -> 0 rows")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
