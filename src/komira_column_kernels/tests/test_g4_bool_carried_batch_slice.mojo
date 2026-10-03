# =============================================================================
# BOOL through `batch_slice` — the byte-width oracle has no width for BOOL
# =============================================================================
#
# Two slice helpers in `komira_column_kernels/batch_slice.mojo` carry a
# BOOL column:
#
#     _slice_batch_first_n   ...   var elem_size = element_size(at)
#     _slice_batch_range     ...   var elem_size = element_size(at)
#
# BOOL's data buffer is `(n + 7) >> 3` bytes, so `n * element_size(BOOL)` is
# not imprecise, it is the WRONG SHAPE. An `else: return 8` oracle would copy
# `n * 8` bytes out of a bit-packed buffer (a 64x over-read) AND index the
# source at `_offset * 8` — a byte address computed from a BIT index. The
# oracle refuses instead, so the same input RAISES:
#
#     arrow_fixed_byte_width: ArrowType bool (type_id=1) has NO fixed
#     per-element byte width
#
# WHY THESE TWO MATTER MORE THAN THEIR CALL COUNT SUGGESTS. They are not niche:
# `_slice_batch_first_n` is LIMIT and TopN (`sort_topn_sink`,
# `partition_topn_sink`, `stage_streaming_collect_sink`) and
# `_slice_batch_range` is the intra-row-group morsel split, the paginated SDK
# result, the multi-row-group Parquet writer's per-chunk encode
# (`record_batch_writer`, `streaming_parquet_writer`, `parquet_parallel_writer`)
# and `sort_frame_resolver`. So `SELECT ... LIMIT n` over any table CARRYING a
# bool column, and writing any such table to a multi-row-group Parquet file,
# both go through a site that cannot answer for bool.
#
# ⚠ THE ZERO-ROW LEG IS NOT A CORNER CASE. `sort_topn_sink` calls
# `_slice_batch_first_n(batch, 0)` on its empty paths, so a bool column would
# make even an EMPTY TopN result unbuildable — `n * width` never runs for
# n == 0, but `element_size(at)` is evaluated before the multiply.
#
# The fix is the shared bit primitive — `bitmap.copy_bits_aligned_buffer`,
# the contiguous-run form — NOT another hand-rolled width ladder (see the
# notes at `compiler_helpers.element_size`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_column_kernels.batch_slice import (
    _slice_batch_first_n,
    _slice_batch_range,
)


# -----------------------------------------------------------------------------
# Fixture: `id` INT64 + `flag` BOOL, `flag[i] = (i % 3 == 0)`. Period 3 over
# 8-bit bytes means the bit pattern differs in EVERY byte, so a copy that lands
# one byte off — or that drops the sub-byte bit position of a non-aligned
# offset — cannot coincidentally agree.
# -----------------------------------------------------------------------------


def _expected_flag(i: Int) -> Bool:
    return i % 3 == 0


def _make_id_flag_batch(n: Int) raises -> RecordBatch:
    var ids = List[Scalar[DType.int64]]()
    for i in range(n):
        ids.append(Scalar[DType.int64](i))
    var id_arr = PrimitiveArray[DType.int64].from_list(ids^)

    var flags = BooleanArray.allocate(n)
    for i in range(n):
        flags.set(i, _expected_flag(i))

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("flag", ArrowType.BOOL, False))

    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](id_arr^))
    builder.add_column(Column.from_boolean(flags))
    var schema = sb.build()
    return builder.build(schema^)


def _make_nullable_id_flag_batch(n: Int) raises -> RecordBatch:
    """Same, but every 4th row of `flag` is NULL.

    Null and value are carried in SEPARATE bitmaps, so a copy can get one right
    and the other wrong. `flag[i]` is still set even where null, so a fix that
    conflated validity with the value bitmap shows up as a wrong value.
    """
    var ids = List[Scalar[DType.int64]]()
    for i in range(n):
        ids.append(Scalar[DType.int64](i))
    var id_arr = PrimitiveArray[DType.int64].from_list(ids^)

    var flags = BooleanArray.allocate_nullable(n)
    for i in range(n):
        flags.set(i, _expected_flag(i))
        if i % 4 == 0:
            flags._set_null(i)
        else:
            flags._set_valid(i)

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("flag", ArrowType.BOOL, True))

    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](id_arr^))
    builder.add_column(Column.from_boolean(flags))
    var schema = sb.build()
    return builder.build(schema^)


def _read_flag(batch: RecordBatch, col: Int, row: Int) raises -> Bool:
    var ba = batch.column_at(col).as_boolean()
    return ba.get(row)


def _read_id(batch: RecordBatch, col: Int, row: Int) raises -> Int:
    var arr = batch.column_at(col).as_primitive[DType.int64]()
    return Int(arr.get(row))


# =============================================================================
# `_slice_batch_first_n` (LIMIT / TopN)
# =============================================================================


def test_slice_batch_first_n_carries_a_bool_column() raises:
    """`LIMIT 21` over a table carrying a bool column.

    21 is not a multiple of 8, so the copy ends mid-byte and the trailing
    partial byte is exercised.
    """
    comptime N = 40
    comptime K = 21
    var batch = _make_id_flag_batch(N)

    var out = _slice_batch_first_n(batch, K)
    assert_equal(out.num_rows(), K)
    assert_equal(out.num_columns(), 2)
    assert_equal(out.schema.field_arrow_type(1), ArrowType.BOOL)

    for r in range(K):
        assert_equal(_read_id(out, 0, r), r)
        assert_equal(
            _read_flag(out, 1, r),
            _expected_flag(r),
            "_slice_batch_first_n lost a carried BOOL bit at row " + String(r),
        )


def test_slice_batch_first_n_zero_rows_with_bool_column() raises:
    """`_slice_batch_first_n(batch, 0)` — the EMPTY TopN path.

    `sort_topn_sink` calls exactly this on its empty legs. `n * width` is never
    evaluated for n == 0, but `element_size(at)` is evaluated BEFORE the
    multiply, so a bool column would make even a zero-row slice unbuildable.
    """
    var batch = _make_id_flag_batch(16)
    var out = _slice_batch_first_n(batch, 0)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 2)
    assert_equal(out.schema.field_arrow_type(1), ArrowType.BOOL)


def test_slice_batch_first_n_carries_a_nullable_bool_column() raises:
    """Nullable bool: the VALUE bits and the VALIDITY bits are two bitmaps."""
    comptime N = 32
    comptime K = 19
    var batch = _make_nullable_id_flag_batch(N)

    var out = _slice_batch_first_n(batch, K)
    assert_equal(out.num_rows(), K)

    var ba = out.column_at(1).as_boolean()
    for r in range(K):
        assert_equal(_read_id(out, 0, r), r)
        assert_equal(
            ba.is_null(r),
            r % 4 == 0,
            "_slice_batch_first_n mis-copied BOOL validity at row " + String(r),
        )
        assert_equal(
            ba.get(r),
            _expected_flag(r),
            "_slice_batch_first_n mis-copied a BOOL value bit at row "
            + String(r),
        )


# =============================================================================
# `_slice_batch_range` (morsel split / paginated result / Parquet
# per-row-group chunking)
# =============================================================================


def test_slice_batch_range_carries_a_bool_column() raises:
    """A range slice starting at a NON-BYTE-ALIGNED row.

    `start = 5` is the whole point: the source bit offset is not a multiple of
    8, which is precisely what `_offset * elem_size` destroyed — it lands in the
    wrong byte AND discards the sub-byte bit position. A byte-granular copy
    cannot pass this.
    """
    comptime N = 40
    var batch = _make_id_flag_batch(N)

    var out = _slice_batch_range(batch, 5, 27)
    assert_equal(out.num_rows(), 27)
    assert_equal(out.num_columns(), 2)

    for r in range(27):
        var src = r + 5
        assert_equal(_read_id(out, 0, r), src)
        assert_equal(
            _read_flag(out, 1, r),
            _expected_flag(src),
            "_slice_batch_range mis-shifted a carried BOOL bit at row "
            + String(r),
        )


def test_slice_batch_range_byte_aligned_start_carries_a_bool_column() raises:
    """The byte-aligned sibling: `start = 8`, the fast path in the primitive.

    Kept alongside the unaligned case because `copy_bits_aligned_buffer` has
    two genuinely different implementations and one test only covers one.
    """
    comptime N = 40
    var batch = _make_id_flag_batch(N)

    var out = _slice_batch_range(batch, 8, 16)
    assert_equal(out.num_rows(), 16)
    for r in range(16):
        var src = r + 8
        assert_equal(_read_id(out, 0, r), src)
        assert_equal(_read_flag(out, 1, r), _expected_flag(src))


def test_slice_batch_range_zero_length_with_bool_column() raises:
    """`_slice_batch_range(batch, 0, 0)` — the empty page of a paginated result.

    `paginated_result` emits exactly this for an empty page.
    """
    var batch = _make_id_flag_batch(16)
    var out = _slice_batch_range(batch, 0, 0)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 2)
    assert_equal(out.schema.field_arrow_type(1), ArrowType.BOOL)


def test_slice_batch_range_carries_a_nullable_bool_column() raises:
    """Nullable bool through the range slice, unaligned start."""
    comptime N = 32
    var batch = _make_nullable_id_flag_batch(N)

    var out = _slice_batch_range(batch, 3, 21)
    assert_equal(out.num_rows(), 21)

    var ba = out.column_at(1).as_boolean()
    for r in range(21):
        var src = r + 3
        assert_equal(_read_id(out, 0, r), src)
        assert_equal(
            ba.is_null(r),
            src % 4 == 0,
            "_slice_batch_range mis-copied BOOL validity at row " + String(r),
        )
        assert_equal(ba.get(r), _expected_flag(src))


def test_slice_batch_range_over_an_already_offset_bool_column() raises:
    """The source column itself carries `_offset > 0`.

    `_slice_batch_range` reads `col._offset + start`, so BOTH terms have to be
    treated as BIT indices. This leg pins the composition: a column already
    windowed at bit 3, range-sliced from row 2, must yield source rows 5.. —
    the same rows as the unaligned test above, reached by a different route.
    A fix that handled `start` as bits but `_offset` as bytes passes the test
    above and fails this one.
    """
    comptime N = 40
    var batch = _make_id_flag_batch(N)

    # Re-wrap the same buffers as a window starting at row 3. BOOL is not on
    # `supports_zero_copy_slice`'s whitelist (bit-packed), so `Column.slice`
    # refuses it; the window is built directly, which is what the offset-
    # honoring consumers must cope with.
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("flag", ArrowType.BOOL, False))
    var rb = RecordBatchBuilder()
    var id_win = batch.column_at(0).share()
    id_win._offset = 3
    id_win._length = N - 3
    var flag_win = batch.column_at(1).share()
    flag_win._offset = 3
    flag_win._length = N - 3
    rb.add_column(id_win^)
    rb.add_column(flag_win^)
    var schema = sb.build()
    var windowed = rb.build(schema^)
    assert_equal(windowed.num_rows(), N - 3)

    var out = _slice_batch_range(windowed, 2, 25)
    assert_equal(out.num_rows(), 25)
    for r in range(25):
        var src = r + 5
        assert_equal(_read_id(out, 0, r), src)
        assert_equal(
            _read_flag(out, 1, r),
            _expected_flag(src),
            "_slice_batch_range ignored the source column's BIT offset at row "
            + String(r),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
