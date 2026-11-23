# =============================================================================
# test_iceberg_store_writer.mojo — StoreSnapshotWriter: one statement's
#   manifest, written once, and its manifest list for each attempt.
# =============================================================================
#
#   * test_the_first_attempt_writes_the_manifest_and_a_list_naming_it: the file
#     names, the manifest's ADDED entries, and the list's one entry (path,
#     size, counts, the commit's sequence number, the statement's snapshot).
#   * test_a_second_attempt_writes_a_new_list_and_no_new_manifest: a retry
#     writes one more object, the manifest bytes are the same, and the new
#     list carries the new sequence number.
#   * test_an_append_lists_the_base_manifests_then_the_new_one: the base's
#     entries come first, unchanged, then the statement's manifest.
#   * test_an_overwrite_lists_only_its_own_manifest: the base's manifests
#     are left out.
#   * test_a_statement_with_no_files_writes_no_manifest: an overwrite lists
#     nothing; an append lists the base's manifests alone.
#   * test_a_base_list_another_writer_wrote_is_refused_for_an_append: the exact
#     ICEBERG_MANIFEST_LIST_UNSUPPORTED message, and nothing is written; an
#     overwrite over the same base succeeds.
#   * test_a_main_snapshot_the_metadata_does_not_list_is_refused: the exact
#     ICEBERG_CATALOG_RESPONSE_INVALID message.
#   * test_a_base_list_the_store_cannot_serve_is_an_error: a missing object
#     raises the store's error; a list outside the store's prefix is
#     ICEBERG_LOCATION_REFUSED.
#   * test_a_metadata_path_outside_the_store_is_refused: nothing is recorded as
#     written.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from iceberg import (
    ICE_SEQ_INHERIT,
    ICE_STATUS_ADDED,
    ColumnBound,
    DataFileInfo,
    ManifestFileEntry,
    build_manifest_list,
    read_manifest_entries,
    read_manifest_list,
)
from objectstore.path import Path
from objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from iceberg_catalog.iceberg_store_writer import StoreSnapshotWriter
from iceberg_catalog.iceberg_table_files import TableFiles
from iceberg_catalog.iceberg_table_metadata import TableMetadata, TableSnapshot


comptime _Files = TableFiles[SharedInMemoryConditionalStore]
comptime _Writer = StoreSnapshotWriter[SharedInMemoryConditionalStore]

comptime _UUID: String = "00000000-0000-7000-8000-000000000001"
comptime _META: String = "s3://wh/db/t/metadata"
comptime _SCHEMA: String = (
    '{"type":"struct","schema-id":3,"fields":[{"id":1,"name":"id",'
    '"required":true,"type":"long"}]}'
)
comptime _MANIFEST: String = "s3://wh/db/t/metadata/00000000-0000-7000-8000-000000000001-m0.avro"


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _file(path: String, rows: Int, size: Int) -> DataFileInfo:
    var bounds = List[ColumnBound]()
    bounds.append(ColumnBound(1, None, None, 0, rows))
    return DataFileInfo(path, size, rows, bounds^)


def _two_files() -> List[DataFileInfo]:
    var files = List[DataFileInfo]()
    files.append(_file(String("s3://wh/db/t/data/u-0.parquet"), 3, 100))
    files.append(_file(String("s3://wh/db/t/data/u-1.parquet"), 4, 200))
    return files^


def _writer(
    store: SharedInMemoryConditionalStore,
    overwrite: Bool,
    var infos: List[DataFileInfo],
) -> _Writer:
    return _Writer(
        _Files(store.clone(), String("s3://wh")),
        String(_UUID),
        overwrite,
        infos^,
        String(_SCHEMA),
        3,
        String(_META),
    )


def _key(uri: String) raises -> Path:
    """The key of a `s3://wh/...` URI."""
    return Path.parse(String(uri[byte=8 : uri.byte_length()]))


def _stored(store: SharedInMemoryConditionalStore, uri: String) raises -> List[UInt8]:
    return store.get(_key(uri))


def _object_count(store: SharedInMemoryConditionalStore) raises -> Int:
    var listed = store.list_with_delimiter(Path.parse(String("")))
    return len(listed.objects)


def _list_uri(snapshot_id: Int64, attempt: Int) -> String:
    return (
        String(_META)
        + String("/snap-")
        + String(snapshot_id)
        + String("-")
        + String(attempt)
        + String("-")
        + String(_UUID)
        + String(".avro")
    )


def _empty_base() -> TableMetadata:
    return TableMetadata()


def _prior_entries() -> List[ManifestFileEntry]:
    """Two manifests an earlier writer's list holds, each with its own
    sequence number and the snapshot that added it."""
    var out = List[ManifestFileEntry]()
    out.append(
        ManifestFileEntry(
            String("s3://wh/db/t/metadata/old-a.avro"),
            1111,
            2,
            Int64(20),
            0,
            Int64(1),
            Int64(11),
            0,
        )
    )
    out.append(
        ManifestFileEntry(
            String("s3://wh/db/t/metadata/old-b.avro"),
            2222,
            1,
            Int64(5),
            0,
            Int64(2),
            Int64(12),
            0,
        )
    )
    return out^


def _base_with_list(
    store: SharedInMemoryConditionalStore, list_uri: String, list_bytes: List[UInt8]
) raises -> TableMetadata:
    """A base whose `main` is snapshot 12, listed at `list_uri` holding
    `list_bytes` in the store."""
    _ = store.put(_key(list_uri), list_bytes)
    var base = TableMetadata()
    base.snapshots.append(
        TableSnapshot(
            12,
            None,
            2,
            1795132800000,
            String(list_uri),
            List[String](),
            List[String](),
        )
    )
    base.main_snapshot_id = Optional[Int64](12)
    base.last_sequence_number = 2
    return base^


def _komira_base(store: SharedInMemoryConditionalStore) raises -> TableMetadata:
    return _base_with_list(
        store,
        String("s3://wh/db/t/metadata/snap-12-0-prior.avro"),
        build_manifest_list(Int64(12), Int64(2), _prior_entries()),
    )


def _write_error(mut writer: _Writer, base: TableMetadata) -> String:
    try:
        _ = writer.write_manifest_list(7001, 0, base, 3)
    except e:
        return String(e)
    return String("")


def test_the_first_attempt_writes_the_manifest_and_a_list_naming_it() raises:
    var store = SharedInMemoryConditionalStore()
    var writer = _writer(store, False, _two_files())

    var uri = writer.write_manifest_list(7001, 0, _empty_base(), 1)

    assert_equal(uri, _list_uri(7001, 0))
    assert_equal(writer.manifest_uri, String(_MANIFEST))
    assert_equal(len(writer.written), 2)
    assert_equal(writer.written[0], String(_MANIFEST))
    assert_equal(writer.written[1], uri)
    assert_equal(_object_count(store), 2)

    var manifest = _stored(store, _MANIFEST)
    var entries = read_manifest_entries(manifest)
    assert_equal(len(entries), 2)
    assert_equal(entries[0].file_path, String("s3://wh/db/t/data/u-0.parquet"))
    assert_equal(entries[0].record_count, 3)
    assert_equal(entries[0].file_size_in_bytes, 100)
    assert_equal(entries[0].status, ICE_STATUS_ADDED)
    assert_equal(entries[1].file_path, String("s3://wh/db/t/data/u-1.parquet"))
    assert_equal(entries[1].record_count, 4)

    var listed = read_manifest_list(_stored(store, uri))
    assert_equal(len(listed), 1)
    assert_equal(listed[0].manifest_path, String(_MANIFEST))
    assert_equal(listed[0].manifest_length, len(manifest))
    assert_equal(listed[0].added_files_count, 2)
    assert_equal(listed[0].added_rows_count, 7)
    assert_equal(listed[0].content, 0)
    assert_equal(listed[0].sequence_number, 1)
    assert_equal(listed[0].added_snapshot_id, 7001)
    assert_equal(listed[0].partition_spec_id, 0)


def test_a_second_attempt_writes_a_new_list_and_no_new_manifest() raises:
    var store = SharedInMemoryConditionalStore()
    var writer = _writer(store, False, _two_files())
    var first = writer.write_manifest_list(7001, 0, _empty_base(), 1)
    var manifest = _stored(store, _MANIFEST)
    assert_equal(store.n_put(), 2)

    var second = writer.write_manifest_list(7001, 1, _empty_base(), 4)

    assert_equal(second, _list_uri(7001, 1))
    assert_true(first != second)
    assert_equal(store.n_put(), 3)
    assert_equal(_object_count(store), 3)
    assert_true(_stored(store, _MANIFEST) == manifest)
    assert_equal(len(writer.written), 3)
    assert_equal(writer.written[2], second)
    var listed = read_manifest_list(_stored(store, second))
    assert_equal(len(listed), 1)
    assert_equal(listed[0].manifest_path, String(_MANIFEST))
    assert_equal(listed[0].sequence_number, 4)
    assert_equal(listed[0].added_snapshot_id, 7001)


def test_an_append_lists_the_base_manifests_then_the_new_one() raises:
    var store = SharedInMemoryConditionalStore()
    var base = _komira_base(store)
    var writer = _writer(store, False, _two_files())

    var uri = writer.write_manifest_list(7001, 0, base, 3)

    var listed = read_manifest_list(_stored(store, uri))
    assert_equal(len(listed), 3)
    assert_equal(listed[0].manifest_path, String("s3://wh/db/t/metadata/old-a.avro"))
    assert_equal(listed[0].manifest_length, 1111)
    assert_equal(listed[0].added_files_count, 2)
    assert_equal(listed[0].added_rows_count, 20)
    assert_equal(listed[0].sequence_number, 1)
    assert_equal(listed[0].added_snapshot_id, 11)
    assert_equal(listed[1].manifest_path, String("s3://wh/db/t/metadata/old-b.avro"))
    assert_equal(listed[1].sequence_number, 2)
    assert_equal(listed[1].added_snapshot_id, 12)
    assert_equal(listed[2].manifest_path, String(_MANIFEST))
    assert_equal(listed[2].sequence_number, 3)
    assert_equal(listed[2].added_snapshot_id, 7001)


def test_an_overwrite_lists_only_its_own_manifest() raises:
    var store = SharedInMemoryConditionalStore()
    var base = _komira_base(store)
    var writer = _writer(store, True, _two_files())

    var uri = writer.write_manifest_list(7001, 0, base, 3)

    var listed = read_manifest_list(_stored(store, uri))
    assert_equal(len(listed), 1)
    assert_equal(listed[0].manifest_path, String(_MANIFEST))
    assert_equal(listed[0].sequence_number, 3)
    assert_equal(listed[0].added_snapshot_id, 7001)


def test_a_statement_with_no_files_writes_no_manifest() raises:
    var store = SharedInMemoryConditionalStore()
    var base = _komira_base(store)
    var overwrite = _writer(store, True, List[DataFileInfo]())
    var emptied = overwrite.write_manifest_list(7001, 0, base, 3)
    assert_equal(len(read_manifest_list(_stored(store, emptied))), 0)
    assert_equal(overwrite.manifest_uri, String(""))
    assert_equal(len(overwrite.written), 1)
    assert_equal(overwrite.written[0], emptied)

    var append = _writer(store, False, List[DataFileInfo]())
    var carried = append.write_manifest_list(7002, 0, base, 3)
    var listed = read_manifest_list(_stored(store, carried))
    assert_equal(len(listed), 2)
    assert_equal(listed[1].manifest_path, String("s3://wh/db/t/metadata/old-b.avro"))
    assert_equal(append.manifest_uri, String(""))

    var fresh = _writer(store, False, List[DataFileInfo]())
    var none = fresh.write_manifest_list(7003, 0, _empty_base(), 1)
    assert_equal(len(read_manifest_list(_stored(store, none))), 0)


def test_a_base_list_another_writer_wrote_is_refused_for_an_append() raises:
    var store = SharedInMemoryConditionalStore()
    var foreign = String("s3://wh/db/t/metadata/foreign.avro")
    var base = _base_with_list(store, foreign, _bytes(String("not an avro file")))
    var before = _object_count(store)

    var append = _writer(store, False, _two_files())
    assert_equal(
        _write_error(append, base),
        String(
            "ICEBERG_MANIFEST_LIST_UNSUPPORTED: manifest list "
            "s3://wh/db/t/metadata/foreign.avro of snapshot 12 was not written"
            " by komira; this write appends only to manifest lists it wrote"
        ),
    )
    assert_equal(_object_count(store), before)
    assert_equal(len(append.written), 0)
    assert_equal(append.manifest_uri, String(""))

    var overwrite = _writer(store, True, _two_files())
    var uri = overwrite.write_manifest_list(7001, 0, base, 3)
    assert_equal(len(read_manifest_list(_stored(store, uri))), 1)


def test_a_main_snapshot_the_metadata_does_not_list_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var base = TableMetadata()
    base.main_snapshot_id = Optional[Int64](99)
    var writer = _writer(store, False, _two_files())
    assert_equal(
        _write_error(writer, base),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: table metadata names main"
            " snapshot 99 but does not list it"
        ),
    )
    assert_equal(_object_count(store), 0)


def test_a_base_list_the_store_cannot_serve_is_an_error() raises:
    var store = SharedInMemoryConditionalStore()
    var base = TableMetadata()
    base.snapshots.append(
        TableSnapshot(
            12,
            None,
            2,
            1,
            String("s3://wh/db/t/metadata/missing.avro"),
            List[String](),
            List[String](),
        )
    )
    base.main_snapshot_id = Optional[Int64](12)
    var writer = _writer(store, False, _two_files())
    assert_true(_write_error(writer, base).find(String("not_found")) >= 0)
    assert_equal(_object_count(store), 0)

    var outside = TableMetadata()
    outside.snapshots.append(
        TableSnapshot(
            12,
            None,
            2,
            1,
            String("s3://other/x.avro"),
            List[String](),
            List[String](),
        )
    )
    outside.main_snapshot_id = Optional[Int64](12)
    assert_equal(
        _write_error(writer, outside),
        String(
            "ICEBERG_LOCATION_REFUSED: s3://other/x.avro is not under"
            " s3://wh, the store this write was given"
        ),
    )


def test_a_metadata_path_outside_the_store_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var writer = _Writer(
        _Files(store.clone(), String("s3://wh")),
        String(_UUID),
        False,
        _two_files(),
        String(_SCHEMA),
        3,
        String("s3://other/metadata"),
    )
    assert_equal(
        _write_error(writer, _empty_base()),
        String(
            "ICEBERG_LOCATION_REFUSED: s3://other/metadata/"
            "00000000-0000-7000-8000-000000000001-m0.avro is not under"
            " s3://wh, the store this write was given"
        ),
    )
    assert_equal(len(writer.written), 0)
    assert_equal(writer.manifest_uri, String(""))
    assert_equal(_object_count(store), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
