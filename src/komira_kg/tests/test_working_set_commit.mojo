# =============================================================================
# test_working_set_commit.mojo -- a working set declared persisted keeps going
#   (an in-memory object store; no network, no wall clock, no environment).
# =============================================================================
#
#   narrowing     after mark_committed the vectors of the entities added or
#                 edited since the load are the f32-narrowed ones a reload of
#                 the written delta gives; a vector already exact in f32 is
#                 unchanged.
#   new baseline  the set then has no delta, and a later edit's delta carries
#                 that edit alone.
#   ids           the node-id high-water mark is kept when the highest entity
#                 was removed.
#   refusals      a vector of another length or with a non-finite component.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg import SnapshotWorkingSet, WorkingEntity
from komira_kg_format import KgSnapshotStore
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


def _ent(nid: Int64, name: String, a: Float64, b: Float64) -> WorkingEntity:
    return WorkingEntity(nid, "u-" + String(nid), "p", name, _vec(a, b), "", "{}")


def _seeded() raises -> Kg:
    var kg = Kg(Backend(), "g")
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_ent(ws.next_nid(), "alpha", 0.5, 0.25))
    ws.add_entity(_ent(ws.next_nid(), "beta", 0.75, 0.125))
    _ = kg.write_snapshot(ws.to_tables(), DIM)
    return kg^


def test_added_and_edited_vectors_are_narrowed_to_what_a_reload_holds() raises:
    var kg = _seeded()
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.entities[0].name_embedding = _vec(0.1, 0.2)  # edited, not exact in f32
    ws.add_entity(_ent(ws.next_nid(), "gamma", 0.3, 0.5))  # added
    assert_equal(ws.entities[0].name_embedding[0], 0.1)
    _ = kg.append_delta(ws.delta_tables(), ws.name_index_delta())

    ws.mark_committed()
    var reloaded = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(ws.entities), len(reloaded.entities))
    for i in range(len(ws.entities)):
        for k in range(DIM):
            assert_equal(
                ws.entities[i].name_embedding[k],
                reloaded.entities[i].name_embedding[k],
            )
    assert_true(ws.entities[0].name_embedding[0] != 0.1)
    assert_equal(ws.entities[0].name_embedding[0], Float64(Float32(0.1)))
    assert_equal(ws.entities[1].name_embedding[0], 0.75)  # exact in f32, untouched


def test_after_mark_committed_the_next_delta_is_relative_to_it() raises:
    var kg = _seeded()
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.add_entity(_ent(ws.next_nid(), "gamma", 0.25, 0.5))
    ws.entities[1].summary = "edited"
    _ = kg.append_delta(ws.delta_tables(), ws.name_index_delta())
    assert_true(ws.has_delta())
    ws.mark_committed()
    assert_false(ws.has_delta())
    assert_equal(len(ws.delta_tables()), 0)
    assert_equal(ws.name_index_delta().num_entries(), 0)

    ws.entities[0].summary = "edited again"
    assert_true(ws.has_delta())
    var delta = ws.delta_tables()
    assert_equal(len(delta), 2)  # the entity row and its projection
    assert_equal(ws.name_index_delta().num_entries(), 1)
    _ = kg.append_delta(delta^, ws.name_index_delta())
    var back = SnapshotWorkingSet.load_latest(kg)
    assert_equal(back.entities[0].summary, "edited again")
    assert_equal(back.entities[1].summary, "edited")
    assert_equal(len(back.entities), 3)


def test_the_node_id_high_water_mark_is_kept() raises:
    var kg = _seeded()
    var ws = SnapshotWorkingSet.load_latest(kg)
    var kept = List[WorkingEntity]()
    kept.append(ws.entities[0].copy())
    ws.entities = kept^  # the highest id (1) is gone
    ws.mark_committed()
    assert_equal(ws.next_nid(), 2)


def test_a_vector_of_another_length_or_not_finite_is_refused() raises:
    var kg = _seeded()
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.entities[0].name_embedding = _vec(0.5, 0.25)
    var long = _vec(0.5, 0.25)
    long.append(1.0)
    ws.entities[1].name_embedding = long^
    ws.entities[1].summary = "edited"
    with assert_raises(contains="3 components but the graph's dimension is 2"):
        ws.mark_committed()

    var big = SnapshotWorkingSet.load_latest(kg)
    big.entities[0].name_embedding = _vec(1.0e300, 0.0)  # beyond f32
    with assert_raises(contains="is not a finite f32"):
        big.mark_committed()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
