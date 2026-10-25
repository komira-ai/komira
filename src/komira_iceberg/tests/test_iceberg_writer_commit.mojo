# =============================================================================
# test_iceberg_writer_commit.mojo — the commit protocol of the table writer.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. A lost create of `v<N>.metadata.json` is a commit conflict that leaves the
#      other writer's file untouched: tolerating it would let the loser's
#      content stand as a version the winner believes it wrote.
#   2. A writer that sees a version past the hint (a writer stopped before moving
#      the hint) commits on top of it, and moves the hint to the new version.
#   3. The hint swap loses cleanly: a hint already at or past this version is
#      left alone, a lagging one is moved up, and it never moves backwards.
#   4. A carried-forward manifest keeps the snapshot it was added under; a
#      carried snapshot keeps its whole summary; earlier schemas stay listed.
#   5. The snapshot's `operation` and delete counters follow what was committed;
#      a caller's summary key that collides with one the commit writes, a change
#      of partition spec, and an equality delete on a nullable key are refused.
#   6. A partitioned table with delete files names the unpartitioned delete spec
#      in its manifest list and metadata, and still reads back.
#   7. Table uuids and snapshot ids are unique and well formed.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false, assert_raises

from komira_libc.posix import _read_env
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    ICE_T_DOUBLE,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    ICE_DATA_CONTENT_POSITION_DELETES,
    IcebergSchema,
    DataFileInfo,
    ColumnBound,
    IcebergTableWriter,
    PartitionSpec,
    SummaryKV,
    RowCell,
    make_long_cell,
    make_string_cell,
    PositionDeleteEntry,
    build_parquet_data_file,
    build_equality_delete_file,
    build_position_delete_file,
    read_manifest_list,
    read_hint_version,
    current_version,
    metadata_json_key,
    pointer_key,
    gen_table_uuid,
    evolve_add_column,
    partition_value_of,
    partition_value_type_tags,
    encode_partition_values,
    ICE_MANIFEST_CONTENT_DATA,
    ICE_MANIFEST_CONTENT_DELETES,
)
from komira_iceberg.iceberg_writer_state import gen_snapshot_id


def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        raise Error("TEST_TMPDIR is not set: the test needs its own scratch directory")
    return d


def _has(s: String, needle: String) -> Bool:
    return s.find(needle) >= 0


def _schema() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("region"), ICE_T_STRING, required=True)
    return s^


def _row(id: Int64, var region: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(region^))
    return r^


def _writer(tag: String) raises -> IcebergTableWriter[LocalFsConditionalStore]:
    var root = _scratch_dir() + String("/commit_") + tag
    return IcebergTableWriter[LocalFsConditionalStore](
        LocalFsConditionalStore(root), String("tbl"), _schema(), gen_table_uuid()
    )


def _reopen(
    tag: String, schema: IcebergSchema, uuid: String
) raises -> IcebergTableWriter[LocalFsConditionalStore]:
    var root = _scratch_dir() + String("/commit_") + tag
    return IcebergTableWriter[LocalFsConditionalStore](
        LocalFsConditionalStore(root), String("tbl"), schema.copy(), uuid.copy()
    )


def _data(
    mut w: IcebergTableWriter[LocalFsConditionalStore],
    name: String,
    rows: List[List[RowCell]],
    schema: IcebergSchema,
) raises -> DataFileInfo:
    var key = w.data_dir() + "/" + name + ".parquet"
    var bytes = build_parquet_data_file(schema, rows)
    w.put_object(key, bytes.copy())
    return DataFileInfo(String(key), len(bytes), len(rows), List[ColumnBound]())


def _one(
    mut w: IcebergTableWriter[LocalFsConditionalStore], name: String, id: Int64
) raises -> List[DataFileInfo]:
    var rows = List[List[RowCell]]()
    rows.append(_row(id, String("eu")))
    var out = List[DataFileInfo]()
    out.append(_data(w, name, rows, _schema()))
    return out^


def _text(bytes: List[UInt8]) -> String:
    return String(from_utf8_lossy=Span(bytes))


def _eq_delete(
    mut w: IcebergTableWriter[LocalFsConditionalStore], name: String, id: Int64
) raises -> DataFileInfo:
    var ids = List[Int]()
    ids.append(1)
    var types = List[Int]()
    types.append(ICE_T_LONG)
    var keys = List[List[RowCell]]()
    var k = List[RowCell]()
    k.append(make_long_cell(id))
    keys.append(k^)
    var bytes = build_equality_delete_file(ids, types, keys)
    var key = w.data_dir() + "/" + name + ".avro"
    w.put_object(key, bytes.copy())
    return DataFileInfo(
        String(key), len(bytes), 1, List[ColumnBound](),
        ICE_DATA_CONTENT_EQUALITY_DELETES, ids^,
    )


def _pos_delete(
    mut w: IcebergTableWriter[LocalFsConditionalStore], name: String, path: String
) raises -> DataFileInfo:
    var entries = List[PositionDeleteEntry]()
    entries.append(PositionDeleteEntry(path.copy(), Int64(0)))
    var bytes = build_position_delete_file(entries)
    var key = w.data_dir() + "/" + name + ".avro"
    w.put_object(key, bytes.copy())
    return DataFileInfo(
        String(key), len(bytes), 1, List[ColumnBound](),
        ICE_DATA_CONTENT_POSITION_DELETES, List[Int](),
    )


def test_a_lost_version_create_is_a_conflict_and_changes_nothing() raises:
    var w = _writer(String("conflict"))
    _ = w.commit_append(_one(w, String("a"), 1))
    # Another writer created v2 first, with content of its own.
    var foreign = List[UInt8](String("{\"foreign\":true}").as_bytes())
    var key2 = metadata_json_key(w.location(), 2)
    w.put_object(key2, foreign.copy())
    var raised = False
    try:
        w._create_version(key2, 2, List[UInt8](String("{\"mine\":true}").as_bytes()))
    except e:
        raised = True
        assert_true(_has(String(e), "iceberg commit conflict"), String(e))
        assert_true(_has(String(e), "version 2"), String(e))
    assert_true(raised, "a lost create must raise")
    assert_equal(_text(w.get_object(key2)), String("{\"foreign\":true}"))


def test_a_commit_builds_on_a_version_the_hint_has_not_reached() raises:
    var tag = String("hintlag")
    var w = _writer(tag)
    var uuid = String("11111111-1111-7111-8111-111111111111")
    var r1 = w.commit_append(_one(w, String("a"), 1))
    assert_equal(r1.version, 1)
    # A writer stopped before moving the hint: put it back at 0.
    w.put_object(pointer_key(w.location()), List[UInt8](String("0").as_bytes()))
    var fresh = _reopen(tag, _schema(), uuid)
    assert_equal(read_hint_version(fresh._store, String("tbl")), 0)
    assert_equal(current_version(fresh._store, String("tbl")), 1)
    # Reads see v1 even though the hint says 0.
    assert_equal(len(fresh.read_live_rows()), 1)
    var r2 = fresh.commit_append(_one(fresh, String("b"), 2))
    assert_equal(r2.version, 2)
    assert_equal(read_hint_version(fresh._store, String("tbl")), 2)
    assert_equal(len(fresh.read_live_rows()), 2)
    # The same with no hint at all.
    fresh._store.delete(Path.parse(pointer_key(String("tbl"))))
    assert_equal(current_version(fresh._store, String("tbl")), 2)
    var r3 = fresh.commit_append(_one(fresh, String("c"), 3))
    assert_equal(r3.version, 3)
    assert_equal(read_hint_version(fresh._store, String("tbl")), 3)


def test_the_hint_swap_loses_cleanly_and_never_moves_backwards() raises:
    var w = _writer(String("swap"))
    _ = w.commit_append(_one(w, String("a"), 1))
    _ = w.commit_append(_one(w, String("b"), 2))
    assert_equal(read_hint_version(w._store, String("tbl")), 2)
    # A stale etag, and the hint already at 2 >= 2: the commit stands, untouched.
    w._advance_hint(Optional[String](String("not-the-etag")), 2)
    assert_equal(read_hint_version(w._store, String("tbl")), 2)
    # A stale etag naming a LATER version already on the hint: never moved down.
    w.put_object(pointer_key(String("tbl")), List[UInt8](String("5").as_bytes()))
    w._advance_hint(Optional[String](String("not-the-etag")), 3)
    assert_equal(read_hint_version(w._store, String("tbl")), 5)
    # A stale etag with the hint BEHIND this version: re-read, swap, move up.
    w.put_object(pointer_key(String("tbl")), List[UInt8](String("1").as_bytes()))
    w._advance_hint(Optional[String](String("not-the-etag")), 3)
    assert_equal(read_hint_version(w._store, String("tbl")), 3)
    # An absent hint is created.
    w._store.delete(Path.parse(pointer_key(String("tbl"))))
    w._advance_hint(None, 4)
    assert_equal(read_hint_version(w._store, String("tbl")), 4)


def test_carried_manifests_snapshots_and_schemas_keep_their_history() raises:
    var tag = String("history")
    var w = _writer(tag)
    var uuid = w._table_uuid.copy()
    var extra1 = List[SummaryKV]()
    extra1.append(SummaryKV(String("ingest.pos"), String("one")))
    var r1 = w.commit_with_summary(_one(w, String("a"), 1), List[DataFileInfo](), extra1)
    var extra2 = List[SummaryKV]()
    extra2.append(SummaryKV(String("ingest.pos"), String("two")))
    var r2 = w.commit_with_summary(_one(w, String("b"), 2), List[DataFileInfo](), extra2)
    # The manifest list of commit 2 lists commit 1's manifest under commit 1's
    # snapshot, commit 2's under commit 2's.
    var entries = read_manifest_list(w.get_object(r2.manifest_list_key))
    assert_equal(len(entries), 2)
    assert_equal(entries[0].added_snapshot_id, r1.snapshot_id)
    assert_equal(entries[0].sequence_number, Int64(1))
    assert_equal(entries[1].added_snapshot_id, r2.snapshot_id)
    assert_equal(entries[1].sequence_number, Int64(2))
    # The first snapshot keeps its summary in the second metadata.json.
    var meta = _text(w.get_object(r2.metadata_json_key))
    assert_true(_has(meta, '"ingest.pos":"one"'), "snapshot 1 lost its summary")
    assert_true(_has(meta, '"ingest.pos":"two"'))
    # After add-column, the earlier schema stays in `schemas` for snapshot 1.
    var evolved = evolve_add_column(_schema(), String("score"), ICE_T_DOUBLE)
    w.set_schema(evolved.copy())
    var r3 = w.commit_append(List[DataFileInfo]())
    var meta3 = _text(w.get_object(r3.metadata_json_key))
    assert_true(_has(meta3, '"schemas":[{"type":"struct","schema-id":0,'))
    assert_true(_has(meta3, '{"type":"struct","schema-id":1,'))
    assert_true(_has(meta3, '"current-schema-id":1'))
    assert_true(_has(meta3, '"schema-id":0}'), "snapshot 1 should still name schema 0")
    # And a third commit from a fresh writer keeps both.
    var fresh = _reopen(tag, evolved, uuid)
    var r4 = fresh.commit_append(List[DataFileInfo]())
    var meta4 = _text(fresh.get_object(r4.metadata_json_key))
    assert_true(_has(meta4, '"schema-id":0,'))
    assert_true(_has(meta4, '"schema-id":1,'))


def test_operation_and_delete_counters_follow_the_commit() raises:
    var w = _writer(String("ops"))
    var r1 = w.commit_append(_one(w, String("a"), 1))
    var m1 = _text(w.get_object(r1.metadata_json_key))
    assert_true(_has(m1, '"operation":"append"'))
    assert_true(_has(m1, '"added-files-size":"'))
    assert_false(_has(m1, "added-delete-files"))
    var deletes = List[DataFileInfo]()
    deletes.append(_eq_delete(w, String("d1"), 1))
    var r2 = w.commit(List[DataFileInfo](), deletes^)
    var m2 = _text(w.get_object(r2.metadata_json_key))
    assert_true(_has(m2, '"operation":"delete"'))
    assert_true(_has(m2, '"added-delete-files":"1"'))
    assert_true(_has(m2, '"added-equality-delete-files":"1"'))
    assert_true(_has(m2, '"added-position-delete-files":"0"'))
    assert_true(_has(m2, '"added-equality-deletes":"1"'))
    var d3 = List[DataFileInfo]()
    d3.append(_eq_delete(w, String("d2"), 7))
    d3.append(_pos_delete(w, String("p1"), w.data_dir() + "/a.parquet"))
    var r3 = w.commit(_one(w, String("b"), 2), d3^)
    var m3 = _text(w.get_object(r3.metadata_json_key))
    assert_true(_has(m3, '"operation":"overwrite"'))
    assert_true(_has(m3, '"added-delete-files":"2"'))
    assert_true(_has(m3, '"added-position-deletes":"1"'))
    # Earlier snapshots keep their own operation.
    assert_true(_has(m3, '"operation":"append"'))
    assert_true(_has(m3, '"operation":"delete"'))


def test_refusals() raises:
    var w = _writer(String("refuse"))
    var bad = List[SummaryKV]()
    bad.append(SummaryKV(String("total-records"), String("999")))
    with assert_raises():
        _ = w.commit_with_summary(_one(w, String("a"), 1), List[DataFileInfo](), bad)
    # Nothing was written by the refused commit.
    assert_equal(current_version(w._store, String("tbl")), 0)
    # A table keeps its partition spec.
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("region"))
    _ = w.commit_with_spec(_one(w, String("b"), 2), List[DataFileInfo](), spec.copy())
    with assert_raises():
        _ = w.commit_append(_one(w, String("c"), 3))
    var other = PartitionSpec(0)
    other.add_bucket(1, 4, String("id_bucket"))
    with assert_raises():
        _ = w.commit_with_spec(_one(w, String("d"), 4), List[DataFileInfo](), other^)
    # An equality delete on a nullable key.
    var sch = IcebergSchema(0)
    sch.add(String("id"), ICE_T_LONG, required=False)
    sch.add(String("region"), ICE_T_STRING, required=True)
    var w2 = IcebergTableWriter[LocalFsConditionalStore](
        LocalFsConditionalStore(_scratch_dir() + String("/commit_nullable")),
        String("tbl"), sch^, gen_table_uuid(),
    )
    var d = List[DataFileInfo]()
    d.append(_eq_delete(w2, String("d"), 1))
    with assert_raises():
        _ = w2.commit(List[DataFileInfo](), d^)
    # A delete whose field id is not in the schema.
    var bogus_ids = List[Int]()
    bogus_ids.append(77)
    var bd = List[DataFileInfo]()
    bd.append(
        DataFileInfo(
            String("tbl/data/x.avro"), 1, 1, List[ColumnBound](),
            ICE_DATA_CONTENT_EQUALITY_DELETES, bogus_ids^,
        )
    )
    with assert_raises():
        _ = w.commit(List[DataFileInfo](), bd^)


def test_a_partitioned_table_with_deletes_names_the_delete_spec() raises:
    var w = _writer(String("pdel"))
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("region"))
    var types = partition_value_type_tags(spec, _schema())
    var rows = List[List[RowCell]]()
    rows.append(_row(1, String("eu")))
    rows.append(_row(2, String("eu")))
    var info = _data(w, String("a"), rows, _schema())
    var pv = partition_value_of(spec, _schema(), rows[0])
    var files = List[DataFileInfo]()
    files.append(info^.with_partition(encode_partition_values(pv), types.copy()))
    _ = w.commit_with_spec(files^, List[DataFileInfo](), spec.copy())
    var dels = List[DataFileInfo]()
    dels.append(_eq_delete(w, String("d"), 2))
    var r2 = w.commit_with_spec(List[DataFileInfo](), dels^, spec.copy())
    var entries = read_manifest_list(w.get_object(r2.manifest_list_key))
    assert_equal(len(entries), 2)
    assert_equal(entries[0].content, ICE_MANIFEST_CONTENT_DATA)
    assert_equal(entries[0].partition_spec_id, 0)
    assert_equal(entries[1].content, ICE_MANIFEST_CONTENT_DELETES)
    assert_equal(entries[1].partition_spec_id, 1)
    var meta = _text(w.get_object(r2.metadata_json_key))
    assert_true(_has(meta, '"default-spec-id":0'))
    assert_true(_has(meta, '{"spec-id":1,"fields":[]}'))
    # The delete is global: it masks the row in the partition, and the other
    # row survives.
    var live = w.read_live_rows()
    assert_equal(len(live), 1)
    assert_equal(live[0][0].as_long(), Int64(1))


def test_ids_are_unique_and_well_formed() raises:
    var a = gen_table_uuid()
    var b = gen_table_uuid()
    assert_equal(a.byte_length(), 36)
    assert_true(a != b)
    var bs = a.as_bytes()
    assert_equal(bs[8], UInt8(ord("-")))
    assert_equal(bs[13], UInt8(ord("-")))
    assert_equal(bs[14], UInt8(ord("7")))  # UUIDv7
    var s1 = gen_snapshot_id()
    var s2 = gen_snapshot_id()
    assert_true(s1 > Int64(0))
    assert_true(s2 > Int64(0))
    assert_true(s1 != s2)


def main() raises:
    test_a_lost_version_create_is_a_conflict_and_changes_nothing()
    test_a_commit_builds_on_a_version_the_hint_has_not_reached()
    test_the_hint_swap_loses_cleanly_and_never_moves_backwards()
    test_carried_manifests_snapshots_and_schemas_keep_their_history()
    test_operation_and_delete_counters_follow_the_commit()
    test_refusals()
    test_a_partitioned_table_with_deletes_names_the_delete_spec()
    test_ids_are_unique_and_well_formed()
    print("test_iceberg_writer_commit: all passed")
