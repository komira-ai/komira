# =============================================================================
# test_thsplc_roundtrip.mojo — THSPLC column codec round-trip + 0-copy alias.
# =============================================================================
#
# Exercises `THSPLCEncoder.encode` + `THSPLCDecoder.decode_copy` /
# `decode_zerocopy` for:
#   (a) int-only columns
#   (b) string / varlen columns
#   (c) mixed int + string + wide (decimal128) columns
#   (d) nullable columns (validity bitmap round-trip)
#
# Both restore paths must reproduce logical equality (values, validity,
# lengths). The 0-copy path's column buffers must ALIAS the source bytes (the
# restored data pointer falls inside the source SAB byte range — no
# allocation), whereas the copy path's data pointer must fall OUTSIDE it.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_engine_runtime.spill.thsplc import THSPLCDecoder, THSPLCEncoder


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


def _bool_list(*vals: Bool) -> List[Bool]:
    var out = List[Bool]()
    for v in vals:
        out.append(v)
    return out^


def _build_batch(
    var columns: Slab[Column[HeapRegion]], var schema: Schema
) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_slab(schema^, columns^)


def _sab_base(buf: SharedAlignedBuffer[HeapRegion]) -> Int:
    return Int(buf.view_range_ro(0, buf.len())._unsafe_ptr())


def _clone_sab(
    buf: SharedAlignedBuffer[HeapRegion],
) -> SharedAlignedBuffer[HeapRegion]:
    """Cheap Arc-clone of a full-length SAB (SAB is not ImplicitlyCopyable;
    `from_borrowed_view(owner, 0, len)` clones the Arc + full-length view).
    Used to feed the same encoded chunk into two decode calls."""
    return SharedAlignedBuffer[HeapRegion].from_borrowed_view(
        buf, Int64(0), buf.length()
    )


def _col_data_addr(batch: RecordBatch, col_idx: Int) raises -> Int:
    """Integer address of the FIRST byte of column `col_idx`'s data buffer."""
    ref col = batch.column_at(col_idx)
    var probe = max(col._data.len(), 1)
    return Int(col._data.view_range_ro(0, probe)._unsafe_ptr())


def _int64_schema(name0: String, name1: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.INT64, False))
    sb.add_field(Field(name1, ArrowType.INT64, False))
    return sb.build()


# =============================================================================
# (a) int-only columns
# =============================================================================


def test_int_only_roundtrip() raises:
    var c0 = _i64_list(1, 2, 3, 4, 5, 6, 7, 8)
    var c1 = _i64_list(-100, 0, 100, 200, 300, 400, 500, 600)

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
    var batch = _build_batch(cols^, _int64_schema("a", "b"))

    var encoded = THSPLCEncoder.encode(batch^)
    var src_base = _sab_base(encoded)
    var src_len = encoded.len()

    # --- copy path ---
    var copy_batch = THSPLCDecoder.decode_copy(
        _clone_sab(encoded), _int64_schema("a", "b")
    )
    assert_equal(copy_batch.num_rows(), 8)
    assert_equal(copy_batch.num_columns(), 2)
    for i in range(8):
        assert_equal(copy_batch.column_as_primitive_int64(0).get(i), c0[i])
        assert_equal(copy_batch.column_as_primitive_int64(1).get(i), c1[i])
    var copy_addr = _col_data_addr(copy_batch, 0)
    assert_true(
        copy_addr < src_base or copy_addr >= src_base + src_len,
        "copy-path data must NOT alias source bytes",
    )

    # --- 0-copy path ---
    var zc_batch = THSPLCDecoder.decode_zerocopy(
        encoded^, _int64_schema("a", "b")
    )
    assert_equal(zc_batch.num_rows(), 8)
    for i in range(8):
        assert_equal(zc_batch.column_as_primitive_int64(0).get(i), c0[i])
        assert_equal(zc_batch.column_as_primitive_int64(1).get(i), c1[i])
    var zc_addr = _col_data_addr(zc_batch, 0)
    assert_true(
        zc_addr >= src_base and zc_addr < src_base + src_len,
        "0-copy data MUST alias source bytes",
    )


# =============================================================================
# (b) string / varlen columns
# =============================================================================


def _string_schema(name0: String, name1: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.STRING, False))
    sb.add_field(Field(name1, ArrowType.STRING, False))
    return sb.build()


def test_string_roundtrip() raises:
    var s0 = _str_list("alpha", "beta", "", "delta-long-value", "e")
    var s1 = _str_list("x", "yy", "zzz", "wwww", "vvvvv")

    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(Column.from_string(StringArray.from_strings(s0)))
    cols.append(Column.from_string(StringArray.from_strings(s1)))
    var batch = _build_batch(cols^, _string_schema("s0", "s1"))

    var encoded = THSPLCEncoder.encode(batch^)
    var src_base = _sab_base(encoded)
    var src_len = encoded.len()

    # --- copy path ---
    var copy_batch = THSPLCDecoder.decode_copy(
        _clone_sab(encoded), _string_schema("s0", "s1")
    )
    assert_equal(copy_batch.num_rows(), 5)
    for i in range(5):
        assert_equal(copy_batch.column_as_string(0).get(i), s0[i])
        assert_equal(copy_batch.column_as_string(1).get(i), s1[i])

    # --- 0-copy path ---
    var zc_batch = THSPLCDecoder.decode_zerocopy(
        encoded^, _string_schema("s0", "s1")
    )
    assert_equal(zc_batch.num_rows(), 5)
    for i in range(5):
        assert_equal(zc_batch.column_as_string(0).get(i), s0[i])
        assert_equal(zc_batch.column_as_string(1).get(i), s1[i])
    var zc_addr = _col_data_addr(zc_batch, 0)
    assert_true(
        zc_addr >= src_base and zc_addr < src_base + src_len,
        "0-copy varlen data MUST alias source bytes",
    )


# =============================================================================
# (c) mixed int + string + wide (decimal128)
# =============================================================================


def _mixed_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("d", ArrowType.DECIMAL128, False))
    return sb.build()


def test_mixed_roundtrip() raises:
    var ints = _i64_list(10, 20, 30, 40)
    var strs = _str_list("foo", "barbar", "b", "quuux")
    var dec = Decimal128Array[HeapRegion].allocate(4, 18, 2)

    var cols = Slab[Column[HeapRegion]].create(3)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ints)
        )
    )
    cols.append(Column.from_string(StringArray.from_strings(strs)))
    cols.append(Column.from_decimal128(dec^))
    var batch = _build_batch(cols^, _mixed_schema())

    var encoded = THSPLCEncoder.encode(batch^)
    var src_base = _sab_base(encoded)
    var src_len = encoded.len()

    # --- copy path ---
    var copy_batch = THSPLCDecoder.decode_copy(
        _clone_sab(encoded), _mixed_schema()
    )
    assert_equal(copy_batch.num_rows(), 4)
    assert_equal(copy_batch.num_columns(), 3)
    for i in range(4):
        assert_equal(copy_batch.column_as_primitive_int64(0).get(i), ints[i])
        assert_equal(copy_batch.column_as_string(1).get(i), strs[i])
    assert_equal(copy_batch.column_length(2), 4)

    # --- 0-copy path ---
    var zc_batch = THSPLCDecoder.decode_zerocopy(encoded^, _mixed_schema())
    assert_equal(zc_batch.num_rows(), 4)
    for i in range(4):
        assert_equal(zc_batch.column_as_primitive_int64(0).get(i), ints[i])
        assert_equal(zc_batch.column_as_string(1).get(i), strs[i])
    assert_equal(zc_batch.column_length(2), 4)
    for c in range(3):
        var a = _col_data_addr(zc_batch, c)
        assert_true(
            a >= src_base and a < src_base + src_len,
            "0-copy mixed col data MUST alias source bytes",
        )


# =============================================================================
# (d) nullable columns — validity bitmap round-trip
# =============================================================================


def _nullable_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def test_nullable_roundtrip() raises:
    var ints = _i64_list(1, 2, 3, 4, 5)
    var valid = _bool_list(True, False, True, False, True)

    var narr = PrimitiveArray[DType.int64].allocate_nullable(5)
    for i in range(5):
        narr.set(i, ints[i])
        if not valid[i]:
            narr.validity.value().clear(i)
            narr.null_count += 1

    var strs = _str_list("a", "b", "c", "d", "e")
    var svalid = _bool_list(True, True, False, True, False)

    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(Column.from_primitive[DType.int64](narr^))
    cols.append(
        Column.from_string(
            StringArray.from_strings_with_validity(strs, svalid)
        )
    )
    var batch = _build_batch(cols^, _nullable_schema())

    var encoded = THSPLCEncoder.encode(batch^)

    # --- copy path ---
    var copy_batch = THSPLCDecoder.decode_copy(
        _clone_sab(encoded), _nullable_schema()
    )
    assert_equal(copy_batch.num_rows(), 5)
    var ic = copy_batch.column_as_primitive_int64(0)
    for i in range(5):
        assert_equal(ic.is_null(i), not valid[i])
        if valid[i]:
            assert_equal(ic.get(i), ints[i])

    # --- 0-copy path ---
    var zc_batch = THSPLCDecoder.decode_zerocopy(encoded^, _nullable_schema())
    assert_equal(zc_batch.num_rows(), 5)
    var zic = zc_batch.column_as_primitive_int64(0)
    for i in range(5):
        assert_equal(zic.is_null(i), not valid[i])
        if valid[i]:
            assert_equal(zic.get(i), ints[i])
    var zsc = zc_batch.column_as_string(1)
    for i in range(5):
        assert_equal(zsc.is_null(i), not svalid[i])
        if svalid[i]:
            assert_equal(zsc.get(i), strs[i])


def main() raises:
    test_int_only_roundtrip()
    print("test_int_only_roundtrip PASSED")
    test_string_roundtrip()
    print("test_string_roundtrip PASSED")
    test_mixed_roundtrip()
    print("test_mixed_roundtrip PASSED")
    test_nullable_roundtrip()
    print("test_nullable_roundtrip PASSED")
    print("ALL THSPLC ROUNDTRIP TESTS PASSED")
