# =============================================================================
# test_iceberg_reader.mojo — merge-on-read over hand-assembled tables.
# =============================================================================
#
# Each table is assembled from the package's own builders (Parquet data files,
# Avro delete files, manifests, manifest list, metadata.json) and put into an
# in-memory store, so the reader is tested apart from the table writer.
#
# What each test proves (and the defect it catches):
#   1. With no deletes every row comes back, in file order, across several data
#      files and manifests.
#   2. An equality delete masks rows whose key columns match, only for data
#      files with a STRICTLY LOWER sequence number: an equal or lower delete
#      sequence masks nothing, and a row re-inserted after the delete survives.
#   3. A composite equality key masks only rows matching every key column.
#   4. A position delete masks (file path, position) exactly, only when the
#      delete's sequence number is >= the data file's; another path or a lower
#      sequence masks nothing.
#   5. A partitioned table reads: the partition record of each entry is
#      consumed byte-aligned, and the partition values decode.
#   6. IcebergTableReader returns what read_live_rows_from returns.
#   7. A pointer that is not a number is refused.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_raises

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.path import Path

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    ICE_DATA_CONTENT_DATA,
    ICE_DATA_CONTENT_POSITION_DELETES,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    ICE_MANIFEST_CONTENT_DATA,
    ICE_MANIFEST_CONTENT_DELETES,
    IcebergSchema,
    DataFileInfo,
    ColumnBound,
    PartitionSpec,
    ManifestFileEntry,
    SnapshotInfo,
    RowCell,
    make_long_cell,
    make_string_cell,
    PositionDeleteEntry,
    schema_json,
    partition_value_of,
    partition_value_type_tags,
    encode_partition_values,
    build_manifest_file,
    build_manifest_list,
    build_table_metadata_json,
    build_parquet_data_file,
    build_equality_delete_file,
    build_position_delete_file,
    read_partition_values_from_manifest,
    IcebergTableReader,
)
from komira_iceberg.iceberg_reader import read_live_rows_from

comptime _LOC: String = "warehouse/orders"


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


def _bytes(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _put(mut store: InMemoryConditionalStore, key: String, bytes: List[UInt8]) raises:
    _ = store.put(Path.parse(key), bytes)


struct _Table(Movable):
    """One table's files, collected then published as ONE snapshot."""

    var store: InMemoryConditionalStore
    var data: List[DataFileInfo]
    var deletes: List[DataFileInfo]
    var spec: PartitionSpec
    var n: Int

    def __init__(out self, var spec: PartitionSpec = PartitionSpec(0)):
        self.store = InMemoryConditionalStore()
        self.data = List[DataFileInfo]()
        self.deletes = List[DataFileInfo]()
        self.spec = spec^
        self.n = 0

    def add_data(
        mut self, rows: List[List[RowCell]], seq: Int64, partition: Bool = False
    ) raises -> String:
        var path = String(_LOC) + "/data/d" + String(self.n) + ".parquet"
        self.n += 1
        var bytes = build_parquet_data_file(_schema(), rows)
        _put(self.store, path, bytes)
        var info = DataFileInfo(
            path.copy(), len(bytes), len(rows), List[ColumnBound](),
            ICE_DATA_CONTENT_DATA, List[Int](), seq,
        )
        if partition:
            var pv = partition_value_of(self.spec, _schema(), rows[0])
            info = info^.with_partition(
                encode_partition_values(pv),
                partition_value_type_tags(self.spec, _schema()),
            )
        self.data.append(info^)
        return path^

    def add_equality_delete(
        mut self, ids: List[Int], types: List[Int], keys: List[List[RowCell]], seq: Int64
    ) raises:
        var path = String(_LOC) + "/data/del" + String(self.n) + ".avro"
        self.n += 1
        var bytes = build_equality_delete_file(ids, types, keys)
        _put(self.store, path, bytes)
        self.deletes.append(
            DataFileInfo(
                path^, len(bytes), len(keys), List[ColumnBound](),
                ICE_DATA_CONTENT_EQUALITY_DELETES, ids.copy(), seq,
            )
        )

    def add_position_delete(
        mut self, entries: List[PositionDeleteEntry], seq: Int64
    ) raises:
        var path = String(_LOC) + "/data/pos" + String(self.n) + ".avro"
        self.n += 1
        var bytes = build_position_delete_file(entries)
        _put(self.store, path, bytes)
        self.deletes.append(
            DataFileInfo(
                path^, len(bytes), len(entries), List[ColumnBound](),
                ICE_DATA_CONTENT_POSITION_DELETES, List[Int](), seq,
            )
        )

    def publish(mut self, top_seq: Int64) raises:
        var schema = _schema()
        var sj = schema_json(schema)
        var manifests = List[ManifestFileEntry]()
        var rows = Int64(0)
        for i in range(len(self.data)):
            rows += Int64(self.data[i].record_count)
        var dm = build_manifest_file(
            schema, sj, Int64(1), top_seq, self.data, ICE_MANIFEST_CONTENT_DATA, self.spec,
        )
        _put(self.store, String(_LOC) + "/metadata/m-data.avro", dm)
        manifests.append(
            ManifestFileEntry(
                String(_LOC) + "/metadata/m-data.avro", len(dm), len(self.data), rows,
                ICE_MANIFEST_CONTENT_DATA, top_seq, Int64(1), self.spec.spec_id,
            )
        )
        if len(self.deletes) > 0:
            var xm = build_manifest_file(
                schema, sj, Int64(1), top_seq, self.deletes, ICE_MANIFEST_CONTENT_DELETES,
            )
            _put(self.store, String(_LOC) + "/metadata/m-del.avro", xm)
            manifests.append(
                ManifestFileEntry(
                    String(_LOC) + "/metadata/m-del.avro", len(xm), len(self.deletes),
                    Int64(0), ICE_MANIFEST_CONTENT_DELETES, top_seq, Int64(1), 0,
                )
            )
        var ml = build_manifest_list(Int64(1), top_seq, manifests)
        _put(self.store, String(_LOC) + "/metadata/snap-1.avro", ml)
        var snaps = List[SnapshotInfo]()
        snaps.append(
            SnapshotInfo(
                Int64(1), top_seq, Int64(1788220800000),
                String(_LOC) + "/metadata/snap-1.avro", len(self.data), rows,
                len(self.data), rows, 0, Int64(-1),
            )
        )
        var md = build_table_metadata_json(
            String("00000000-0000-4000-8000-000000000009"), String(_LOC), schema, snaps,
            Int64(1), top_seq, Int64(1788220800000), self.spec,
        )
        _put(self.store, String(_LOC) + "/metadata/v1.metadata.json", _bytes(md))
        _put(self.store, String(_LOC) + "/metadata/version-hint.text", _bytes(String("1")))

    def read(mut self) raises -> List[List[RowCell]]:
        return read_live_rows_from(self.store, String(_LOC), _schema())

    def into_reader(deinit self) -> IcebergTableReader[InMemoryConditionalStore]:
        return IcebergTableReader(self.store^, String(_LOC), _schema())


def _ids(rows: List[List[RowCell]]) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(rows)):
        out.append(rows[i][0].as_long())
    return out^


def _expect(rows: List[List[RowCell]], expected: List[Int64]) raises:
    var got = _ids(rows)
    assert_equal(len(got), len(expected), "row count")
    for i in range(len(got)):
        assert_equal(got[i], expected[i], "row " + String(i))


def _id_key(id: Int64) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    return r^


def _eq_ids() -> List[Int]:
    var ids = List[Int]()
    ids.append(1)
    return ids^


def _eq_types() -> List[Int]:
    var t = List[Int]()
    t.append(ICE_T_LONG)
    return t^


def test_no_deletes_reads_every_row_in_file_order() raises:
    var t = _Table()
    var a = List[List[RowCell]]()
    a.append(_row(3, String("eu")))
    a.append(_row(1, String("us")))
    var b = List[List[RowCell]]()
    b.append(_row(2, String("eu")))
    _ = t.add_data(a, Int64(1))
    _ = t.add_data(b, Int64(1))
    t.publish(Int64(1))
    _expect(t.read(), [3, 1, 2])


def test_equality_delete_masks_only_strictly_lower_sequences() raises:
    var t = _Table()
    var a = List[List[RowCell]]()
    a.append(_row(1, String("eu")))
    a.append(_row(2, String("eu")))
    a.append(_row(3, String("eu")))
    _ = t.add_data(a, Int64(1))
    var keys = List[List[RowCell]]()
    keys.append(_id_key(2))
    t.add_equality_delete(_eq_ids(), _eq_types(), keys, Int64(2))
    t.publish(Int64(2))
    _expect(t.read(), [1, 3])

    # Same sequence as the data: the delete is NOT strictly greater.
    var same = _Table()
    _ = same.add_data(a, Int64(2))
    same.add_equality_delete(_eq_ids(), _eq_types(), keys, Int64(2))
    same.publish(Int64(2))
    _expect(same.read(), [1, 2, 3])

    # A delete older than the data masks nothing.
    var older = _Table()
    _ = older.add_data(a, Int64(3))
    older.add_equality_delete(_eq_ids(), _eq_types(), keys, Int64(2))
    older.publish(Int64(3))
    _expect(older.read(), [1, 2, 3])


def test_a_reinserted_key_survives_the_earlier_delete() raises:
    var t = _Table()
    var first = List[List[RowCell]]()
    first.append(_row(2, String("old")))
    _ = t.add_data(first, Int64(1))
    var keys = List[List[RowCell]]()
    keys.append(_id_key(2))
    t.add_equality_delete(_eq_ids(), _eq_types(), keys, Int64(2))
    var again = List[List[RowCell]]()
    again.append(_row(2, String("new")))
    _ = t.add_data(again, Int64(3))
    t.publish(Int64(3))
    var rows = t.read()
    assert_equal(len(rows), 1)
    assert_equal(rows[0][1].as_string(), String("new"))


def test_a_composite_key_needs_every_column_to_match() raises:
    var t = _Table()
    var a = List[List[RowCell]]()
    a.append(_row(1, String("eu")))
    a.append(_row(1, String("us")))
    a.append(_row(2, String("eu")))
    _ = t.add_data(a, Int64(1))
    var ids = List[Int]()
    ids.append(1)
    ids.append(2)
    var types = List[Int]()
    types.append(ICE_T_LONG)
    types.append(ICE_T_STRING)
    var keys = List[List[RowCell]]()
    keys.append(_row(1, String("us")))
    t.add_equality_delete(ids, types, keys, Int64(2))
    t.publish(Int64(2))
    var rows = t.read()
    assert_equal(len(rows), 2)
    assert_equal(rows[0][1].as_string(), String("eu"))
    assert_equal(rows[1][0].as_long(), Int64(2))


def test_position_delete_masks_path_and_position_exactly() raises:
    var t = _Table()
    var a = List[List[RowCell]]()
    a.append(_row(10, String("eu")))
    a.append(_row(11, String("eu")))
    a.append(_row(12, String("eu")))
    var path_a = t.add_data(a, Int64(1))
    var b = List[List[RowCell]]()
    b.append(_row(20, String("eu")))
    b.append(_row(21, String("eu")))
    _ = t.add_data(b, Int64(1))
    var entries = List[PositionDeleteEntry]()
    entries.append(PositionDeleteEntry(path_a.copy(), Int64(1)))
    # Position 0 of a path that is not a data file here: masks nothing.
    entries.append(PositionDeleteEntry(String(_LOC) + "/data/other.parquet", Int64(0)))
    t.add_position_delete(entries, Int64(1))
    t.publish(Int64(1))
    # (path_a, 1) is gone; b's rows at the same positions are untouched.
    _expect(t.read(), [10, 12, 20, 21])


def test_position_delete_sequence_gates_on_greater_or_equal() raises:
    var rows = List[List[RowCell]]()
    rows.append(_row(1, String("eu")))
    rows.append(_row(2, String("eu")))
    # Delete sequence equal to the data's: masks (>=).
    var eq = _Table()
    var p1 = eq.add_data(rows, Int64(2))
    var e1 = List[PositionDeleteEntry]()
    e1.append(PositionDeleteEntry(p1^, Int64(0)))
    eq.add_position_delete(e1, Int64(2))
    eq.publish(Int64(2))
    _expect(eq.read(), [2])
    # Delete sequence below the data's (a stale delete at the same path and
    # position): masks nothing.
    var stale = _Table()
    var p2 = stale.add_data(rows, Int64(3))
    var e2 = List[PositionDeleteEntry]()
    e2.append(PositionDeleteEntry(p2^, Int64(0)))
    stale.add_position_delete(e2, Int64(2))
    stale.publish(Int64(3))
    _expect(stale.read(), [1, 2])


def test_a_partitioned_table_reads_and_its_partition_values_decode() raises:
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("region"))
    var t = _Table(spec^)
    var eu = List[List[RowCell]]()
    eu.append(_row(1, String("eu")))
    eu.append(_row(2, String("eu")))
    var us = List[List[RowCell]]()
    us.append(_row(3, String("us")))
    _ = t.add_data(eu, Int64(1), True)
    _ = t.add_data(us, Int64(1), True)
    var keys = List[List[RowCell]]()
    keys.append(_id_key(2))
    t.add_equality_delete(_eq_ids(), _eq_types(), keys, Int64(2))
    t.publish(Int64(2))
    _expect(t.read(), [1, 3])
    var manifest = t.store.get(Path.parse(String(_LOC) + "/metadata/m-data.avro"))
    var pv = read_partition_values_from_manifest(manifest, t.spec, _schema())
    assert_equal(len(pv), 2)
    assert_equal(pv[0][0].as_string(), String("eu"))
    assert_equal(pv[1][0].as_string(), String("us"))
    # A delete-only manifest has no data entries.
    var del_manifest = t.store.get(Path.parse(String(_LOC) + "/metadata/m-del.avro"))
    assert_equal(len(read_partition_values_from_manifest(del_manifest, PartitionSpec(0), _schema())), 0)


def test_the_reader_struct_matches_the_free_function() raises:
    var t = _Table()
    var a = List[List[RowCell]]()
    a.append(_row(5, String("eu")))
    a.append(_row(6, String("eu")))
    _ = t.add_data(a, Int64(1))
    var keys = List[List[RowCell]]()
    keys.append(_id_key(5))
    t.add_equality_delete(_eq_ids(), _eq_types(), keys, Int64(2))
    t.publish(Int64(2))
    var reader = t^.into_reader()
    _expect(reader.read_live_rows(), [6])


def test_an_equality_delete_listing_no_ids_is_refused() raises:
    var t = _Table()
    var a = List[List[RowCell]]()
    a.append(_row(1, String("eu")))
    _ = t.add_data(a, Int64(1))
    var keys = List[List[RowCell]]()
    keys.append(_id_key(1))
    var bytes = build_equality_delete_file(_eq_ids(), _eq_types(), keys)
    var path = String(_LOC) + "/data/noids.avro"
    _put(t.store, path, bytes)
    # A v2 equality delete with no equality ids: read as an empty key it would
    # match, and delete, every older row.
    t.deletes.append(
        DataFileInfo(
            path^, len(bytes), 1, List[ColumnBound](),
            ICE_DATA_CONTENT_EQUALITY_DELETES, List[Int](), Int64(2),
        )
    )
    t.publish(Int64(2))
    with assert_raises():
        _ = t.read()


def test_a_corrupt_pointer_and_a_missing_table_are_refused() raises:
    var store = InMemoryConditionalStore()
    with assert_raises():
        _ = read_live_rows_from(store, String(_LOC), _schema())
    _put(store, String(_LOC) + "/metadata/version-hint.text", _bytes(String("abc")))
    with assert_raises():
        _ = read_live_rows_from(store, String(_LOC), _schema())


def main() raises:
    test_no_deletes_reads_every_row_in_file_order()
    test_equality_delete_masks_only_strictly_lower_sequences()
    test_a_reinserted_key_survives_the_earlier_delete()
    test_a_composite_key_needs_every_column_to_match()
    test_position_delete_masks_path_and_position_exactly()
    test_position_delete_sequence_gates_on_greater_or_equal()
    test_a_partitioned_table_reads_and_its_partition_values_decode()
    test_the_reader_struct_matches_the_free_function()
    test_an_equality_delete_listing_no_ids_is_refused()
    test_a_corrupt_pointer_and_a_missing_table_are_refused()
    print("test_iceberg_reader: all passed")
