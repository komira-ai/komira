# =============================================================================
# test_iceberg_parquet_merge_on_read.mojo — merge-on-read over Parquet data
# files, and the sequence-number boundaries.
# =============================================================================
#
# THE GATE (test_parquet_data_through_merge_masks_key):
#   Write a Parquet data file, commit it, equality-delete a key, assert the
#   reader masks it -> reader sees N-1.
#
# Also the boundaries:
#   * a position delete masks ONLY data files with a sequence number <= the
#     delete's (data_seq <= del_seq). A LATER data file at the SAME (path, pos)
#     with a HIGHER seq survives a stale position delete.
#   * equal-seq masked-side boundary: data(seq=2) + equality-delete(seq=2) on
#     the same key -> the row SURVIVES (strictly-lower rule).
#   * commit() REJECTS an equality-delete key on a NULLABLE column (raise).
# =============================================================================

from std.testing import assert_true, assert_equal, assert_raises

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
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
    read_parquet_data_file,
    col_types_of,
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
    schema.add(String("name"), ICE_T_STRING, required=True)
    return schema^


def _row(id: Int64, var name: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    return r^


def _data_file_info(
    key: String, record_count: Int, size: Int
) -> DataFileInfo:
    return DataFileInfo(String(key), size, record_count, List[ColumnBound]())


def _eq_delete_info(
    key: String, record_count: Int, size: Int, seq: Int64
) -> DataFileInfo:
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
    var rows = List[List[RowCell]]()
    for i in range(len(ids)):
        var r = List[RowCell]()
        r.append(make_long_cell(ids[i]))
        rows.append(r^)
    return rows^


def _has_id(rows: List[List[RowCell]], id: Int64) -> Bool:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            return True
    return False


def _find_name_for_id(rows: List[List[RowCell]], id: Int64) raises -> String:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            return rows[i][1].as_string()
    raise Error("id " + String(id) + " not found in live rows")


# =============================================================================
# Round-trip unit: the Parquet leg itself (write -> read == identity).
# =============================================================================


def test_parquet_data_file_roundtrip() raises:
    """The Parquet DATA-file leg round-trips typed rows byte-for-value: build a
    real Parquet file from rows, decode it back, assert cell equality + FILE-
    ABSOLUTE ROW ORDER (the DECODE INVARIANT the position-delete predicate relies
    on)."""
    var schema = _people_schema()
    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(10), String("x")))
    rows.append(_row(Int64(11), String("y")))
    rows.append(_row(Int64(12), String("z")))

    var bytes = build_parquet_data_file(schema, rows)
    # A real Parquet file begins + ends with the PAR1 magic.
    assert_true(len(bytes) > 12, "produced a non-trivial Parquet file")
    assert_true(
        bytes[0] == UInt8(80)
        and bytes[1] == UInt8(65)
        and bytes[2] == UInt8(82)
        and bytes[3] == UInt8(49),
        "leading PAR1 magic (this is a Parquet file, not Avro)",
    )

    var decoded = read_parquet_data_file(bytes, col_types_of(schema))
    assert_equal(len(decoded), 3, "decoded row count matches")
    # Order preserved (offset 0,1,2 == id 10,11,12).
    assert_equal(decoded[0][0].as_long(), Int64(10), "row 0 id (order)")
    assert_equal(decoded[1][0].as_long(), Int64(11), "row 1 id (order)")
    assert_equal(decoded[2][0].as_long(), Int64(12), "row 2 id (order)")
    assert_equal(decoded[0][1].as_string(), String("x"), "row 0 name")
    assert_equal(decoded[1][1].as_string(), String("y"), "row 1 name")
    assert_equal(decoded[2][1].as_string(), String("z"), "row 2 name")


# =============================================================================
# THE GATE: Parquet through merge -> equality-delete masks.
# =============================================================================


def test_parquet_data_through_merge_masks_key() raises:
    """THE GATE. Write a Parquet data file, commit it, equality-delete a key,
    assert `read_live_rows` masks it -> reader sees N-1."""
    var location = String("warehouse/g1/people")
    var schema = _people_schema()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # commit 1 (seq 1): 3 rows as a REAL Parquet data file.
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

    # commit 2 (seq 2): equality-delete key id=2 (delete file stays Avro).
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

    # read back: exactly N-1 = 2 rows, id=2 gone — over REAL Parquet.
    var live = writer.read_live_rows()
    assert_equal(
        len(live), 2, "N-1 rows after equality-delete over REAL Parquet"
    )
    assert_true(_has_id(live, Int64(1)), "id 1 survives")
    assert_true(not _has_id(live, Int64(2)), "id 2 is deleted")
    assert_true(_has_id(live, Int64(3)), "id 3 survives")


# =============================================================================
# Position-delete sequence rule (data_seq <= del_seq).
# =============================================================================


def test_position_delete_only_masks_le_sequence() raises:
    """A position delete masks ONLY data files with a sequence number <= the
    delete's. A LATER data file at the SAME (path, pos) with a HIGHER seq
    SURVIVES a stale position delete of a lower generation (matching on
    (path, pos) alone would silently over-mask it)."""
    var location = String("warehouse/c3/people")
    var schema = _people_schema()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # A single reused data-file KEY across two generations (path reuse — the
    # exact scenario compaction / re-columnarize enables). The store PUT
    # overwrites the object; the manifest carry-forward means BOTH manifest
    # entries (seq 1 and seq 3) reference this key, but the object holds the
    # seq-3 content. We assert the SURVIVING row is the seq-3 content, NOT
    # masked by the seq-2 position delete.
    var reused_key = writer.data_dir() + "/reused-0001.parquet"

    # commit 1 (seq 1): the reused key holds 1 row at offset 0.
    var rows1 = List[List[RowCell]]()
    rows1.append(_row(Int64(7), String("gen1")))
    var b1 = build_parquet_data_file(schema, rows1)
    writer.put_object(reused_key, b1.copy())
    var dfs1 = List[DataFileInfo]()
    dfs1.append(_data_file_info(reused_key, 1, len(b1)))
    _ = writer.commit(dfs1^, List[DataFileInfo]())

    # commit 2 (seq 2): position-delete (reused_key, offset 0). Masks seq <= 2.
    var pos_entries = List[PositionDeleteEntry]()
    pos_entries.append(PositionDeleteEntry(String(reused_key), Int64(0)))
    var pos_bytes = build_position_delete_file(pos_entries)
    var pos_key = writer.data_dir() + "/posdel-0002.avro"
    writer.put_object(pos_key, pos_bytes.copy())
    var deletes2 = List[DataFileInfo]()
    deletes2.append(_pos_delete_info(pos_key, 1, len(pos_bytes), Int64(2)))
    _ = writer.commit(List[DataFileInfo](), deletes2^)

    # commit 3 (seq 3): the reused key is RE-EMITTED with fresh content at the
    # same offset 0. Overwrite the object AND register a seq-3 manifest entry.
    var rows3 = List[List[RowCell]]()
    rows3.append(_row(Int64(7), String("gen3")))
    var b3 = build_parquet_data_file(schema, rows3)
    writer.put_object(reused_key, b3.copy())
    var dfs3 = List[DataFileInfo]()
    dfs3.append(_data_file_info(reused_key, 1, len(b3)))
    _ = writer.commit(dfs3^, List[DataFileInfo]())

    # The seq-2 position delete masks the seq-1 generation of (reused_key, 0)
    # but NOT the seq-3 generation. The seq-3 row survives.
    var live = writer.read_live_rows()
    assert_true(
        _has_id(live, Int64(7)),
        "the seq-3 re-emitted row survives the stale seq-2 position delete"
        " (data_seq <= del_seq gate)",
    )
    assert_equal(
        _find_name_for_id(live, Int64(7)),
        String("gen3"),
        "the surviving row is the seq-3 content, not the masked seq-1",
    )


# =============================================================================
# Equal-seq masked-side boundary (strictly-lower rule).
# =============================================================================


def test_equality_delete_equal_seq_survives() raises:
    """Boundary: data(seq=2) + equality-delete(seq=2) on the SAME key -> the row
    SURVIVES. An equality delete masks ONLY data with a STRICTLY LOWER sequence
    number (< del_seq), so an equal-seq data row is NOT masked (an ordering rule
    of `<=` would wrongly mask it: len 0 instead of 1)."""
    var location = String("warehouse/c5/people")
    var schema = _people_schema()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # commit 1 (seq 1): a filler row so commit 2 lands at seq 2 (both the data
    # file AND the equality delete are committed in seq 2 -> equal seq).
    var rows1 = List[List[RowCell]]()
    rows1.append(_row(Int64(99), String("filler")))
    var b1 = build_parquet_data_file(schema, rows1)
    var k1 = writer.data_dir() + "/filler-0001.parquet"
    writer.put_object(k1, b1.copy())
    var dfs1 = List[DataFileInfo]()
    dfs1.append(_data_file_info(k1, 1, len(b1)))
    _ = writer.commit(dfs1^, List[DataFileInfo]())

    # commit 2 (seq 2): data file with id=8 AND an equality-delete of id=8, both
    # at seq 2. The strictly-lower rule (data_seq < del_seq) => 2 < 2 is FALSE
    # => id=8 is NOT masked by its equal-seq delete. (The seq-1 filler is not
    # id=8, so it is untouched.)
    var rows2 = List[List[RowCell]]()
    rows2.append(_row(Int64(8), String("same_seq")))
    var b2 = build_parquet_data_file(schema, rows2)
    var k2 = writer.data_dir() + "/d-0002.parquet"
    writer.put_object(k2, b2.copy())

    var del_ids = List[Int64]()
    del_ids.append(Int64(8))
    var eq_field_ids = List[Int]()
    eq_field_ids.append(1)
    var eq_types = List[Int]()
    eq_types.append(ICE_T_LONG)
    var del_bytes = build_equality_delete_file(
        eq_field_ids, eq_types, _eq_delete_rows_by_id(del_ids)
    )
    var del_key = writer.data_dir() + "/eqdel-0002.avro"
    writer.put_object(del_key, del_bytes.copy())

    var dfs2 = List[DataFileInfo]()
    dfs2.append(_data_file_info(k2, 1, len(b2)))
    var deletes2 = List[DataFileInfo]()
    # The caller-supplied seq is IGNORED (commit stamps it to the commit seq
    # == 2); pass a placeholder to prove the stamp is authoritative.
    deletes2.append(_eq_delete_info(del_key, 1, len(del_bytes), Int64(999)))
    _ = writer.commit(dfs2^, deletes2^)

    var live = writer.read_live_rows()
    # id=8 survives (equal-seq, strictly-lower rule); filler(99) also survives.
    assert_true(
        _has_id(live, Int64(8)),
        "equal-seq data row is NOT masked (strictly-lower rule: 2 < 2 is false)",
    )
    assert_equal(
        _find_name_for_id(live, Int64(8)),
        String("same_seq"),
        "the equal-seq row is present with its own value",
    )
    assert_true(_has_id(live, Int64(99)), "seq-1 filler untouched")


# =============================================================================
# Reject an equality-delete key on a NULLABLE column.
# =============================================================================


def test_equality_delete_on_nullable_key_rejected() raises:
    """commit() REJECTS an equality-delete whose key is declared on a NULLABLE
    column. Null equality-key semantics (IS-NOT-DISTINCT-FROM) are not
    implemented, so admitting one would silently mis-mask NULL-bearing rows."""
    var location = String("warehouse/c2/people")
    # `name` (field-id 2) is NULLABLE (required=False). Declare the equality key
    # on it to trip the guard.
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    schema.add(String("name"), ICE_T_STRING, required=False)  # NULLABLE

    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # commit 1 (seq 1): one row.
    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(1), String("alice")))
    var data_key = writer.data_dir() + "/d-0001.parquet"
    var data_bytes = build_parquet_data_file(schema, rows)
    writer.put_object(data_key, data_bytes.copy())
    var dfs = List[DataFileInfo]()
    dfs.append(_data_file_info(data_key, 1, len(data_bytes)))
    _ = writer.commit(dfs^, List[DataFileInfo]())

    # commit 2: an equality-delete keyed on the NULLABLE `name` column (field-id
    # 2). commit() must REJECT it.
    var del_rows = List[List[RowCell]]()
    var dr = List[RowCell]()
    dr.append(make_string_cell(String("alice")))
    del_rows.append(dr^)
    var eq_field_ids = List[Int]()
    eq_field_ids.append(2)  # field-id 2 = `name` (NULLABLE)
    var eq_types = List[Int]()
    eq_types.append(ICE_T_STRING)
    var del_bytes = build_equality_delete_file(
        eq_field_ids, eq_types, del_rows
    )
    var del_key = writer.data_dir() + "/eqdel-name-0002.avro"
    writer.put_object(del_key, del_bytes.copy())

    var nullable_eids = List[Int]()
    nullable_eids.append(2)
    var bad_delete = DataFileInfo(
        String(del_key),
        len(del_bytes),
        1,
        List[ColumnBound](),
        ICE_DATA_CONTENT_EQUALITY_DELETES,
        nullable_eids^,
        Int64(2),
    )
    var deletes = List[DataFileInfo]()
    deletes.append(bad_delete^)

    with assert_raises(contains="NULLABLE"):
        _ = writer.commit(List[DataFileInfo](), deletes^)


def main() raises:
    test_parquet_data_file_roundtrip()
    test_parquet_data_through_merge_masks_key()
    test_position_delete_only_masks_le_sequence()
    test_equality_delete_equal_seq_survives()
    test_equality_delete_on_nullable_key_rejected()
    print("test_iceberg_parquet_merge_on_read: ALL PASS")
