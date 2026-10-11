# =============================================================================
# Row / GroupRef / GroupColumn -- the pointer-free public API
# =============================================================================
#
# These three views used to hold an `UnsafePointer[Column, MutUntrackedOrigin]`
# and took one in their public constructors. They now borrow the parent batch
# as a `Pointer[RecordBatch, origin]` whose origin is the batch's own, and are
# built from the batch itself. This file drives them through that API only:
# no `_columns_ptr()`, no pointer of any kind in the test.
#
# What it pins:
#   * values read through each accessor are the batch's values, row by row, so
#     a view that resolves the wrong column or the wrong row is red;
#   * the column NAME lookup resolves to the column index the view then reads
#     (the second column is not the first);
#   * the views read the batch where it LIVES: the batch is built by a helper
#     and moved into the caller, so a view bound to a dead temporary reads
#     garbage here;
#   * the type-mismatch and unknown-column paths still raise;
#   * accessed-column tracking is per view;
#   * a user trait that spells the parameter as a bare `Row` / `GroupRef`
#     (the downstream operator packages do) is satisfiable.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_buffer.heap_region import HeapRegion

from komira_engine_runtime.group_ref import GroupColumn, GroupRef
from komira_engine_runtime.row import Row


def _make_batch(n: Int) raises -> RecordBatch:
    """Columns 'a' (int64, a[i] = i) and 'b' (float64, b[i] = 10 * i + 0.5)."""
    comptime i64_size = size_of[Scalar[DType.int64]]()
    comptime f64_size = size_of[Scalar[DType.float64]]()

    var buf_a = OwnedAlignedBuffer(max(n * i64_size, 1))
    var ptr_a = buf_a.view_typed_mut[DType.int64]()
    for i in range(n):
        (ptr_a + i).unsafe_write(Scalar[DType.int64](i))
    buf_a.set_length(Int64(n * i64_size))
    var arr_a = PrimitiveArray[DType.int64](
        buf_a^, n, Optional[Bitmap[HeapRegion]](None), 0, 0
    )
    var col_a = Column.from_primitive[DType.int64](arr_a)

    var buf_b = OwnedAlignedBuffer(max(n * f64_size, 1))
    var ptr_b = buf_b.view_typed_mut[DType.float64]()
    for i in range(n):
        (ptr_b + i).unsafe_write(Scalar[DType.float64](Float64(10 * i) + 0.5))
    buf_b.set_length(Int64(n * f64_size))
    var arr_b = PrimitiveArray[DType.float64](
        buf_b^, n, Optional[Bitmap[HeapRegion]](None), 0, 0
    )
    var col_b = Column.from_primitive[DType.float64](arr_b)

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.FLOAT64, False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col_a^)
    builder.add_column(col_b^)
    return builder.build(schema^)


def _names(batch: RecordBatch) -> List[String]:
    var names = List[String]()
    for i in range(batch.num_columns()):
        names.append(batch.schema.field_name(i))
    return names^


def test_row_reads_every_row_by_name() raises:
    var batch = _make_batch(64)
    var names = _names(batch)
    for i in range(64):
        var row = Row(batch, names, i)
        assert_equal(Int(row.get_i64("a")), i)
        assert_equal(row.get_f64("b"), Float64(10 * i) + 0.5)
        assert_equal(row.row_index(), i)


def test_row_factory_matches_constructor() raises:
    var batch = _make_batch(8)
    var names = _names(batch)
    var row = Row.from_batch_with_names(batch, names, 5)
    assert_equal(Int(row.get_i64("a")), 5)
    assert_equal(row.get_f64("b"), 50.5)


def test_row_copy_reads_same_row() raises:
    var batch = _make_batch(8)
    var names = _names(batch)
    var row = Row(batch, names, 3)
    var copy = row.copy()
    assert_equal(Int(copy.get_i64("a")), 3)
    assert_equal(Int(row.get_i64("a")), 3)


def test_row_unknown_column_raises() raises:
    var batch = _make_batch(4)
    var names = _names(batch)
    var row = Row(batch, names, 0)
    var raised = False
    try:
        _ = row.get_i64("nope")
    except:
        raised = True
    assert_true(raised)


def test_row_tracks_accessed_columns_per_view() raises:
    var batch = _make_batch(4)
    var names = _names(batch)
    var r0 = Row(batch, names, 0)
    var r1 = Row(batch, names, 1)
    _ = r0.get_i64("a")
    _ = r1.get_f64("b")
    var c0 = r0.accessed_column_names()
    var c1 = r1.accessed_column_names()
    assert_true("a" in c0)
    assert_false("b" in c0)
    assert_true("b" in c1)
    assert_false("a" in c1)


def test_group_ref_get_resolves_name_to_column() raises:
    var batch = _make_batch(16)
    for i in range(16):
        var g = GroupRef.from_batch(batch, i)
        assert_equal(Int(g.get("a").as_i64()), i)
        assert_equal(g.get("b").as_f64(), Float64(10 * i) + 0.5)
        assert_equal(g.row_index(), i)


def test_group_ref_with_cached_names_matches_from_batch() raises:
    var batch = _make_batch(8)
    var names = _names(batch)
    var g = GroupRef.from_batch_with_names(batch, names, 6)
    assert_equal(Int(g.get("a").as_i64()), 6)
    var g2 = GroupRef(batch, names, 7)
    assert_equal(g2.get("b").as_f64(), 70.5)


def test_group_column_outlives_group_ref_but_not_batch() raises:
    var batch = _make_batch(8)
    # The GroupRef is a temporary; the GroupColumn it returned borrows the
    # BATCH (not the GroupRef), so it stays valid after the GroupRef is gone.
    var g = GroupRef.from_batch(batch, 2)
    var col = g.get("a")
    _ = g^
    assert_equal(Int(col.as_i64()), 2)


def test_group_column_type_mismatch_raises() raises:
    var batch = _make_batch(4)
    var g = GroupRef.from_batch(batch, 0)
    var raised = False
    try:
        _ = g.get("b").as_i64()
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = g.get("a").as_f64()
    except:
        raised = True
    assert_true(raised)


def test_group_ref_unknown_column_raises_and_tracks() raises:
    var batch = _make_batch(4)
    var g = GroupRef.from_batch(batch, 0)
    _ = g.get("a")
    var raised = False
    try:
        _ = g.get("zzz")
    except:
        raised = True
    assert_true(raised)
    assert_true("a" in g.accessed_column_names())


def test_views_read_the_batch_where_it_lives() raises:
    """The batch is moved out of the helper and into a container; the views
    must read it at its final home."""
    var batches = List[RecordBatch]()
    batches.append(_make_batch(4))
    batches.append(_make_batch(9))
    var names = _names(batches[1])
    var row = Row(batches[1], names, 8)
    assert_equal(Int(row.get_i64("a")), 8)
    var g = GroupRef.from_batch(batches[1], 8)
    assert_equal(g.get("b").as_f64(), 80.5)


# A user-defined trait spelling the view parameter bare, the way the
# operator packages declare their closure traits.
trait _RowFn:
    def __call__(mut self, mut row: Row) raises -> Float64:
        ...


trait _GroupFn:
    def accumulate(mut self, mut group: GroupRef) raises:
        ...


struct _SumAB(_RowFn, Movable):
    def __init__(out self):
        pass

    def __call__(mut self, mut row: Row) raises -> Float64:
        return Float64(row.get_i64("a")) + row.get_f64("b")


struct _Acc(_GroupFn, Movable):
    var total: Float64

    def __init__(out self):
        self.total = 0.0

    def accumulate(mut self, mut group: GroupRef) raises:
        self.total += group.get("b").as_f64()


def test_bare_row_and_group_ref_in_user_traits() raises:
    var batch = _make_batch(5)
    var names = _names(batch)
    var f = _SumAB()
    var acc = _Acc()
    var sum_rows = 0.0
    for i in range(5):
        var row = Row.from_batch_with_names(batch, names, i)
        sum_rows += f(row)
        var g = GroupRef.from_batch_with_names(batch, names, i)
        acc.accumulate(g)
    # sum_i (i + 10 i + 0.5) = 11 * 10 + 2.5
    assert_equal(sum_rows, 112.5)
    # sum_i (10 i + 0.5) = 100 + 2.5
    assert_equal(acc.total, 102.5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
