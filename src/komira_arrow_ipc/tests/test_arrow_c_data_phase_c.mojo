# =============================================================================
# Arrow C Data Interface — Dictionary slot, kv-metadata, flag bits
#
# The round-trip surface covered here:
#
#   1. `CArrowSchema.metadata` encode/decode (Arrow's length-prefixed packed
#      format: i32 count + repeated (i32 klen + bytes + i32 vlen + bytes)).
#
#   2. `CArrowSchema.dictionary` + `CArrowArray.dictionary` slot population.
#      A dictionary-encoded column round-trips: parent schema format = index
#      type (`i` for INT32), dictionary slot = child schema with value-type
#      format (`u` for STRING); parent array buffers = (validity, i32
#      indices); dictionary slot = child array with the value table's 3
#      buffers (validity, i32 offsets, utf8 bytes).
#
#   3. `ARROW_FLAG_DICTIONARY_ORDERED` (bit 1) and `ARROW_FLAG_MAP_KEYS_SORTED`
#      (bit 4) honoring, carried by `Field._flags: Int64` + `Field.set_flag()`
#      through the C-Data export+import.
#
# The fixtures use a Mojo -> CArrowArrayStream -> Mojo round-trip (the same
# pattern as `test_arrow_c_data_stream`). A PyArrow cross-language round-trip
# is the *point* of the C ABI but needs a Python bridge that is not wired
# here; the in-process round-trip is the gate.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow_ipc.c_data_interface import (
    encode_metadata,
    decode_metadata,
    ARROW_FLAG_NULLABLE,
    ARROW_FLAG_DICTIONARY_ORDERED,
    ARROW_FLAG_MAP_KEYS_SORTED,
)
from komira_arrow_ipc.c_data_stream import (
    CArrowArray,
    CArrowArrayStream,
    build_record_batch_stream,
    drain_record_batch_stream,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

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


def _make_dict_string_column(values: List[String], indices: List[Int32]) raises -> Column[HeapRegion]:
    """Build a DICTIONARY Column[HeapRegion] carrying STRING values keyed by INT32
    indices.  Uses the canonical `Column.from_dictionary` path."""
    var dict_strings = StringArray.from_strings(values.copy())
    var idx_arr = PrimitiveArray[DType.int32].from_list(indices.copy())
    var dict_arr = StringDictionaryArray.from_parts(idx_arr^, dict_strings^)
    return Column.from_dictionary(dict_arr)


def _stream_round_trip(
    var batches: Slab[RecordBatch], var schema_for_stream: Schema
) raises -> Slab[RecordBatch]:
    """Push batches through a CArrowArrayStream + drain it back; helper to
    keep the per-test boilerplate compact."""
    var c_stream = CArrowArrayStream()
    var stream_ptr = UnsafePointer(to=c_stream).unsafe_origin_cast[MutUntrackedOrigin]()
    build_record_batch_stream(batches^, schema_for_stream^, stream_ptr)
    var out = drain_record_batch_stream(stream_ptr)
    assert_true(c_stream.is_released(), "stream released after drain")
    return out^


# --- Metadata helper round-trip (pure helper, no C-Data stream) -------------


def _is_null_int8_ptr(p: UnsafePointer[Int8, MutUntrackedOrigin]) -> Bool:
    return p == _null_ptr[Int8, MutUntrackedOrigin]()


def test_encode_decode_metadata_round_trip() raises:
    """`encode_metadata` -> `decode_metadata` round-trip: 3 kv-pairs preserved
    byte-identical (key + value strings; empty value tolerated)."""
    var keys = List[String]()
    keys.append(String("ARROW:extension:name"))
    keys.append(String("ARROW:extension:metadata"))
    keys.append(String("user_key"))
    var values = List[String]()
    values.append(String("geoarrow.point"))
    values.append(String(""))  # empty value (legal per spec)
    values.append(String("user_value"))
    var encoded = encode_metadata(keys.copy(), values.copy())
    assert_false(_is_null_int8_ptr(encoded), "encode_metadata returns non-NULL for 3 entries")
    var decoded = decode_metadata(encoded)
    var d_keys = decoded[0].copy()
    var d_values = decoded[1].copy()
    assert_equal(len(d_keys), 3, "decoded count == 3")
    assert_equal(len(d_values), 3, "decoded values count == 3")
    assert_true(d_keys[0] == String("ARROW:extension:name"), "key[0] preserved")
    assert_true(d_values[0] == String("geoarrow.point"), "value[0] preserved")
    assert_true(d_keys[1] == String("ARROW:extension:metadata"), "key[1] preserved")
    assert_true(d_values[1] == String(""), "value[1] empty preserved")
    assert_true(d_keys[2] == String("user_key"), "key[2] preserved")
    assert_true(d_values[2] == String("user_value"), "value[2] preserved")
    encoded.free()


def test_encode_empty_metadata_returns_null() raises:
    """Empty kv-list encodes to a NULL pointer (Arrow spec canonical form
    for "no metadata") so `decode_metadata(NULL)` round-trips an empty list."""
    var keys = List[String]()
    var values = List[String]()
    var encoded = encode_metadata(keys^, values^)
    # encode_metadata returns NULL pointer for n==0.
    assert_true(_is_null_int8_ptr(encoded), "empty kv-list encodes to NULL")
    var decoded = decode_metadata(encoded)
    var d_keys = decoded[0].copy()
    var d_values = decoded[1].copy()
    assert_equal(len(d_keys), 0, "NULL decoded as empty list")
    assert_equal(len(d_values), 0, "NULL decoded as empty list")


def test_decode_metadata_with_long_value() raises:
    """A 200-byte value round-trips intact — sanity check on the i32 length
    prefix + memcpy path for non-trivial payloads."""
    var keys = List[String]()
    keys.append(String("ARROW:extension:metadata"))
    var values = List[String]()
    # 200 chars
    var big = String("")
    for _ in range(20):
        big += String("0123456789")
    values.append(big.copy())
    var encoded = encode_metadata(keys^, values^)
    assert_false(_is_null_int8_ptr(encoded), "encode_metadata non-NULL")
    var decoded = decode_metadata(encoded)
    var d_keys = decoded[0].copy()
    var d_values = decoded[1].copy()
    assert_equal(len(d_keys), 1, "1 entry")
    assert_equal(d_values[0].byte_length(), 200, "value bytes preserved")
    assert_true(d_values[0] == big, "value content preserved")
    encoded.free()


# --- Dictionary C-Data round-trip ------------------------------------------


def test_c_data_dictionary_round_trip() raises:
    """A dictionary-encoded STRING column (int32 indices) survives a full
    C-Data export + drain.  Validates:
      * parent CArrowSchema.format = "i" (the index type)
      * CArrowSchema.dictionary slot carries a child schema with format "u"
      * indices and dictionary value table survive on the import side
      * `Schema.field_at(0)` reconstructs a DICTIONARY Field with INT32 index
    """
    var values = List[String]()
    values.append(String("apple"))
    values.append(String("banana"))
    values.append(String("cherry"))
    var indices = List[Int32]()
    indices.append(Int32(0))
    indices.append(Int32(1))
    indices.append(Int32(0))
    indices.append(Int32(2))
    indices.append(Int32(1))
    var col = _make_dict_string_column(values, indices)

    var sb = SchemaBuilder()
    sb.add_field(Field.dictionary("category", ArrowType.INT32, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field.dictionary("category", ArrowType.INT32, nullable=False))
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out_batches), 1, "one chunk drained")
    ref rb = out_batches[0]
    assert_equal(rb.num_columns(), 1, "1 column")
    assert_equal(rb.num_rows(), 5, "5 rows")
    assert_true(
        rb.schema.field_arrow_type(0) == ArrowType.DICTIONARY, "col0 DICTIONARY"
    )
    # `_dict_index_type` survives.
    var f_reconstructed = rb.schema.field_at(0)
    assert_true(
        f_reconstructed.dict_index_type() == ArrowType.INT32,
        "index type INT32 preserved",
    )
    # The dictionary array survives — round-trip the indices and values.
    var dict_col_out = rb.column_at(0).as_dictionary()
    assert_equal(dict_col_out.length, 5, "indices length 5")
    assert_equal(len(dict_col_out.dictionary), 3, "3 unique values")


def test_c_data_dictionary_field_format_string() raises:
    """`Field.dictionary(...).format_string()` returns the INDEX type's
    format — the parent CArrowSchema.format value. Sanity-check the
    `format_string()` source-of-truth contract the export relies on."""
    var f32 = Field.dictionary("c", ArrowType.INT32, nullable=True)
    assert_true(f32.format_string() == String("i"), "INT32 indices -> 'i'")
    var f8 = Field.dictionary("c", ArrowType.INT8, nullable=True)
    assert_true(f8.format_string() == String("c"), "INT8 indices -> 'c'")
    var f64 = Field.dictionary("c", ArrowType.INT64, nullable=True)
    assert_true(f64.format_string() == String("l"), "INT64 indices -> 'l'")


# --- Extension kv-metadata round-trip via C-Data stream ---------------------


def test_c_data_extension_metadata_round_trip() raises:
    """An int32 column carrying `ARROW:extension:name` +
    `ARROW:extension:metadata` kv-pairs survives the full C-Data stream
    round-trip.  Validates:
      * `Field.set_metadata` -> `_metadata_keys/_values` on export
      * encode_metadata packs the Arrow length-prefixed payload
      * import side decodes + re-attaches via `Field.set_metadata`
    """
    var data = PrimitiveArray[DType.int32].from_list(
        [Int32(10), Int32(20), Int32(30)]
    )

    var field_in = Field("geo", ArrowType.INT32, nullable=False)
    field_in.set_metadata(
        String("ARROW:extension:name"), String("geoarrow.point")
    )
    field_in.set_metadata(
        String("ARROW:extension:metadata"), String("epsg:4326")
    )
    field_in.set_metadata(String("user:annotation"), String("test_column"))

    var sb = SchemaBuilder()
    sb.add_field(field_in^)
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int32](data^))
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var field_in2 = Field("geo", ArrowType.INT32, nullable=False)
    field_in2.set_metadata(
        String("ARROW:extension:name"), String("geoarrow.point")
    )
    field_in2.set_metadata(
        String("ARROW:extension:metadata"), String("epsg:4326")
    )
    field_in2.set_metadata(String("user:annotation"), String("test_column"))
    var sb2 = SchemaBuilder()
    sb2.add_field(field_in2^)
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out_batches), 1, "one chunk drained")
    ref rb = out_batches[0]

    var f_out = rb.schema.field_at(0)
    assert_true(
        f_out.has_metadata(String("ARROW:extension:name")),
        "ext-name key preserved",
    )
    assert_true(
        f_out.get_metadata(String("ARROW:extension:name")).value()
            == String("geoarrow.point"),
        "ext-name value byte-identical",
    )
    assert_true(
        f_out.get_metadata(String("ARROW:extension:metadata")).value()
            == String("epsg:4326"),
        "ext-metadata value byte-identical",
    )
    assert_true(
        f_out.get_metadata(String("user:annotation")).value()
            == String("test_column"),
        "user kv value byte-identical",
    )
    assert_equal(f_out.metadata_count(), 3, "3 kv pairs survive")


# --- Flag bit round-trip ----------------------------------------------------


def test_c_data_dictionary_ordered_flag_round_trip() raises:
    """ARROW_FLAG_DICTIONARY_ORDERED (bit 1) survives the round-trip on a
    dictionary column."""
    var values = List[String]()
    values.append(String("low"))
    values.append(String("med"))
    values.append(String("high"))
    var indices = List[Int32]()
    indices.append(Int32(0))
    indices.append(Int32(1))
    indices.append(Int32(2))
    var col = _make_dict_string_column(values, indices)

    var f_in = Field.dictionary("level", ArrowType.INT32, nullable=False)
    f_in.set_flag(ARROW_FLAG_DICTIONARY_ORDERED, True)
    assert_true(f_in.is_dictionary_ordered(), "flag set on input field")

    var sb = SchemaBuilder()
    sb.add_field(f_in^)
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var f_in2 = Field.dictionary("level", ArrowType.INT32, nullable=False)
    f_in2.set_flag(ARROW_FLAG_DICTIONARY_ORDERED, True)
    var sb2 = SchemaBuilder()
    sb2.add_field(f_in2^)
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out_batches), 1, "one chunk")
    ref rb = out_batches[0]
    var f_out = rb.schema.field_at(0)
    assert_true(
        f_out.is_dictionary_ordered(),
        "ARROW_FLAG_DICTIONARY_ORDERED survives round-trip",
    )
    # ARROW_FLAG_NULLABLE is OR'd in at export-time from `nullable`; here
    # the field is non-nullable so that bit must NOT be set.
    assert_false(
        (f_out.flags() & ARROW_FLAG_NULLABLE) != 0,
        "nullable bit reflects non-null field",
    )


def test_c_data_map_keys_sorted_flag_round_trip() raises:
    """ARROW_FLAG_MAP_KEYS_SORTED (bit 4) survives a round-trip on a plain
    int32 column. The flag is per-Field and passed through unchanged; this
    test covers the bit, not the Map type."""
    var data = PrimitiveArray[DType.int32].from_list(
        [Int32(1), Int32(2), Int32(3)]
    )

    var f_in = Field("k", ArrowType.INT32, nullable=True)
    f_in.set_flag(ARROW_FLAG_MAP_KEYS_SORTED, True)
    assert_true(f_in.are_map_keys_sorted(), "flag set on input field")

    var sb = SchemaBuilder()
    sb.add_field(f_in^)
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int32](data^))
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var f_in2 = Field("k", ArrowType.INT32, nullable=True)
    f_in2.set_flag(ARROW_FLAG_MAP_KEYS_SORTED, True)
    var sb2 = SchemaBuilder()
    sb2.add_field(f_in2^)
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    ref rb = out_batches[0]
    var f_out = rb.schema.field_at(0)
    assert_true(
        f_out.are_map_keys_sorted(),
        "ARROW_FLAG_MAP_KEYS_SORTED survives round-trip",
    )
    # And the nullable bit also survives (input was nullable).
    assert_true(
        (f_out.flags() & ARROW_FLAG_NULLABLE) != 0,
        "nullable bit set on round-trip",
    )


def test_c_data_no_flags_clears_to_minimum() raises:
    """A Field built without explicit flags only carries the
    NULLABLE-derived bit after round-trip — no spurious flag bits accreted."""
    var data = PrimitiveArray[DType.int64].from_list(
        [Int64(42), Int64(7)]
    )

    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int64](data^))
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field("x", ArrowType.INT64, nullable=False))
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    ref rb = out_batches[0]
    var f_out = rb.schema.field_at(0)
    assert_equal(
        Int(f_out.flags()),
        0,
        "non-nullable + no explicit flags == 0",
    )
    assert_false(f_out.is_dictionary_ordered(), "no DICT_ORDERED")
    assert_false(f_out.are_map_keys_sorted(), "no MAP_KEYS_SORTED")


# --- Timestamp tz round-trip (fidelity bug fixed by the Field-driven path) -


def test_c_data_timestamp_tz_round_trip() raises:
    """A TIMESTAMP_US column with a non-empty tz survives the round-trip.
    The export must use `Field.format_string()`, which emits `tsu:<tz>`;
    `arrow_t.format_string()` emits `tsu:` (empty suffix) and would drop the
    timezone silently."""
    var values = [Int64(1_700_000_000_000_000), Int64(1_700_000_001_000_000)]
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * 8, 1))
    for i in range(n):
        buf.write_i64_le_at(i * 8, values[i])
    buf.set_length(Int64(n * 8))

    var col = Column[HeapRegion](
        arrow_type=ArrowType.TIMESTAMP_US,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )

    var f_in = Field.timestamp(
        "ts", ArrowType.TIMESTAMP_US, String("America/New_York"), nullable=False
    )
    var sb = SchemaBuilder()
    sb.add_field(f_in^)
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var f_in2 = Field.timestamp(
        "ts", ArrowType.TIMESTAMP_US, String("America/New_York"), nullable=False
    )
    var sb2 = SchemaBuilder()
    sb2.add_field(f_in2^)
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    ref rb = out_batches[0]
    var f_out = rb.schema.field_at(0)
    assert_true(
        f_out.arrow_type == ArrowType.TIMESTAMP_US,
        "TIMESTAMP_US type preserved",
    )
    assert_true(
        f_out.timezone() == String("America/New_York"),
        "tz suffix preserved through export+import",
    )


def main() raises:
    var suite = TestSuite()
    # metadata helper round-trip
    suite.test[test_encode_decode_metadata_round_trip]()
    suite.test[test_encode_empty_metadata_returns_null]()
    suite.test[test_decode_metadata_with_long_value]()
    # dictionary C-Data round-trip
    suite.test[test_c_data_dictionary_round_trip]()
    suite.test[test_c_data_dictionary_field_format_string]()
    # extension kv-metadata
    suite.test[test_c_data_extension_metadata_round_trip]()
    # flag round-trip
    suite.test[test_c_data_dictionary_ordered_flag_round_trip]()
    suite.test[test_c_data_map_keys_sorted_flag_round_trip]()
    suite.test[test_c_data_no_flags_clears_to_minimum]()
    # silent fidelity bug fix
    suite.test[test_c_data_timestamp_tz_round_trip]()
    suite^.run()
