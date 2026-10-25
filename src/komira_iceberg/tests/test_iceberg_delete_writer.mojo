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

from std.testing import assert_true, assert_equal

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


def main() raises:
    test_equality_delete_file_roundtrip()
    test_equality_delete_file_two_column_key()
    test_position_delete_file_roundtrip()
    print("test_iceberg_delete_writer: ALL PASS")
