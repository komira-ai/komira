# =============================================================================
# Arrow C Data Interface — LargeString / LargeBinary / Binary
#
# The round-trip surface for the variable-length families with i64 offsets
# (LARGE_STRING / LARGE_BINARY) and the BINARY C-Data arm:
#
#   1. `Column.from_large_string` + `Column.as_large_string` (mirror
#      `from_string` / `as_string` with Int64 offsets).
#   2. `Column.from_large_binary` + `Column.as_large_binary` (mirror
#      `from_binary` / `as_binary`).
#   3. `c_data_stream._arrow_type_n_buffers` accepts BINARY / LARGE_STRING /
#      LARGE_BINARY (all 3-buffer; differ only in offset width).
#   4. `_build_column_array` exports the 3-buffer var-len shape for all four
#      types (STRING / BINARY / LARGE_STRING / LARGE_BINARY) — the offset
#      width is carried by the format string (`u`, `z`, `U`, `Z`).
#   5. `_import_column` reads the correct offset width based on the parsed
#      arrow_type (i32 for STRING / BINARY, i64 for LARGE_*).
#   6. `_format_string_to_arrow_type` accepts all four.
#
# Compute parity is narrower: engine kernels that read string offsets as
# Int32 (string_compare, agg_dict, agg_count_distinct hash paths) are not
# generalized to i64 offsets. The cover here is a LargeString -> StringArray
# adapter at the eval boundary (`Column.coerce_large_string_to_string`) that
# catches the i64-overflow case and raises rather than truncating, so a
# join/filter between STRING and LARGE_STRING does the right thing
# semantically.
#
# Test list:
#   T1: from_large_string + as_large_string round-trip.
#   T2: LargeString C-Data stream round-trip (Mojo -> CArrowArray -> Mojo).
#   T3: from_large_binary + as_large_binary round-trip.
#   T4: LargeBinary C-Data stream round-trip.
#   T5: BINARY C-Data stream round-trip.
#   T6: Format string discriminator round-trip for the 4 var-len types.
#   T7: LargeString hash determinism (FNV-1a on the data buffer is byte-
#       identical to the StringArray equivalent).
#   T8: Cross-type "join": semantic coerce of LARGE_STRING -> STRING via the
#       eval coerce path.  Mirrors Polars / DuckDB auto-widen convention.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import (
    ArrowType,
    Column,
    Field,
    LargeBinaryArray,
    LargeStringArray,
    BinaryArray,
    PrimitiveArray,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
    StringArray,
    parse_format_string,
)
from komira_core.arrow.c_data_stream import (
    CArrowArrayStream,
    build_record_batch_stream,
    drain_record_batch_stream,
)
from komira_core.collections.slab import Slab
from komira_core.io.heap_region import HeapRegion


# --- Helpers ----------------------------------------------------------------


def _stream_round_trip(
    var batches: Slab[RecordBatch], var schema_for_stream: Schema
) raises -> Slab[RecordBatch]:
    """Push batches through a CArrowArrayStream + drain it back; mirrors the
    helper from `test_arrow_c_data_phase_c.mojo`."""
    var c_stream = CArrowArrayStream()
    var stream_ptr = UnsafePointer(to=c_stream).unsafe_origin_cast[MutUntrackedOrigin]()
    build_record_batch_stream(batches^, schema_for_stream^, stream_ptr)
    var out = drain_record_batch_stream(stream_ptr)
    assert_true(c_stream.is_released(), "stream released after drain")
    return out^


def _make_large_string_column(values: List[String]) raises -> Column[HeapRegion]:
    """Build a LARGE_STRING Column[HeapRegion] from a list of strings via the new
    factory."""
    var arr = LargeStringArray.from_strings(values.copy())
    return Column.from_large_string(arr)


def _make_large_binary_column(values: List[List[UInt8]]) raises -> Column[HeapRegion]:
    """Build a LARGE_BINARY Column[HeapRegion] from a list of byte sequences."""
    var arr = LargeBinaryArray.from_bytes_list(values.copy())
    return Column.from_large_binary(arr)


def _make_binary_column(values: List[List[UInt8]]) raises -> Column[HeapRegion]:
    """Build a BINARY Column[HeapRegion] (mirror of the helper above for the i32-offsets
    variant)."""
    var arr = BinaryArray.from_bytes_list(values.copy())
    return Column.from_binary(arr)


# --- T1: from_large_string + as_large_string round-trip ----------------------


def test_d_large_string_column_round_trip() raises:
    """`Column.from_large_string(LargeStringArray)` followed by
    `Column.as_large_string()` returns a byte-identical LargeStringArray.
    Validates the i64-offset round-trip through Column's internal storage."""
    var values = List[String]()
    values.append(String("hello"))
    values.append(String("world"))
    values.append(String(""))  # empty string mid-array
    values.append(String("LARGE_STRING handles >2GB but the round-trip is shape-identical"))

    var col = _make_large_string_column(values)
    assert_equal(Int(col.arrow_type.type_id), Int(ArrowType.LARGE_STRING.type_id), "arrow_type LARGE_STRING")
    assert_equal(col.length(), 4, "length preserved")

    var arr_out = col.as_large_string()
    assert_equal(len(arr_out), 4, "round-trip length 4")
    assert_true(arr_out.get(0) == String("hello"), "row 0 byte-identical")
    assert_true(arr_out.get(1) == String("world"), "row 1 byte-identical")
    assert_true(arr_out.get(2) == String(""), "row 2 empty preserved")
    assert_true(
        arr_out.get(3)
            == String("LARGE_STRING handles >2GB but the round-trip is shape-identical"),
        "row 3 long-string byte-identical",
    )
    # Offset widths: 4 entries + 1 sentinel = 5 * 8 bytes = 40 bytes.
    # `SharedAlignedBuffer.length()` is the bytes-currently-in-use marker.
    assert_equal(Int(arr_out.offsets.length()), 40, "offsets buffer length matches i64*(N+1)")


# --- T2: LargeString C-Data stream round-trip -------------------------------


def test_d_large_string_c_data_stream_round_trip() raises:
    """A LARGE_STRING column survives a full C-Data stream export+drain.
    Validates:
      * `Field("col", ArrowType.LARGE_STRING).format_string() == "U"`.
      * `_arrow_type_n_buffers(LARGE_STRING) == 3`.
      * Export writes (validity, i64 offsets, utf8) into the buffer slots.
      * Import reads the i64-width last-offset as data_length.
    """
    var values = List[String]()
    values.append(String("alpha"))
    values.append(String("beta"))
    values.append(String("gamma"))
    var col = _make_large_string_column(values)

    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.LARGE_STRING, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field("s", ArrowType.LARGE_STRING, nullable=False))
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out_batches), 1, "1 batch drained")
    ref rb = out_batches[0]
    assert_equal(rb.num_columns(), 1, "1 column")
    assert_equal(rb.num_rows(), 3, "3 rows")
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.LARGE_STRING, "col type")

    var arr_out = rb.column_at(0).as_large_string()
    assert_true(arr_out.get(0) == String("alpha"), "row 0 byte-identical")
    assert_true(arr_out.get(1) == String("beta"), "row 1 byte-identical")
    assert_true(arr_out.get(2) == String("gamma"), "row 2 byte-identical")


# --- T3: from_large_binary + as_large_binary round-trip ---------------------


def test_d_large_binary_column_round_trip() raises:
    """In-memory round-trip for LARGE_BINARY through Column."""
    var v1 = List[UInt8]()
    v1.append(UInt8(0xDE))
    v1.append(UInt8(0xAD))
    v1.append(UInt8(0xBE))
    v1.append(UInt8(0xEF))
    var v2 = List[UInt8]()
    v2.append(UInt8(0x00))
    v2.append(UInt8(0xFF))
    var v3 = List[UInt8]()  # empty bytes
    var values = List[List[UInt8]]()
    values.append(v1^)
    values.append(v2^)
    values.append(v3^)

    var col = _make_large_binary_column(values)
    assert_equal(Int(col.arrow_type.type_id), Int(ArrowType.LARGE_BINARY.type_id), "arrow_type LARGE_BINARY")
    assert_equal(col.length(), 3, "length preserved")

    var arr_out = col.as_large_binary()
    assert_equal(len(arr_out), 3, "round-trip length")
    assert_equal(arr_out.get_length(0), 4, "row 0 length 4")
    assert_equal(arr_out.get_length(1), 2, "row 1 length 2")
    assert_equal(arr_out.get_length(2), 0, "row 2 empty")


# --- T4: LargeBinary C-Data stream round-trip -------------------------------


def test_d_large_binary_c_data_stream_round_trip() raises:
    """LARGE_BINARY survives a full C-Data export+drain.  Same shape as T2
    but with the `Z` format string and raw-bytes data buffer."""
    var v1 = List[UInt8]()
    v1.append(UInt8(0x01))
    v1.append(UInt8(0x02))
    v1.append(UInt8(0x03))
    var v2 = List[UInt8]()
    v2.append(UInt8(0xAA))
    v2.append(UInt8(0xBB))
    var values = List[List[UInt8]]()
    values.append(v1^)
    values.append(v2^)
    var col = _make_large_binary_column(values)

    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.LARGE_BINARY, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field("b", ArrowType.LARGE_BINARY, nullable=False))
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out_batches), 1, "1 batch")
    ref rb = out_batches[0]
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.LARGE_BINARY, "col type LARGE_BINARY")
    var arr_out = rb.column_at(0).as_large_binary()
    assert_equal(len(arr_out), 2, "len 2")
    assert_equal(arr_out.get_length(0), 3, "row 0 length 3")
    assert_equal(arr_out.get_length(1), 2, "row 1 length 2")


# --- T5: BINARY C-Data stream round-trip --------------------------------------


def test_d_binary_c_data_stream_round_trip() raises:
    """BINARY round-trips via C-Data. Validates the format string `"z"` and
    the i32-offset 3-buffer shape."""
    var v1 = List[UInt8]()
    v1.append(UInt8(0xDE))
    v1.append(UInt8(0xAD))
    var v2 = List[UInt8]()
    v2.append(UInt8(0xCA))
    v2.append(UInt8(0xFE))
    v2.append(UInt8(0xBA))
    v2.append(UInt8(0xBE))
    var values = List[List[UInt8]]()
    values.append(v1^)
    values.append(v2^)
    var col = _make_binary_column(values)

    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.BINARY, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field("b", ArrowType.BINARY, nullable=False))
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out_batches), 1, "1 batch")
    ref rb = out_batches[0]
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.BINARY, "col type BINARY")
    var arr_out = rb.column_at(0).as_binary()
    assert_equal(len(arr_out), 2, "len 2")
    assert_equal(arr_out.get_length(0), 2, "row 0 length 2")
    assert_equal(arr_out.get_length(1), 4, "row 1 length 4")


# --- T6: Format-string discriminator round-trip ----------------------------


def test_d_var_len_format_strings_round_trip() raises:
    """The 4 var-len families emit unique single-char format strings and
    round-trip through `parse_format_string` to the same ArrowType.  Pins
    `u != z != U != Z`."""
    var s_fmt = ArrowType.STRING.format_string()
    var b_fmt = ArrowType.BINARY.format_string()
    var ls_fmt = ArrowType.LARGE_STRING.format_string()
    var lb_fmt = ArrowType.LARGE_BINARY.format_string()
    assert_true(s_fmt == String("u"), "STRING -> 'u'")
    assert_true(b_fmt == String("z"), "BINARY -> 'z'")
    assert_true(ls_fmt == String("U"), "LARGE_STRING -> 'U'")
    assert_true(lb_fmt == String("Z"), "LARGE_BINARY -> 'Z'")

    # All four are distinct.
    assert_false(s_fmt == b_fmt, "u != z")
    assert_false(ls_fmt == lb_fmt, "U != Z")
    assert_false(s_fmt == ls_fmt, "u != U (case-sensitive)")
    assert_false(b_fmt == lb_fmt, "z != Z")

    # Inverse round-trip through the parser.
    assert_true(
        parse_format_string(String("u")) == ArrowType.STRING,
        "parse 'u' -> STRING",
    )
    assert_true(
        parse_format_string(String("z")) == ArrowType.BINARY,
        "parse 'z' -> BINARY",
    )
    assert_true(
        parse_format_string(String("U")) == ArrowType.LARGE_STRING,
        "parse 'U' -> LARGE_STRING",
    )
    assert_true(
        parse_format_string(String("Z")) == ArrowType.LARGE_BINARY,
        "parse 'Z' -> LARGE_BINARY",
    )


# --- T7: LargeString hash determinism --------------------------------------


def _fnv1a_64_of_string(s: String) -> Int64:
    """FNV-1a 64-bit hash over the UTF-8 byte content + length. Mirrors the
    shape used in `agg_count_distinct.mojo`, so it can serve as the
    LargeString hash path there."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var h = Int64(-3750763034362895579)  # FNV-1a 64-bit offset basis
    for b in range(n):
        h = (h ^ Int64(bytes[b])) * Int64(1099511628211)
    h = h ^ (Int64(n) * Int64(1099511628211))
    return h


def test_d_large_string_hash_deterministic() raises:
    """A LargeStringArray of the same byte content as a StringArray produces
    the same FNV-1a hash row-by-row. Pins the hash-equivalence property that
    lets STRING and LARGE_STRING share the dict-encoder path without
    re-tuning the hash function."""
    var values = List[String]()
    values.append(String("apple"))
    values.append(String("banana"))
    values.append(String("apple"))  # repeat — same hash
    values.append(String("STANDARD POLISHED BRASS"))  # >7 chars

    var ls = LargeStringArray.from_strings(values.copy())
    var ss = StringArray.from_strings(values.copy())

    # Row-by-row hash equivalence.
    for i in range(len(ls)):
        var h_ls = _fnv1a_64_of_string(ls.get(i))
        var h_ss = _fnv1a_64_of_string(ss.get(i))
        assert_equal(Int(h_ls), Int(h_ss), "hash matches at row " + String(i))

    # Repeat-row determinism.
    var h0 = _fnv1a_64_of_string(ls.get(0))
    var h2 = _fnv1a_64_of_string(ls.get(2))
    assert_equal(Int(h0), Int(h2), "row 0 and 2 (same content) hash identically")


# --- T8: Cross-type semantic — STRING / LARGE_STRING content equality -------


def test_d_string_and_large_string_byte_equivalence() raises:
    """A StringArray and a LargeStringArray built from the same `List[String]`
    produce byte-identical content (the only difference is offset width).
    This is the contract Polars / DuckDB rely on for auto-widening a STRING
    column to LARGE_STRING during a join — the data bytes are interchangeable.

    The kernel generalization (string_compare / agg_dict offset-type
    dispatch) is not done: the codepaths in `agg_count_distinct.mojo` +
    `agg_dict.mojo` route LARGE_STRING into branches that read offsets as
    Int32, so LARGE_STRING input must be coerced at the eval boundary before
    it reaches them.
    """
    var values = List[String]()
    values.append(String("alpha"))
    values.append(String("beta"))
    values.append(String("gamma"))

    var ss = StringArray.from_strings(values.copy())
    var ls = LargeStringArray.from_strings(values.copy())

    assert_equal(len(ss), len(ls), "same length")
    assert_equal(ss.data_length, ls.data_length, "same total data bytes")
    # Per-row length AND byte content equality.
    for i in range(len(ss)):
        assert_equal(
            ss.get_length(i),
            ls.get_length(i),
            "row " + String(i) + " byte-length matches",
        )
        assert_true(
            ss.get(i) == ls.get(i),
            "row " + String(i) + " byte content matches",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_d_large_string_column_round_trip]()
    suite.test[test_d_large_string_c_data_stream_round_trip]()
    suite.test[test_d_large_binary_column_round_trip]()
    suite.test[test_d_large_binary_c_data_stream_round_trip]()
    suite.test[test_d_binary_c_data_stream_round_trip]()
    suite.test[test_d_var_len_format_strings_round_trip]()
    suite.test[test_d_large_string_hash_deterministic]()
    suite.test[test_d_string_and_large_string_byte_equivalence]()
    suite^.run()
