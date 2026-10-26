# =============================================================================
# test_snapshot_store_compaction.mojo -- folding a delta chain into a fresh base
#   and retiring the folded deltas (an in-memory conditional-write store; no
#   network; the time stamped on a retired delta is a number the test passes).
# =============================================================================
#
#   fold          a compactor that reads a chain, writes the folded tables with
#                 write_base_tables and commits them makes the new base the head
#                 with no deltas; the chain it read, pinned before the fold, and
#                 every earlier head still read the same bytes and rows.
#   pending       the base a compactor writes is not the head until it is
#                 committed: the latest snapshot, the head chain and the next
#                 delta are those of the chain being folded, on an empty lineage
#                 too.
#   carry         a delta that arrives while the fold runs, before or after the
#                 new base is written, is carried onto the new base; only the
#                 deltas the compactor folded are dropped from the chain.
#   refusals      a commit is refused, and writes nothing, for a chunk that is
#                 not a pending base, a base that is not the one the head chain
#                 sits on (another compaction committed first), and a folded
#                 delta that is not on the head chain, or a base written before
#                 a delta it says it folded.
#   chain of one  a base alone is folded into a fresh base with no deltas.
#   policy        the size a chain reports, with the policy, decides a fold
#                 before it and not after.
#   retire        a folded delta is stamped with the time the caller passes, its
#                 age is measured against the time the caller passes, and its
#                 chunk and objects stay readable; a delta still on the head
#                 chain, a base and a delta never retired are refused, and a
#                 handle holding an old tail cannot retire a delta that another
#                 handle's chain head names.
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
    CompactionPolicy,
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    decode_framed_delta_to_batch,
    delta_object_is_framed,
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


def _index(a: String, a_id: Int64) -> KgNameIndexBody:
    var idx = KgNameIndexBody()
    idx.add(a, a_id)
    return idx^


def _setup(mut kg: Kg) raises:
    """Chunks: 0 base, 1 delta, 2 chain head, 3 delta, 4 chain head."""
    assert_equal(kg.write_snapshot(_one("entities", _batch(1, 3, "e")), 4), 0)
    assert_equal(
        kg.append_delta(_one("entities", _batch(10, 2, "d")), _index("a", 10)),
        2,
    )
    assert_equal(
        kg.append_delta(_one("entities", _batch(20, 1, "d")), _index("b", 20)),
        4,
    )


def test_a_fold_makes_the_new_base_the_head_and_the_pinned_chain_still_reads() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _setup(kg)
    var pinned = kg.open_latest_chain()
    assert_equal(pinned.id(), 4)
    assert_equal(pinned.num_deltas(), 2)

    # The compactor folds the base and both deltas into one table of 6 rows.
    var new_base = kg.write_base_tables(_one("entities", _batch(1, 6, "f")), 4)
    assert_equal(new_base, 5)
    var head = kg.commit_compacted_head(
        new_base, pinned.base_id(), pinned.delta_seqs.copy()
    )
    assert_equal(head, 6)
    assert_equal(kg.last_write_lost_races(), 0)

    assert_equal(kg.latest_snapshot_id(), 6)
    assert_true(kg.head_is_chain())
    var after = kg.open_latest_chain()
    assert_equal(after.base_id(), 5)
    assert_equal(after.num_deltas(), 0)
    assert_equal(after.base.row_count("entities"), 6)
    assert_equal(after.base.embedding_dim(), 4)
    _assert_rows(after.base.get_table_bytes("entities"), 1, 6, "f")
    assert_equal(after.resolve_name_index("a"), -1)  # folded into the base

    # The chain pinned before the fold reads exactly what it read.
    assert_equal(pinned.num_deltas(), 2)
    _assert_rows(pinned.base.get_table_bytes("entities"), 1, 3, "e")
    _framed_rows(pinned.delta_object_bytes(0, "entities"), 10, 2, "d")
    _framed_rows(pinned.delta_object_bytes(1, "entities"), 20, 1, "d")
    assert_equal(pinned.resolve_name_index("a"), 10)
    assert_equal(pinned.resolve_name_index("b"), 20)
    # So does every head from before the fold, resolved afresh.
    var old = kg.read_chain(4)
    assert_equal(old.base_id(), 0)
    assert_equal(old.num_deltas(), 2)
    _assert_rows(old.base.get_table_bytes("entities"), 1, 3, "e")
    _framed_rows(old.delta_object_bytes(1, "entities"), 20, 1, "d")
    assert_equal(kg.read_chain(2).num_deltas(), 1)
    assert_equal(kg.read_chain(0).num_deltas(), 0)


def test_the_base_a_compactor_writes_is_not_the_head_until_it_is_committed() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _setup(kg)
    var new_base = kg.write_base_tables(_one("entities", _batch(1, 6, "f")), 4)
    assert_equal(new_base, 5)
    assert_equal(kg.latest_snapshot_id(), 4)
    assert_equal(kg.head_seq(), 4)
    assert_true(kg.head_is_chain())
    assert_equal(kg.open_latest_chain().num_deltas(), 2)
    assert_equal(kg.resolve_head_chain().base_seq, 0)
    # A fresh handle sees the same head.
    assert_equal(Kg(backend.clone(), "kg").latest_snapshot_id(), 4)
    # The pending base itself is a readable base.
    assert_equal(kg.read_snapshot(new_base).row_count("entities"), 6)
    # A delta appended now is chained over the head, not over the pending base.
    assert_equal(kg.append_delta(_one("entities", _batch(30, 1, "g")), KgNameIndexBody()), 7)
    assert_equal(kg.open_latest_chain().base_id(), 0)
    assert_equal(kg.open_latest_chain().num_deltas(), 3)

    # On an empty lineage a pending base is not a snapshot either.
    var empty = Kg(backend.clone(), "other")
    assert_equal(empty.write_base_tables(_one("entities", _batch(1, 2)), 4), 0)
    assert_equal(empty.latest_snapshot_id(), -1)
    assert_false(empty.head_is_chain())
    with assert_raises(contains="no snapshot written yet"):
        _ = empty.open_latest()
    with assert_raises(contains="write a base snapshot before a delta"):
        _ = empty.append_delta(Slab[KgTable](), KgNameIndexBody())


def test_a_delta_that_arrives_during_the_fold_is_carried_onto_the_new_base() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    assert_equal(kg.write_snapshot(_one("entities", _batch(1, 3, "e")), 4), 0)
    assert_equal(
        kg.append_delta(_one("entities", _batch(10, 1, "d")), _index("a", 10)),
        2,
    )
    # The compactor reads the chain (base 0, delta 1): this is what it folds.
    var pinned = kg.open_latest_chain()
    assert_equal(pinned.delta_seqs[0], 1)

    # A delta arrives while it folds, before it writes the new base...
    assert_equal(
        kg.append_delta(_one("entities", _batch(20, 1, "d")), _index("b", 20)),
        4,
    )
    var new_base = kg.write_base_tables(_one("entities", _batch(1, 4, "f")), 4)
    assert_equal(new_base, 5)
    # ...and another after, before it commits.
    assert_equal(
        kg.append_delta(_one("entities", _batch(30, 1, "d")), _index("c", 30)),
        7,
    )
    var chain_before = kg.open_latest_chain()
    assert_equal(chain_before.base_id(), 0)
    assert_equal(chain_before.num_deltas(), 3)

    var head = kg.commit_compacted_head(
        new_base, pinned.base_id(), pinned.delta_seqs.copy()
    )
    assert_equal(head, 8)
    var after = kg.open_latest_chain()
    assert_equal(after.base_id(), 5)
    assert_equal(after.num_deltas(), 2)
    assert_equal(after.delta_seqs[0], 3)  # arrived before the new base
    assert_equal(after.delta_seqs[1], 6)  # arrived after it
    assert_equal(after.resolve_name_index("a"), -1)  # folded
    assert_equal(after.resolve_name_index("b"), 20)
    assert_equal(after.resolve_name_index("c"), 30)
    _framed_rows(after.delta_object_bytes(0, "entities"), 20, 1, "d")
    _framed_rows(after.delta_object_bytes(1, "entities"), 30, 1, "d")


def test_a_commit_is_refused_and_writes_nothing_when_it_does_not_fit() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _setup(kg)
    var pinned = kg.open_latest_chain()
    var raw = Raw(backend.clone(), "kg/manifest")

    # A base that was committed as a snapshot, a delta, a chain head, nothing.
    with assert_raises(contains="chunk 0 is not a pending base"):
        _ = kg.commit_compacted_head(0, 0, pinned.delta_seqs.copy())
    with assert_raises(contains="chunk 1 is not a pending base"):
        _ = kg.commit_compacted_head(1, 0, pinned.delta_seqs.copy())
    with assert_raises(contains="chunk 2 is not a pending base"):
        _ = kg.commit_compacted_head(2, 0, pinned.delta_seqs.copy())
    with assert_raises(contains="negative base"):
        _ = kg.commit_compacted_head(-1, 0, pinned.delta_seqs.copy())

    var new_base = kg.write_base_tables(_one("entities", _batch(1, 6, "f")), 4)
    # A folded delta the head chain does not have.
    with assert_raises(contains="folded delta 99 is not on the head chain"):
        _ = kg.commit_compacted_head(new_base, 0, [Int64(1), Int64(99)])
    # Folded from a base the chain does not sit on.
    with assert_raises(contains="the head's base is 0, not the base 3"):
        _ = kg.commit_compacted_head(new_base, 3, pinned.delta_seqs.copy())
    var tip = raw.read_head_authoritative().chunk_seq
    assert_equal(tip, new_base)
    assert_equal(kg.latest_snapshot_id(), 4)

    # A second compactor that folded the same chain loses to the first.
    var second_base = kg.write_base_tables(_one("entities", _batch(1, 7, "g")), 4)
    assert_equal(
        kg.commit_compacted_head(new_base, 0, pinned.delta_seqs.copy()),
        second_base + 1,
    )
    var tip_after = raw.read_head_authoritative().chunk_seq
    with assert_raises(contains="another compaction committed first"):
        _ = kg.commit_compacted_head(
            second_base, pinned.base_id(), pinned.delta_seqs.copy()
        )
    assert_equal(raw.read_head_authoritative().chunk_seq, tip_after)
    assert_equal(kg.open_latest_chain().base_id(), new_base)


def test_a_base_alone_is_folded_into_a_fresh_base() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    assert_equal(kg.write_snapshot(_one("entities", _batch(1, 3, "e")), 4), 0)
    var new_base = kg.write_base_tables(_one("entities", _batch(1, 3, "r")), 4)
    assert_equal(new_base, 1)
    assert_false(kg.head_is_chain())
    assert_equal(kg.commit_compacted_head(new_base, 0, List[Int64]()), 2)
    assert_true(kg.head_is_chain())
    var chain = kg.open_latest_chain()
    assert_equal(chain.base_id(), 1)
    assert_equal(chain.num_deltas(), 0)
    _assert_rows(chain.base.get_table_bytes("entities"), 1, 3, "r")


def test_the_reported_sizes_decide_a_fold_before_it_and_not_after() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _setup(kg)
    var before = kg.chain_total_bytes(kg.resolve_head_chain())
    var policy = CompactionPolicy(2, Int64(0), Int64(0))  # count leg only
    assert_true(policy.should_compact(2, before[1], before[0]))
    var size_policy = CompactionPolicy(1000000, Int64(1), Int64(1))
    assert_false(
        size_policy.should_compact(2, Int64(1), before[0])
    )  # tiny deltas
    var pinned = kg.open_latest_chain()
    var new_base = kg.write_base_tables(_one("entities", _batch(1, 6, "f")), 4)
    _ = kg.commit_compacted_head(
        new_base, pinned.base_id(), pinned.delta_seqs.copy()
    )
    var chain = kg.resolve_head_chain()
    var after = kg.chain_total_bytes(chain)
    assert_equal(after[1], 0)
    assert_true(after[0] > 0)
    assert_false(policy.should_compact(chain.num_deltas(), after[1], after[0]))


def test_a_folded_delta_is_stamped_with_the_callers_time_and_stays_readable() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _setup(kg)
    var pinned = kg.open_latest_chain()
    var new_base = kg.write_base_tables(_one("entities", _batch(1, 6, "f")), 4)
    _ = kg.commit_compacted_head(
        new_base, pinned.base_id(), pinned.delta_seqs.copy()
    )
    var raw = Raw(backend.clone(), "kg/manifest")

    kg.retire_folded_delta(1, 5000)
    kg.retire_folded_delta(3, 7000)
    assert_equal(raw.tombstone_schedule_ts(1), 5000)
    assert_equal(raw.tombstone_schedule_ts(3), 7000)
    assert_equal(kg.retired_age_ms(1, 5000), 0)
    assert_equal(kg.retired_age_ms(1, 6500), 1500)
    assert_equal(kg.retired_age_ms(3, 6500), 0)  # a stamp after "now" is age 0
    assert_equal(kg.retired_age_ms(3, 7000 + 86400000), 86400000)
    # Restamping moves the age's start.
    kg.retire_folded_delta(1, 9000)
    assert_equal(kg.retired_age_ms(1, 9500), 500)

    # Retired is not deleted: the chunks, the objects and the pinned chain read.
    assert_equal(kg.read_delta_body(1).num_tables(), 1)
    assert_equal(kg.read_delta_body(3).num_tables(), 1)
    var old = kg.read_chain(4)
    assert_equal(old.num_deltas(), 2)
    _framed_rows(old.delta_object_bytes(0, "entities"), 10, 2, "d")
    _framed_rows(pinned.delta_object_bytes(1, "entities"), 20, 1, "d")
    _assert_rows(pinned.base.get_table_bytes("entities"), 1, 3, "e")


def test_retiring_a_live_delta_a_base_or_a_never_retired_one_is_refused() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    _setup(kg)
    # Delta 3 is on the head chain: it was not folded.
    with assert_raises(contains="delta 3 is still on the head chain"):
        kg.retire_folded_delta(3, 1000)
    with assert_raises(contains="chunk 0 is not a delta"):
        kg.retire_folded_delta(0, 1000)
    with assert_raises(contains="chunk 2 is not a delta"):
        kg.retire_folded_delta(2, 1000)
    with assert_raises(contains="not_found"):
        _ = kg.retired_age_ms(1, 1000)
    # None of the refusals left a marker.
    assert_equal(len(Raw(backend.clone(), "kg/manifest").tombstone_seqs()), 0)


def test_a_stale_handle_cannot_retire_a_delta_the_head_still_names() raises:
    var backend = Backend()
    var a = Kg(backend.clone(), "kg")
    var b = Kg(backend.clone(), "kg")
    assert_equal(a.write_snapshot(_two(), 4), 0)
    # Another handle appends a delta (chunk 1); the head is chunk 2.
    assert_equal(
        b.append_delta(_one("entities", _batch(10, 2, "d")), _index("a", 10)), 2
    )
    # Handle a still holds the tail it wrote (chunk 0), where no delta is live.
    with assert_raises(contains="delta 1 is still on the head chain"):
        a.retire_folded_delta(1, 5)
    assert_equal(len(Raw(backend.clone(), "kg/manifest").tombstone_seqs()), 0)


def test_a_base_written_before_a_folded_delta_cannot_commit() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "kg")
    assert_equal(kg.write_snapshot(_two(), 4), 0)
    var early = kg.write_base_tables(_one("entities", _batch(1, 3, "f")), 4)
    assert_equal(early, 1)
    # Delta 2 and its chain head 3 arrive after the pending base was written.
    assert_equal(
        kg.append_delta(_one("entities", _batch(10, 2, "d")), _index("a", 10)), 3
    )
    with assert_raises(contains="base 1 was written before folded delta 2"):
        _ = kg.commit_compacted_head(early, 0, [Int64(2)])
    var raw = Raw(backend.clone(), "kg/manifest")
    assert_equal(raw.read_head_authoritative().chunk_seq, 3)
    var chain = kg.resolve_head_chain()
    assert_equal(chain.base_seq, 0)
    assert_equal(chain.num_deltas(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
