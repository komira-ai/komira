# Direct tests of `ColumnDecodeContext` (column_decode_context.mojo): each
# reusable buffer is allocated on first use and grows but never shrinks; the
# band slots hold a column's values in slot c and its dictionary in slots
# N+c and 2N+c, and a row group's dictionary replaces the last one; the
# numeric band resolve maps codes through the dictionary and refuses a code
# outside it; the band cursors fill their slots and expose a PLAIN grain in
# place under the context's origin.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_parquet_api.types import CompressionCodec, ParquetType

from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.subrg_column_cursor import ResumableColumnCursor, SUBRG_MAX_RUN


def _uleb(mut out: List[UInt8], v: Int):
    var x = v
    while True:
        var b = x & 0x7F
        x >>= 7
        if x != 0:
            out.append(UInt8(b | 0x80))
        else:
            out.append(UInt8(b))
            return


def _i32_field(mut out: List[UInt8], v: Int):
    out.append(UInt8((1 << 4) | 5))
    _uleb(out, (v << 1) ^ (v >> 63))


def _data_page(mut chunk: List[UInt8], body: List[UInt8], nv: Int, enc: Int):
    """An uncompressed V1 DATA_PAGE (parquet.thrift PageHeader)."""
    _i32_field(chunk, 0)
    _i32_field(chunk, len(body))
    _i32_field(chunk, len(body))
    chunk.append(UInt8((2 << 4) | 12))
    _i32_field(chunk, nv)
    _i32_field(chunk, enc)
    _i32_field(chunk, 3)
    _i32_field(chunk, 3)
    chunk.append(UInt8(0))
    chunk.append(UInt8(0))
    chunk.extend(body.copy())


def _plain_i64(first: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in range(first, first + n):
        for k in range(8):
            out.append(UInt8(((v * 11) >> (8 * k)) & 0xFF))
    return out^


def test_buffers_are_allocated_on_first_use_and_only_grow() raises:
    var ctx = ColumnDecodeContext()
    assert_false(ctx.has_scratch())
    assert_false(ctx.has_codes())
    assert_equal(ctx.scratch_capacity(), 0)
    ctx.ensure_scratch(1000)
    assert_true(ctx.has_scratch())
    var cap = ctx.scratch_capacity()
    assert_true(cap >= 1000)
    ctx.ensure_scratch(10)
    assert_equal(ctx.scratch_capacity(), cap, "a smaller request does not shrink")
    ctx.ensure_scratch(5000)
    assert_true(ctx.scratch_capacity() >= 5000)
    ctx.ensure_codes(400)
    assert_true(ctx.codes_capacity() >= 400)
    ctx.codes_ref().set_length(8)
    ctx.codes_ref().set_typed[Int32](1, Int32(77))
    assert_equal(ctx.codes_ref().get_typed[Int32](1), Int32(77))
    ctx.ensure_subrg_codes(64)
    ctx.ensure_subrg_value(128)
    assert_true(ctx.subrg_codes_ref().capacity() >= 64)
    assert_true(ctx.subrg_value_ref().capacity() >= 128)


def test_the_gates_are_construction_arguments() raises:
    var a = ColumnDecodeContext()
    assert_false(a.numeric_dict_vec_enabled)
    assert_false(a.recycle_codes_enabled)
    var b = ColumnDecodeContext(True, True)
    assert_true(b.numeric_dict_vec_enabled)
    assert_true(b.recycle_codes_enabled)


def test_band_slots_and_row_group_dictionaries() raises:
    var ctx = ColumnDecodeContext()
    var sizes: List[Int] = [16, 32]
    ctx.ensure_band_slots(2, sizes)
    assert_equal(ctx.band_n_cols(), 2)
    var off1: List[Int32] = [0, 2, 5]
    var data1: List[UInt8] = [97, 98, 99, 100, 101]
    ctx.set_rg_dict(1, off1, data1)
    var ov = ctx.band_dict_off_view_ro(1).into_span()
    assert_equal(len(ov), 12)
    assert_equal(ov[4], UInt8(2))
    assert_equal(ctx.band_dict_bytes_view_ro(1).len(), 5)
    assert_equal(ctx.band_dict_off_view_ro(0).len(), 0, "column 0 has no dictionary")
    # The next row group's smaller dictionary replaces it.
    var off2: List[Int32] = [0, 1]
    var data2: List[UInt8] = [122]
    ctx.set_rg_dict(1, off2, data2)
    assert_equal(ctx.band_dict_off_view_ro(1).len(), 8)
    var bv = ctx.band_dict_bytes_view_ro(1).into_span()
    assert_equal(len(bv), 1)
    assert_equal(bv[0], UInt8(122))
    with assert_raises(contains="band slots hold 2 columns, asked for 3"):
        ctx.ensure_band_slots(3, [8, 8, 8])


def test_the_numeric_band_resolve() raises:
    var ctx = ColumnDecodeContext()
    ctx.ensure_band_slots(1, [64])
    ctx.ensure_band_codes(16)
    ref codes = ctx.band_codes_ref()
    codes.set_length(16)
    var cs: List[Int32] = [2, 0, 1, 2]
    for i in range(4):
        codes.set_typed[Int32](i, cs[i])
    var d64: List[Int64] = [100, -5, 7]
    ctx.band_resolve_dict_int(0, 4, 8, d64)
    assert_equal(ctx.band_value_ref(0).get_typed[Int64](0), Int64(7))
    assert_equal(ctx.band_value_ref(0).get_typed[Int64](1), Int64(100))
    ctx.band_resolve_dict_int(0, 4, 4, d64)
    assert_equal(ctx.band_value_ref(0).get_typed[Int32](2), Int32(-5))
    var df: List[Float64] = [0.5, 1.5, 2.5]
    ctx.band_resolve_dict_f64(0, 4, df)
    assert_equal(ctx.band_value_ref(0).get_typed[Float64](3), 2.5)
    ctx.band_codes_ref().set_typed[Int32](1, Int32(3))
    with assert_raises(contains="dictionary code 3 outside a dictionary of 3"):
        ctx.band_resolve_dict_int(0, 4, 8, d64)


def test_band_cursors_fill_slots_and_expose_a_grain() raises:
    var chunk = List[UInt8]()
    _data_page(chunk, _plain_i64(0, 6), 6, 0)
    _data_page(chunk, _plain_i64(6, 4), 4, 0)
    var cursors = Slab[ResumableColumnCursor]()
    cursors.append(
        ResumableColumnCursor.try_open(
            chunk.copy(), ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 10, False
        )
    )
    cursors.append(
        ResumableColumnCursor.try_open(
            chunk^, ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 10, False
        )
    )
    var ctx = ColumnDecodeContext()
    ctx.ensure_band_slots(2, [10 * 8, 10 * 8])
    ctx.band_value_ref(0).set_length(80)
    ctx.set_band_cursors(cursors^)
    assert_true(ctx.band_cursor_read(0).supported())
    # Column 0 copies values into its slot.
    assert_equal(ctx.band_fill_flat(0, 4, 0), 4)
    assert_equal(ctx.band_fill_flat(0, 4, 4), 4)
    assert_equal(ctx.band_value_ref(0).get_typed[Int64](5), Int64(55))
    # Column 1 is read in place: the page offers 6, a grain of 4 is taken.
    assert_equal(ctx.band_ensure_page(1), 6)
    ctx.band_commit_grain(1, 4)
    var view = ctx.band_agg_page_view(1, 32).into_span()
    assert_equal(len(view), 32)
    assert_equal(view[8], UInt8(11), "row 1's value, 11, in place")
    assert_equal(ctx.band_ensure_page(1), 2)
    var col = ctx.band_col_view(0, 16).into_span()
    assert_equal(col[8], UInt8(11))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
