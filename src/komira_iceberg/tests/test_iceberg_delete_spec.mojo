# =============================================================================
# test_iceberg_delete_spec.mojo — delete files against the Iceberg v2 spec.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. The position-delete schema is the spec's: `file_path` string with field
#      id 2147483546 and `pos` long with field id 2147483545 (a reader binds
#      the columns by those ids).
#   2. The equality-delete schema carries the equality columns' table field ids
#      and spec type names, and each file's header says which kind it is.
#   3. A delete key whose cell type does not match the declared column type is
#      refused: an over-Int64 integer promoted to a string would otherwise
#      encode as 0 and one key's delete would mask another key's row.
#   4. Arity mismatches and an empty file are handled: a ragged row or a
#      mismatched id/type list is refused, no rows gives a header-only file.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_raises

from komira_avro.avro_schema import AvroSchema
from komira_avro.ocf_header import decode_ocf_header
from komira_avro.varint_encode import encode_string

from komira_iceberg import (
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_STRING,
    RowCell,
    make_long_cell,
    make_string_cell,
    PositionDeleteEntry,
    ICE_POS_DELETE_FILE_PATH_ID,
    ICE_POS_DELETE_POS_ID,
    build_equality_delete_file,
    read_equality_delete_file,
    build_position_delete_file,
    read_position_delete_file,
)


def _has(s: String, needle: String) -> Bool:
    return s.find(needle) >= 0


def _contains(hay: List[UInt8], needle: List[UInt8]) -> Bool:
    var n = len(needle)
    for i in range(len(hay) - n + 1):
        var ok = True
        for j in range(n):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return True
    return False


def _kv(key: String, value: String) -> List[UInt8]:
    var out = List[UInt8]()
    encode_string(key, out)
    encode_string(value, out)
    return out^


def test_position_delete_schema_ids() raises:
    assert_equal(ICE_POS_DELETE_FILE_PATH_ID, 2147483546)
    assert_equal(ICE_POS_DELETE_POS_ID, 2147483545)
    var entries = List[PositionDeleteEntry]()
    entries.append(PositionDeleteEntry(String("d/a.parquet"), Int64(3)))
    var bytes = build_position_delete_file(entries)
    var hdr = decode_ocf_header(Span(bytes))
    assert_true(_has(hdr.schema_json, '"name":"file_path","type":"string","field-id":2147483546}'))
    assert_true(_has(hdr.schema_json, '"name":"pos","type":"long","field-id":2147483545}'))
    _ = AvroSchema.parse(hdr.schema_json)
    assert_true(_contains(bytes, _kv(String("content"), String("position-deletes"))))
    assert_true(_contains(bytes, _kv(String("format-version"), String("2"))))
    var back = read_position_delete_file(bytes)
    assert_equal(len(back), 1)
    assert_equal(back[0].file_path, String("d/a.parquet"))
    assert_equal(back[0].pos, Int64(3))
    var c = back[0].copy()
    assert_equal(c.pos, Int64(3))


def test_equality_delete_schema_carries_table_field_ids() raises:
    var ids = List[Int]()
    ids.append(1)
    ids.append(4)
    var types = List[Int]()
    types.append(ICE_T_LONG)
    types.append(ICE_T_STRING)
    var rows = List[List[RowCell]]()
    var r = List[RowCell]()
    r.append(make_long_cell(Int64(10)))
    r.append(make_string_cell(String("k")))
    rows.append(r^)
    var bytes = build_equality_delete_file(ids, types, rows)
    var hdr = decode_ocf_header(Span(bytes))
    assert_true(_has(hdr.schema_json, '"name":"f1","type":"long","field-id":1}'))
    assert_true(_has(hdr.schema_json, '"name":"f4","type":"string","field-id":4}'))
    _ = AvroSchema.parse(hdr.schema_json)
    assert_true(_contains(bytes, _kv(String("content"), String("equality-deletes"))))
    var back = read_equality_delete_file(bytes, types)
    assert_equal(len(back), 1)
    assert_equal(back[0][0].as_long(), Int64(10))
    assert_equal(back[0][1].as_string(), String("k"))


def test_a_mistyped_delete_key_is_refused() raises:
    var ids = List[Int]()
    ids.append(1)
    var types = List[Int]()
    types.append(ICE_T_LONG)
    var rows = List[List[RowCell]]()
    var r = List[RowCell]()
    # An integer beyond Int64, promoted to its decimal string, for a LONG key.
    r.append(make_string_cell(String("18446744073709551615")))
    rows.append(r^)
    with assert_raises():
        _ = build_equality_delete_file(ids, types, rows)


def test_arity_mismatches_and_empty_files() raises:
    var ids = List[Int]()
    ids.append(1)
    var two_types = List[Int]()
    two_types.append(ICE_T_LONG)
    two_types.append(ICE_T_INT)
    with assert_raises():
        _ = build_equality_delete_file(ids, two_types, List[List[RowCell]]())
    var one_type = List[Int]()
    one_type.append(ICE_T_LONG)
    var ragged = List[List[RowCell]]()
    var r = List[RowCell]()
    r.append(make_long_cell(Int64(1)))
    r.append(make_long_cell(Int64(2)))
    ragged.append(r^)
    with assert_raises():
        _ = build_equality_delete_file(ids, one_type, ragged)
    # No rows: a header-only file that decodes to no rows.
    var empty_eq = build_equality_delete_file(ids, one_type, List[List[RowCell]]())
    assert_equal(len(read_equality_delete_file(empty_eq, one_type)), 0)
    var empty_pos = build_position_delete_file(List[PositionDeleteEntry]())
    assert_equal(len(read_position_delete_file(empty_pos)), 0)


def main() raises:
    test_position_delete_schema_ids()
    test_equality_delete_schema_carries_table_field_ids()
    test_a_mistyped_delete_key_is_refused()
    test_arity_mismatches_and_empty_files()
    print("test_iceberg_delete_spec: all passed")
