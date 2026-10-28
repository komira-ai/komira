# =============================================================================
# test_snapshot_store.mojo -- base snapshots on the lineage store: write, read
#   back, history, refusals and the fingerprints that share the store (an
#   in-memory conditional-write store; no network, no clock).
# =============================================================================
#
#   read back     a written base opens with its tables in the order given, their
#                 row counts, schema versions and the graph's embedding
#                 dimension; each table's object is byte for byte what an
#                 independent Parquet serialization of the same rows is, and
#                 decodes to the rows that went in.
#   addressing    an object's key is <prefix>/objects/<hash of its bytes>.parquet,
#                 so the same rows written twice are one key.
#   history       ids run 0, 1, 2 without a gap; the latest snapshot is the
#                 newest, and an older one still opens and still reads its own
#                 bytes.
#   empty         a lineage nothing was written to has no latest id, is not a
#                 chain, and every open or resolve of it is an error.
#   refusals      no tables, a table named twice, a negative schema version and a
#                 non-positive embedding dimension are each refused and leave the
#                 store with no object and no chunk; a prefix that is empty or
#                 ends in a slash, and fewer than one head attempt, are refused
#                 at construction; a negative snapshot id and a chunk that is
#                 not a base are refused on read.
#   version gate  assert_table_readable accepts a table stamped at or below the
#                 reader's version and refuses a higher one and a missing table.
#   handles       a second handle on the same store sees the first handle's
#                 latest snapshot; two prefixes on one store are independent.
#   fingerprints  the fingerprint lineage on the same store saves, looks up and
#                 patches one key without touching the others or the snapshot
#                 ids.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_collections.slab import Slab
from komira_kg_format import (
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    SourceFingerprintSet,
    fnv1a64_hex,
)
from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet_api.types import CompressionCodec
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)


comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    # SAFETY: the view borrows `data`'s buffer under the origin `o`, so the
    # list it came from outlives every use of the view in this file.
    return ByteView[o](data.unsafe_ptr(), len(data))


def _read_parquet(file: List[UInt8]) raises -> RecordBatch:
    """TEST SUPPORT: decode a one-row-group in-memory Parquet file with the
    reader (a separate implementation from the writer under test)."""
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    var md = parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))
    assert_equal(len(md.row_groups), 1)
    ref rg = md.row_groups[0]
    var br = row_group_byte_range(rg)
    return decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.all(),
    )


def _batch(first_id: Int, n: Int, tag: String = "n") raises -> RecordBatch:
    """n rows of (id: INT64, name: STRING): ids first_id.., names tag-<id>."""
    var ids = List[Int64](capacity=n)
    var names = List[String](capacity=n)
    for i in range(n):
        ids.append(Int64(first_id + i))
        names.append(tag + "-" + String(first_id + i))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids)
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(names)))
    return rb.build(sb.build())


def _one(
    name: String, var batch: RecordBatch, version: Int64 = 1
) -> Slab[KgTable]:
    var tables = Slab[KgTable]()
    tables.append(KgTable(name.copy(), batch^, version))
    return tables^


def _two() raises -> Slab[KgTable]:
    var tables = Slab[KgTable]()
    tables.append(KgTable("entities", _batch(1, 3, "e"), 1))
    tables.append(KgTable("edges", _batch(100, 2, "x"), 3))
    return tables^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _serialize(batch: RecordBatch) raises -> List[UInt8]:
    return write_record_batch_to_parquet_bytes(batch, CompressionCodec.SNAPPY)


def _assert_rows(file: List[UInt8], first_id: Int, n: Int, tag: String) raises:
    var back = _read_parquet(file)
    assert_equal(back.num_rows(), n)
    var ids = back.column_as_primitive_int64(0)
    var names = back.column_as_string(1)
    for i in range(n):
        assert_equal(ids.get(i), Int64(first_id + i))
        assert_equal(
            String(unsafe_from_utf8=names.get_span(i)),
            tag + "-" + String(first_id + i),
        )


def _nothing_under(backend: Backend, prefix: String) raises -> Bool:
    var lr = backend.list_with_delimiter(Path.parse(prefix))
    return len(lr.objects) == 0 and len(lr.common_prefixes) == 0


def test_a_written_base_opens_with_its_tables_and_bytes() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    var sid = kg.write_snapshot(_two(), 8)
    assert_equal(sid, 0)
    assert_equal(kg.last_write_lost_races(), 0)

    var view = kg.open_latest()
    assert_equal(view.id(), 0)
    assert_equal(view.embedding_dim(), 8)
    assert_equal(view.num_tables(), 2)
    assert_equal(view.body.tables[0].name, "entities")
    assert_equal(view.body.tables[1].name, "edges")
    assert_true(view.has_table("entities"))
    assert_false(view.has_table("communities"))
    assert_equal(view.row_count("entities"), 3)
    assert_equal(view.row_count("edges"), 2)
    assert_equal(view.schema_version("entities"), 1)
    assert_equal(view.schema_version("edges"), 3)

    var entities = view.get_table_bytes("entities")
    var edges = view.get_table_bytes("edges")
    assert_true(_same(entities, _serialize(_batch(1, 3, "e"))))
    assert_true(_same(edges, _serialize(_batch(100, 2, "x"))))
    _assert_rows(entities, 1, 3, "e")
    _assert_rows(edges, 100, 2, "x")
    with assert_raises(contains="table not present"):
        _ = view.get_table_bytes("communities")
    with assert_raises(contains="table not present"):
        _ = view.row_count("communities")


def test_an_objects_key_is_the_hash_of_its_bytes() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_one("entities", _batch(1, 3)), 4)
    _ = kg.write_snapshot(_one("entities", _batch(1, 3)), 4)
    _ = kg.write_snapshot(_one("entities", _batch(1, 4)), 4)
    var first = kg.read_snapshot(0)
    var second = kg.read_snapshot(1)
    var third = kg.read_snapshot(2)
    var bytes = first.get_table_bytes("entities")
    assert_equal(
        first.object_key("entities"),
        "kg/objects/" + fnv1a64_hex(Span(bytes)) + ".parquet",
    )
    # The same rows are the same object; other rows are another one.
    assert_equal(first.object_key("entities"), second.object_key("entities"))
    assert_true(first.object_key("entities") != third.object_key("entities"))
    assert_equal(
        third.object_key("entities"),
        "kg/objects/"
        + fnv1a64_hex(Span(third.get_table_bytes("entities")))
        + ".parquet",
    )


def test_ids_run_without_a_gap_and_history_stays_readable() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    assert_equal(kg.write_snapshot(_one("entities", _batch(1, 2, "a")), 4), 0)
    assert_equal(kg.write_snapshot(_one("entities", _batch(1, 3, "b")), 4), 1)
    assert_equal(kg.write_snapshot(_one("entities", _batch(1, 4, "c")), 4), 2)
    assert_equal(kg.latest_snapshot_id(), 2)
    assert_equal(kg.head_seq(), 2)
    assert_false(kg.head_is_chain())
    assert_equal(kg.lost_races(), 0)

    var latest = kg.open_latest()
    assert_equal(latest.id(), 2)
    _assert_rows(latest.get_table_bytes("entities"), 1, 4, "c")
    var old = kg.read_snapshot(0)
    assert_equal(old.id(), 0)
    _assert_rows(old.get_table_bytes("entities"), 1, 2, "a")
    var middle = kg.read_snapshot(1)
    _assert_rows(middle.get_table_bytes("entities"), 1, 3, "b")
    # A view keeps reading after the store that made it is gone.
    var survivor = kg.read_snapshot(1)
    _ = kg^
    _assert_rows(survivor.get_table_bytes("entities"), 1, 3, "b")


def test_an_empty_lineage_has_no_head() raises:
    var kg = Kg(Backend(), "kg")
    assert_equal(kg.latest_snapshot_id(), -1)
    assert_equal(kg.head_seq(), -1)
    assert_false(kg.head_is_chain())
    with assert_raises(contains="no snapshot written yet"):
        _ = kg.open_latest()
    with assert_raises(contains="no snapshot written yet"):
        _ = kg.open_latest_chain()
    with assert_raises(contains="no snapshot written yet"):
        _ = kg.resolve_head_chain()
    with assert_raises(contains="negative snapshot id"):
        _ = kg.read_snapshot(-1)
    with assert_raises(contains="negative head seq"):
        _ = kg.read_chain(-1)
    with assert_raises(contains="not_found"):
        _ = kg.read_snapshot(0)


def test_an_invalid_write_is_refused_and_writes_nothing() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")

    with assert_raises(contains="no tables"):
        _ = kg.write_snapshot(Slab[KgTable](), 4)

    var twice = _one("entities", _batch(1, 2))
    twice.append(KgTable("entities", _batch(5, 2), 1))
    with assert_raises(contains="table named twice: entities"):
        _ = kg.write_snapshot(twice^, 4)

    with assert_raises(contains="negative schema_version -1"):
        _ = kg.write_snapshot(_one("entities", _batch(1, 2), -1), 4)

    # The second table is the bad one: the first must not have been written.
    var late = _one("entities", _batch(1, 2))
    late.append(KgTable("edges", _batch(5, 2), -7))
    with assert_raises(contains="negative schema_version -7"):
        _ = kg.write_snapshot(late^, 4)

    with assert_raises(contains="embedding dimension must be positive"):
        _ = kg.write_snapshot(_one("entities", _batch(1, 2)), 0)

    assert_true(_nothing_under(backend, "kg/"))
    assert_equal(kg.latest_snapshot_id(), -1)
    # The store is intact: a valid write goes through as snapshot 0.
    assert_equal(kg.write_snapshot(_one("entities", _batch(1, 2)), 4), 0)


def test_construction_refuses_a_bad_prefix_and_a_bad_attempt_bound() raises:
    with assert_raises(contains="prefix must be non-empty"):
        _ = Kg(Backend(), "")
    with assert_raises(contains="must not end in a slash"):
        _ = Kg(Backend(), "kg/")
    with assert_raises(contains="max_head_attempts must be at least 1"):
        _ = Kg(Backend(), "kg", max_head_attempts=0)
    assert_equal(Kg(Backend(), "kg/sub").prefix(), "kg/sub")


def test_reading_a_chunk_that_is_not_a_base_is_refused() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_one("entities", _batch(1, 2)), 4)
    _ = kg.append_delta(_one("entities", _batch(9, 1)), KgNameIndexBody())
    # Chunks: 0 base, 1 delta, 2 chain head.
    with assert_raises(contains="chunk 1 is not a base snapshot"):
        _ = kg.read_snapshot(1)
    with assert_raises(contains="chunk 2 is not a base snapshot"):
        _ = kg.read_snapshot(2)
    assert_equal(kg.read_snapshot(0).id(), 0)


def test_the_table_version_gate() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_two(), 4)
    var view = kg.open_latest()
    view.assert_table_readable("entities", 1)  # equal
    view.assert_table_readable("entities", 5)  # reader newer
    view.assert_table_readable("edges", 3)
    with assert_raises(contains="schema_version 3 > reader-supported 2"):
        view.assert_table_readable("edges", 2)
    with assert_raises(contains="table not present"):
        view.assert_table_readable("communities", 9)


def test_a_second_handle_sees_the_latest_and_prefixes_are_independent() raises:
    var backend = Backend()
    var writer = Kg(backend.clone(), "kg")
    _ = writer.write_snapshot(_one("entities", _batch(1, 2, "a")), 4)
    _ = writer.write_snapshot(_one("entities", _batch(1, 3, "b")), 4)

    var reader = Kg(backend.clone(), "kg")
    assert_equal(reader.latest_snapshot_id(), 1)
    _assert_rows(reader.open_latest().get_table_bytes("entities"), 1, 3, "b")

    var other = Kg(backend.clone(), "other")
    assert_equal(other.latest_snapshot_id(), -1)
    assert_equal(
        other.write_snapshot(_one("entities", _batch(7, 1, "z")), 4), 0
    )
    assert_equal(writer.latest_snapshot_id(), 1)
    _assert_rows(other.open_latest().get_table_bytes("entities"), 7, 1, "z")


def test_fingerprints_ride_the_same_store() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    assert_equal(kg.fingerprint_lookup("p1", "doc-1"), "")
    assert_true(kg.fingerprint_load().is_empty())

    _ = kg.write_snapshot(_one("entities", _batch(1, 2)), 4)
    kg.fingerprint_patch_save("p1", "doc-1", "1111111111111111", "")
    kg.fingerprint_patch_save("p1", "doc-2", "2222222222222222", "sig")
    kg.fingerprint_patch_save("p2", "doc-1", "3333333333333333", "")
    kg.fingerprint_patch_save("p1", "doc-1", "4444444444444444", "")

    assert_equal(kg.fingerprint_lookup("p1", "doc-1"), "4444444444444444")
    assert_equal(kg.fingerprint_lookup("p1", "doc-2"), "2222222222222222")
    assert_equal(kg.fingerprint_lookup("p2", "doc-1"), "3333333333333333")
    assert_equal(kg.fingerprint_lookup("p2", "doc-2"), "")
    assert_equal(kg.fingerprint_load().num_entries(), 3)
    # A fresh handle on the store reads the same set.
    var again = Kg(backend.clone(), "kg")
    assert_equal(again.fingerprint_lookup("p1", "doc-2"), "2222222222222222")
    # The snapshot lineage was not touched by any of it.
    assert_equal(kg.latest_snapshot_id(), 0)
    var raw = CasManifestStore[Backend](backend.clone(), "kg/manifest")
    assert_equal(raw.read_head_fresh().chunk_seq, 0)

    kg.fingerprint_save(kg.fingerprint_load())
    with assert_raises(contains="refusing to replace"):
        kg.fingerprint_save(SourceFingerprintSet())
    assert_equal(kg.fingerprint_load().num_entries(), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
