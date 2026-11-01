# =============================================================================
# test_iceberg_merge_on_read.mojo — insert -> update -> delete -> read-back
# correctness over the in-memory ConditionalWriteStore.
# =============================================================================
#
# Five falsifiers of the merge-on-read loop (no cloud, no external source):
#
#   (1) write N rows -> equality-delete by key k -> reader sees exactly N-1
#       (the deleted key is gone).
#   (2) update (delete-old-by-key + append-new) -> reader sees the NEW value,
#       not the old.
#   (3) position-delete a specific row offset -> exactly that row masked.
#   (4) an equality delete masks ONLY data files with a STRICTLY LOWER sequence
#       number (a later re-insert of the same key survives).
#   (5) the plain APPEND path (no deletes) reads back every row.
#
# A reader that wrote the delete files but did not honor them would show the
# deleted, stale or masked rows: the silent correctness hole this gate closes.
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    ICE_DATA_CONTENT_DATA,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    ICE_DATA_CONTENT_POSITION_DELETES,
    IcebergSchema,
    DataFileInfo,
    ColumnBound,
    IcebergTableWriter,
    RowCell,
    make_long_cell,
    make_string_cell,
    build_parquet_data_file,
    build_equality_delete_file,
    build_position_delete_file,
    PositionDeleteEntry,
    gen_table_uuid,
)




# =============================================================================
# Helpers.
# =============================================================================


def _people_schema() -> IcebergSchema:
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    schema.add(String("name"), ICE_T_STRING, required=False)
    return schema^


def _row(id: Int64, var name: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    return r^


def _data_file_info(
    key: String, record_count: Int, size: Int
) -> DataFileInfo:
    """A DATA-file DataFileInfo (content=0, seq inherits the commit)."""
    return DataFileInfo(String(key), size, record_count, List[ColumnBound]())


def _eq_delete_info(
    key: String, record_count: Int, size: Int, seq: Int64
) -> DataFileInfo:
    """An EQUALITY-delete DataFileInfo (content=2, equality on field-id 1 = id,
    with its OWN sequence number)."""
    var eids = List[Int]()
    eids.append(1)  # equality on the `id` column (field-id 1)
    return DataFileInfo(
        String(key),
        size,
        record_count,
        List[ColumnBound](),
        ICE_DATA_CONTENT_EQUALITY_DELETES,
        eids^,
        seq,
    )


def _pos_delete_info(
    key: String, record_count: Int, size: Int, seq: Int64
) -> DataFileInfo:
    """A POSITION-delete DataFileInfo (content=1, its OWN sequence number)."""
    return DataFileInfo(
        String(key),
        size,
        record_count,
        List[ColumnBound](),
        ICE_DATA_CONTENT_POSITION_DELETES,
        List[Int](),
        seq,
    )


def _eq_delete_rows_by_id(ids: List[Int64]) -> List[List[RowCell]]:
    """Equality-delete rows: one single-cell (id) tuple per key to delete."""
    var rows = List[List[RowCell]]()
    for i in range(len(ids)):
        var r = List[RowCell]()
        r.append(make_long_cell(ids[i]))
        rows.append(r^)
    return rows^


def _find_name_for_id(
    rows: List[List[RowCell]], id: Int64
) raises -> String:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            return rows[i][1].as_string()
    raise Error("id " + String(id) + " not found in live rows")


def _has_id(rows: List[List[RowCell]], id: Int64) -> Bool:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            return True
    return False


# =============================================================================
# Falsifier (1): write N rows -> equality-delete key k -> reader sees N-1.
# =============================================================================


def test_equality_delete_masks_key() raises:
    var location = String("warehouse/t1/people")
    var schema = _people_schema()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # commit 1 (seq 1): 3 rows.
    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(1), String("alice")))
    rows.append(_row(Int64(2), String("bob")))
    rows.append(_row(Int64(3), String("carol")))
    var data_key = writer.data_dir() + "/d-0001.parquet"
    var data_bytes = build_parquet_data_file(schema, rows)
    writer.put_object(data_key, data_bytes.copy())
    var dfs = List[DataFileInfo]()
    dfs.append(_data_file_info(data_key, 3, len(data_bytes)))
    _ = writer.commit(dfs^, List[DataFileInfo]())

    # commit 2 (seq 2): equality-delete key id=2.
    var del_key = writer.data_dir() + "/eqdel-0002.avro"
    var del_ids = List[Int64]()
    del_ids.append(Int64(2))
    var eq_field_ids = List[Int]()
    eq_field_ids.append(1)
    var eq_types = List[Int]()
    eq_types.append(ICE_T_LONG)
    var del_bytes = build_equality_delete_file(
        eq_field_ids, eq_types, _eq_delete_rows_by_id(del_ids)
    )
    writer.put_object(del_key, del_bytes.copy())
    var deletes = List[DataFileInfo]()
    deletes.append(_eq_delete_info(del_key, 1, len(del_bytes), Int64(2)))
    _ = writer.commit(List[DataFileInfo](), deletes^)

    # read back: exactly N-1 = 2 rows, id=2 gone.
    var live = writer.read_live_rows()
    assert_equal(len(live), 2, "N-1 rows after equality-delete of one key")
    assert_true(_has_id(live, Int64(1)), "id 1 survives")
    assert_true(not _has_id(live, Int64(2)), "id 2 is deleted")
    assert_true(_has_id(live, Int64(3)), "id 3 survives")


# =============================================================================
# Falsifier (2): update (delete-old + append-new) -> reader sees NEW value.
# =============================================================================


def test_update_sees_new_value() raises:
    var location = String("warehouse/t2/people")
    var schema = _people_schema()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # commit 1 (seq 1): id=1 name="alice".
    var rows1 = List[List[RowCell]]()
    rows1.append(_row(Int64(1), String("alice")))
    var d1_key = writer.data_dir() + "/d-0001.parquet"
    var d1_bytes = build_parquet_data_file(schema, rows1)
    writer.put_object(d1_key, d1_bytes.copy())
    var dfs1 = List[DataFileInfo]()
    dfs1.append(_data_file_info(d1_key, 1, len(d1_bytes)))
    _ = writer.commit(dfs1^, List[DataFileInfo]())

    # commit 2 (seq 2): UPDATE id=1 -> "alicia" = equality-delete id=1 (seq 2)
    # + append (id=1,"alicia") as a NEW data file (seq 2). The delete masks ONLY
    # seq < 2, so the seq-2 data file survives; the seq-1 "alice" row is masked.
    var del_key = writer.data_dir() + "/eqdel-0002.avro"
    var del_ids = List[Int64]()
    del_ids.append(Int64(1))
    var eq_field_ids = List[Int]()
    eq_field_ids.append(1)
    var eq_types = List[Int]()
    eq_types.append(ICE_T_LONG)
    var del_bytes = build_equality_delete_file(
        eq_field_ids, eq_types, _eq_delete_rows_by_id(del_ids)
    )
    writer.put_object(del_key, del_bytes.copy())

    var rows2 = List[List[RowCell]]()
    rows2.append(_row(Int64(1), String("alicia")))
    var d2_key = writer.data_dir() + "/d-0002.parquet"
    var d2_bytes = build_parquet_data_file(schema, rows2)
    writer.put_object(d2_key, d2_bytes.copy())

    var dfs2 = List[DataFileInfo]()
    dfs2.append(_data_file_info(d2_key, 1, len(d2_bytes)))
    var deletes = List[DataFileInfo]()
    deletes.append(_eq_delete_info(del_key, 1, len(del_bytes), Int64(2)))
    _ = writer.commit(dfs2^, deletes^)

    var live = writer.read_live_rows()
    assert_equal(len(live), 1, "exactly one live row after update")
    assert_equal(
        _find_name_for_id(live, Int64(1)),
        String("alicia"),
        "update reads the NEW value, not the old 'alice'",
    )


# =============================================================================
# Falsifier (3): position-delete a specific row offset -> that row masked.
# =============================================================================


def test_position_delete_masks_offset() raises:
    var location = String("warehouse/t3/people")
    var schema = _people_schema()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # commit 1 (seq 1): 3 rows at offsets 0,1,2.
    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(10), String("x")))
    rows.append(_row(Int64(11), String("y")))
    rows.append(_row(Int64(12), String("z")))
    var data_key = writer.data_dir() + "/d-0001.parquet"
    var data_bytes = build_parquet_data_file(schema, rows)
    writer.put_object(data_key, data_bytes.copy())
    var dfs = List[DataFileInfo]()
    dfs.append(_data_file_info(data_key, 3, len(data_bytes)))
    _ = writer.commit(dfs^, List[DataFileInfo]())

    # commit 2 (seq 2): position-delete (data_key, offset 1) => mask id=11.
    var pos_entries = List[PositionDeleteEntry]()
    pos_entries.append(PositionDeleteEntry(String(data_key), Int64(1)))
    var pos_bytes = build_position_delete_file(pos_entries)
    var pos_key = writer.data_dir() + "/posdel-0002.avro"
    writer.put_object(pos_key, pos_bytes.copy())
    var deletes = List[DataFileInfo]()
    deletes.append(_pos_delete_info(pos_key, 1, len(pos_bytes), Int64(2)))
    _ = writer.commit(List[DataFileInfo](), deletes^)

    var live = writer.read_live_rows()
    assert_equal(len(live), 2, "one row masked by position-delete")
    assert_true(_has_id(live, Int64(10)), "offset-0 row survives")
    assert_true(not _has_id(live, Int64(11)), "offset-1 row masked")
    assert_true(_has_id(live, Int64(12)), "offset-2 row survives")


# =============================================================================
# Falsifier (4): equality delete masks ONLY LOWER-seq data (re-insert survives).
# =============================================================================


def test_equality_delete_only_masks_lower_sequence() raises:
    var location = String("warehouse/t4/people")
    var schema = _people_schema()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # commit 1 (seq 1): id=5 name="old".
    var rows1 = List[List[RowCell]]()
    rows1.append(_row(Int64(5), String("old")))
    var d1_key = writer.data_dir() + "/d-0001.parquet"
    var d1_bytes = build_parquet_data_file(schema, rows1)
    writer.put_object(d1_key, d1_bytes.copy())
    var dfs1 = List[DataFileInfo]()
    dfs1.append(_data_file_info(d1_key, 1, len(d1_bytes)))
    _ = writer.commit(dfs1^, List[DataFileInfo]())

    # commit 2 (seq 2): equality-delete id=5 (seq 2). Masks the seq-1 row.
    var del_key = writer.data_dir() + "/eqdel-0002.avro"
    var del_ids = List[Int64]()
    del_ids.append(Int64(5))
    var eq_field_ids = List[Int]()
    eq_field_ids.append(1)
    var eq_types = List[Int]()
    eq_types.append(ICE_T_LONG)
    var del_bytes = build_equality_delete_file(
        eq_field_ids, eq_types, _eq_delete_rows_by_id(del_ids)
    )
    writer.put_object(del_key, del_bytes.copy())
    var deletes2 = List[DataFileInfo]()
    deletes2.append(_eq_delete_info(del_key, 1, len(del_bytes), Int64(2)))
    _ = writer.commit(List[DataFileInfo](), deletes2^)

    # commit 3 (seq 3): RE-INSERT id=5 name="new" as a seq-3 data file. The
    # seq-2 equality delete masks ONLY seq < 2, so the seq-3 row SURVIVES.
    var rows3 = List[List[RowCell]]()
    rows3.append(_row(Int64(5), String("new")))
    var d3_key = writer.data_dir() + "/d-0003.parquet"
    var d3_bytes = build_parquet_data_file(schema, rows3)
    writer.put_object(d3_key, d3_bytes.copy())
    var dfs3 = List[DataFileInfo]()
    dfs3.append(_data_file_info(d3_key, 1, len(d3_bytes)))
    _ = writer.commit(dfs3^, List[DataFileInfo]())

    var live = writer.read_live_rows()
    assert_equal(len(live), 1, "the re-inserted key is live (delete is lower)")
    assert_equal(
        _find_name_for_id(live, Int64(5)),
        String("new"),
        "the higher-seq re-insert survives the lower-seq equality delete",
    )


# =============================================================================
# Falsifier (5): the plain append path (no deletes) reads back every row.
# =============================================================================


def test_append_only_reads_all_rows() raises:
    var location = String("warehouse/t5/people")
    var schema = _people_schema()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # commit 1: 2 rows.
    var rows1 = List[List[RowCell]]()
    rows1.append(_row(Int64(1), String("a")))
    rows1.append(_row(Int64(2), String("b")))
    var d1_key = writer.data_dir() + "/d-0001.parquet"
    var d1_bytes = build_parquet_data_file(schema, rows1)
    writer.put_object(d1_key, d1_bytes.copy())
    var dfs1 = List[DataFileInfo]()
    dfs1.append(_data_file_info(d1_key, 2, len(d1_bytes)))
    var res1 = writer.commit_append(dfs1^)
    assert_equal(res1.version, 1, "append via commit_append is v1")

    # commit 2: 1 more row (append carry-forward must keep commit-1 rows).
    var rows2 = List[List[RowCell]]()
    rows2.append(_row(Int64(3), String("c")))
    var d2_key = writer.data_dir() + "/d-0002.parquet"
    var d2_bytes = build_parquet_data_file(schema, rows2)
    writer.put_object(d2_key, d2_bytes.copy())
    var dfs2 = List[DataFileInfo]()
    dfs2.append(_data_file_info(d2_key, 1, len(d2_bytes)))
    _ = writer.commit_append(dfs2^)

    var live = writer.read_live_rows()
    assert_equal(len(live), 3, "append path reads back ALL rows (no regression)")
    assert_true(_has_id(live, Int64(1)), "commit-1 row 1 present")
    assert_true(_has_id(live, Int64(2)), "commit-1 row 2 present")
    assert_true(_has_id(live, Int64(3)), "commit-2 row 3 present")


def main() raises:
    test_equality_delete_masks_key()
    test_update_sees_new_value()
    test_position_delete_masks_offset()
    test_equality_delete_only_masks_lower_sequence()
    test_append_only_reads_all_rows()
    print("test_iceberg_merge_on_read: ALL PASS")
