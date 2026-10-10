# =============================================================================
# FFI-BOUNDARY: the C ABI of the arrow_c_abi_probe shared library.
# =============================================================================
# Three `@export abi("C")` functions put komira_arrow_ipc's Arrow C Stream
# Interface behind a real dynamic-library boundary, so separately compiled
# consumers (the two gate drivers, arrow_c_abi_driver.mojo and
# arrow_c_abi_error_driver.mojo, which share no type with this file) reach
# every callback through a C function pointer, as pyarrow or arrow-rs would:
#
#   probe_export_stream(struct ArrowArrayStream *out) -> int32
#       fills the caller's struct with a stream of two fixed record batches
#       (columns int64, float64, nullable utf8, large utf8, dictionary<int32,
#       utf8>, decimal128(10, 2)). The caller owns the stream and every schema
#       and array it hands out, and releases each of them.
#   probe_export_failing_stream(struct ArrowArrayStream *out) -> int32
#       fills the caller's struct with an empty stream whose one column is a
#       list<int64>. Its get_schema fails with EIO (an empty stream has no
#       sample batch to derive a nested child type from), and its
#       get_last_error then returns the error text. The caller releases it.
#   probe_import_stream(struct ArrowArrayStream *in, uint64_t *checksum,
#                       char *err, int64_t err_cap) -> int32
#       drains a caller-produced stream with drain_record_batch_stream (which
#       calls the caller's release callbacks) and writes a checksum of the
#       imported values. On failure it writes the error message, which
#       includes the text the caller's get_last_error returned, to `err` as a
#       NUL-terminated string of at most `err_cap` bytes. The caller owns
#       `in`'s memory; this library calls only the release callbacks the
#       caller put in it.
#
# All three return 0 on success and 5 (EIO) after printing the error.
#
# Ownership across the boundary: every pointer the caller passes stays the
# caller's. `probe_export_stream` writes into `*out`; the buffers it hands out
# are freed by the release callbacks this library installs, when the caller
# calls them. `probe_import_stream` frees nothing the caller produced.
#
# The checksum is FNV-1a 64 over, per batch: the row count (8 bytes LE); per
# column, the name bytes, a type tag (int64 1, float64 2, utf8 3, large utf8 4,
# dictionary 5, decimal128 6, then precision and scale bytes); then per row a
# 0 byte for NULL, or a 1 byte and the value: int64 8 bytes LE, float64 its 8
# IEEE bytes LE, a string its byte length (8 bytes LE) and bytes (a dictionary
# row is its decoded value), a decimal128 its 16 bytes LE. The driver computes
# the same function over the values it put in the stream.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow_ipc.c_data_stream import (
    CArrowArrayStream,
    build_record_batch_stream,
    drain_record_batch_stream,
)
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from std.memory import bitcast

comptime _StreamPtr = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]
comptime _EIO: Int32 = 5


# --- the exported batches ------------------------------------------------------


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, nullable=False))
    sb.add_field(Field("f", ArrowType.FLOAT64, nullable=False))
    sb.add_field(Field("s", ArrowType.STRING, nullable=True))
    sb.add_field(Field("ls", ArrowType.LARGE_STRING, nullable=False))
    sb.add_field(Field.dictionary("d", ArrowType.INT32, nullable=False))
    sb.add_field(Field.decimal128("m", 10, 2, nullable=False))
    return sb.build()


def _i128(v: Int64) -> SIMD[DType.int128, 1]:
    return SIMD[DType.int128, 1](v)


def _batch(
    i64: List[Int64],
    f64: List[Float64],
    s: List[String],
    s_valid: List[Bool],
    ls: List[String],
    d_idx: List[Int32],
    d_values: List[String],
    m: List[SIMD[DType.int128, 1]],
) raises -> RecordBatch:
    var n = len(i64)
    var dec = Decimal128Array.allocate(n, 10, 2)
    for r in range(n):
        dec.set_i128(r, m[r])
    var rbb = RecordBatchBuilder.with_capacity(6)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(i64.copy())))
    rbb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(f64.copy())))
    rbb.add_column(Column.from_string(StringArray.from_strings_with_validity(s.copy(), s_valid.copy())))
    rbb.add_column(Column.from_large_string(LargeStringArray.from_strings(ls.copy())))
    rbb.add_column(
        Column.from_dictionary(
            StringDictionaryArray(
                PrimitiveArray[DType.int32].from_list(d_idx.copy()),
                StringArray.from_strings(d_values.copy()),
                n,
            )
        )
    )
    rbb.add_column(Column.from_decimal128(dec))
    return rbb.build(_schema())


def _batch0() raises -> RecordBatch:
    return _batch(
        [Int64(11), Int64(-22), Int64(33), Int64(44)],
        [Float64(1.5), Float64(-2.25), Float64(3.125), Float64(4096.5)],
        [String("alpha"), String("ignored"), String(""), String("delta")],
        [True, False, True, True],
        [String("one"), String("two"), String("three"), String("four")],
        [Int32(2), Int32(0), Int32(1), Int32(2)],
        [String("AIR"), String("RAIL"), String("SHIP")],
        [_i128(12345), _i128(-1), _i128(0), _i128(99999)],
    )


def _batch1() raises -> RecordBatch:
    var big = (_i128(1) << _i128(70)) | _i128(7)
    return _batch(
        [Int64(55), Int64(66), Int64(-77)],
        [Float64(0.5), Float64(8.0), Float64(-16.75)],
        [String("ignored"), String("zeta"), String("eta")],
        [False, True, True],
        [String("x"), String(""), String("yz")],
        [Int32(1), Int32(1), Int32(0)],
        [String("P"), String("Q")],
        [_i128(100), _i128(-100), big],
    )


# --- the checksum --------------------------------------------------------------


struct _Fnv:
    var h: UInt64

    def __init__(out self):
        self.h = UInt64(0xCBF29CE484222325)

    def byte(mut self, b: UInt8):
        self.h = (self.h ^ UInt64(b)) * UInt64(0x100000001B3)

    def u64(mut self, v: UInt64):
        for k in range(8):
            self.byte(UInt8((v >> UInt64(8 * k)) & UInt64(0xFF)))

    def text(mut self, s: String):
        var b = s.as_bytes()
        self.u64(UInt64(len(b)))
        for k in range(len(b)):
            self.byte(b[k])


def _checksum(ref batches: Slab[RecordBatch]) raises -> UInt64:
    var h = _Fnv()
    for b in range(len(batches)):
        ref rb = batches[b]
        var rows = rb.num_rows()
        h.u64(UInt64(rows))
        for c in range(rb.num_columns()):
            ref col = rb.column_at(c)
            var name = rb.schema.field_name(c)
            var nb = name.as_bytes()
            for k in range(len(nb)):
                h.byte(nb[k])
            var t = col.arrow_type
            if t == ArrowType.INT64:
                h.byte(1)
                var a = col.as_primitive[DType.int64]()
                for r in range(rows):
                    if col.is_null_at(r):
                        h.byte(0)
                    else:
                        h.byte(1)
                        h.u64(a.get(r).cast[DType.uint64]())
            elif t == ArrowType.FLOAT64:
                h.byte(2)
                var a = col.as_primitive[DType.float64]()
                for r in range(rows):
                    if col.is_null_at(r):
                        h.byte(0)
                    else:
                        h.byte(1)
                        h.u64(bitcast[DType.uint64](a.get(r)))
            elif t == ArrowType.STRING:
                h.byte(3)
                var a = col.as_string()
                for r in range(rows):
                    if col.is_null_at(r):
                        h.byte(0)
                    else:
                        h.byte(1)
                        h.text(a.get(r))
            elif t == ArrowType.LARGE_STRING:
                h.byte(4)
                var a = col.as_large_string()
                for r in range(rows):
                    if col.is_null_at(r):
                        h.byte(0)
                    else:
                        h.byte(1)
                        h.text(a.get(r))
            elif t == ArrowType.DICTIONARY:
                h.byte(5)
                var a = col.as_dictionary()
                for r in range(rows):
                    if col.is_null_at(r):
                        h.byte(0)
                    else:
                        h.byte(1)
                        h.text(a.get(r))
            elif t == ArrowType.DECIMAL128:
                h.byte(6)
                h.byte(UInt8(rb.schema.field_decimal_precision(c)))
                h.byte(UInt8(rb.schema.field_decimal_scale(c)))
                var a = col.as_decimal128()
                for r in range(rows):
                    if col.is_null_at(r):
                        h.byte(0)
                    else:
                        h.byte(1)
                        var v = a.get_i128(r)
                        h.u64(v.cast[DType.uint64]())
                        h.u64((v >> SIMD[DType.int128, 1](64)).cast[DType.uint64]())
            else:
                raise Error("probe_import_stream: column " + name + " has unexpected type " + String(t))
    return h.h


# --- the C ABI -----------------------------------------------------------------


@export
def probe_export_stream(out_stream: _StreamPtr) abi("C") -> Int32:
    """Fill `*out_stream` with the two fixed batches. The caller releases it."""
    try:
        var batches = Slab[RecordBatch].with_capacity(2)
        batches.append(_batch0())
        batches.append(_batch1())
        build_record_batch_stream(batches^, _schema(), out_stream)
    except e:
        print("probe_export_stream: " + String(e))
        return _EIO
    return 0


@export
def probe_export_failing_stream(out_stream: _StreamPtr) abi("C") -> Int32:
    """Fill `*out_stream` with an empty stream of one list<int64> column,
    whose get_schema fails. The caller releases it."""
    try:
        var sb = SchemaBuilder()
        sb.add_field(Field.list_of("l", ArrowType.INT64, nullable=True))
        build_record_batch_stream(Slab[RecordBatch].with_capacity(1), sb.build(), out_stream)
    except e:
        print("probe_export_failing_stream: " + String(e))
        return _EIO
    return 0


def _write_c_string(msg: String, dst: UnsafePointer[UInt8, MutUntrackedOrigin], cap: Int64):
    """Copy `msg` into the caller's `dst[0:cap]`, truncated, NUL-terminated."""
    if cap <= 0:
        return
    var b = msg.as_bytes()
    var n = min(len(b), Int(cap) - 1)
    for k in range(n):
        # SAFETY: k < cap - 1, inside the caller's `err_cap` bytes.
        dst[k] = b[k]
    dst[n] = 0


@export
def probe_import_stream(
    in_stream: _StreamPtr,
    out_checksum: UnsafePointer[UInt64, MutUntrackedOrigin],
    err: UnsafePointer[UInt8, MutUntrackedOrigin],
    err_cap: Int64,
) abi("C") -> Int32:
    """Drain the caller's `*in_stream` (releasing it) and write the checksum of
    its values to `*out_checksum`; on failure write the error to `err`."""
    try:
        var batches = drain_record_batch_stream(in_stream)
        # SAFETY: `out_checksum` is the caller's live `uint64_t`; one write.
        out_checksum[] = _checksum(batches)
    except e:
        var msg = "probe_import_stream: " + String(e)
        print(msg)
        _write_c_string(msg, err, err_cap)
        return _EIO
    return 0
