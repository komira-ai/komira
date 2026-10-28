# =============================================================================
# test_working_set_delta.mojo -- a base plus deltas merges to the rows a full
#   rewrite would hold, and a delta carries only what changed (an in-memory
#   object store; no network, no clock, no environment).
# =============================================================================
#
#   keystone      after a base and two deltas (new entity, new edge, new episode,
#                 an edge closed, an existing entity edited), load_latest equals
#                 the working set that made them, and equals a reload of a full
#                 snapshot of the same set.
#   delta shape   a delta holds only the changed rows: the added and edited
#                 entities with their embedding projection, the appended edges,
#                 one tombstone per closed edge and the appended episodes; an
#                 unchanged set has no delta and has_delta is false.
#   framing       a delta of a few rows is stored framed and one of
#                 FRAMED_MAX_ROWS rows or more as Parquet; both merge the same.
#   later wins    a delta entity replaces the loaded row of the same node id.
#   name index    name_index_delta names the added and edited entities only, and
#                 full_name_index every entity; the chain resolves a name from
#                 the index without loading the base.
#   projection    full_embedding_projection holds one row per entity.
#   high water    the node ids minted after a reload continue past the largest.
#   edge keys     two edges between the same nodes created at different times are
#                 closed independently. Two edges that share (src, dst, created_at)
#                 cannot be told apart by a tombstone: a delta that would close one
#                 of two open ones is refused (write a base instead), a base keeps
#                 both closures exactly, and a delta can close the one open edge of
#                 a shared key.
#   twins         a delta cannot close an edge when an open twin of its key is
#                 appended by the same delta; a later delta can close the
#                 twin of an edge an earlier delta closed, and the chain equals
#                 the full rewrite.
#   diff views    added_entity_indices names the entities not loaded and
#                 edited_entity_indices the loaded ones whose row changed.
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
    WorkingEdge,
    WorkingEntity,
    WorkingEpisode,
    apply_invalidation,
    open_edge,
)
from komira_kg_format import (
    FRAMED_MAX_ROWS,
    KgSnapshotStore,
    TS_OPEN_SENTINEL,
    delta_object_is_framed,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime DIM = 3


def _vec(seed: Int) -> List[Float64]:
    var v = List[Float64]()
    v.append(0.0)
    v.append(Float64(seed) * 0.25)
    v.append(1.0 - Float64(seed) * 0.5)
    return v^


def _ent(nid: Int64, name: String, seed: Int) -> WorkingEntity:
    return WorkingEntity(nid, "u-" + String(nid), "part", name, _vec(seed), "", "{}")


def _base_set() raises -> SnapshotWorkingSet:
    var ws = SnapshotWorkingSet(DIM)
    var a = ws.next_nid()
    var b = ws.next_nid()
    ws.add_entity(_ent(a, "alpha", 1))
    ws.add_entity(_ent(b, "beta", 2))
    ws.add_edge(open_edge(a, b, "", "alpha beta v1", 10, 20, 10))
    ws.add_edge(open_edge(a, b, "", "alpha beta v2", 30, 40, 30))
    ws.append_episode(WorkingEpisode("ep-1", "part", "first", 20, 10, "k"))
    return ws^


def _same(a: SnapshotWorkingSet, b: SnapshotWorkingSet) raises:
    assert_equal(len(a.entities), len(b.entities))
    for i in range(len(a.entities)):
        assert_equal(a.entities[i].nid, b.entities[i].nid)
        assert_equal(a.entities[i].name, b.entities[i].name)
        assert_equal(a.entities[i].summary, b.entities[i].summary)
        for k in range(DIM):
            assert_equal(
                a.entities[i].name_embedding[k], b.entities[i].name_embedding[k]
            )
    assert_equal(len(a.edges), len(b.edges))
    for i in range(len(a.edges)):
        assert_equal(a.edges[i].fact, b.edges[i].fact)
        assert_equal(a.edges[i].created_at, b.edges[i].created_at)
        assert_equal(a.edges[i].invalid_at, b.edges[i].invalid_at)
        assert_equal(a.edges[i].expired_at, b.edges[i].expired_at)
    assert_equal(len(a.episodes), len(b.episodes))
    for i in range(len(a.episodes)):
        assert_equal(a.episodes[i].uuid, b.episodes[i].uuid)
        assert_equal(a.episodes[i].body, b.episodes[i].body)
        assert_equal(a.episodes[i].facet, b.episodes[i].facet)


def _append(mut kg: Kg, ws: SnapshotWorkingSet) raises:
    _ = kg.append_delta(ws.delta_tables(), ws.name_index_delta())


def test_base_and_two_deltas_equal_a_full_rewrite() raises:
    var kg = Kg(Backend(), "g")
    var base = _base_set()
    _ = kg.write_snapshot(base.to_tables(), DIM)

    # Delta 1: a new entity, edge and episode; the older edge is superseded.
    var ws = SnapshotWorkingSet.load_latest(kg)
    var c = ws.next_nid()
    ws.add_entity(_ent(c, "gamma", 3))
    var newer = open_edge(0, c, "", "alpha gamma", 50, 60, 50)
    ws.add_edge(newer.copy())
    ws.append_episode(WorkingEpisode("ep-2", "part", "second", 60, 50))
    assert_true(ws.has_delta())
    ws.edges[0].invalid_at = 30
    ws.edges[0].expired_at = 60
    _append(kg, ws)

    # Delta 2: an existing entity edited, a second edge closed.
    var ws2 = SnapshotWorkingSet.load_latest(kg)
    _same(ws, ws2)
    ws2.entities[1].summary = "beta, edited"
    ws2.edges[1].invalid_at = 55
    ws2.edges[1].expired_at = 70
    _append(kg, ws2)

    var merged = SnapshotWorkingSet.load_latest(kg)
    _same(ws2, merged)
    assert_equal(merged.entities[1].summary, "beta, edited")
    assert_equal(merged.edges[0].invalid_at, 30)
    assert_equal(merged.edges[1].expired_at, 70)
    assert_equal(merged.edges[2].invalid_at, TS_OPEN_SENTINEL)

    # A full snapshot of the same set reloads to the same rows.
    var kg2 = Kg(Backend(), "g")
    _ = kg2.write_snapshot(ws2.to_tables(), DIM)
    _same(merged, SnapshotWorkingSet.load_latest(kg2))


def test_delta_carries_only_what_changed() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)

    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_false(ws.has_delta())
    assert_equal(len(ws.delta_tables()), 0)
    assert_equal(ws.name_index_delta().num_entries(), 0)

    ws.append_episode(WorkingEpisode("ep-2", "part", "second", 60, 50))
    assert_true(ws.has_delta())
    var only_episode = ws.delta_tables()
    assert_equal(len(only_episode), 1)
    assert_equal(only_episode[0].name, "episodes")

    ws.edges[1].invalid_at = 35
    ws.edges[1].expired_at = 45
    ws.add_entity(_ent(ws.next_nid(), "gamma", 3))
    var tables = ws.delta_tables()
    var names = List[String]()
    for i in range(len(tables)):
        names.append(tables[i].name)
    assert_equal(len(names), 4)
    assert_equal(names[0], "entities")
    assert_equal(names[1], "entities_embedding")
    assert_equal(names[2], "edges_tombstone")
    assert_equal(names[3], "episodes")
    # One entity row (not the two loaded ones), one tombstone (not both edges).
    assert_equal(tables[0].batch.value().num_rows(), 1)
    assert_equal(tables[1].batch.value().num_rows(), 1)
    assert_equal(tables[2].batch.value().num_rows(), 1)
    assert_equal(tables[3].batch.value().num_rows(), 1)


def test_small_delta_is_framed_and_large_is_parquet() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)

    var small = SnapshotWorkingSet.load_latest(kg)
    small.add_entity(_ent(small.next_nid(), "small", 1))
    _append(kg, small)

    var large = SnapshotWorkingSet.load_latest(kg)
    for i in range(FRAMED_MAX_ROWS):
        large.add_entity(_ent(large.next_nid(), "bulk-" + String(i), i % 7))
    _append(kg, large)

    var chain = kg.open_latest_chain()
    assert_equal(chain.num_deltas(), 2)
    assert_true(delta_object_is_framed(chain.delta_object_bytes(0, "entities")))
    assert_false(delta_object_is_framed(chain.delta_object_bytes(1, "entities")))
    var merged = SnapshotWorkingSet.load_latest(kg)
    _same(large, merged)
    assert_equal(len(merged.entities), 2 + 1 + FRAMED_MAX_ROWS)


def test_later_delta_entity_replaces_the_loaded_row() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.entities[0].name = "alpha, renamed"
    ws.entities[0].name_embedding = _vec(5)
    _append(kg, ws)
    var back = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(back.entities), 2)
    assert_equal(back.entities[0].name, "alpha, renamed")
    assert_equal(back.entities[0].name_embedding[1], 1.25)
    assert_equal(back.entities[1].name, "beta")


def test_name_index_covers_added_and_edited_entities() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.entities[1].name = "Beta Prime"
    ws.add_entity(_ent(ws.next_nid(), "Gamma", 3))
    var delta = ws.name_index_delta()
    assert_equal(delta.num_entries(), 2)
    assert_equal(delta.entries[0].normalized_name, "beta prime")
    assert_equal(delta.entries[0].nid, 1)
    assert_equal(delta.entries[1].normalized_name, "gamma")
    assert_equal(delta.entries[1].nid, 2)
    assert_equal(ws.full_name_index().num_entries(), 3)
    _append(kg, ws)
    var chain = kg.open_latest_chain()
    assert_equal(chain.resolve_name_index("gamma"), 2)
    assert_equal(chain.resolve_name_index("beta prime"), 1)
    # A name written before the first delta is in no index.
    assert_equal(chain.resolve_name_index("alpha"), -1)


def test_full_embedding_projection_has_a_row_per_entity() raises:
    var ws = _base_set()
    var batch = ws.full_embedding_projection()
    assert_equal(batch.num_rows(), 2)
    assert_equal(batch.num_columns(), 2)
    var nids = batch.column_as_primitive_int64(0)
    assert_equal(nids.get(0), 0)
    assert_equal(nids.get(1), 1)


def test_ids_continue_after_a_reload() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.add_entity(_ent(ws.next_nid(), "gamma", 3))
    _append(kg, ws)
    var again = SnapshotWorkingSet.load_latest(kg)
    assert_equal(again.next_nid(), 3)
    assert_equal(again.next_nid(), 4)


def test_edges_between_the_same_nodes_close_independently() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    # Close only the second of the two edges (created at 40).
    var verdict = open_edge(0, 1, "", "alpha beta v3", 90, 100, 90)
    apply_invalidation(ws.edges[1], verdict, 100)
    _append(kg, ws)
    var back = SnapshotWorkingSet.load_latest(kg)
    assert_equal(back.edges[0].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(back.edges[1].invalid_at, 90)
    assert_equal(back.edges[1].expired_at, 100)


def _twin_set() raises -> SnapshotWorkingSet:
    """Two entities and two edges that share the key (0, 1, 10)."""
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_ent(ws.next_nid(), "alpha", 1))
    ws.add_entity(_ent(ws.next_nid(), "beta", 2))
    ws.add_edge(open_edge(0, 1, "", "twin one", 10, 10, 10))
    ws.add_edge(open_edge(0, 1, "", "twin two", 20, 10, 20))
    return ws^


def test_two_open_edges_with_one_key_cannot_be_closed_by_a_delta() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_twin_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.edges[1].invalid_at = 30
    ws.edges[1].expired_at = 40
    with assert_raises(contains="to_tables"):
        _ = ws.delta_tables()
    # The same change as a full base is exact.
    var kg2 = Kg(Backend(), "g")
    _ = kg2.write_snapshot(ws.to_tables(), DIM)
    var back = SnapshotWorkingSet.load_latest(kg2)
    assert_equal(back.edges[0].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(back.edges[1].invalid_at, 30)
    assert_equal(back.edges[1].expired_at, 40)


def test_full_rewrite_keeps_two_same_key_closures_at_different_times() raises:
    var ws = _twin_set()
    ws.edges[0].invalid_at = 50
    ws.edges[0].expired_at = 60
    ws.edges[1].invalid_at = 70
    ws.edges[1].expired_at = 80
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(ws.to_tables(), DIM)
    var back = SnapshotWorkingSet.load_latest(kg)
    _same(ws, back)
    assert_equal(back.edges[0].fact, "twin one")
    assert_equal(back.edges[0].invalid_at, 50)
    assert_equal(back.edges[0].expired_at, 60)
    assert_equal(back.edges[1].fact, "twin two")
    assert_equal(back.edges[1].invalid_at, 70)
    assert_equal(back.edges[1].expired_at, 80)


def test_a_delta_closes_the_one_open_edge_of_a_shared_key() raises:
    var base = _twin_set()
    base.edges[0].invalid_at = 15
    base.edges[0].expired_at = 16
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(base.to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.edges[1].invalid_at = 30
    ws.edges[1].expired_at = 40
    _append(kg, ws)
    var back = SnapshotWorkingSet.load_latest(kg)
    _same(ws, back)
    assert_equal(back.edges[0].invalid_at, 15)
    assert_equal(back.edges[0].expired_at, 16)
    assert_equal(back.edges[1].invalid_at, 30)
    assert_equal(back.edges[1].expired_at, 40)


def test_added_and_edited_entity_indices() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(ws.added_entity_indices()), 0)
    assert_equal(len(ws.edited_entity_indices()), 0)

    ws.entities[1].summary = "beta, edited"
    ws.add_entity(_ent(ws.next_nid(), "gamma", 3))
    ws.add_entity(_ent(ws.next_nid(), "delta", 4))
    var added = ws.added_entity_indices()
    assert_equal(len(added), 2)
    assert_equal(added[0], 2)
    assert_equal(added[1], 3)
    var edited = ws.edited_entity_indices()
    assert_equal(len(edited), 1)
    assert_equal(edited[0], 1)

    # An edit changed back to the loaded value is no edit.
    ws.entities[1].summary = ""
    assert_equal(len(ws.edited_entity_indices()), 0)
    # An embedding edit counts.
    ws.entities[0].name_embedding = _vec(6)
    var again = ws.edited_entity_indices()
    assert_equal(len(again), 1)
    assert_equal(again[0], 0)


def test_a_set_with_an_appended_edge_has_a_delta() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_false(ws.has_delta())
    ws.add_edge(open_edge(0, 1, "", "alpha beta v3", 50, 60, 50))
    assert_true(ws.has_delta())
    assert_equal(len(ws.tombstone_edge_indices()), 0)
    assert_false(ws.delta_cannot_say_closures())


def test_a_closure_of_a_lone_key_is_no_reason_for_a_base() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.edges[0].invalid_at = 50
    ws.edges[0].expired_at = 60
    assert_false(ws.delta_cannot_say_closures())
    _ = ws.delta_tables()
    # A shrunk list is an error of its own, not a closure ambiguity.
    var shrunk = SnapshotWorkingSet.load_latest(kg)
    _ = shrunk.edges.pop()
    assert_false(shrunk.delta_cannot_say_closures())
    with assert_raises(contains="the edge list shrank"):
        _ = shrunk.delta_tables()


def test_an_edge_closed_and_an_open_twin_appended_needs_a_base() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_base_set().to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    # Edge 0 has the key (0, 1, 20). Close it and append an open twin of it:
    # when the delta applies, both would be open under that key.
    ws.edges[0].invalid_at = 50
    ws.edges[0].expired_at = 60
    ws.add_edge(open_edge(0, 1, "", "alpha beta twin", 55, 20, 55))
    assert_true(ws.delta_cannot_say_closures())
    with assert_raises(contains="shares its key with 1 other edge(s)"):
        _ = ws.delta_tables()
    # The full rewrite keeps all three edges exactly.
    var kg2 = Kg(Backend(), "g")
    _ = kg2.write_snapshot(ws.to_tables(), DIM)
    var back = SnapshotWorkingSet.load_latest(kg2)
    _same(ws, back)
    assert_equal(back.edges[0].invalid_at, 50)
    assert_equal(back.edges[2].invalid_at, TS_OPEN_SENTINEL)


def test_a_later_delta_may_close_a_twin_of_a_closed_edge() raises:
    # Base: one edge. Delta 1 closes it. Delta 2 adds an open twin with the
    # same key. Delta 3 closes the twin.
    var kg = Kg(Backend(), "g")
    var base = SnapshotWorkingSet(DIM)
    base.add_entity(_ent(base.next_nid(), "alpha", 1))
    base.add_entity(_ent(base.next_nid(), "beta", 2))
    base.add_edge(open_edge(0, 1, "", "first", 10, 10, 10))
    _ = kg.write_snapshot(base.to_tables(), DIM)

    var d1 = SnapshotWorkingSet.load_latest(kg)
    d1.edges[0].invalid_at = 15
    d1.edges[0].expired_at = 16
    _append(kg, d1)

    var d2 = SnapshotWorkingSet.load_latest(kg)
    d2.add_edge(open_edge(0, 1, "", "twin", 20, 10, 20))
    _append(kg, d2)

    var d3 = SnapshotWorkingSet.load_latest(kg)
    d3.edges[1].invalid_at = 30
    d3.edges[1].expired_at = 40
    _append(kg, d3)

    var chain = SnapshotWorkingSet.load_latest(kg)
    # The same graph written as one full rewrite.
    var kg2 = Kg(Backend(), "g")
    _ = kg2.write_snapshot(d3.to_tables(), DIM)
    var full = SnapshotWorkingSet.load_latest(kg2)
    _same(chain, full)
    assert_equal(len(chain.edges), 2)
    assert_equal(chain.edges[0].fact, "first")
    assert_equal(chain.edges[0].invalid_at, 15)
    assert_equal(chain.edges[0].expired_at, 16)
    assert_equal(chain.edges[1].fact, "twin")
    assert_equal(chain.edges[1].invalid_at, 30)
    assert_equal(chain.edges[1].expired_at, 40)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
