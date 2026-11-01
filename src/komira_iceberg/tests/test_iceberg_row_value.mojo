# =============================================================================
# test_iceberg_row_value.mojo — the Avro row form of a typed cell.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. Every cell type round-trips through its Avro primitive form, alone and as
#      a row, and a row decodes only as far as its declared types say.
#   2. reconcile_cell_type accepts a cell whose tag matches the declared column
#      type (a null of the right tag included) and refuses every other, naming
#      the column: a STRING cell for a LONG column would otherwise encode as 0.
#   3. The Avro data file round-trips typed rows, refuses a row of the wrong
#      arity and carries the Iceberg field id of each column in its schema.
#   4. A partition value decodes from its one-value byte blob.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false, assert_raises

from komira_avro.ocf_block_emit import (
    generate_sync_marker,
    emit_ocf_header_kv,
    emit_ocf_block,
)
from komira_avro.ocf_header import decode_ocf_header, AVRO_CODEC_NULL
from komira_avro.varint_decode_scalar import AvroByteReader

from komira_iceberg import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    IcebergSchema,
    RowCell,
    make_boolean_cell,
    make_int_cell,
    make_long_cell,
    make_float_cell,
    make_double_cell,
    make_string_cell,
    make_null_cell,
    reconcile_cell_type,
    encode_cell,
    decode_cell,
    encode_row,
    decode_row,
    rows_equal,
    decode_partition_cell,
    col_types_of,
    build_data_file,
    read_data_file,
)


def _all_cells() -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_boolean_cell(True))
    r.append(make_int_cell(Int32(-7)))
    r.append(make_long_cell(Int64(-9000000000)))
    r.append(make_float_cell(Float32(2.5)))
    r.append(make_double_cell(Float64(-0.125)))
    r.append(make_string_cell(String("café 日本")))
    return r^


def _all_types() -> List[Int]:
    var t = List[Int]()
    t.append(ICE_T_BOOLEAN)
    t.append(ICE_T_INT)
    t.append(ICE_T_LONG)
    t.append(ICE_T_FLOAT)
    t.append(ICE_T_DOUBLE)
    t.append(ICE_T_STRING)
    return t^


def test_a_row_of_every_type_round_trips() raises:
    var row = _all_cells()
    var bytes = List[UInt8]()
    encode_row(row, bytes)
    var reader = AvroByteReader(Span(bytes))
    var back = decode_row(reader, _all_types())
    assert_true(rows_equal(row, back))
    # Cell by cell, through the single-cell codec.
    for i in range(len(row)):
        var one = List[UInt8]()
        encode_cell(row[i], one)
        var r = AvroByteReader(Span(one))
        assert_true(decode_cell(r, _all_types()[i]).equals(row[i]))
    with assert_raises():
        var junk = List[UInt8]()
        junk.append(0)
        var r2 = AvroByteReader(Span(junk))
        _ = decode_cell(r2, 99)


def test_a_partition_value_decodes_from_its_blob() raises:
    var blob = List[UInt8]()
    encode_cell(make_string_cell(String("us-east")), blob)
    assert_equal(decode_partition_cell(blob, ICE_T_STRING).as_string(), String("us-east"))
    var n = List[UInt8]()
    encode_cell(make_int_cell(Int32(12)), n)
    assert_equal(decode_partition_cell(n, ICE_T_INT).as_long(), Int64(12))


def test_reconcile_accepts_a_matching_tag_and_refuses_the_rest() raises:
    reconcile_cell_type(make_long_cell(Int64(1)), ICE_T_LONG, String("id"))
    # A genuine null carries its declared tag and is representable.
    reconcile_cell_type(make_null_cell(ICE_T_LONG), ICE_T_LONG, String("id"))
    # A STRING cell for a numeric or boolean column names the column and why.
    for declared in [ICE_T_LONG, ICE_T_INT, ICE_T_BOOLEAN]:
        var raised = False
        try:
            reconcile_cell_type(
                make_string_cell(String("18446744073709551615")), declared, String("order_id")
            )
        except e:
            raised = True
            assert_true(String(e).find("order_id") >= 0, String(e))
            assert_true(String(e).find("STRING-typed cell") >= 0, String(e))
        assert_true(raised, "a string cell in a numeric column must be refused")
    # Any other mismatch names both types.
    var raised2 = False
    try:
        reconcile_cell_type(make_double_cell(Float64(1.5)), ICE_T_LONG, String("n"))
    except e:
        raised2 = True
        assert_true(String(e).find("double") >= 0, String(e))
        assert_true(String(e).find("long") >= 0, String(e))
    assert_true(raised2)


def test_the_avro_data_file_round_trips_and_names_field_ids() raises:
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    schema.add(String('we"ird'), ICE_T_STRING)
    var rows = List[List[RowCell]]()
    var r1 = List[RowCell]()
    r1.append(make_long_cell(Int64(1)))
    r1.append(make_string_cell(String("a")))
    var r2 = List[RowCell]()
    r2.append(make_long_cell(Int64(2)))
    r2.append(make_string_cell(String("é")))
    rows.append(r1^)
    rows.append(r2^)
    var bytes = build_data_file(schema, rows)
    var back = read_data_file(bytes, col_types_of(schema))
    assert_equal(len(back), 2)
    assert_true(rows_equal(rows[1], back[1]))
    # The embedded schema carries the field ids, and a column name holding a
    # quote is escaped, so the schema is still valid Avro.
    var hdr = decode_ocf_header(Span(bytes))
    assert_true(hdr.schema_json.find('"field-id":1') >= 0)
    assert_true(hdr.schema_json.find('"field-id":2') >= 0)
    assert_true(hdr.schema_json.find('"name":"we\\"ird"') >= 0)
    # (Avro names are restricted; the parser's verdict on this one is not the
    # point, that the JSON stays well formed is.)
    assert_equal(len(col_types_of(schema)), 2)
    # No rows: a header-only file.
    assert_equal(len(read_data_file(build_data_file(schema, List[List[RowCell]]()), col_types_of(schema))), 0)
    # A row with the wrong number of cells is refused.
    var ragged = List[List[RowCell]]()
    var short = List[RowCell]()
    short.append(make_long_cell(Int64(1)))
    ragged.append(short^)
    with assert_raises():
        _ = build_data_file(schema, ragged)


def _ocf_with(count: Int, payload: List[UInt8]) raises -> List[UInt8]:
    """A one-long-column data file whose single block CLAIMS `count` records
    over `payload`: the header and framing are real, the count is the lie."""
    var sync = generate_sync_marker()
    var out = List[UInt8]()
    emit_ocf_header_kv(
        String('{"type":"record","name":"data","fields":[{"name":"id","type":"long","field-id":1}]}'),
        AVRO_CODEC_NULL, sync, List[String](), List[String](), out,
    )
    emit_ocf_block(Span(payload), count, AVRO_CODEC_NULL, sync, out)
    return out^


def _long_types() -> List[Int]:
    var t = List[Int]()
    t.append(ICE_T_LONG)
    return t^


def test_a_string_from_the_store_must_be_valid_utf8_and_stays_whole() raises:
    # Avro string: zigzag length, then the bytes. 0xC3 0x28 is not UTF-8.
    var bad = List[UInt8]()
    bad.append(4)
    bad.append(0xC3)
    bad.append(0x28)
    var r = AvroByteReader(Span(bad))
    with assert_raises():
        _ = decode_cell(r, ICE_T_STRING)
    # A NUL inside a string is legal and must not end it early: 3 bytes, and
    # the cursor lands exactly at the end.
    var nul = List[UInt8]()
    nul.append(6)
    nul.append(UInt8(ord("a")))
    nul.append(0)
    nul.append(UInt8(ord("b")))
    var r2 = AvroByteReader(Span(nul))
    var cell = decode_cell(r2, ICE_T_STRING)
    assert_equal(cell.as_string().byte_length(), 3)
    assert_true(r2.at_end())
    # A truncated payload is refused too.
    var cut = List[UInt8]()
    cut.append(10)
    cut.append(UInt8(ord("x")))
    var r3 = AvroByteReader(Span(cut))
    with assert_raises():
        _ = decode_cell(r3, ICE_T_STRING)
    # The same guard through a partition value.
    with assert_raises():
        _ = decode_partition_cell(bad, ICE_T_STRING)


def test_a_data_file_cannot_claim_more_records_than_it_has_bytes() raises:
    var payload = List[UInt8]()
    payload.append(2)  # one long: zigzag(1)
    payload.append(4)
    payload.append(6)
    # 3 bytes, 3 records: fine.
    assert_equal(len(read_data_file(_ocf_with(3, payload), _long_types())), 3)
    # 3 bytes cannot hold 1,000,000 records.
    with assert_raises(contains="block claims 1000000 records in 3 payload"):
        _ = read_data_file(_ocf_with(1000000, payload), _long_types())
    # Bytes left over after the last record are refused.
    with assert_raises():
        _ = read_data_file(_ocf_with(2, payload), _long_types())
    # No columns: a record would take no bytes, so any count would loop (and
    # an empty payload has nothing left over to give it away).
    with assert_raises():
        _ = read_data_file(_ocf_with(5, payload), List[Int]())
    with assert_raises():
        _ = read_data_file(_ocf_with(2000000000, List[UInt8]()), List[Int]())
    # Refused outright, even when nothing is claimed.
    with assert_raises():
        _ = read_data_file(_ocf_with(0, List[UInt8]()), List[Int]())


def main() raises:
    test_a_row_of_every_type_round_trips()
    test_a_partition_value_decodes_from_its_blob()
    test_reconcile_accepts_a_matching_tag_and_refuses_the_rest()
    test_the_avro_data_file_round_trips_and_names_field_ids()
    test_a_string_from_the_store_must_be_valid_utf8_and_stays_whole()
    test_a_data_file_cannot_claim_more_records_than_it_has_bytes()
    print("test_iceberg_row_value: all passed")
