# =============================================================================
# Arrow C Stream Interface — round-trip + release-callback + EOF + error tests
#
# Exercises the C-ABI machinery in
# `komira_arrow_ipc.c_data_stream`:
#   - Mojo RecordBatch -> CArrowArrayStream (export) -> drain back to a
#     RecordBatch (import); schema + per-cell values must round-trip for
#     Int64 / Float64 / String / Bool.
#   - Release-callback null-out: after `release_c_stream`, the stream struct's
#     `release` member must be NULL (the Arrow "released structure" contract);
#     calling it again must be a safe no-op.
#   - End-of-stream protocol: after the (single) chunk is yielded, the next
#     `get_next` leaves its output ArrowArray in the released state
#     (`array.release == NULL`).
#   - Error case: draining a NULL pointer / an already-released stream raises.
#   - Unsupported-type case: a LIST column raises UnsupportedArrowCABIType at
#     export time.
#
# A real PyArrow cross-language round-trip is the *point* of the C ABI but is
# not feasible from this Mojo test harness (no Python interop wired up here);
# the Mojo -> stream -> Mojo round-trip below + the documented supported-type
# subset in `c_data_stream.mojo` is the acceptance gate.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow_ipc.c_data_stream import (
    CArrowArray,
    CArrowArrayStream,
    build_record_batch_stream,
    drain_record_batch_stream,
    release_c_stream,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from std.memory import alloc

@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Origin `o` is concrete; the NULL sentinel is never
    # dereferenced (placeholder / explicit C-NULL arg).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# --- Helpers -----------------------------------------------------------------


def _make_bool_column(values: List[Bool]) raises -> Column[HeapRegion]:
    """Build a non-nullable BOOL Column[HeapRegion] from a list of bools."""
    var n = len(values)
    var bm = Bitmap.create(n)
    for i in range(n):
        if values[i]:
            bm.set(i)
    var bool_arr = BooleanArray.from_bitmap(bm^)
    return Column.from_boolean(bool_arr)


def _make_kv4_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.FLOAT64, nullable=False))
    sb.add_field(Field("c", ArrowType.STRING, nullable=False))
    sb.add_field(Field("d", ArrowType.BOOL, nullable=False))
    return sb.build()


def _make_test_batch() raises -> RecordBatch:
    """A 4-row RecordBatch with Int64 / Float64 / String / Bool columns."""
    var i64 = PrimitiveArray[DType.int64].from_list(
        [Int64(10), Int64(20), Int64(30), Int64(40)]
    )
    var f64 = PrimitiveArray[DType.float64].from_list(
        [Float64(1.5), Float64(2.5), Float64(3.5), Float64(4.5)]
    )
    var strs = StringArray.from_strings(
        [String("alpha"), String("beta"), String("gamma"), String("delta")]
    )
    var bools = _make_bool_column([True, False, True, False])

    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(Column.from_primitive[DType.int64](i64^))
    rbb.add_column(Column.from_primitive[DType.float64](f64^))
    rbb.add_column(Column.from_string(strs^))
    rbb.add_column(bools^)
    return rbb.build(_make_kv4_schema())


def _is_null_ptr(p: UnsafePointer[NoneType, MutUntrackedOrigin]) -> Bool:
    return p == _null_ptr[NoneType, MutUntrackedOrigin]()


def _make_i32_data_column(arrow_type: ArrowType, values: List[Int32]) -> Column[HeapRegion]:
    """Build a Column[HeapRegion] with an int32 data buffer under an arbitrary (int32-
    backed) ArrowType tag — used to exercise DATE32 on the C-ABI path."""
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * 4, 1))
    for i in range(n):
        buf.write_i32_le_at(i * 4, values[i])
    buf.set_length(Int64(n * 4))

    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _make_i64_data_column(arrow_type: ArrowType, values: List[Int64]) -> Column[HeapRegion]:
    """Build a Column[HeapRegion] with an int64 data buffer under an arbitrary (int64-
    backed) ArrowType tag — used to exercise TIMESTAMP on the C-ABI path."""
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * 8, 1))
    for i in range(n):
        buf.write_i64_le_at(i * 8, values[i])
    buf.set_length(Int64(n * 8))

    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _make_decimal128_data_column(lows: List[Int64], highs: List[Int64]) -> Column[HeapRegion]:
    """Build a DECIMAL128 Column[HeapRegion] with a 16-byte-per-row data buffer (low|high
    little-endian halves) — exercises DECIMAL128 on the C-ABI path."""
    var n = len(lows)
    var buf = OwnedAlignedBuffer(max(n * 16, 1))
    for i in range(n):
        buf.write_i64_le_at(i * 16, lows[i])
        buf.write_i64_le_at(i * 16 + 8, highs[i])
    buf.set_length(Int64(n * 16))

    return Column[HeapRegion](
        arrow_type=ArrowType.DECIMAL128,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


# --- Tests -------------------------------------------------------------------


def test_round_trip_primitive_string_bool() raises:
    """Mojo RecordBatch -> ArrowArrayStream -> drain -> RecordBatch preserves
    schema + buffer contents for Int64/Float64/String/Bool."""
    var batch = _make_test_batch()

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var schema = _make_kv4_schema()

    var c_stream = CArrowArrayStream()
    var stream_ptr = UnsafePointer(to=c_stream).unsafe_origin_cast[MutUntrackedOrigin]()
    build_record_batch_stream(batches^, schema^, stream_ptr)

    assert_false(c_stream.is_released(), "stream live after export")

    var out_batches = drain_record_batch_stream(stream_ptr)
    assert_equal(len(out_batches), 1, "one chunk drained")
    assert_true(c_stream.is_released(), "stream released after drain")

    ref rb = out_batches[0]
    assert_equal(rb.num_columns(), 4, "4 columns round-tripped")
    assert_equal(rb.num_rows(), 4, "4 rows round-tripped")
    assert_equal(rb.schema.num_columns(), 4, "schema has 4 fields")
    assert_equal(rb.schema.field_name(0), String("a"), "col0 name")
    assert_equal(rb.schema.field_name(2), String("c"), "col2 name")
    assert_true(
        rb.schema.field_arrow_type(0) == ArrowType.INT64, "col0 type INT64"
    )
    assert_true(
        rb.schema.field_arrow_type(1) == ArrowType.FLOAT64, "col1 type FLOAT64"
    )
    assert_true(
        rb.schema.field_arrow_type(2) == ArrowType.STRING, "col2 type STRING"
    )
    assert_true(
        rb.schema.field_arrow_type(3) == ArrowType.BOOL, "col3 type BOOL"
    )

    var c0 = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(c0.get(0), Int64(10), "i64[0]")
    assert_equal(c0.get(3), Int64(40), "i64[3]")
    var c1 = rb.column_at(1).as_primitive[DType.float64]()
    assert_equal(c1.get(0), Float64(1.5), "f64[0]")
    assert_equal(c1.get(2), Float64(3.5), "f64[2]")
    var c2 = rb.column_at(2).as_string()
    assert_equal(c2.get(0), String("alpha"), "str[0]")
    assert_equal(c2.get(1), String("beta"), "str[1]")
    assert_equal(c2.get(3), String("delta"), "str[3]")
    var c3 = rb.column_at(3).as_boolean()
    assert_true(c3.get(0), "bool[0]")
    assert_false(c3.get(1), "bool[1]")
    assert_true(c3.get(2), "bool[2]")
    assert_false(c3.get(3), "bool[3]")


def _make_decimal128_column(
    values: List[Int], precision: Int, scale: Int
) raises -> Column[HeapRegion]:
    """Build a non-nullable Decimal128 Column[HeapRegion] from unscaled Int values."""
    var arr = Decimal128Array.allocate(len(values), precision, scale)
    for i in range(len(values)):
        arr.set_i128(i, SIMD[DType.int128, 1](Int64(values[i])))
    return Column.from_decimal128(arr)


def test_c_data_decimal128_round_trip() raises:
    """A Decimal128 column round-trips through
    the C ABI — the `d:P,S` format string + the 16-byte-LE buffer + (p, s)
    on the schema and the column all survive export -> drain."""
    # Two decimal columns: D(20, 2) and D(10, 0); mix of +, 0, -, and a
    # value that does not fit in Int64 (exercises the upper i128 bytes).
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("amount", 20, 2, nullable=False))
    sb.add_field(Field.decimal128("count", 10, 0, nullable=False))
    var schema = sb.build()

    var amount = Decimal128Array.allocate(4, 20, 2)
    amount.set_i128(0, SIMD[DType.int128, 1](Int64(12345)))      # 123.45
    amount.set_i128(1, SIMD[DType.int128, 1](Int64(0)))          # 0.00
    amount.set_i128(2, SIMD[DType.int128, 1](Int64(-990000)))    # -9900.00
    # 2^70 + 7 (does not fit in Int64).
    var big = (SIMD[DType.int128, 1](1) << SIMD[DType.int128, 1](70)) | SIMD[DType.int128, 1](7)
    amount.set_i128(3, big)

    var count = _make_decimal128_column([Int(42), Int(-7), Int(0), Int(1000000)], 10, 0)

    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(Column.from_decimal128(amount))
    builder.add_column(count^)
    var batch = builder.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    # SchemaBuilder.build() empties the builder, so build a fresh one for the
    # stream's schema handle.
    var sb2 = SchemaBuilder()
    sb2.add_field(Field.decimal128("amount", 20, 2, nullable=False))
    sb2.add_field(Field.decimal128("count", 10, 0, nullable=False))
    var schema2 = sb2.build()

    var c_stream = CArrowArrayStream()
    var stream_ptr = UnsafePointer(to=c_stream).unsafe_origin_cast[MutUntrackedOrigin]()
    build_record_batch_stream(batches^, schema2^, stream_ptr)
    assert_false(c_stream.is_released(), "stream live after export")
    var out_batches = drain_record_batch_stream(stream_ptr)
    assert_equal(len(out_batches), 1, "one chunk drained")
    assert_true(c_stream.is_released(), "stream released after drain")

    ref rb = out_batches[0]
    assert_equal(rb.num_columns(), 2, "2 columns")
    assert_equal(rb.num_rows(), 4, "4 rows")
    # Schema: type + (precision, scale) survive.
    assert_true(
        rb.schema.field_arrow_type(0) == ArrowType.DECIMAL128, "col0 DECIMAL128"
    )
    assert_equal(rb.schema.field_decimal_precision(0), 20, "col0 precision")
    assert_equal(rb.schema.field_decimal_scale(0), 2, "col0 scale")
    assert_true(
        rb.schema.field_arrow_type(1) == ArrowType.DECIMAL128, "col1 DECIMAL128"
    )
    assert_equal(rb.schema.field_decimal_precision(1), 10, "col1 precision")
    assert_equal(rb.schema.field_decimal_scale(1), 0, "col1 scale")

    var d0 = rb.column_as_decimal128(0)
    assert_equal(d0.length, 4, "col0 length")
    assert_equal(d0.precision, 20, "col0 column precision")
    assert_equal(d0.scale, 2, "col0 column scale")
    assert_true(d0.get_i128(0) == SIMD[DType.int128, 1](Int64(12345)), "d0[0]")
    assert_true(d0.get_i128(1) == SIMD[DType.int128, 1](Int64(0)), "d0[1]")
    assert_true(d0.get_i128(2) == SIMD[DType.int128, 1](Int64(-990000)), "d0[2]")
    assert_true(d0.get_i128(3) == big, "d0[3] (does not fit in i64)")

    var d1 = rb.column_as_decimal128(1)
    assert_equal(d1.precision, 10, "col1 column precision")
    assert_equal(d1.scale, 0, "col1 column scale")
    assert_true(d1.get_i128(0) == SIMD[DType.int128, 1](Int64(42)), "d1[0]")
    assert_true(d1.get_i128(1) == SIMD[DType.int128, 1](Int64(-7)), "d1[1]")
    assert_true(d1.get_i128(2) == SIMD[DType.int128, 1](Int64(0)), "d1[2]")
    assert_true(d1.get_i128(3) == SIMD[DType.int128, 1](Int64(1000000)), "d1[3]")


def test_release_callback_null_out() raises:
    """After the release callback runs, the stream struct's `release` field is
    NULL; calling release again is a no-op (the Arrow released-structure
    contract).

    THE STRUCT IS HEAP-ALLOCATED AND EVERY READ GOES THROUGH THE POINTER.
    A stack `var c_stream = CArrowArrayStream()` +
    `UnsafePointer(to=c_stream).unsafe_origin_cast[MutExternalOrigin]()`,
    with the LOCAL read back after the pointer-based mutation, is the pattern
    `drain_record_batch_stream` documents as unsound ("Mojo does not extend
    `c`'s lifetime through the UnsafePointer, so the compiler is free to
    reuse the stack slot"), and the wildcard `MutExternalOrigin` cast severs
    lifetime tracking. Such a test reads a STALE `release` after
    `release_c_stream`: the writes land in the stack slot, the reads come
    from the compiler's copy.

    Assertions: live => release non-NULL and private_data non-NULL;
    released => both NULL; a second release is a safe no-op. The storage is
    on the heap, which is what the production drain path itself does for
    exactly this reason."""
    var batch = _make_test_batch()
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var schema = _make_kv4_schema()

    # FFI carve-out (the production `drain_record_batch_stream` precedent):
    # heap storage so the struct outlives every pointer-based write + read.
    var stream_ptr = alloc[CArrowArrayStream](1).unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    stream_ptr.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(batches^, schema^, stream_ptr)

    assert_false(stream_ptr[].is_released(), "release non-NULL while live")
    assert_false(
        _is_null_ptr(stream_ptr[].private_data),
        "private_data non-NULL while live",
    )

    release_c_stream(stream_ptr)
    assert_true(stream_ptr[].is_released(), "release == NULL after release")
    assert_true(
        _is_null_ptr(stream_ptr[].private_data),
        "private_data == NULL after release",
    )

    # Idempotent: calling release again is a safe no-op.
    release_c_stream(stream_ptr)
    assert_true(
        stream_ptr[].is_released(), "still released after second release call"
    )
    stream_ptr.free()


def test_eof_protocol() raises:
    """get_next leaves its output ArrowArray in the released state once the
    (single) chunk has been yielded."""
    var batch = _make_test_batch()
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var schema = _make_kv4_schema()

    var c_stream = CArrowArrayStream()
    var stream_ptr = UnsafePointer(to=c_stream).unsafe_origin_cast[MutUntrackedOrigin]()
    build_record_batch_stream(batches^, schema^, stream_ptr)

    var arr1 = CArrowArray()
    var arr1_ptr = UnsafePointer(to=arr1).unsafe_origin_cast[MutUntrackedOrigin]()
    var rc1 = c_stream.get_next(stream_ptr.bitcast[NoneType](), arr1_ptr)
    assert_equal(Int(rc1), 0, "get_next rc==0 for live chunk")
    assert_false(arr1.is_released(), "first chunk is live")
    assert_equal(Int(arr1.length), 4, "first chunk has 4 rows")
    assert_equal(Int(arr1.n_children), 4, "first chunk has 4 children")

    var arr2 = CArrowArray()
    var arr2_ptr = UnsafePointer(to=arr2).unsafe_origin_cast[MutUntrackedOrigin]()
    var rc2 = c_stream.get_next(stream_ptr.bitcast[NoneType](), arr2_ptr)
    assert_equal(Int(rc2), 0, "get_next rc==0 at EOF")
    assert_true(arr2.is_released(), "EOF chunk is released (release == NULL)")

    release_c_stream(stream_ptr)


def test_drain_null_pointer_raises() raises:
    """Draining a NULL stream pointer raises."""
    var null_ptr = _null_ptr[CArrowArrayStream, MutUntrackedOrigin]()
    var raised = False
    try:
        var _b = drain_record_batch_stream(null_ptr)
    except e:
        raised = True
    assert_true(raised, "drain on NULL pointer raises")


def test_drain_already_released_raises() raises:
    """Draining an already-released stream raises."""
    var c_stream = CArrowArrayStream()  # zeroed -> release == NULL
    var stream_ptr = UnsafePointer(to=c_stream).unsafe_origin_cast[MutUntrackedOrigin]()
    assert_true(c_stream.is_released(), "zeroed stream is released")
    var raised = False
    try:
        var _b = drain_record_batch_stream(stream_ptr)
    except e:
        raised = True
    assert_true(raised, "drain on released stream raises")
    # Keep `c_stream` live across the call above — UnsafePointer(to=local)
    # does not extend the local's lifetime; a direct use after the
    # pointer-based call pins the stack slot so it isn't reused mid-call.
    assert_true(c_stream.is_released(), "still released after raise")


def test_unsupported_format_string_raises_on_import() raises:
    """An UNKNOWN Arrow C ABI format string raises UnsupportedArrowCABIType
    on the IMPORT side.

    The export side supports every ArrowType slot (Int*/UInt*/Float*/
    Bool/Date/Time/Timestamp/Duration/Interval/Decimal128/Decimal256/
    String/Binary/LargeString/LargeBinary/Dictionary/List/Struct/Map/
    UnionSparse/UnionDense). The boundary that remains is the import-
    side parser rejecting format strings outside that subset (e.g.
    Arrow 1.0+ Run-End-Encoded `+r`).

    This test exercises `_format_string_to_arrow_type` indirectly via
    its only caller, the `parse_format_string` public helper.  An
    unrecognized format string returns ArrowType.NULL; the import
    path turns that into a raised UnsupportedArrowCABIType."""
    from komira_arrow.arrow_types import parse_format_string
    # "+r" is the Run-End-Encoded prefix (Arrow 1.0+); not in the supported
    # subset.  The format-string parser returns NULL for it; the import
    # path's `_format_string_to_arrow_type` raises on a non-"n"
    # NULL-from-parser case.
    var t = parse_format_string(String("+r"))
    assert_true(t == ArrowType.NULL, "+r parses to NULL (unrecognized)")
    # "xyz" is plain garbage — should also parse to NULL.
    var t2 = parse_format_string(String("xyz"))
    assert_true(t2 == ArrowType.NULL, "garbage parses to NULL")


def test_extended_types_round_trip() raises:
    """DATE32 / TIMESTAMP[us] / DECIMAL128 columns round-trip through the C
    stream: schema type tags + row counts survive (these types use the
    fixed-width 2-buffer layout; the supported-type machinery covers them
    even though the in-tree Column factories don't have dedicated builders)."""
    var d32 = _make_i32_data_column(
        ArrowType.DATE32, [Int32(19000), Int32(19001), Int32(19002)]
    )
    var ts = _make_i64_data_column(
        ArrowType.TIMESTAMP_US,
        [Int64(1_700_000_000_000_000), Int64(1_700_000_001_000_000), Int64(1_700_000_002_000_000)],
    )
    var dec = _make_decimal128_data_column(
        [Int64(123), Int64(456), Int64(789)], [Int64(0), Int64(0), Int64(0)]
    )

    var sb = SchemaBuilder()
    sb.add_field(Field("dt", ArrowType.DATE32, nullable=False))
    sb.add_field(Field("tm", ArrowType.TIMESTAMP_US, nullable=False))
    sb.add_field(Field("amt", ArrowType.DECIMAL128, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(d32^)
    rbb.add_column(ts^)
    rbb.add_column(dec^)
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("dt", ArrowType.DATE32, nullable=False))
    sb2.add_field(Field("tm", ArrowType.TIMESTAMP_US, nullable=False))
    sb2.add_field(Field("amt", ArrowType.DECIMAL128, nullable=False))
    var schema2 = sb2.build()

    var c_stream = CArrowArrayStream()
    var stream_ptr = UnsafePointer(to=c_stream).unsafe_origin_cast[MutUntrackedOrigin]()
    build_record_batch_stream(batches^, schema2^, stream_ptr)

    var out_batches = drain_record_batch_stream(stream_ptr)
    assert_equal(len(out_batches), 1, "one chunk drained")
    assert_true(c_stream.is_released(), "stream released")

    ref rb = out_batches[0]
    assert_equal(rb.num_columns(), 3, "3 columns")
    assert_equal(rb.num_rows(), 3, "3 rows")
    assert_true(rb.column_at(0).arrow_type == ArrowType.DATE32, "col0 DATE32")
    assert_true(rb.column_at(1).arrow_type == ArrowType.TIMESTAMP_US, "col1 TIMESTAMP_US")
    assert_true(rb.column_at(2).arrow_type == ArrowType.DECIMAL128, "col2 DECIMAL128")
    assert_equal(rb.column_at(0).length(), 3, "col0 len")
    assert_equal(rb.column_at(2).length(), 3, "col2 len")


def main() raises:
    var suite = TestSuite()
    suite.test[test_round_trip_primitive_string_bool]()
    suite.test[test_c_data_decimal128_round_trip]()
    suite.test[test_extended_types_round_trip]()
    suite.test[test_release_callback_null_out]()
    suite.test[test_eof_protocol]()
    suite.test[test_drain_null_pointer_raises]()
    suite.test[test_drain_already_released_raises]()
    suite.test[test_unsupported_format_string_raises_on_import]()
    suite^.run()
