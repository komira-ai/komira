# =============================================================================
# test_erase.mojo -- erasing one partition (an in-memory object store; no
#   network, no wall clock, no environment).
# =============================================================================
#
#   working set   erase_partition drops the partition's entities and episodes and
#                 every edge with one of its entities as an endpoint (either
#                 end), keeps every other row field for field, reports the
#                 counts, and does not lower the node-id high-water mark. An
#                 absent partition removes nothing. A set that erased a loaded
#                 entity cannot be written as a delta.
#   the head      after erase_kg_partition on a base with three deltas (an
#                 added entity, an edited one, a closed edge, so the chain holds
#                 an embedding projection, a name index and a tombstone), the
#                 head holds no entity, episode or edge of the partition, no
#                 closure of its edges, none of its name-index entries and none
#                 of its embeddings in the projection; the other partition's
#                 rows, closures, names and embeddings are all there.
#   whole lineage erasing the only partition leaves a readable, empty graph of
#                 the same dimension, not an error and not the old head.
#   episodes only a partition with episodes and no entity is erased.
#   idempotent    a second erasure and an erasure of an absent partition write
#                 nothing.
#   retirement    the deltas of the old chain are stamped with the caller's time.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg import (
    SnapshotWorkingSet,
    WorkingEntity,
    WorkingEpisode,
    erase_kg_partition,
    erase_partition,
    open_edge,
    resolve_embedding_topk,
)
from komira_kg_format import KgSnapshotStore, TS_OPEN_SENTINEL
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime DIM = 2


def _vec(a: Float64, b: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    return v^


def _ent(nid: Int64, name: String, part: String, a: Float64, b: Float64) -> WorkingEntity:
    return WorkingEntity(nid, "u-" + String(nid), part, name, _vec(a, b), "s", "{}")


def _set() raises -> SnapshotWorkingSet:
    """Entities 0, 1 (partition x), 2, 3 (partition y); edges between every
    kind of pair; episodes of both."""
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_ent(ws.next_nid(), "xa", "x", 1.0, 0.0))
    ws.add_entity(_ent(ws.next_nid(), "xb", "x", 1.0, 1.0))
    ws.add_entity(_ent(ws.next_nid(), "ya", "y", 0.0, 1.0))
    ws.add_entity(_ent(ws.next_nid(), "yb", "y", -1.0, 1.0))
    ws.add_edge(open_edge(0, 1, "", "x to x", 1, 2, 1))
    ws.add_edge(open_edge(0, 2, "", "x to y", 1, 2, 1))
    ws.add_edge(open_edge(2, 1, "", "y to x", 1, 2, 1))
    ws.add_edge(open_edge(2, 3, "", "y to y", 1, 2, 1))
    ws.append_episode(WorkingEpisode("ep-x", "x", "about x", 5, 4))
    ws.append_episode(WorkingEpisode("ep-y", "y", "about y", 6, 4))
    return ws^


def test_erase_partition_drops_its_rows_and_the_edges_touching_them() raises:
    var ws = _set()
    var report = erase_partition(ws, "x")
    assert_equal(report.entities, 2)
    assert_equal(report.edges, 3)
    assert_equal(report.episodes, 1)
    assert_false(report.is_empty())

    assert_equal(len(ws.entities), 2)
    assert_equal(ws.entities[0].nid, 2)
    assert_equal(ws.entities[0].name, "ya")
    assert_equal(ws.entities[0].name_embedding[1], 1.0)
    assert_equal(ws.entities[1].nid, 3)
    assert_equal(ws.entities[1].partition_id, "y")
    assert_equal(len(ws.edges), 1)
    assert_equal(ws.edges[0].fact, "y to y")
    assert_equal(ws.edges[0].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(len(ws.episodes), 1)
    assert_equal(ws.episodes[0].uuid, "ep-y")
    # Ids are not reused inside the set.
    assert_equal(ws.next_nid(), 4)


def test_erasing_a_partition_the_set_does_not_hold_removes_nothing() raises:
    var ws = _set()
    var report = erase_partition(ws, "absent")
    assert_true(report.is_empty())
    assert_equal(len(ws.entities), 4)
    assert_equal(len(ws.edges), 4)
    assert_equal(len(ws.episodes), 2)


def test_a_set_that_erased_a_loaded_entity_cannot_be_a_delta() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    # Nothing but entities removed: the edge and episode lists do not shrink.
    var kept = List[WorkingEntity]()
    kept.append(ws.entities[0].copy())
    ws.entities = kept^
    with assert_raises(contains="was removed since the load"):
        _ = ws.delta_tables()
    # A full snapshot is the way to write it.
    assert_equal(len(ws.to_tables()), 3)


def _lineage(mut kg: Kg) raises:
    var base = SnapshotWorkingSet(DIM)
    base.add_entity(_ent(base.next_nid(), "xa", "x", 1.0, 0.0))
    base.add_entity(_ent(base.next_nid(), "ya", "y", 0.0, 1.0))
    base.add_edge(open_edge(0, 1, "", "x to y", 1, 2, 1))
    base.append_episode(WorkingEpisode("ep-x1", "x", "about x", 5, 4))
    base.append_episode(WorkingEpisode("ep-y1", "y", "about y", 6, 4))
    _ = kg.write_snapshot(base.to_tables(), DIM)

    var d1 = SnapshotWorkingSet.load_latest(kg)
    d1.add_entity(_ent(d1.next_nid(), "xb", "x", 1.0, 1.0))
    d1.add_entity(_ent(d1.next_nid(), "yb", "y", -1.0, 1.0))
    d1.add_edge(open_edge(2, 3, "", "x to y again", 3, 4, 3))
    d1.add_edge(open_edge(3, 1, "", "y to y", 3, 4, 3))
    d1.append_episode(WorkingEpisode("ep-x2", "x", "more x", 8, 7))
    _ = kg.append_delta(d1.delta_tables(), d1.name_index_delta())

    var d2 = SnapshotWorkingSet.load_latest(kg)
    d2.entities[1].summary = "ya, edited"
    d2.edges[0].invalid_at = 10  # the x-to-y edge closes
    d2.edges[0].expired_at = 11
    d2.edges[2].invalid_at = 12  # a y-to-y edge closes
    d2.edges[2].expired_at = 13
    _ = kg.append_delta(d2.delta_tables(), d2.name_index_delta())


def test_the_head_holds_nothing_of_an_erased_partition() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var folded = kg.open_latest_chain().delta_seqs.copy()
    var chain_before = kg.open_latest_chain()
    assert_true(chain_before.deltas[1].has_table("edges_tombstone"))
    assert_equal(chain_before.resolve_name_index("xb"), 2)

    var report = erase_kg_partition(kg, "x", 7000)
    assert_equal(report.entities, 2)
    assert_equal(report.edges, 2)
    assert_equal(report.episodes, 2)

    var live = SnapshotWorkingSet.load_latest(kg)
    assert_equal(live.embedding_dim, DIM)
    assert_equal(len(live.entities), 2)
    for i in range(len(live.entities)):
        assert_equal(live.entities[i].partition_id, "y")
    assert_equal(live.entities[0].name, "ya")
    assert_equal(live.entities[0].summary, "ya, edited")
    assert_equal(live.entities[1].name, "yb")
    assert_equal(len(live.episodes), 1)
    assert_equal(live.episodes[0].uuid, "ep-y1")
    # Only the y-to-y edge is left, with its closure.
    assert_equal(len(live.edges), 1)
    assert_equal(live.edges[0].fact, "y to y")
    assert_equal(live.edges[0].invalid_at, 12)
    assert_equal(live.edges[0].expired_at, 13)

    # No tombstone is left on the chain, and no object of the old chain.
    var chain = kg.open_latest_chain()
    for d in range(chain.num_deltas()):
        assert_false(chain.deltas[d].has_table("edges_tombstone"))
        assert_false(chain.deltas[d].has_table("entities"))
    # The name index and the embedding projection hold the survivors only.
    assert_equal(chain.resolve_name_index("xa"), -1)
    assert_equal(chain.resolve_name_index("xb"), -1)
    assert_equal(chain.resolve_name_index("ya"), 1)
    assert_equal(chain.resolve_name_index("yb"), 3)
    var near = resolve_embedding_topk(chain, _vec(1.0, 1.0), 10)
    assert_equal(len(near), 2)
    for i in range(len(near)):
        assert_true(near[i].nid == 1 or near[i].nid == 3)
    # The old chain's deltas are retired with the caller's time.
    for i in range(len(folded)):
        assert_equal(kg.retired_age_ms(folded[i], 7500), 500)


def test_erasing_the_only_partition_leaves_an_empty_readable_graph() raises:
    var kg = Kg(Backend(), "g")
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_ent(ws.next_nid(), "xa", "x", 1.0, 0.0))
    ws.add_entity(_ent(ws.next_nid(), "xb", "x", 0.0, 1.0))
    ws.add_edge(open_edge(0, 1, "", "x to x", 1, 2, 1))
    ws.append_episode(WorkingEpisode("ep-x", "x", "about x", 5, 4))
    _ = kg.write_snapshot(ws.to_tables(), DIM)
    var old_head = kg.head_seq()

    var report = erase_kg_partition(kg, "x", 7000)
    assert_equal(report.entities, 2)
    assert_true(kg.head_seq() > old_head)
    var live = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(live.entities), 0)
    assert_equal(len(live.edges), 0)
    assert_equal(len(live.episodes), 0)
    assert_equal(live.embedding_dim, DIM)
    # The empty graph still takes new rows.
    live.add_entity(_ent(live.next_nid(), "fresh", "z", 1.0, 0.0))
    _ = kg.append_delta(live.delta_tables(), live.name_index_delta())
    assert_equal(len(SnapshotWorkingSet.load_latest(kg).entities), 1)


def test_a_partition_with_episodes_and_no_entity_is_erased() raises:
    var kg = Kg(Backend(), "g")
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_ent(ws.next_nid(), "ya", "y", 1.0, 0.0))
    ws.append_episode(WorkingEpisode("ep-x", "x", "about x", 5, 4))
    ws.append_episode(WorkingEpisode("ep-y", "y", "about y", 6, 4))
    _ = kg.write_snapshot(ws.to_tables(), DIM)

    var report = erase_kg_partition(kg, "x", 7000)
    assert_equal(report.entities, 0)
    assert_equal(report.episodes, 1)
    var live = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(live.episodes), 1)
    assert_equal(live.episodes[0].uuid, "ep-y")
    assert_equal(len(live.entities), 1)


def test_a_second_erasure_and_an_absent_partition_write_nothing() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    _ = erase_kg_partition(kg, "x", 7000)
    var head = kg.head_seq()
    var again = erase_kg_partition(kg, "x", 7100)
    assert_true(again.is_empty())
    assert_equal(kg.head_seq(), head)
    var absent = erase_kg_partition(kg, "never", 7200)
    assert_true(absent.is_empty())
    assert_equal(kg.head_seq(), head)


def test_an_empty_lineage_cannot_be_erased() raises:
    var kg = Kg(Backend(), "g")
    with assert_raises(contains="empty lineage"):
        _ = erase_kg_partition(kg, "x", 7000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
