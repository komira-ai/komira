# =============================================================================
# test_orc_pyarrow_orc_cross_impl_read.mojo — pyarrow/orc-cpp spec conformance.
# =============================================================================
#
# Gates the spec-conformance rule that pyarrow.orc (and any orc-cpp-backed
# reader) enforces on read: a writer that emits ColumnEncoding.kind=DIRECT_V2
# for EVERY schema node (including the root STRUCT and FLOAT / DOUBLE /
# BOOLEAN / BYTE columns) produces files those readers reject with
# `OSError: Unknown encoding for StructColumnReader`.
#
# The ORC spec (orc_proto.proto ColumnEncoding.Kind) only permits DIRECT_V2 on
# integer-encoded types — STRUCT / LIST / MAP / UNION and FLOAT / DOUBLE /
# BOOLEAN / BYTE columns MUST use DIRECT (kind=0). This package's reader is
# permissive and would round-trip the bad bytes; pyarrow.orc strictly
# validates the per-type kind and raises.
#
# This test reads a written ORC's StripeFooter back and asserts each
# ColumnEncoding.kind matches the spec for the column's Type.Kind. That is
# both (a) the cross-impl invariant pyarrow.orc enforces, and (b) the
# byte-level proof that the writer emits spec-valid kinds.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    OrcFileTail,
    StripeFooter,
    OrcColumnEncoding,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
    ORC_ENCODING_DIRECT,
    ORC_ENCODING_DIRECT_V2,
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_BINARY,
    ORC_KIND_DATE,
    ORC_KIND_STRUCT,
    ORC_KIND_LIST,
    ORC_KIND_MAP,
    ORC_KIND_UNION,
)


def _spec_expected_encoding(kind: Int) -> Int:
    """Return the spec-mandated ColumnEncoding.kind for an ORC Type.kind.

    Mirror of the writer-side `_spec_encoding_for_kind` (kept duplicated so
    the test is independent of the writer's helper). STRUCT / LIST / MAP /
    UNION / BOOLEAN / BYTE / FLOAT / DOUBLE must be DIRECT. INT-family
    + STRING-family use DIRECT_V2 since the writer emits RLEv2."""
    if (
        kind == ORC_KIND_BOOLEAN
        or kind == ORC_KIND_BYTE
        or kind == ORC_KIND_FLOAT
        or kind == ORC_KIND_DOUBLE
        or kind == ORC_KIND_STRUCT
        or kind == ORC_KIND_LIST
        or kind == ORC_KIND_MAP
        or kind == ORC_KIND_UNION
    ):
        return ORC_ENCODING_DIRECT
    return ORC_ENCODING_DIRECT_V2


def _build_mixed_primitive_batch() raises -> RecordBatch:
    """Build a small RB covering every primitive ORC type spec-class. One row
    per type bucket is sufficient — the bug fires on the per-NODE encoding
    kind, which is independent of row count."""
    var n = 3
    var sb = SchemaBuilder()
    sb.add_field(Field("bl", ArrowType.BOOL, True))     # BOOLEAN -> DIRECT
    sb.add_field(Field("t8", ArrowType.INT8, True))     # BYTE -> DIRECT
    sb.add_field(Field("s16", ArrowType.INT16, True))   # SHORT -> DIRECT_V2
    sb.add_field(Field("i32", ArrowType.INT32, True))   # INT -> DIRECT_V2
    sb.add_field(Field("l64", ArrowType.INT64, True))   # LONG -> DIRECT_V2
    sb.add_field(Field("dt", ArrowType.DATE32, True))   # DATE -> DIRECT_V2
    sb.add_field(Field("f32", ArrowType.FLOAT32, True)) # FLOAT -> DIRECT
    sb.add_field(Field("f64", ArrowType.FLOAT64, True)) # DOUBLE -> DIRECT
    sb.add_field(Field("st", ArrowType.STRING, True))   # STRING -> DIRECT_V2

    var bl = BooleanArray.allocate(n)
    bl.set(0, True); bl.set(1, False); bl.set(2, True)
    var a8 = PrimitiveArray[DType.int8].allocate(n)
    a8.set(0, Int8(1)); a8.set(1, Int8(2)); a8.set(2, Int8(3))
    var a16 = PrimitiveArray[DType.int16].allocate(n)
    a16.set(0, Int16(10)); a16.set(1, Int16(20)); a16.set(2, Int16(30))
    var a32 = PrimitiveArray[DType.int32].allocate(n)
    a32.set(0, Int32(100)); a32.set(1, Int32(200)); a32.set(2, Int32(300))
    var a64 = PrimitiveArray[DType.int64].allocate(n)
    a64.set(0, Int64(1000)); a64.set(1, Int64(2000)); a64.set(2, Int64(3000))
    var adt = PrimitiveArray[DType.int32].allocate(n)
    adt.set(0, Int32(0)); adt.set(1, Int32(1)); adt.set(2, Int32(2))
    var af32 = PrimitiveArray[DType.float32].allocate(n)
    af32.set(0, Float32(1.5)); af32.set(1, Float32(2.5)); af32.set(2, Float32(3.5))
    var af64 = PrimitiveArray[DType.float64].allocate(n)
    af64.set(0, Float64(0.5)); af64.set(1, Float64(1.5)); af64.set(2, Float64(2.5))
    var ss = List[String]()
    ss.append(String("a")); ss.append(String("bb")); ss.append(String("ccc"))
    var ast = StringArray.from_strings(ss)

    var builder = RecordBatchBuilder.with_capacity(9)
    builder.add_column(Column.from_boolean(bl^))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int8](a8^, ArrowType.INT8))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int16](a16^, ArrowType.INT16))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int32](a32^, ArrowType.INT32))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int64](a64^, ArrowType.INT64))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int32](adt^, ArrowType.DATE32))
    builder.add_column(Column.from_primitive[DType.float32](af32^))
    builder.add_column(Column.from_primitive[DType.float64](af64^))
    builder.add_column(Column.from_string(ast^))
    return builder.build(sb.build())


def _decode_first_stripe_footer(file_bytes: List[UInt8]) raises -> StripeFooter:
    """Decode the FIRST stripe's StripeFooter from a NONE-codec ORC file."""
    var tail = OrcFileTail.parse(Span(file_bytes))
    assert_true(len(tail.footer.stripes) > 0, "file has at least one stripe")
    var si = tail.footer.stripes[0].copy()
    var sf_start = si.stripe_footer_start()
    var sf_end = si.stripe_footer_end()
    # NONE codec -> raw protobuf (no chunk framing).
    return StripeFooter.parse(Span(file_bytes)[sf_start:sf_end])


def test_root_struct_is_direct_not_direct_v2() raises:
    """Root STRUCT column (node 0) must be DIRECT, not DIRECT_V2.

    This is the byte-level repro of `Unknown encoding for StructColumnReader`
    from pyarrow.orc 24.0.0."""
    var rb = _build_mixed_primitive_batch()
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    var sf = _decode_first_stripe_footer(bytes)
    assert_true(
        len(sf.columns) >= 1, "StripeFooter has at least the root encoding"
    )
    assert_equal(
        sf.columns[0].kind,
        ORC_ENCODING_DIRECT,
        "root STRUCT (node 0) MUST be DIRECT (0) — DIRECT_V2 (2) is invalid"
        " and rejected by pyarrow.orc / orc-cpp StructColumnReader",
    )


def test_per_type_encoding_kinds_match_spec() raises:
    """Every primitive column's ColumnEncoding.kind matches the spec rule.

    Mirrors what pyarrow.orc / orc-cpp enforce on read. DIRECT_V2 on
    BOOLEAN / BYTE / FLOAT / DOUBLE is rejected by orc-cpp with `Unknown encoding for
    {Boolean,Byte,Float,Double}ColumnReader`."""
    var rb = _build_mixed_primitive_batch()
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    var sf = _decode_first_stripe_footer(bytes)

    # Expected per-node ORC Type.Kind in flat layout: node 0 = STRUCT root,
    # nodes 1..9 = columns in schema order (bl/t8/s16/i32/l64/dt/f32/f64/st).
    var expected_kinds = List[Int]()
    expected_kinds.append(ORC_KIND_STRUCT)
    expected_kinds.append(ORC_KIND_BOOLEAN)
    expected_kinds.append(ORC_KIND_BYTE)
    expected_kinds.append(ORC_KIND_SHORT)
    expected_kinds.append(ORC_KIND_INT)
    expected_kinds.append(ORC_KIND_LONG)
    expected_kinds.append(ORC_KIND_DATE)
    expected_kinds.append(ORC_KIND_FLOAT)
    expected_kinds.append(ORC_KIND_DOUBLE)
    expected_kinds.append(ORC_KIND_STRING)

    assert_equal(
        len(sf.columns),
        len(expected_kinds),
        "ColumnEncoding count == n_schema_nodes (root + 9 primitive cols)",
    )

    for i in range(len(expected_kinds)):
        var type_kind = expected_kinds[i]
        var expected_enc = _spec_expected_encoding(type_kind)
        var got_enc = sf.columns[i].kind
        assert_equal(
            got_enc,
            expected_enc,
            String("node ")
            + String(i)
            + ": ColumnEncoding.kind must be spec-valid for Type.Kind",
        )


def test_roundtrip_still_green_after_encoding_fix() raises:
    """Self-round-trip MUST still pass: this package's reader handles both
    encoding kinds; the spec rule only narrows the writer's emission."""
    var rb = _build_mixed_primitive_batch()
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_columns(), 9, "round-trip preserves column count")
    assert_equal(back.num_rows(), 3, "round-trip preserves row count")
    var bl = back.column_as_boolean(0)
    assert_true(bl.get(0), "bl[0] True round-trip")
    assert_true(not bl.get(1), "bl[1] False round-trip")
    var f64 = back.column_as_primitive_float64(7)
    assert_true(f64.get(2) == 2.5, "f64[2] round-trip")
    var st = back.column_as_string(8)
    assert_equal(st.get(2), String("ccc"), "string[2] round-trip")


def test_roundtrip_still_green_zstd() raises:
    """Same as the NONE round-trip, but with ZSTD codec — confirms the spec rule is
    codec-agnostic (compression layer is below the encoding-kind selection)."""
    var rb = _build_mixed_primitive_batch()
    var opts = OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10000, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_columns(), 9, "zstd round-trip column count")
    assert_equal(back.num_rows(), 3, "zstd round-trip row count")


def main() raises:
    test_root_struct_is_direct_not_direct_v2()
    test_per_type_encoding_kinds_match_spec()
    test_roundtrip_still_green_after_encoding_fix()
    test_roundtrip_still_green_zstd()
    print("test_orc_pyarrow_orc_cross_impl_read: ALL PASS")
