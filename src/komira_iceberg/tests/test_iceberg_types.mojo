# =============================================================================
# test_iceberg_types.mojo — the type model and the JSON primitives.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. The type tags render as the spec's primitive names, and an unknown tag is
#      refused rather than rendered as something else.
#   2. json_escape_string escapes the mandatory set and passes UTF-8 through byte
#      for byte: a column or value with non-ASCII text must not be re-encoded.
#   3. The json_kv_* helpers write `"key":value` with the key escaped and the
#      value in the right form.
#   4. IcebergSchema assigns field ids 1..N in column order, copies deeply, and
#      evolve_add_column appends one NULLABLE column with the next id and a
#      bumped schema id, leaving the base schema as it was.
#   5. DataFileInfo's constructors default content, sequence number and
#      partition as documented, with_partition attaches a tuple, and copy is
#      deep (a change to the copy never shows in the original).
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false, assert_raises

from komira_iceberg import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    ICE_DATA_CONTENT_DATA,
    ICE_DATA_CONTENT_POSITION_DELETES,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    ICE_SEQ_INHERIT,
    iceberg_type_name,
    IcebergField,
    IcebergSchema,
    evolve_add_column,
    ColumnBound,
    DataFileInfo,
    json_escape_string,
)
from komira_iceberg.iceberg_types import (
    json_kv_str,
    json_kv_int,
    json_kv_int64,
    json_kv_bool,
    json_kv_raw,
)


def test_type_names_are_the_spec_primitives() raises:
    assert_equal(iceberg_type_name(ICE_T_BOOLEAN), String("boolean"))
    assert_equal(iceberg_type_name(ICE_T_INT), String("int"))
    assert_equal(iceberg_type_name(ICE_T_LONG), String("long"))
    assert_equal(iceberg_type_name(ICE_T_FLOAT), String("float"))
    assert_equal(iceberg_type_name(ICE_T_DOUBLE), String("double"))
    assert_equal(iceberg_type_name(ICE_T_STRING), String("string"))
    with assert_raises():
        _ = iceberg_type_name(99)
    with assert_raises():
        _ = iceberg_type_name(-1)


def test_json_escape_mandatory_set() raises:
    assert_equal(json_escape_string(String("plain")), String('"plain"'))
    assert_equal(json_escape_string(String("")), String('""'))
    assert_equal(
        json_escape_string(String('a"b\\c')), String('"a\\"b\\\\c"')
    )
    assert_equal(
        json_escape_string(String("l1\nl2\r\t")), String('"l1\\nl2\\r\\t"')
    )
    var ctl = String()
    ctl += chr(0x08)
    ctl += chr(0x0C)
    ctl += chr(0x01)
    ctl += chr(0x1F)
    assert_equal(json_escape_string(ctl), String('"\\b\\f\\u0001\\u001F"'))


def test_json_escape_passes_utf8_through() raises:
    # Each non-ASCII character is 2..3 bytes; the output must hold the SAME
    # bytes between the quotes, not each byte re-encoded as its own code point.
    var s = String("café 日本")
    var out = json_escape_string(s)
    assert_equal(out, String('"') + s + String('"'))
    assert_equal(out.byte_length(), s.byte_length() + 2)
    # 4-byte characters too.
    var emoji = String("a😀b")
    assert_equal(json_escape_string(emoji), String('"') + emoji + String('"'))


def test_json_kv_helpers() raises:
    assert_equal(json_kv_str(String("k"), String("v\"")), String('"k":"v\\""'))
    assert_equal(json_kv_str(String("k\n"), String("v")), String('"k\\n":"v"'))
    assert_equal(json_kv_int(String("n"), -5), String('"n":-5'))
    assert_equal(json_kv_int64(String("n"), Int64(9000000000)), String('"n":9000000000'))
    assert_equal(json_kv_bool(String("b"), True), String('"b":true'))
    assert_equal(json_kv_bool(String("b"), False), String('"b":false'))
    assert_equal(json_kv_raw(String("o"), String("{}")), String('"o":{}'))


def test_schema_assigns_ids_and_copies_deeply() raises:
    var s = IcebergSchema(0)
    assert_equal(s.num_fields(), 0)
    assert_equal(s.last_column_id(), 0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("name"), ICE_T_STRING)
    assert_equal(s.num_fields(), 2)
    assert_equal(s.last_column_id(), 2)
    assert_equal(s.fields[0].field_id, 1)
    assert_equal(s.fields[1].field_id, 2)
    assert_true(s.fields[0].required)
    assert_false(s.fields[1].required)
    var c = s.copy()
    c.add(String("extra"), ICE_T_DOUBLE)
    c.fields[0].name = String("renamed")
    assert_equal(s.num_fields(), 2)
    assert_equal(s.fields[0].name, String("id"))
    assert_equal(c.num_fields(), 3)
    var f = IcebergField(7, String("x"), ICE_T_INT, True)
    assert_equal(f.copy().field_id, 7)


def test_evolve_add_column() raises:
    var base = IcebergSchema(3)
    base.add(String("id"), ICE_T_LONG, required=True)
    var next = evolve_add_column(base, String("score"), ICE_T_DOUBLE)
    assert_equal(next.schema_id, 4)
    assert_equal(next.num_fields(), 2)
    assert_equal(next.fields[0].field_id, 1)
    assert_equal(next.fields[1].field_id, 2)
    assert_equal(next.fields[1].name, String("score"))
    assert_false(next.fields[1].required)  # an added column must be optional
    # The base is untouched.
    assert_equal(base.schema_id, 3)
    assert_equal(base.num_fields(), 1)


def test_data_file_info_constructors_and_deep_copy() raises:
    var bounds = List[ColumnBound]()
    var lo = List[UInt8]()
    lo.append(1)
    bounds.append(
        ColumnBound(1, Optional[List[UInt8]](lo^), None, 2, 10)
    )
    var d = DataFileInfo(String("a.parquet"), 100, 10, bounds^)
    assert_equal(d.content, ICE_DATA_CONTENT_DATA)
    assert_equal(len(d.equality_ids), 0)
    assert_equal(d.sequence_number, ICE_SEQ_INHERIT)
    assert_equal(len(d.partition_avro), 0)
    assert_equal(len(d.partition_types), 0)

    var ids = List[Int]()
    ids.append(4)
    var e = DataFileInfo(
        String("d.avro"), 5, 1, List[ColumnBound](),
        ICE_DATA_CONTENT_EQUALITY_DELETES, ids^, Int64(8),
    )
    assert_equal(e.content, ICE_DATA_CONTENT_EQUALITY_DELETES)
    assert_equal(e.sequence_number, Int64(8))
    assert_equal(e.equality_ids[0], 4)
    var p = DataFileInfo(
        String("p.avro"), 5, 1, List[ColumnBound](),
        ICE_DATA_CONTENT_POSITION_DELETES, List[Int](),
    )
    assert_equal(p.sequence_number, ICE_SEQ_INHERIT)

    # with_partition attaches a tuple; copy is deep.
    var blob = List[UInt8]()
    blob.append(7)
    var pa = List[List[UInt8]]()
    pa.append(blob^)
    var pt = List[Int]()
    pt.append(ICE_T_INT)
    var part = d^.with_partition(pa^, pt^)
    assert_equal(len(part.partition_avro), 1)
    assert_equal(part.partition_types[0], ICE_T_INT)
    var c = part.copy()
    c.file_path = String("other")
    c.partition_avro[0][0] = 99
    c.bounds[0].null_count = 77
    assert_equal(part.file_path, String("a.parquet"))
    assert_equal(part.partition_avro[0][0], 7)
    assert_equal(part.bounds[0].null_count, 2)
    assert_equal(c.bounds[0].lower.value()[0], 1)
    assert_equal(part.bounds[0].value_count, 10)


def main() raises:
    test_type_names_are_the_spec_primitives()
    test_json_escape_mandatory_set()
    test_json_escape_passes_utf8_through()
    test_json_kv_helpers()
    test_schema_assigns_ids_and_copies_deeply()
    test_evolve_add_column()
    test_data_file_info_constructors_and_deep_copy()
    print("test_iceberg_types: all passed")
