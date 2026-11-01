# =============================================================================
# test_snapshot_store_races.mojo -- lost compare-and-set races on the lineage
#   store: retried, reported, bounded, and never at the cost of another writer's
#   delta (an in-memory conditional-write store with a rival that takes slots; no
#   network, no clock).
# =============================================================================
#
#   lost slot     a base write whose slot another handle took is retried at the
#                 next slot, wins, and the store reports the lost race
#                 (last_write_lost_races, lost_races); a write that wins first
#                 time reports none; every snapshot of both handles reads back.
#   lost head     an append_delta whose chain head was beaten to its slot by a
#                 rival chain head is retried from the new tip, builds its chain
#                 over the rival's head, and the head names both deltas.
#   head order    two writers' chain heads land in the opposite order to their
#                 deltas: the chain lists the deltas in the order the heads
#                 landed, no delta is lost, and the name index's later entry wins
#                 by that order.
#   carry         a commit_compacted_head beaten the same way carries the
#                 rival's delta onto the new base instead of dropping it.
#   bounded       a base write that loses every slot stops after the retry
#                 policy's budget (max_retries + 1 puts) with an error ending
#                 "(retryable)", reports every slot lost and publishes nothing;
#                 an append_delta that loses every chain head stops after
#                 max_head_attempts, with the same ending, leaves the head as the
#                 rival made it, and the delta it wrote is not on it.
# =============================================================================

from std.memory import ArcPointer
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
from komira_collections.slab import Slab
from komira_kg_format import (
    KgChainBody,
    KgDeltaBody,
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
)
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    chunk_key,
    encode_chunk,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


comptime Backend = SharedInMemoryConditionalStore
comptime Plain = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime Raw = CasManifestStore[SharedInMemoryConditionalStore]


struct _Rival(Movable):
    """What the rival does to the writer's chunk puts: leave `envelope` at the
    key just before the writer's create (so the writer loses the slot), once at
    `armed_key`, or on every chunk put after `skip` of them."""

    var armed_key: String
    var envelope: List[UInt8]
    var second_key: String
    var second_envelope: List[UInt8]
    var always: Bool
    var skip: Int
    var chunk_puts: Int
    var stolen: Int

    def __init__(out self):
        self.armed_key = String("")
        self.envelope = List[UInt8]()
        self.second_key = String("")
        self.second_envelope = List[UInt8]()
        self.always = False
        self.skip = 0
        self.chunk_puts = 0
        self.stolen = 0


struct _Contended(CloneableConditionalWriteStore, Movable):
    """A shared in-memory store whose manifest-chunk creates a `_Rival` can win."""

    var inner: SharedInMemoryConditionalStore
    var rival: ArcPointer[_Rival]

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var rival: ArcPointer[_Rival],
    ):
        self.inner = inner^
        self.rival = rival^

    def clone(self) -> Self:
        return Self(self.inner.clone(), self.rival.copy())

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return CoalescePolicy.default()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        var key = path.raw()
        if key.endswith(".chunk"):
            ref r = self.rival[]
            r.chunk_puts += 1
            var steal = False
            if r.armed_key == key:
                steal = True
                r.armed_key = String("")
            elif r.second_key == key:
                r.second_key = String("")
                r.stolen += 1
                _ = self.inner.put(path, r.second_envelope.copy())
            elif r.always:
                if r.skip > 0:
                    r.skip -= 1
                else:
                    steal = True
            if steal:
                r.stolen += 1
                _ = self.inner.put(path, r.envelope.copy())
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


comptime Contended = KgSnapshotStore[_Contended]


def _batch(first_id: Int, n: Int) raises -> RecordBatch:
    var ids = List[Int64](capacity=n)
    var names = List[String](capacity=n)
    for i in range(n):
        ids.append(Int64(first_id + i))
        names.append("n-" + String(first_id + i))
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


def _one(first_id: Int, n: Int) raises -> Slab[KgTable]:
    var tables = Slab[KgTable]()
    tables.append(KgTable("entities", _batch(first_id, n), 1))
    return tables^


def _index(name: String, nid: Int64) -> KgNameIndexBody:
    var idx = KgNameIndexBody()
    idx.add(name, nid)
    return idx^


def _slot(seq: Int64) raises -> String:
    return chunk_key("kg/manifest", seq).raw()


def _contended(
    backend: Backend,
    rival: ArcPointer[_Rival],
    retry: RetryPolicy = RetryPolicy.fast_test(),
    max_head_attempts: Int = 8,
) raises -> Contended:
    return Contended(
        _Contended(backend.clone(), rival.copy()),
        "kg",
        retry,
        max_head_attempts,
    )


def test_a_lost_slot_is_retried_and_reported() raises:
    var backend = Backend()
    var a = Plain(backend.clone(), "kg", RetryPolicy.fast_test())
    var b = Plain(backend.clone(), "kg", RetryPolicy.fast_test())
    assert_equal(a.write_snapshot(_one(1, 2), 4), 0)
    assert_equal(a.last_write_lost_races(), 0)
    # b is a second writer on the same lineage; it takes slot 1 from under a.
    assert_equal(b.write_snapshot(_one(10, 3), 4), 1)
    assert_equal(b.last_write_lost_races(), 0)

    assert_equal(a.write_snapshot(_one(20, 4), 4), 2)
    assert_equal(a.last_write_lost_races(), 1)
    assert_equal(a.lost_races(), 1)
    assert_equal(b.lost_races(), 0)

    # The next write wins first time and says so; the total stays.
    assert_equal(a.write_snapshot(_one(30, 1), 4), 3)
    assert_equal(a.last_write_lost_races(), 0)
    assert_equal(a.lost_races(), 1)

    var reader = Plain(backend.clone(), "kg")
    assert_equal(reader.latest_snapshot_id(), 3)
    assert_equal(reader.read_snapshot(0).row_count("entities"), 2)
    assert_equal(reader.read_snapshot(1).row_count("entities"), 3)
    assert_equal(reader.read_snapshot(2).row_count("entities"), 4)
    assert_equal(reader.read_snapshot(3).row_count("entities"), 1)


def test_a_chain_head_beaten_to_its_slot_is_rebuilt_over_the_rivals() raises:
    var backend = Backend()
    var rival = ArcPointer[_Rival](_Rival())
    var a = _contended(backend, rival)
    assert_equal(a.write_snapshot(_one(1, 2), 4), 0)

    # The rival appends a delta (chunk 1)...
    var raw = Raw(backend.clone(), "kg/manifest")
    var rival_delta = KgDeltaBody()
    rival_delta.add_index_entry("rival", 7)
    assert_equal(raw.append(rival_delta.encode(), 0).chunk_seq, 1)
    # ...and a's delta lands at chunk 2 (a lost slot on the way), so a's chain
    # head goes to slot 3, where the rival's chain head {base 0, delta 1} gets
    # there first.
    rival[].armed_key = _slot(3)
    rival[].envelope = encode_chunk(KgChainBody(0, [Int64(1)]).encode(), 1)

    assert_equal(a.append_delta(_one(10, 1), _index("mine", 8)), 4)
    assert_equal(rival[].stolen, 1)
    # The delta's slot and the chain head's slot were each lost once.
    assert_equal(a.last_write_lost_races(), 2)

    var chain = a.open_latest_chain()
    assert_equal(chain.id(), 4)
    assert_equal(chain.base_id(), 0)
    assert_equal(chain.num_deltas(), 2)
    assert_equal(chain.delta_seqs[0], 1)  # the rival's delta is kept
    assert_equal(chain.delta_seqs[1], 2)
    assert_equal(chain.resolve_name_index("rival"), 7)
    assert_equal(chain.resolve_name_index("mine"), 8)


def test_the_chain_follows_the_order_the_heads_land_not_the_ingest_order() raises:
    var backend = Backend()
    var rival = ArcPointer[_Rival](_Rival())
    var a = _contended(backend, rival)
    assert_equal(a.write_snapshot(_one(1, 2), 4), 0)

    # a's delta (name "k" -> 5) is chunk 1. The rival's delta (name "k" -> 6) takes
    # a's chain-head slot 2, so a is behind it; then the rival's chain head,
    # which names only its own delta, takes slot 3 before a's head can.
    var rival_delta = KgDeltaBody()
    rival_delta.add_index_entry("k", 6)
    rival[].armed_key = _slot(2)
    rival[].envelope = encode_chunk(rival_delta.encode(), 0)
    rival[].second_key = _slot(3)
    rival[].second_envelope = encode_chunk(KgChainBody(0, [Int64(2)]).encode(), 1)

    assert_equal(a.append_delta(_one(10, 1), _index("k", 5)), 4)
    assert_equal(rival[].stolen, 2)

    var chain = a.open_latest_chain()
    assert_equal(chain.num_deltas(), 2)
    # The rival's delta was ingested second and sits first; nothing is lost.
    assert_equal(chain.delta_seqs[0], 2)
    assert_equal(chain.delta_seqs[1], 1)
    # "Later wins" follows the chain, so the entry ingested first wins.
    assert_equal(chain.resolve_name_index("k"), 5)


def test_a_compaction_beaten_to_its_slot_carries_the_rivals_delta() raises:
    var backend = Backend()
    var rival = ArcPointer[_Rival](_Rival())
    var a = _contended(backend, rival)
    assert_equal(a.write_snapshot(_one(1, 2), 4), 0)
    assert_equal(a.append_delta(_one(10, 1), _index("mine", 8)), 2)
    # The compactor reads the chain, folds it and writes the pending base.
    var pinned = a.open_latest_chain()
    assert_equal(pinned.num_deltas(), 1)
    var new_base = a.write_base_tables(_one(1, 3), 4)
    assert_equal(new_base, 3)

    # While it was folding, the rival appended a delta (chunk 4) and published
    # the chain head {base 0, deltas 1 and 4} at slot 5 just before the
    # compactor's own chain head.
    var raw = Raw(backend.clone(), "kg/manifest")
    var rival_delta = KgDeltaBody()
    rival_delta.add_index_entry("rival", 7)
    assert_equal(raw.append(rival_delta.encode(), 0).chunk_seq, 4)
    rival[].armed_key = _slot(5)
    rival[].envelope = encode_chunk(
        KgChainBody(0, [Int64(1), Int64(4)]).encode(), 2
    )

    var head = a.commit_compacted_head(
        new_base, pinned.base_id(), pinned.delta_seqs.copy()
    )
    assert_equal(head, 6)
    assert_equal(a.last_write_lost_races(), 1)
    var chain = a.open_latest_chain()
    assert_equal(chain.base_id(), 3)
    assert_equal(chain.num_deltas(), 1)
    assert_equal(chain.delta_seqs[0], 4)  # the rival's delta, carried forward
    assert_equal(chain.resolve_name_index("rival"), 7)
    assert_equal(chain.resolve_name_index("mine"), -1)  # folded into the base


def test_a_base_write_that_loses_every_slot_stops_and_publishes_nothing() raises:
    var backend = Backend()
    var rival = ArcPointer[_Rival](_Rival())
    rival[].always = True
    rival[].envelope = encode_chunk(KgDeltaBody().encode(), 1)
    var retry = RetryPolicy(Int64(1), Int64(1), 3)
    var a = _contended(backend, rival, retry)

    with assert_raises(contains="exhausted 3 retries"):
        _ = a.write_snapshot(_one(1, 2), 4)
    # One put per attempt: the first and three retries. No more.
    assert_equal(rival[].chunk_puts, 4)
    assert_equal(rival[].stolen, 4)
    assert_equal(a.lost_races(), 4)
    assert_equal(a.last_write_lost_races(), 4)
    # The error is the retryable kind, and nothing became the head.
    with assert_raises(contains="(retryable)"):
        _ = a.write_snapshot(_one(1, 2), 4)
    assert_equal(a.latest_snapshot_id(), -1)


def test_a_delta_that_loses_every_chain_head_stops_after_its_attempts() raises:
    var backend = Backend()
    var rival = ArcPointer[_Rival](_Rival())
    var a = _contended(backend, rival, RetryPolicy.fast_test(), 3)
    assert_equal(a.write_snapshot(_one(1, 2), 4), 0)

    # Let the delta chunk through, then beat every chain head to its slot with
    # a chain head of the base alone.
    rival[].always = True
    rival[].skip = 1
    rival[].envelope = encode_chunk(KgChainBody(0).encode(), 0)
    rival[].chunk_puts = 0

    with assert_raises(
        contains="lost the race for the chain head 3 times (retryable)"
    ):
        _ = a.append_delta(_one(10, 1), _index("mine", 8))
    # The delta chunk, then one chain head per attempt. No more.
    assert_equal(rival[].chunk_puts, 4)
    assert_equal(rival[].stolen, 3)
    assert_equal(a.last_write_lost_races(), 3)

    # The head is the rival's, and the delta that was written is not on it.
    var chain = a.resolve_head_chain()
    assert_equal(chain.base_seq, 0)
    assert_equal(chain.num_deltas(), 0)
    assert_equal(a.open_latest_chain().resolve_name_index("mine"), -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
