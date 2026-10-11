# =============================================================================
# test_native_spill_writer_reader.mojo — Native spill writer/reader round-trip.
# =============================================================================
#
# The thin `NativeColumnSpillWriter`/Reader (THSPLC)
# and `NativeRowSpillWriter`/Reader (THSPILL2) layer over the `SpillStorage`
# substrate. These tests write batches/blocks to a real on-disk spill run via
# the writer, re-open the run via the reader, and assert byte-for-byte logical
# round-trip — INCLUDING the multi-batch-per-run shape the external-sort
# run-merge needs.
# =============================================================================

from std.time import perf_counter_ns

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_engine_runtime.spill.native_spill import (
    NativeColumnSpillWriter,
    NativeColumnSpillReader,
    NativeRowSpillWriter,
    NativeRowSpillReader,
    NativeRowBlock,
)
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# Scratch files go under $TEST_TMPDIR (set by the test runner, unique per
# action), else $TMPDIR; a fixed path would be shared by concurrent runs of
# this test. `_read_env` rather than `std.os.getenv`: komira_libc.posix owns
# the one `getenv` declaration in the link.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


# =============================================================================
# Helpers
# =============================================================================


def _i64_list(*vals: Int) -> List[Scalar[DType.int64]]:
    var out = List[Scalar[DType.int64]]()
    for v in vals:
        out.append(Int64(v))
    return out^


def _str_list(*vals: String) -> List[String]:
    var out = List[String]()
    for v in vals:
        out.append(v)
    return out^


def _int64_schema(name0: String, name1: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.INT64, False))
    sb.add_field(Field(name1, ArrowType.INT64, False))
    return sb.build()


def _mixed_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, False))
    return sb.build()


def _i64_batch(
    c0: List[Scalar[DType.int64]], c1: List[Scalar[DType.int64]]
) raises -> RecordBatch:
    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(c0)
        )
    )
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(c1)
        )
    )
    return RecordBatch.from_typed_columns_slab(_int64_schema("a", "b"), cols^)


def _mixed_batch(
    keys: List[Scalar[DType.int64]], names: List[String]
) raises -> RecordBatch:
    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(keys)
        )
    )
    cols.append(Column.from_string(StringArray.from_strings(names)))
    return RecordBatch.from_typed_columns_slab(_mixed_schema(), cols^)


def _tmp_dir(tag: String) raises -> String:
    return (_scratch_dir() + String("/komira_native_spill_test_")) + tag + String("_") + String(
        Int(perf_counter_ns())
    )


# =============================================================================
# (a) Column writer/reader — single batch round-trip.
# =============================================================================


def test_column_single_batch_roundtrip() raises:
    var dir = _tmp_dir("col1")
    var c0 = _i64_list(1, 2, 3, 4, 5)
    var c1 = _i64_list(-10, 20, -30, 40, -50)

    var w = NativeColumnSpillWriter.create(dir, 0)
    w.write_batch(_i64_batch(c0, c1))
    var n = w.num_batches()
    var root = w.root()
    w.close()

    assert_equal(n, 1)

    var r = NativeColumnSpillReader.open(root, n)
    assert_equal(r.count_batches(), 1)
    var b = r.read_batch(0, _int64_schema("a", "b"))
    assert_equal(b.num_rows(), 5)
    assert_equal(b.num_columns(), 2)
    for i in range(5):
        assert_equal(b.column_as_primitive_int64(0).get(i), c0[i])
        assert_equal(b.column_as_primitive_int64(1).get(i), c1[i])
    r.cleanup()


# =============================================================================
# (b) Column writer/reader — MULTI batch per run (run-merge shape).
# =============================================================================


def test_column_multi_batch_roundtrip() raises:
    var dir = _tmp_dir("colN")

    var b0c0 = _i64_list(1, 2, 3)
    var b0c1 = _i64_list(10, 20, 30)
    var b1c0 = _i64_list(4, 5)
    var b1c1 = _i64_list(40, 50)
    var b2c0 = _i64_list(6, 7, 8, 9)
    var b2c1 = _i64_list(60, 70, 80, 90)

    var w = NativeColumnSpillWriter.create(dir, 7)
    w.write_batch(_i64_batch(b0c0, b0c1))
    w.write_batch(_i64_batch(b1c0, b1c1))
    w.write_batch(_i64_batch(b2c0, b2c1))
    var n = w.num_batches()
    var root = w.root()
    w.close()

    assert_equal(n, 3)

    var r = NativeColumnSpillReader.open(root, n)
    assert_equal(r.count_batches(), 3)

    # Batch 0
    var x0 = r.read_batch(0, _int64_schema("a", "b"))
    assert_equal(x0.num_rows(), 3)
    for i in range(3):
        assert_equal(x0.column_as_primitive_int64(0).get(i), b0c0[i])
        assert_equal(x0.column_as_primitive_int64(1).get(i), b0c1[i])
    # Batch 1
    var x1 = r.read_batch(1, _int64_schema("a", "b"))
    assert_equal(x1.num_rows(), 2)
    for i in range(2):
        assert_equal(x1.column_as_primitive_int64(0).get(i), b1c0[i])
        assert_equal(x1.column_as_primitive_int64(1).get(i), b1c1[i])
    # Batch 2
    var x2 = r.read_batch(2, _int64_schema("a", "b"))
    assert_equal(x2.num_rows(), 4)
    for i in range(4):
        assert_equal(x2.column_as_primitive_int64(0).get(i), b2c0[i])
        assert_equal(x2.column_as_primitive_int64(1).get(i), b2c1[i])

    r.cleanup()


# =============================================================================
# (c) Column writer/reader — mixed int + string columns.
# =============================================================================


def test_column_mixed_roundtrip() raises:
    var dir = _tmp_dir("colmix")
    var keys = _i64_list(100, 200, 300)
    var names = _str_list("alpha", "", "delta-long-value")

    var w = NativeColumnSpillWriter.create(dir, 0)
    w.write_batch(_mixed_batch(keys, names))
    var n = w.num_batches()
    var root = w.root()
    w.close()

    var r = NativeColumnSpillReader.open(root, n)
    var b = r.read_batch(0, _mixed_schema())
    assert_equal(b.num_rows(), 3)
    for i in range(3):
        assert_equal(b.column_as_primitive_int64(0).get(i), keys[i])
        assert_equal(b.column_as_string(1).get(i), names[i])
    r.cleanup()


# =============================================================================
# (d) Row writer/reader — THSPILL2 fixed-stride body round-trip.
# =============================================================================


def _row_block(stride: Int, n_rows: Int, fill_base: Int) raises -> NativeRowBlock:
    """Build a NativeRowBlock with a deterministic byte pattern."""
    var body_len = stride * n_rows
    var oab = OwnedAlignedBuffer(capacity=max(body_len, 1))
    oab.set_length(Int64(body_len))
    for i in range(body_len):
        oab.write_u8_at(i, UInt8((fill_base + i) & 0xFF))
    var sab = SharedAlignedBuffer[HeapRegion].from_owned(oab^)
    return NativeRowBlock(sab^, Int64(n_rows), UInt64(0xABCDEF))


def test_row_block_roundtrip() raises:
    var dir = _tmp_dir("row")
    var stride = 24
    var n_rows = 5

    var w = NativeRowSpillWriter.create(dir, 0)
    w.write_block(_row_block(stride, n_rows, 0))
    var n = w.num_blocks()
    var root = w.root()
    w.close()

    assert_equal(n, 1)

    var r = NativeRowSpillReader.open(root, n)
    assert_equal(r.count_blocks(), 1)
    var blk = r.read_block(0)
    assert_equal(Int(blk.row_count()), n_rows)
    assert_equal(blk.entry_stride(), stride)
    assert_equal(blk.schema_fingerprint(), UInt64(0xABCDEF))
    var bv = blk.byte_view()
    for i in range(stride * n_rows):
        assert_equal(Int(bv.read_u8_at(i)), (0 + i) & 0xFF)
    r.cleanup()


def test_row_multi_block_roundtrip() raises:
    var dir = _tmp_dir("rowN")
    var stride = 16

    var w = NativeRowSpillWriter.create(dir, 3)
    w.write_block(_row_block(stride, 3, 0))
    w.write_block(_row_block(stride, 7, 100))
    var n = w.num_blocks()
    var root = w.root()
    w.close()

    assert_equal(n, 2)

    var r = NativeRowSpillReader.open(root, n)
    var b0 = r.read_block(0)
    assert_equal(Int(b0.row_count()), 3)
    var bv0 = b0.byte_view()
    for i in range(stride * 3):
        assert_equal(Int(bv0.read_u8_at(i)), (0 + i) & 0xFF)

    var b1 = r.read_block(1)
    assert_equal(Int(b1.row_count()), 7)
    var bv1 = b1.byte_view()
    for i in range(stride * 7):
        assert_equal(Int(bv1.read_u8_at(i)), (100 + i) & 0xFF)

    r.cleanup()


# =============================================================================
# main
# =============================================================================


def main() raises:
    test_column_single_batch_roundtrip()
    test_column_multi_batch_roundtrip()
    test_column_mixed_roundtrip()
    test_row_block_roundtrip()
    test_row_multi_block_roundtrip()
    print("test_native_spill_writer_reader: ALL PASS")
