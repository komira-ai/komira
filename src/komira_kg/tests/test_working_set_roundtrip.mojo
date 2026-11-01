# =============================================================================
# test_working_set_roundtrip.mojo -- a working set written as a base snapshot
#   reads back identically (an in-memory object store; no network, no clock, no
#   environment).
# =============================================================================
#
#   read back     entities, edges and episodes written with to_tables and
#                 loaded again are equal field for field, including a zero
#                 embedding component (NUL bytes in the cell), a NUL byte inside
#                 an episode body and a fact, multi-byte text, the open-interval
#                 sentinel and a closed interval; the reload holds the manifest's
#                 dimension and the high-water mark.
#   dimensions    the same rows round-trip at embedding dimensions 2 and 5, and
#                 the set records the dimension it was made with.
#   subsets       a set with only entities writes only that table and loads with
#                 empty edges and episodes; an empty set writes no table.
#   consistency   a snapshot opened before a newer one is written still reads
#                 its own entities, edges and episodes (all three from one
#                 snapshot), and the newer one reads its own.
#   determinism   two sets built from the same inputs in two separate stores
#                 write the same table objects (the keys are content hashes):
#                 nothing in the write depends on a clock or a nonce.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_kg import (
    SnapshotWorkingSet,
    WorkingEdge,
    WorkingEntity,
    WorkingEpisode,
    open_edge,
)
from komira_kg_format import KgSnapshotStore, TS_OPEN_SENTINEL
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]


def _vec(dim: Int, seed: Int) -> List[Float64]:
    """A vector of `dim` components, each a multiple of 0.25 (exact in f32); the
    first component is 0.0 so the packed cell holds NUL bytes."""
    var v = List[Float64]()
    for i in range(dim):
        if i == 0:
            v.append(0.0)
        else:
            v.append(Float64(seed + i) * 0.25 - 1.0)
    return v^


def _filled(dim: Int) raises -> SnapshotWorkingSet:
    var ws = SnapshotWorkingSet(dim)
    var a = ws.next_nid()
    var b = ws.next_nid()
    var c = ws.next_nid()
    ws.add_entity(WorkingEntity(a, "ent-a", "part-1", "alpha", _vec(dim, 1), "first", "{}"))
    ws.add_entity(
        WorkingEntity(
            b, "ent-b", "part-1", "béta 中", _vec(dim, 2), "", "{\"facet\":\"x\"}"
        )
    )
    ws.add_entity(WorkingEntity(c, "ent-c", "part-2", "gamma", _vec(dim, 3), "third", "{}"))
    ws.add_edge(open_edge(a, b, "", "alpha relates to beta", 100, 110, 105, "src-1"))
    var closed = open_edge(b, c, "", "fact with a NUL " + chr(0) + " inside", 50, 60, 55)
    closed.invalid_at = 90
    closed.expired_at = 95
    ws.add_edge(closed^)
    ws.append_episode(WorkingEpisode("ep-1", "part-1", "body one", 110, 105, "kind-a"))
    ws.append_episode(WorkingEpisode("ep-2", "part-2", "body " + chr(0) + " two", 120, 115))
    return ws^


def _assert_same(a: SnapshotWorkingSet, b: SnapshotWorkingSet) raises:
    assert_equal(a.embedding_dim, b.embedding_dim)
    assert_equal(len(a.entities), len(b.entities))
    for i in range(len(a.entities)):
        ref x = a.entities[i]
        ref y = b.entities[i]
        assert_equal(x.nid, y.nid)
        assert_equal(x.uuid, y.uuid)
        assert_equal(x.partition_id, y.partition_id)
        assert_equal(x.name, y.name)
        assert_equal(x.summary, y.summary)
        assert_equal(x.attrs, y.attrs)
        assert_equal(len(x.name_embedding), len(y.name_embedding))
        for k in range(len(x.name_embedding)):
            assert_equal(x.name_embedding[k], y.name_embedding[k])
    assert_equal(len(a.edges), len(b.edges))
    for i in range(len(a.edges)):
        ref x = a.edges[i]
        ref y = b.edges[i]
        assert_equal(x.src_nid, y.src_nid)
        assert_equal(x.dst_nid, y.dst_nid)
        assert_equal(x.fact, y.fact)
        assert_equal(x.valid_at, y.valid_at)
        assert_equal(x.invalid_at, y.invalid_at)
        assert_equal(x.expired_at, y.expired_at)
        assert_equal(x.created_at, y.created_at)
        assert_equal(x.reference_time, y.reference_time)
        assert_equal(x.source, y.source)
    assert_equal(len(a.episodes), len(b.episodes))
    for i in range(len(a.episodes)):
        ref x = a.episodes[i]
        ref y = b.episodes[i]
        assert_equal(x.uuid, y.uuid)
        assert_equal(x.partition_id, y.partition_id)
        assert_equal(x.body, y.body)
        assert_equal(x.ts, y.ts)
        assert_equal(x.valid_at, y.valid_at)
        assert_equal(x.facet, y.facet)


def test_base_reads_back_identically() raises:
    var ws = _filled(3)
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(ws.to_tables(), ws.embedding_dim)
    var back = SnapshotWorkingSet.load_latest(kg)
    _assert_same(ws, back)
    assert_equal(back.embedding_dim, 3)
    # The text with a NUL byte came back whole, not cut at the NUL.
    assert_equal(back.edges[1].fact, "fact with a NUL " + chr(0) + " inside")
    assert_equal(back.episodes[1].body, "body " + chr(0) + " two")
    assert_equal(back.edges[0].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(back.edges[1].invalid_at, 90)
    # The high-water mark is rebuilt from the entities.
    assert_equal(back.next_nid(), 3)


def test_load_from_a_snapshot_view() raises:
    var ws = _filled(3)
    var kg = Kg(Backend(), "g")
    var id = kg.write_snapshot(ws.to_tables(), ws.embedding_dim)
    var back = SnapshotWorkingSet.load_from(kg.read_snapshot(id))
    _assert_same(ws, back)


def test_two_dimensions_round_trip() raises:
    var dims = List[Int]()
    dims.append(2)
    dims.append(5)
    for d in range(len(dims)):
        var ws = _filled(dims[d])
        var kg = Kg(Backend(), "g")
        _ = kg.write_snapshot(ws.to_tables(), ws.embedding_dim)
        var back = SnapshotWorkingSet.load_latest(kg)
        assert_equal(back.embedding_dim, dims[d])
        assert_equal(len(back.entities[0].name_embedding), dims[d])
        _assert_same(ws, back)


def test_only_entities_writes_only_that_table() raises:
    var ws = SnapshotWorkingSet(2)
    ws.add_entity(WorkingEntity(ws.next_nid(), "u", "p", "solo", _vec(2, 1), "", "{}"))
    var tables = ws.to_tables()
    assert_equal(len(tables), 1)
    var kg = Kg(Backend(), "g")
    var id = kg.write_snapshot(tables^, 2)
    var view = kg.read_snapshot(id)
    assert_equal(view.num_tables(), 1)
    var back = SnapshotWorkingSet.load_from(view)
    assert_equal(len(back.entities), 1)
    assert_equal(len(back.edges), 0)
    assert_equal(len(back.episodes), 0)


def test_empty_set_writes_no_table() raises:
    var ws = SnapshotWorkingSet(4)
    assert_equal(len(ws.to_tables()), 0)
    assert_equal(len(ws.delta_tables()), 0)


def test_snapshot_read_sees_one_consistent_set() raises:
    var first = _filled(3)
    var kg = Kg(Backend(), "g")
    var id1 = kg.write_snapshot(first.to_tables(), 3)
    var pinned = kg.read_snapshot(id1)

    var second = SnapshotWorkingSet(3)
    second.add_entity(WorkingEntity(second.next_nid(), "u9", "p9", "omega", _vec(3, 9), "", "{}"))
    second.add_edge(open_edge(0, 0, "", "self loop", 1, 2, 1))
    second.append_episode(WorkingEpisode("ep-9", "p9", "only episode", 3, 3))
    var id2 = kg.write_snapshot(second.to_tables(), 3)

    # The older snapshot still reads all three of its tables, none of the newer.
    var old = SnapshotWorkingSet.load_from(pinned)
    _assert_same(first, old)
    var new = SnapshotWorkingSet.load_from(kg.read_snapshot(id2))
    _assert_same(second, new)
    assert_equal(len(new.entities), 1)
    assert_equal(len(new.episodes), 1)


def test_same_inputs_write_the_same_objects() raises:
    var keys = List[String]()
    for _ in range(2):
        var ws = _filled(3)
        var kg = Kg(Backend(), "g")
        var id = kg.write_snapshot(ws.to_tables(), 3)
        var view = kg.read_snapshot(id)
        keys.append(
            view.object_key("entities")
            + "|"
            + view.object_key("edges")
            + "|"
            + view.object_key("episodes")
        )
    assert_equal(keys[0], keys[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
