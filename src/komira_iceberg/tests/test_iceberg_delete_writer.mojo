# =============================================================================
# test_iceberg_delete_writer.mojo — the delete-file writer round trips.
# =============================================================================
#
# The delete-file writer serializes the two Iceberg v2 delete-file kinds as Avro
# OCF, reusing the komira_avro OCF framing (the same serializer the manifest
# layer uses):
#
#   (1) An EQUALITY-delete file (delete-by-key) round-trips its delete keys:
#       build over rows [(id=2), (id=3)] on equality column field-id 1, decode
#       back, get exactly those two key-tuples.
#   (2) A POSITION-delete file round-trips its (data-file-path, row-position)
#       pairs: build over [(f, 0), (f, 4)], decode back, get exactly those pairs.
#   (3) Both files are valid Avro OCF (magic "Obj\x01").
# =============================================================================

from std.testing import assert_true, assert_equal, assert_raises

from komira_avro.ocf_block_emit import (
    generate_sync_marker,
    emit_ocf_header_kv,
    emit_ocf_block,
)
from komira_avro.ocf_header import AVRO_CODEC_NULL

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    RowCell,
    make_long_cell,
    make_string_cell,
    build_equality_delete_file,
    read_equality_delete_file,
    PositionDeleteEntry,
    build_position_delete_file,
    read_position_delete_file,
)


def _is_avro_ocf(bytes: List[UInt8]) -> Bool:
    if len(bytes) < 4:
        return False
    return (
        bytes[0] == UInt8(ord("O"))
        and bytes[1] == UInt8(ord("b"))
        and bytes[2] == UInt8(ord("j"))
        and bytes[3] == UInt8(0x01)
    )


def test_equality_delete_file_roundtrip() raises:
    """An equality-delete file over id=2, id=3 (equality field-id 1, type long)
    round-trips to exactly two single-cell delete rows [2] and [3]."""
    # equality columns = [field-id 1 (id, long)].
    var eq_field_ids = List[Int]()
    eq_field_ids.append(1)
    var eq_types = List[Int]()
    eq_types.append(ICE_T_LONG)

    # two delete rows, each a one-cell tuple.
    var rows = List[List[RowCell]]()
    var r2 = List[RowCell]()
    r2.append(make_long_cell(Int64(2)))
    rows.append(r2^)
    var r3 = List[RowCell]()
    r3.append(make_long_cell(Int64(3)))
    rows.append(r3^)

    var bytes = build_equality_delete_file(eq_field_ids, eq_types, rows)
    assert_true(_is_avro_ocf(bytes), "equality-delete file is Avro OCF")

    var decoded = read_equality_delete_file(bytes, eq_types)
    assert_equal(len(decoded), 2, "two delete keys round-trip")
    assert_equal(len(decoded[0]), 1, "row 0 is a one-cell tuple")
    assert_equal(decoded[0][0].as_long(), Int64(2), "first delete key == 2")
    assert_equal(decoded[1][0].as_long(), Int64(3), "second delete key == 3")


def test_equality_delete_file_two_column_key() raises:
    """A composite equality key (id long, name string) round-trips both cells of
    each delete row — proves the writer handles multi-column equality keys."""
    var eq_field_ids = List[Int]()
    eq_field_ids.append(1)
    eq_field_ids.append(2)
    var eq_types = List[Int]()
    eq_types.append(ICE_T_LONG)
    eq_types.append(ICE_T_STRING)

    var rows = List[List[RowCell]]()
    var r = List[RowCell]()
    r.append(make_long_cell(Int64(7)))
    r.append(make_string_cell(String("gone")))
    rows.append(r^)

    var bytes = build_equality_delete_file(eq_field_ids, eq_types, rows)
    var decoded = read_equality_delete_file(bytes, eq_types)
    assert_equal(len(decoded), 1, "one composite delete key")
    assert_equal(decoded[0][0].as_long(), Int64(7), "id cell == 7")
    assert_equal(
        decoded[0][1].as_string(), String("gone"), "name cell == 'gone'"
    )


def test_position_delete_file_roundtrip() raises:
    """A position-delete file over (f, 0) and (f, 4) round-trips both pairs."""
    var entries = List[PositionDeleteEntry]()
    entries.append(PositionDeleteEntry(String("/tbl/data/d.avro"), Int64(0)))
    entries.append(PositionDeleteEntry(String("/tbl/data/d.avro"), Int64(4)))

    var bytes = build_position_delete_file(entries)
    assert_true(_is_avro_ocf(bytes), "position-delete file is Avro OCF")

    var decoded = read_position_delete_file(bytes)
    assert_equal(len(decoded), 2, "two position-delete entries round-trip")
    assert_equal(
        decoded[0].file_path, String("/tbl/data/d.avro"), "entry 0 path"
    )
    assert_equal(decoded[0].pos, Int64(0), "entry 0 pos == 0")
    assert_equal(decoded[1].pos, Int64(4), "entry 1 pos == 4")


def _ocf_claiming(
    schema_json: String, count: Int, payload: List[UInt8]
) raises -> List[UInt8]:
    """A file whose single block CLAIMS `count` records over `payload`: the
    header and framing are real, the count is the lie."""
    var sync = generate_sync_marker()
    var out = List[UInt8]()
    emit_ocf_header_kv(
        schema_json, AVRO_CODEC_NULL, sync, List[String](), List[String](), out
    )
    emit_ocf_block(Span(payload), count, AVRO_CODEC_NULL, sync, out)
    return out^


def test_an_equality_delete_block_cannot_claim_more_rows_than_bytes() raises:
    """One long column, a 2-byte payload: at most 2 rows. A block that claims
    3 is refused by the count bound itself, and a block that claims exactly 2
    is read."""
    var schema = String(
        '{"type":"record","name":"d","fields":[{"name":"id","type":"long",'
        '"field-id":1}]}'
    )
    var types = List[Int]()
    types.append(ICE_T_LONG)
    var payload = List[UInt8]()
    payload.append(2)
    payload.append(4)
    assert_equal(
        len(read_equality_delete_file(_ocf_claiming(schema, 2, payload), types)),
        2,
    )
    with assert_raises(contains="block claims 3 rows in 2 payload bytes"):
        _ = read_equality_delete_file(_ocf_claiming(schema, 3, payload), types)
    with assert_raises(contains="block claims 1000000 rows in 2 payload"):
        _ = read_equality_delete_file(
            _ocf_claiming(schema, 1000000, payload), types
        )


def test_a_position_delete_block_cannot_claim_more_rows_than_bytes() raises:
    """A position-delete row is at least 2 bytes (an empty path and a long), so
    a 4-byte payload holds at most 2 rows. A block that claims 3 is refused by
    the count bound itself, and a block that claims exactly 2 is read."""
    var schema = String(
        '{"type":"record","name":"d","fields":[{"name":"file_path",'
        '"type":"string","field-id":2147483546},{"name":"pos","type":"long",'
        '"field-id":2147483545}]}'
    )
    var payload = List[UInt8]()
    for _ in range(4):
        payload.append(0)
    var two = read_position_delete_file(_ocf_claiming(schema, 2, payload))
    assert_equal(len(two), 2)
    with assert_raises(contains="block claims 3 rows in 4 payload bytes"):
        _ = read_position_delete_file(_ocf_claiming(schema, 3, payload))
    with assert_raises(contains="block claims 1000000 rows in 4 payload"):
        _ = read_position_delete_file(_ocf_claiming(schema, 1000000, payload))


def main() raises:
    test_equality_delete_file_roundtrip()
    test_equality_delete_file_two_column_key()
    test_position_delete_file_roundtrip()
    test_an_equality_delete_block_cannot_claim_more_rows_than_bytes()
    test_a_position_delete_block_cannot_claim_more_rows_than_bytes()
    print("test_iceberg_delete_writer: ALL PASS")
