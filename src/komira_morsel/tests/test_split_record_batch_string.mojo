# =============================================================================
# split_record_batch STRING-aware slicing (Phase 1f.4) -- unit test
# =============================================================================
#
# Validates `split_record_batch` + `_slice_variable_width` correctly slice
# STRING columns. Before 1f.4, split_record_batch fell through to the
# 8-byte fixed-width path for STRING / BINARY, which memcpy'd the wrong
# bytes and left offsets un-rebased -- corrupting the output on any source
# with variable-width columns (lineitem, F-4 string-eq filter, etc).
#
# Two schemas are exercised:
#   schema1: STRING only
#   schema2: STRING + INT64 + STRING (mixed, to stress ordering + offsets)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    Schema,
    SchemaBuilder,
)
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.bitmap import Bitmap
from komira_morsel.morsel import MorselArray, split_record_batch
from komira_core.io.heap_region import HeapRegion


def _make_strings(n: Int) -> List[String]:
    """Deterministic list of `n` strings of varying length incl. empties."""
    var out = List[String]()
    for i in range(n):
        if i % 7 == 0:
            out.append(String(""))
        elif i % 3 == 0:
            out.append(String("row_") + String(i) + String("_payload"))
        else:
            out.append(String("v") + String(i))
    return out^


def _make_ints(n: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(n):
        out.append(Int64(i * 7 + 3))
    return out^


def _make_int64_column(values: List[Int64]) raises -> Column[HeapRegion]:
    comptime elem_size = 8
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * elem_size, 1))
    var ptr = buf.view_typed_ro[DType.int64]()
    for i in range(n):
        ptr[i] = values[i]
    buf.set_length(Int64(n * elem_size))

    return Column[HeapRegion](
        arrow_type=ArrowType.INT64,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _verify_string_column_matches(
    ma: MorselArray, col_idx: Int, expected: List[String]
) raises:
    """Walk each morsel's column at `col_idx` and confirm string-by-string
    equality with `expected`."""
    var cursor = 0
    var total = 0
    for m in range(len(ma)):
        total += ma[m].num_rows()
    assert_equal(total, len(expected), "total row count after split")

    for m in range(len(ma)):
        var nrows = ma[m].num_rows()
        if nrows == 0:
            continue
        ref col_ref = ma[m].column_at(col_idx)
        var sa = col_ref.as_string()
        for i in range(nrows):
            var got = sa.get(i)
            var want = expected[cursor + i]
            if String(got) != want:
                raise Error(
                    "mismatch morsel=" + String(m) + " row=" + String(i)
                    + " got='" + String(got) + "' want='" + want + "'"
                )
        cursor += nrows
    assert_equal(cursor, len(expected), "cursor advanced == expected len")


def _verify_int64_column_matches(
    ma: MorselArray, col_idx: Int, expected: List[Int64]
) raises:
    var cursor = 0
    for m in range(len(ma)):
        var nrows = ma[m].num_rows()
        if nrows == 0:
            continue
        ref col_ref = ma[m].column_at(col_idx)
        var arr = col_ref.as_primitive[DType.int64]()
        var data_ptr = arr.data.view_typed_ro[DType.int64]()
        for i in range(nrows):
            var got = Int64(data_ptr[arr.offset + i])
            var want = expected[cursor + i]
            if got != want:
                raise Error(
                    "int64 mismatch m=" + String(m) + " i=" + String(i)
                    + " got=" + String(Int(got))
                    + " want=" + String(Int(want))
                )
        cursor += nrows
    assert_equal(cursor, len(expected), "int64 cursor advanced")


def test_string_only_split_exact_boundary() raises:
    """Split 1000 rows of STRING into 4 sub-batches of 250 each."""
    var vals = _make_strings(1000)
    var col = Column.from_string(StringArray.from_strings(vals)^)
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var schema = sb.build()
    var batch = RecordBatch.from_typed_columns_1(schema^, col^)

    var ma = split_record_batch(batch^, 250)
    assert_equal(len(ma), 4, "4 morsels of 250")
    for m in range(len(ma)):
        assert_equal(ma[m].num_rows(), 250, "each morsel has 250 rows")
    _verify_string_column_matches(ma, 0, vals)


def test_string_only_split_uneven() raises:
    """300 rows into morsels of 128 -> [128, 128, 44]."""
    var vals = _make_strings(300)
    var col = Column.from_string(StringArray.from_strings(vals)^)
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var schema = sb.build()
    var batch = RecordBatch.from_typed_columns_1(schema^, col^)

    var ma = split_record_batch(batch^, 128)
    assert_equal(len(ma), 3, "3 uneven morsels")
    assert_equal(ma[0].num_rows(), 128, "m0 == 128")
    assert_equal(ma[1].num_rows(), 128, "m1 == 128")
    assert_equal(ma[2].num_rows(), 44, "m2 == 44")
    _verify_string_column_matches(ma, 0, vals)


def test_string_mixed_schema_split() raises:
    """STRING + INT64 + STRING, 500 rows split into morsels of 100."""
    var n = 500
    var s0 = _make_strings(n)
    var ints = _make_ints(n)
    var s1 = List[String]()
    for i in range(n):
        s1.append(String("tail_") + String(i))

    var col0 = Column.from_string(StringArray.from_strings(s0)^)
    var col1 = _make_int64_column(ints)
    var col2 = Column.from_string(StringArray.from_strings(s1)^)

    var sb = SchemaBuilder()
    sb.add_field(Field("s0", ArrowType.STRING, False))
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("s1", ArrowType.STRING, False))
    var schema = sb.build()
    var batch = RecordBatch.from_typed_columns_3(schema^, col0^, col1^, col2^)

    var ma = split_record_batch(batch^, 100)
    assert_equal(len(ma), 5, "5 morsels")
    _verify_string_column_matches(ma, 0, s0)
    _verify_int64_column_matches(ma, 1, ints)
    _verify_string_column_matches(ma, 2, s1)


def test_string_single_morsel() raises:
    """morsel_size >= total_rows -> 1 morsel, entire batch intact."""
    var vals = _make_strings(64)
    var col = Column.from_string(StringArray.from_strings(vals)^)
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var schema = sb.build()
    var batch = RecordBatch.from_typed_columns_1(schema^, col^)

    var ma = split_record_batch(batch^, 1024)
    assert_equal(len(ma), 1, "single morsel")
    assert_equal(ma[0].num_rows(), 64, "all rows in one morsel")
    _verify_string_column_matches(ma, 0, vals)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
