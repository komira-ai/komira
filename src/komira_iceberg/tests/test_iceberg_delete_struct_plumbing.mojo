# =============================================================================
# test_iceberg_delete_struct_plumbing.mojo — DataFileInfo carries content and
# equality_ids; the manifest-entry encoder round-trips content 1/2 and the
# delete entry's own sequence number.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. DataFileInfo's 4-argument constructor defaults to content 0 (data), no
#      equality ids, an inherited sequence number: the append path's shape.
#   2. The content constants are the spec's: 0 data, 1 position deletes, 2
#      equality deletes.
#   3. A manifest built over data, position-delete and equality-delete files
#      encodes each entry's content and its OWN sequence number, and decoding it
#      recovers content, sequence number and the equality ids. A delete entry
#      that took the commit's sequence number would be ordered wrongly against
#      data files by merge-on-read.
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    IcebergSchema,
    DataFileInfo,
    ColumnBound,
    ICE_CONTENT_DATA,
    ICE_CONTENT_POSITION_DELETES,
    ICE_CONTENT_EQUALITY_DELETES,
    build_manifest_file,
    read_manifest_entries,
    schema_json,
)


def test_datafileinfo_content_and_equality_ids_defaults() raises:
    """The legacy 4-arg DataFileInfo ctor still works and defaults content=data
    with an empty equality_ids list (the append path + REST projection rely on
    positional 4-arg construction)."""
    var df = DataFileInfo(
        String("/tbl/data/f.parquet"), 100, 3, List[ColumnBound]()
    )
    assert_equal(df.content, ICE_CONTENT_DATA, "legacy ctor defaults content=0")
    assert_equal(
        len(df.equality_ids), 0, "legacy ctor defaults empty equality_ids"
    )


def test_delete_content_constants() raises:
    """The delete content-type constants exist and are 1 (position) / 2
    (equality) per the Iceberg v2 spec."""
    assert_equal(ICE_CONTENT_DATA, 0, "data content == 0")
    assert_equal(
        ICE_CONTENT_POSITION_DELETES, 1, "position-delete content == 1"
    )
    assert_equal(
        ICE_CONTENT_EQUALITY_DELETES, 2, "equality-delete content == 2"
    )


def test_manifest_entry_encodes_content_and_per_entry_seq() raises:
    """A manifest FILE over a mix of one data file (seq 5), one position-delete
    file (seq 7), and one equality-delete file (seq 9, equality_ids=[2]) encodes
    each entry's content + its OWN sequence number, and re-decoding recovers all
    three round-trip."""
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    schema.add(String("name"), ICE_T_STRING, required=False)
    var sj = schema_json(schema)

    # a data file at seq 5
    var data_df = DataFileInfo(
        String("/tbl/data/d.parquet"),
        200,
        10,
        List[ColumnBound](),
        ICE_CONTENT_DATA,
        List[Int](),
        Int64(5),
    )
    # a position-delete file at seq 7
    var pos_df = DataFileInfo(
        String("/tbl/data/p-delete.avro"),
        40,
        1,
        List[ColumnBound](),
        ICE_CONTENT_POSITION_DELETES,
        List[Int](),
        Int64(7),
    )
    # an equality-delete file at seq 9, equality on field-id 2 (name)
    var eq_ids = List[Int]()
    eq_ids.append(2)
    var eq_df = DataFileInfo(
        String("/tbl/data/e-delete.avro"),
        30,
        1,
        List[ColumnBound](),
        ICE_CONTENT_EQUALITY_DELETES,
        eq_ids^,
        Int64(9),
    )

    var files = List[DataFileInfo]()
    files.append(data_df^)
    files.append(pos_df^)
    files.append(eq_df^)

    # snapshot_id 12345; the fallback commit sequence number (77) is used only
    # when an entry does NOT carry its own per-entry seq — every entry here does.
    var manifest_bytes = build_manifest_file(
        schema, sj, Int64(12345), Int64(77), files
    )

    var decoded = read_manifest_entries(manifest_bytes)
    assert_equal(len(decoded), 3, "three manifest entries round-trip")

    # entry 0: data, seq 5
    assert_equal(decoded[0].content, ICE_CONTENT_DATA, "e0 content=data")
    assert_equal(decoded[0].sequence_number, Int64(5), "e0 seq==5")
    assert_equal(len(decoded[0].equality_ids), 0, "e0 no equality_ids")

    # entry 1: position-delete, seq 7
    assert_equal(
        decoded[1].content,
        ICE_CONTENT_POSITION_DELETES,
        "e1 content=position-delete",
    )
    assert_equal(decoded[1].sequence_number, Int64(7), "e1 seq==7")

    # entry 2: equality-delete, seq 9, equality_ids=[2]
    assert_equal(
        decoded[2].content,
        ICE_CONTENT_EQUALITY_DELETES,
        "e2 content=equality-delete",
    )
    assert_equal(decoded[2].sequence_number, Int64(9), "e2 seq==9")
    assert_equal(len(decoded[2].equality_ids), 1, "e2 one equality id")
    assert_equal(decoded[2].equality_ids[0], 2, "e2 equality id == field 2")


def main() raises:
    test_datafileinfo_content_and_equality_ids_defaults()
    test_delete_content_constants()
    test_manifest_entry_encodes_content_and_per_entry_seq()
    print("test_iceberg_delete_struct_plumbing: ALL PASS")
