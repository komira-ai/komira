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

from komira_avro.ocf_header import decode_ocf_header
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


def main() raises:
    test_a_row_of_every_type_round_trips()
    test_a_partition_value_decodes_from_its_blob()
    test_reconcile_accepts_a_matching_tag_and_refuses_the_rest()
    test_the_avro_data_file_round_trips_and_names_field_ids()
    print("test_iceberg_row_value: all passed")
