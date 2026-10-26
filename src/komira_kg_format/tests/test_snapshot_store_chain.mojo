# =============================================================================
# test_snapshot_store_chain.mojo -- delta chains on the lineage store: a base,
#   deltas appended over it, and every way to read the chain back (an in-memory
#   conditional-write store; no network, no clock).
# =============================================================================
#
#   read back     a base then two deltas read back as a chain: the base is
#                 untouched, each delta lists its changed tables, its objects
#                 are the delta codec's (framed when small, Parquet from
#                 FRAMED_MAX_ROWS rows) and decode to the rows that went in, the
#                 name index folds with the later delta winning, and the head is
#                 a chain.
#   chain of one  a base alone reads as a chain with no deltas.
#   point in time every earlier head resolves its own base and deltas; a delta
#                 is not a head.
#   chunk kinds   the lineage alternates base, delta, chain head as written, and
#                 the store tells them apart by format version
#                 (kg_chunk_kind), refusing a short body and an unknown version;
#                 read_delta_body refuses a base and a chain head.
#   tip           a delta no chain head names yet, at the tip, is not the head: a
#                 reader keeps the head below it and the next delta is chained
#                 without it.
#   corrupt       a chain head that names a chunk not before it, or a base or
#                 chain head as a delta, is refused on read.
#   refusals      a delta onto an empty lineage, an invalid delta table and a
#                 delta index out of range are refused, and a refused delta
#                 writes no chunk.
#   index only    a delta with no table, only name-index entries, is a delta.
#   sizes         chain_total_bytes is the sum of the sizes of the base objects
#                 and of the delta objects.
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
    FRAMED_MAX_ROWS,
    KG_CHUNK_BASE,
    KG_CHUNK_CHAIN,
    KG_CHUNK_DELTA,
    KgChainBody,
    KgDeltaBody,
    KgManifestBody,
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    decode_framed_delta_to_batch,
    delta_object_is_framed,
    delta_object_parquet_bytes,
    kg_chunk_kind,
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
comptime Raw = CasManifestStore[SharedInMemoryConditionalStore]


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


def _index(a: String, a_id: Int64) -> KgNameIndexBody:
    var idx = KgNameIndexBody()
    idx.add(a, a_id)
    return idx^


def _framed_rows(object: List[UInt8], first_id: Int, n: Int, tag: String) raises:
    """A framed delta object decodes to ids first_id.. and names tag-<id>."""
    assert_true(delta_object_is_framed(object))
    var back = decode_framed_delta_to_batch(object)
    assert_equal(back.num_rows(), n)
    var ids = back.column_as_primitive_int64(0)
    var names = back.column_as_string(1)
    for i in range(n):
        assert_equal(ids.get(i), Int64(first_id + i))
        assert_equal(
            String(unsafe_from_utf8=names.get_span(i)),
            tag + "-" + String(first_id + i),
        )


def _base_and_two_deltas(mut kg: Kg) raises:
    """Chunks: 0 base, 1 delta, 2 chain head, 3 delta, 4 chain head."""
    assert_equal(kg.write_snapshot(_two(), 4), 0)
    var first = kg.append_delta(
        _one("entities", _batch(10, 2, "d")), _index("alpha", 10)
    )
    assert_equal(first, 2)
    var second_tables = _one("entities", _batch(20, 1, "e"))
    second_tables.append(KgTable("edges", _batch(200, 1, "y"), 3))
    var idx = _index("alpha", 20)
    idx.add("beta", 21)
    assert_equal(kg.append_delta(second_tables^, idx^), 4)


def test_a_base_then_two_deltas_read_back_as_a_chain() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _base_and_two_deltas(kg)
    assert_equal(kg.last_write_lost_races(), 0)
    assert_equal(kg.latest_snapshot_id(), 4)
    assert_true(kg.head_is_chain())

    var chain = kg.open_latest_chain()
    assert_equal(chain.id(), 4)
    assert_equal(chain.base_id(), 0)
    assert_equal(chain.num_deltas(), 2)
    assert_equal(len(chain.delta_seqs), 2)
    assert_equal(chain.delta_seqs[0], 1)
    assert_equal(chain.delta_seqs[1], 3)

    # The base is untouched by the deltas.
    assert_equal(chain.base.num_tables(), 2)
    assert_true(
        _same(
            chain.base.get_table_bytes("entities"),
            _serialize(_batch(1, 3, "e")),
        )
    )

    ref d0 = chain.deltas[0]
    assert_equal(d0.num_tables(), 1)
    assert_true(d0.has_table("entities"))
    assert_false(d0.has_table("edges"))
    assert_equal(d0.resolve("entities").row_count, 2)
    _framed_rows(chain.delta_object_bytes(0, "entities"), 10, 2, "d")
    ref d1 = chain.deltas[1]
    assert_equal(d1.num_tables(), 2)
    _framed_rows(chain.delta_object_bytes(1, "entities"), 20, 1, "e")
    _framed_rows(chain.delta_object_bytes(1, "edges"), 200, 1, "y")
    assert_true(
        d0.resolve("entities").object_key.startswith("kg/deltas/")
    )

    assert_equal(chain.resolve_name_index("alpha"), 20)  # later delta wins
    assert_equal(chain.resolve_name_index("beta"), 21)
    assert_equal(chain.resolve_name_index("gamma"), -1)

    var body = kg.resolve_head_chain()
    assert_equal(body.base_seq, 0)
    assert_equal(body.num_deltas(), 2)
    with assert_raises(contains="the head is a delta chain"):
        _ = kg.open_latest()


def test_a_delta_of_many_rows_is_a_parquet_object() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_one("entities", _batch(1, 2)), 4)
    _ = kg.append_delta(
        _one("entities", _batch(500, FRAMED_MAX_ROWS, "w")), KgNameIndexBody()
    )
    var chain = kg.open_latest_chain()
    var object = chain.delta_object_bytes(0, "entities")
    assert_false(delta_object_is_framed(object))
    var rows = _read_parquet(delta_object_parquet_bytes(object))
    assert_equal(rows.num_rows(), FRAMED_MAX_ROWS)
    assert_equal(rows.column_as_primitive_int64(0).get(0), 500)
    assert_equal(
        chain.deltas[0].resolve("entities").row_count, Int64(FRAMED_MAX_ROWS)
    )


def test_a_base_alone_reads_as_a_chain_of_one() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_two(), 4)
    assert_false(kg.head_is_chain())
    var chain = kg.open_latest_chain()
    assert_equal(chain.id(), 0)
    assert_equal(chain.base_id(), 0)
    assert_equal(chain.num_deltas(), 0)
    assert_equal(chain.resolve_name_index("alpha"), -1)
    var body = kg.resolve_head_chain()
    assert_equal(body.base_seq, 0)
    assert_equal(body.num_deltas(), 0)
    assert_equal(kg.read_chain_body(0).num_deltas(), 0)


def test_every_earlier_head_resolves_its_own_chain() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _base_and_two_deltas(kg)
    assert_equal(kg.read_chain(0).num_deltas(), 0)
    var middle = kg.read_chain(2)
    assert_equal(middle.id(), 2)
    assert_equal(middle.num_deltas(), 1)
    assert_equal(middle.delta_seqs[0], 1)
    assert_equal(middle.resolve_name_index("alpha"), 10)
    assert_equal(middle.resolve_name_index("beta"), -1)
    assert_equal(kg.read_chain(4).num_deltas(), 2)
    with assert_raises(contains="chunk 1 is a delta, not a head"):
        _ = kg.read_chain(1)
    with assert_raises(contains="chunk 3 is a delta, not a head"):
        _ = kg.read_chain_body(3)


def test_the_chunks_are_told_apart_by_their_format_version() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _base_and_two_deltas(kg)
    var raw = Raw(backend.clone(), "kg/manifest")
    var kinds = List[Int]()
    for seq in range(5):
        kinds.append(kg_chunk_kind(raw.read_chunk(Int64(seq))))
    var expected: List[Int] = [
        KG_CHUNK_BASE,
        KG_CHUNK_DELTA,
        KG_CHUNK_CHAIN,
        KG_CHUNK_DELTA,
        KG_CHUNK_CHAIN,
    ]
    for i in range(5):
        assert_equal(kinds[i], expected[i])

    # Each body kind on its own, and the refusals.
    assert_equal(kg_chunk_kind(KgManifestBody(4).encode()), KG_CHUNK_BASE)
    assert_equal(kg_chunk_kind(KgChainBody(0).encode()), KG_CHUNK_CHAIN)
    assert_equal(kg_chunk_kind(KgDeltaBody().encode()), KG_CHUNK_DELTA)
    with assert_raises(contains="truncated i64"):
        _ = kg_chunk_kind(List[UInt8]())
    var unknown = KgChainBody(0).encode()
    unknown[0] = 9
    with assert_raises(contains="unknown chunk format version 9"):
        _ = kg_chunk_kind(unknown)

    # The store's own readers hold to the kinds.
    assert_equal(kg.read_delta_body(1).num_tables(), 1)
    with assert_raises(contains="chunk 0 is not a delta"):
        _ = kg.read_delta_body(0)
    with assert_raises(contains="chunk 2 is not a delta"):
        _ = kg.read_delta_body(2)
    with assert_raises(contains="negative delta seq"):
        _ = kg.read_delta_body(-1)


def test_a_delta_at_the_tip_that_no_chain_names_is_not_the_head() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_one("entities", _batch(1, 2)), 4)
    _ = kg.append_delta(_one("entities", _batch(10, 1)), KgNameIndexBody())
    # A writer that stopped between its two appends: chunk 3, a delta, and no
    # chain head after it.
    var raw = Raw(backend.clone(), "kg/manifest")
    var orphan = KgDeltaBody()
    orphan.add_index_entry("ghost", 99)
    assert_equal(raw.append(orphan.encode(), 0).chunk_seq, 3)

    var reader = Kg(backend.clone(), "kg")
    assert_equal(reader.latest_snapshot_id(), 2)
    assert_true(reader.head_is_chain())
    var chain = reader.open_latest_chain()
    assert_equal(chain.num_deltas(), 1)
    assert_equal(chain.resolve_name_index("ghost"), -1)

    # The next delta is chained over the head, not over the orphan.
    var writer = Kg(backend.clone(), "kg")
    assert_equal(
        writer.append_delta(_one("entities", _batch(20, 1)), KgNameIndexBody()),
        5,
    )
    var after = writer.open_latest_chain()
    assert_equal(after.num_deltas(), 2)
    assert_equal(after.delta_seqs[0], 1)
    assert_equal(after.delta_seqs[1], 4)
    assert_equal(after.resolve_name_index("ghost"), -1)


def test_a_chain_that_names_a_chunk_not_before_it_is_refused() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_one("entities", _batch(1, 2)), 4)
    var raw = Raw(backend.clone(), "kg/manifest")
    # Chunk 1 names delta 5, which does not exist yet.
    assert_equal(raw.append(KgChainBody(0, [Int64(5)]).encode(), 1).chunk_seq, 1)
    with assert_raises(contains="chain head 1 names delta 5, which is not before it"):
        _ = kg.read_chain(1)
    var reader = Kg(backend.clone(), "kg")
    with assert_raises(contains="which is not before it"):
        _ = reader.open_latest_chain()
    with assert_raises(contains="which is not before it"):
        _ = reader.latest_snapshot_id()

    var other = Backend()
    var kg2 = Kg(other.clone(), "kg")
    _ = kg2.write_snapshot(_one("entities", _batch(1, 2)), 4)
    var raw2 = Raw(other.clone(), "kg/manifest")
    # Chunk 1 names itself as its base.
    assert_equal(raw2.append(KgChainBody(1).encode(), 0).chunk_seq, 1)
    with assert_raises(contains="chain head 1 names base 1, which is not before it"):
        _ = kg2.read_chain_body(1)


def test_a_chain_that_names_a_base_as_a_delta_is_refused() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_one("entities", _batch(1, 2)), 4)
    var raw = Raw(backend.clone(), "kg/manifest")
    # Chunk 1 is a chain head whose "delta" is the base chunk 0.
    assert_equal(raw.append(KgChainBody(0, [Int64(0)]).encode(), 1).chunk_seq, 1)
    with assert_raises(contains="chunk 0 is not a delta"):
        _ = kg.read_chain(1)


def test_a_delta_onto_an_empty_lineage_is_refused_and_writes_nothing() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    with assert_raises(contains="write a base snapshot before a delta"):
        _ = kg.append_delta(_one("entities", _batch(1, 1)), KgNameIndexBody())
    assert_true(_nothing_under(backend, "kg/"))


def test_an_invalid_delta_table_is_refused_and_writes_no_chunk() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_one("entities", _batch(1, 2)), 4)
    var twice = _one("entities", _batch(5, 1))
    twice.append(KgTable("entities", _batch(6, 1), 1))
    with assert_raises(contains="table named twice: entities"):
        _ = kg.append_delta(twice^, KgNameIndexBody())
    with assert_raises(contains="negative schema_version -2"):
        _ = kg.append_delta(
            _one("entities", _batch(5, 1), -2), KgNameIndexBody()
        )
    assert_equal(kg.latest_snapshot_id(), 0)
    assert_equal(Raw(backend.clone(), "kg/manifest").read_head_authoritative().chunk_seq, 0)


def test_a_delta_with_only_name_index_entries_is_a_delta() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _ = kg.write_snapshot(_one("entities", _batch(1, 2)), 4)
    assert_equal(kg.append_delta(Slab[KgTable](), _index("seed", 3)), 2)
    var chain = kg.open_latest_chain()
    assert_equal(chain.num_deltas(), 1)
    assert_equal(chain.deltas[0].num_tables(), 0)
    assert_equal(chain.resolve_name_index("seed"), 3)
    assert_equal(kg.read_delta_body(1).num_tables(), 0)
    with assert_raises(contains="table not present in delta: entities"):
        _ = chain.delta_object_bytes(0, "entities")


def test_a_delta_index_out_of_range_or_a_table_it_lacks_is_refused() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _base_and_two_deltas(kg)
    var chain = kg.open_latest_chain()
    with assert_raises(contains="delta index -1 out of range for a chain of 2"):
        _ = chain.delta_object_bytes(-1, "entities")
    with assert_raises(contains="delta index 2 out of range for a chain of 2"):
        _ = chain.delta_object_bytes(2, "entities")
    with assert_raises(contains="table not present in delta: edges"):
        _ = chain.delta_object_bytes(0, "edges")


def test_chain_total_bytes_sums_the_object_sizes() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _base_and_two_deltas(kg)
    var chain = kg.open_latest_chain()
    var base_bytes = Int64(0)
    base_bytes += Int64(len(chain.base.get_table_bytes("entities")))
    base_bytes += Int64(len(chain.base.get_table_bytes("edges")))
    var delta_bytes = Int64(0)
    delta_bytes += Int64(len(chain.delta_object_bytes(0, "entities")))
    delta_bytes += Int64(len(chain.delta_object_bytes(1, "entities")))
    delta_bytes += Int64(len(chain.delta_object_bytes(1, "edges")))
    var sizes = kg.chain_total_bytes(kg.resolve_head_chain())
    assert_equal(sizes[0], base_bytes)
    assert_equal(sizes[1], delta_bytes)
    assert_true(base_bytes > 0 and delta_bytes > 0)
    var alone = kg.chain_total_bytes(kg.read_chain_body(0))
    assert_equal(alone[0], base_bytes)
    assert_equal(alone[1], 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
