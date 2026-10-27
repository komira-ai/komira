# =============================================================================
# test_spill_codec_boundary.mojo — THSPLC / FileSystemSpillStorage
# boundary cases of the THSPLC codec and the spill storage.
# =============================================================================
# Extends the happy-path and corruption coverage in test_thsplc_roundtrip.mojo,
# test_filesystem_spill_storage.mojo and test_spill_thsplc_robustness.mojo with
# these boundary cases:
#
#   (1) SLICED-INPUT (the real correctness case — spill-after-filter/limit):
#       a fixed-width column with `_offset != 0`, exercising the
#       `src_byte_off = col._offset * w` branch in thsplc.mojo that NO
#       happy-path test reaches (all those columns are built fresh with
#       `_offset == 0`). Both decode paths must restore the SLICED logical
#       values — not the underlying full buffer's offset-prefix bytes.
#
#   (2) STORAGE-TEARDOWN-LIFETIME (the deeper 0-copy Arc-pin case): spill a
#       THSPLC chunk to `FileSystemSpillStorage[LocalFs]`, `decode_zerocopy`
#       the restored batch, DROP the storage object, THEN read every byte of
#       the restored columns — proving the borrowed-view Arc pins the
#       underlying region independent of the storage object's lifetime. The
#       existing keepalive tests keep storage alive the whole time; this one
#       destroys it first.
#
#   (3) WIDE-SCHEMA: a >=12-column round-trip (mixed dtypes), exercising the
#       `n_cols x 48B` descriptor-section math at scale (only <=3 cols tested
#       elsewhere).
#
#   (4) ALL-NULL column: validity all-zero, null_count == length — copy +
#       0-copy; validity + null_count preserved.
#
#   (5) SINGLE-ROW batch + ZERO-LENGTH varlen entries (all "").
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
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

from std.ffi import external_call
from std.os import makedirs

from komira_engine_runtime.spill.filesystem_spill_storage import (
    FileSystemSpillStorage,
)
from komira_engine_runtime.spill.spill_storage import ChunkId
from komira_engine_runtime.spill.thsplc import THSPLCDecoder, THSPLCEncoder
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
# Helpers (match the established style in test_thsplc_roundtrip.mojo)
# =============================================================================

comptime _SpillFs = LocalFs[NoopSink]
comptime _Storage = FileSystemSpillStorage[_SpillFs]


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
    return SharedAlignedBuffer[HeapRegion].from_borrowed_view(
        buf, Int64(0), buf.length()
    )


def _col_data_addr(batch: RecordBatch, col_idx: Int) raises -> Int:
    ref col = batch.column_at(col_idx)
    var probe = max(col._data.len(), 1)
    return Int(col._data.view_range_ro(0, probe)._unsafe_ptr())


def _mkdir_p(path: String) raises:
    """Create `path` and its missing parents (no shell)."""
    makedirs(path, exist_ok=True)


def _temp_root(tag: String) raises -> String:
    var pid = external_call["getpid", Int32]()
    var root = (
        (_scratch_dir() + String("/komira-spill-boundary-"))
        + String(Int(pid))
        + String("-")
        + tag
    )
    _mkdir_p(root)
    return root


# =============================================================================
# (1) SLICED-INPUT — exercises the src_byte_off = offset * w branch of thsplc.mojo.
#
# `PrimitiveArray.slice(start, length)` produces an array whose `offset` is
# nonzero and whose underlying data buffer still holds the `[0, offset)`
# prefix bytes. `Column.from_primitive` preserves that offset + the full
# `(offset + length)`-element buffer. The encoder writes only the slice's
# `length` values, copying from `col._offset * w` — both decode paths must
# restore the SLICED logical values, NOT the prefix bytes.
# =============================================================================


def _int64_schema_1(name0: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.INT64, False))
    return sb.build()


def test_sliced_fixed_width_roundtrip() raises:
    # Full array of 8 ints; slice off the first 3 so the slice's logical
    # values are [40, 50, 60, 70, 80] with _offset == 3.
    var full = _i64_list(10, 20, 30, 40, 50, 60, 70, 80)
    var arr = PrimitiveArray[DType.int64].from_list(full)
    var sliced = arr.slice(3, 5)  # start=3, length=5 -> offset becomes 3

    # Guard the fixture actually produces the offset branch input.
    assert_equal(sliced.offset, 3, "slice offset must be 3 (drives the branch)")
    assert_equal(sliced.length, 5, "slice length must be 5")

    var col = Column.from_primitive[DType.int64](sliced)
    assert_equal(col._offset, 3, "Column must carry the slice offset")

    var cols = Slab[Column[HeapRegion]].create(1)
    cols.append(col^)
    var batch = _build_batch(cols^, _int64_schema_1("v"))

    var encoded = THSPLCEncoder.encode(batch^)

    var expected = _i64_list(40, 50, 60, 70, 80)

    # --- copy path ---
    var copy_batch = THSPLCDecoder.decode_copy(
        _clone_sab(encoded), _int64_schema_1("v")
    )
    assert_equal(copy_batch.num_rows(), 5, "sliced copy: 5 rows")
    var cc = copy_batch.column_as_primitive_int64(0)
    for i in range(5):
        assert_equal(
            cc.get(i),
            expected[i],
            "sliced copy: value must be the SLICED logical value, not prefix",
        )

    # --- 0-copy path ---
    var zc_batch = THSPLCDecoder.decode_zerocopy(encoded^, _int64_schema_1("v"))
    assert_equal(zc_batch.num_rows(), 5, "sliced 0-copy: 5 rows")
    var zc = zc_batch.column_as_primitive_int64(0)
    for i in range(5):
        assert_equal(
            zc.get(i),
            expected[i],
            "sliced 0-copy: value must be the SLICED logical value",
        )


# =============================================================================
# (2) STORAGE-TEARDOWN-LIFETIME — restored 0-copy block survives storage drop.
#
# Spill a THSPLC chunk to FileSystemSpillStorage[LocalFs], read_chunk it,
# decode_zerocopy, take an independent reference image of the restored bytes,
# DESTROY the storage object, THEN read every restored value and assert it
# still equals the reference. The borrowed-view Arc must pin the underlying
# region independent of the storage object's lifetime.
#
# (LocalFs.read_at returns a heap-resident realigned SAB — `realign_to[64]`,
# Path B — so the borrowed view aliases that heap buffer, whose Arc the
# restored columns clone. Dropping the storage cannot free it.)
# =============================================================================


def _mixed_teardown_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    return sb.build()


def test_storage_teardown_zerocopy_lifetime() raises:
    var root = _temp_root("teardown")

    var ints = _i64_list(101, 202, 303, 404, 505, 606)
    var strs = _str_list("aa", "bbbb", "c", "dddddddd", "ee", "fff")
    var expect_ints = _i64_list(101, 202, 303, 404, 505, 606)
    var expect_strs = _str_list("aa", "bbbb", "c", "dddddddd", "ee", "fff")

    # Restore the batch under a scope so the storage drops while `restored`
    # (returned from the helper) stays alive past the drop.
    var restored = _spill_then_restore_zerocopy_and_drop_storage(
        root, ints, strs
    )

    # The storage object is GONE here. Read every byte of every column.
    assert_equal(restored.num_rows(), 6, "teardown: 6 rows survive drop")
    assert_equal(restored.num_columns(), 2, "teardown: 2 cols survive drop")
    var ic = restored.column_as_primitive_int64(0)
    var sc = restored.column_as_string(1)
    for i in range(6):
        assert_equal(
            ic.get(i),
            expect_ints[i],
            "teardown: int value must survive storage drop",
        )
        assert_equal(
            sc.get(i),
            expect_strs[i],
            "teardown: string value must survive storage drop",
        )


def _spill_then_restore_zerocopy_and_drop_storage(
    root: String,
    ints: List[Scalar[DType.int64]],
    strs: List[String],
) raises -> RecordBatch:
    """Build a batch, THSPLC-encode it, write_chunk to a
    FileSystemSpillStorage[LocalFs], read_chunk + decode_zerocopy, then DROP
    the storage and return the restored batch. The returned batch's borrowed
    columns must keep the read-chunk SAB alive after the storage is gone."""
    var fs = _SpillFs.new()
    var storage = _Storage.with_unlimited(fs^, root)

    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ints)
        )
    )
    cols.append(Column.from_string(StringArray.from_strings(strs)))
    var batch = _build_batch(cols^, _mixed_teardown_schema())

    var encoded = THSPLCEncoder.encode(batch^)
    var cid = storage.write_chunk(encoded^)

    var chunk = storage.read_chunk(cid)
    var restored = THSPLCDecoder.decode_zerocopy(
        chunk^, _mixed_teardown_schema()
    )

    # Drop the backing files + the storage object explicitly BEFORE returning.
    storage.release_chunk(cid)
    _ = storage^  # storage object destroyed here

    return restored^


# =============================================================================
# (3) WIDE-SCHEMA — >=12 columns, mixed dtypes (descriptor-section math at scale)
# =============================================================================


def _wide_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c00", ArrowType.INT64, False))
    sb.add_field(Field("c01", ArrowType.INT32, False))
    sb.add_field(Field("c02", ArrowType.FLOAT64, False))
    sb.add_field(Field("c03", ArrowType.FLOAT32, False))
    sb.add_field(Field("c04", ArrowType.STRING, False))
    sb.add_field(Field("c05", ArrowType.INT64, False))
    sb.add_field(Field("c06", ArrowType.DECIMAL128, False))
    sb.add_field(Field("c07", ArrowType.INT32, False))
    sb.add_field(Field("c08", ArrowType.STRING, False))
    sb.add_field(Field("c09", ArrowType.FLOAT64, False))
    sb.add_field(Field("c10", ArrowType.INT64, False))
    sb.add_field(Field("c11", ArrowType.INT32, False))
    sb.add_field(Field("c12", ArrowType.STRING, False))
    return sb.build()


def test_wide_schema_roundtrip() raises:
    comptime N = 4
    var i64a = _i64_list(1, 2, 3, 4)
    var i64b = _i64_list(11, 22, 33, 44)
    var i64c = _i64_list(111, 222, 333, 444)

    var i32a = PrimitiveArray[DType.int32].allocate(N)
    var i32b = PrimitiveArray[DType.int32].allocate(N)
    var i32c = PrimitiveArray[DType.int32].allocate(N)
    var f64a = PrimitiveArray[DType.float64].allocate(N)
    var f64b = PrimitiveArray[DType.float64].allocate(N)
    var f32a = PrimitiveArray[DType.float32].allocate(N)
    for i in range(N):
        i32a.set(i, Int32(i + 1))
        i32b.set(i, Int32((i + 1) * 10))
        i32c.set(i, Int32((i + 1) * 100))
        f64a.set(i, Float64(i) + 0.5)
        f64b.set(i, Float64(i) * 2.0)
        f32a.set(i, Float32(i) + 0.25)

    var s0 = _str_list("alpha", "beta", "gamma", "delta")
    var s1 = _str_list("", "x", "yy", "zzz")
    var s2 = _str_list("longish-value-0", "v1", "v2", "")
    var dec = Decimal128Array[HeapRegion].allocate(N, 18, 2)

    var cols = Slab[Column[HeapRegion]].create(13)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64a)
        )
    )
    cols.append(Column.from_primitive[DType.int32](i32a^))
    cols.append(Column.from_primitive[DType.float64](f64a^))
    cols.append(Column.from_primitive[DType.float32](f32a^))
    cols.append(Column.from_string(StringArray.from_strings(s0)))
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64b)
        )
    )
    cols.append(Column.from_decimal128(dec^))
    cols.append(Column.from_primitive[DType.int32](i32b^))
    cols.append(Column.from_string(StringArray.from_strings(s1)))
    cols.append(Column.from_primitive[DType.float64](f64b^))
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64c)
        )
    )
    cols.append(Column.from_primitive[DType.int32](i32c^))
    cols.append(Column.from_string(StringArray.from_strings(s2)))

    var batch = _build_batch(cols^, _wide_schema())
    assert_equal(batch.num_columns(), 13, "wide: 13 columns built")

    var encoded = THSPLCEncoder.encode(batch^)

    # --- copy path ---
    var copy_batch = THSPLCDecoder.decode_copy(_clone_sab(encoded), _wide_schema())
    assert_equal(copy_batch.num_rows(), N, "wide copy: row count")
    assert_equal(copy_batch.num_columns(), 13, "wide copy: col count")
    for i in range(N):
        assert_equal(copy_batch.column_as_primitive_int64(0).get(i), i64a[i])
        assert_equal(copy_batch.column_as_string(4).get(i), s0[i])
        assert_equal(copy_batch.column_as_string(12).get(i), s2[i])
        assert_equal(copy_batch.column_as_primitive_int64(5).get(i), i64b[i])
        assert_equal(copy_batch.column_as_primitive_int64(10).get(i), i64c[i])
    assert_equal(copy_batch.column_length(6), N, "wide copy: decimal length")

    # --- 0-copy path ---
    var zc_batch = THSPLCDecoder.decode_zerocopy(encoded^, _wide_schema())
    assert_equal(zc_batch.num_rows(), N, "wide 0-copy: row count")
    for i in range(N):
        assert_equal(zc_batch.column_as_primitive_int64(0).get(i), i64a[i])
        assert_equal(zc_batch.column_as_string(4).get(i), s0[i])
        assert_equal(zc_batch.column_as_string(8).get(i), s1[i])
        assert_equal(zc_batch.column_as_string(12).get(i), s2[i])
        assert_equal(zc_batch.column_as_primitive_int64(10).get(i), i64c[i])
    assert_equal(zc_batch.column_length(6), N, "wide 0-copy: decimal length")


# =============================================================================
# (4) ALL-NULL column — validity all-zero, null_count == length.
# =============================================================================


def _allnull_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("n", ArrowType.INT64, True))
    return sb.build()


def test_all_null_column_roundtrip() raises:
    comptime N = 6
    var narr = PrimitiveArray[DType.int64].allocate_nullable(N)
    for i in range(N):
        narr.set(i, Int64(i * 7))  # value bytes present but logically null
        narr.validity.value().clear(i)
        narr.null_count += 1
    assert_equal(narr.null_count, N, "fixture: every element null")

    var cols = Slab[Column[HeapRegion]].create(1)
    cols.append(Column.from_primitive[DType.int64](narr^))
    var batch = _build_batch(cols^, _allnull_schema())
    assert_equal(
        batch.column_at(0).null_count(), N, "fixture: column null_count == N"
    )

    var encoded = THSPLCEncoder.encode(batch^)

    # --- copy path ---
    var copy_batch = THSPLCDecoder.decode_copy(
        _clone_sab(encoded), _allnull_schema()
    )
    assert_equal(copy_batch.num_rows(), N, "all-null copy: row count")
    assert_equal(
        copy_batch.column_at(0).null_count(),
        N,
        "all-null copy: null_count preserved",
    )
    var cc = copy_batch.column_as_primitive_int64(0)
    for i in range(N):
        assert_true(cc.is_null(i), "all-null copy: every element null")

    # --- 0-copy path ---
    var zc_batch = THSPLCDecoder.decode_zerocopy(encoded^, _allnull_schema())
    assert_equal(zc_batch.num_rows(), N, "all-null 0-copy: row count")
    assert_equal(
        zc_batch.column_at(0).null_count(),
        N,
        "all-null 0-copy: null_count preserved",
    )
    var zc = zc_batch.column_as_primitive_int64(0)
    for i in range(N):
        assert_true(zc.is_null(i), "all-null 0-copy: every element null")


# =============================================================================
# (5a) SINGLE-ROW batch.
# =============================================================================


def _single_row_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    return sb.build()


def test_single_row_roundtrip() raises:
    var ints = _i64_list(42)
    var strs = _str_list("only")

    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ints)
        )
    )
    cols.append(Column.from_string(StringArray.from_strings(strs)))
    var batch = _build_batch(cols^, _single_row_schema())

    var encoded = THSPLCEncoder.encode(batch^)

    var copy_batch = THSPLCDecoder.decode_copy(
        _clone_sab(encoded), _single_row_schema()
    )
    assert_equal(copy_batch.num_rows(), 1, "single-row copy: 1 row")
    assert_equal(copy_batch.column_as_primitive_int64(0).get(0), Int64(42))
    assert_equal(copy_batch.column_as_string(1).get(0), String("only"))

    var zc_batch = THSPLCDecoder.decode_zerocopy(encoded^, _single_row_schema())
    assert_equal(zc_batch.num_rows(), 1, "single-row 0-copy: 1 row")
    assert_equal(zc_batch.column_as_primitive_int64(0).get(0), Int64(42))
    assert_equal(zc_batch.column_as_string(1).get(0), String("only"))


# =============================================================================
# (5b) ZERO-LENGTH varlen — a string column where EVERY entry is "".
# =============================================================================


def _allempty_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    return sb.build()


def test_all_empty_string_roundtrip() raises:
    comptime N = 5
    var strs = _str_list("", "", "", "", "")  # all zero-length

    var cols = Slab[Column[HeapRegion]].create(1)
    cols.append(Column.from_string(StringArray.from_strings(strs)))
    var batch = _build_batch(cols^, _allempty_schema())

    var encoded = THSPLCEncoder.encode(batch^)

    var copy_batch = THSPLCDecoder.decode_copy(
        _clone_sab(encoded), _allempty_schema()
    )
    assert_equal(copy_batch.num_rows(), N, "all-empty copy: row count")
    for i in range(N):
        assert_equal(
            copy_batch.column_as_string(0).get(i),
            String(""),
            "all-empty copy: every entry is the empty string",
        )

    var zc_batch = THSPLCDecoder.decode_zerocopy(encoded^, _allempty_schema())
    assert_equal(zc_batch.num_rows(), N, "all-empty 0-copy: row count")
    for i in range(N):
        assert_equal(
            zc_batch.column_as_string(0).get(i),
            String(""),
            "all-empty 0-copy: every entry is the empty string",
        )


# =============================================================================
# main
# =============================================================================


def main() raises:
    test_sliced_fixed_width_roundtrip()
    print("test_sliced_fixed_width_roundtrip PASSED")
    test_storage_teardown_zerocopy_lifetime()
    print("test_storage_teardown_zerocopy_lifetime PASSED")
    test_wide_schema_roundtrip()
    print("test_wide_schema_roundtrip PASSED")
    test_all_null_column_roundtrip()
    print("test_all_null_column_roundtrip PASSED")
    test_single_row_roundtrip()
    print("test_single_row_roundtrip PASSED")
    test_all_empty_string_roundtrip()
    print("test_all_empty_string_roundtrip PASSED")
    print("ALL SPILL CODEC BOUNDARY TESTS PASSED")
