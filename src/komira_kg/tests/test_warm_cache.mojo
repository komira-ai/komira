# =============================================================================
# test_warm_cache.mojo -- the merged graph kept in memory, keyed by the head (an
#   in-memory object store; no network, no wall clock, no environment).
# =============================================================================
#
#   cold          a new cache is not warm and has no key; reading an empty
#                 lineage is refused.
#   hit           a second get at an unchanged head lends the resident set (an
#                 edit made through the first borrow is still there), keyed at
#                 the head.
#   miss          the head moving by a delta from another handle (read through a
#                 fresh handle), by a fold and
#                 by an erasure each make the next get merge again: the edit is
#                 gone and the new rows are there. invalidate does the same.
#   single writer take_current on a cold cache merges the head; after commit the
#                 next take_current returns the resident set (with an unpersisted
#                 edit that a reload would not have), and its embeddings are the
#                 f32-narrowed ones a reload gives. A head another writer moved
#                 is merged again, so the foreign delta is never lost. An empty
#                 lineage gives an empty set of the stated dimension. The cache
#                 is empty between take_current and commit.
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
    WarmMergedCache,
    WorkingEntity,
    compact_chain,
    erase_kg_partition,
)
from komira_kg_format import KgSnapshotStore
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime Cache = WarmMergedCache[SharedInMemoryConditionalStore]
comptime DIM = 2


def _vec(a: Float64, b: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    return v^


def _ent(nid: Int64, name: String, part: String, a: Float64, b: Float64) -> WorkingEntity:
    return WorkingEntity(nid, "u-" + String(nid), part, name, _vec(a, b), "", "{}")


def _seed(mut kg: Kg) raises:
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_ent(ws.next_nid(), "alpha", "p1", 1.0, 0.0))
    ws.add_entity(_ent(ws.next_nid(), "beta", "p2", 0.0, 1.0))
    _ = kg.write_snapshot(ws.to_tables(), DIM)


def _add(mut kg: Kg, name: String, part: String) raises -> Int64:
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.add_entity(_ent(ws.next_nid(), name, part, 1.0, 1.0))
    _ = kg.append_delta(ws.delta_tables(), ws.name_index_delta())
    return kg.head_seq()


def test_a_new_cache_is_cold_and_an_empty_lineage_is_refused() raises:
    var cache = Cache()
    assert_false(cache.is_warm())
    assert_equal(cache.cached_head_seq(), -1)
    var kg = Kg(Backend(), "g")
    with assert_raises(contains="empty lineage"):
        _ = cache.get(kg).num_entities()
    assert_false(cache.is_warm())


def test_a_get_at_an_unchanged_head_lends_the_resident_set() raises:
    var kg = Kg(Backend(), "g")
    _seed(kg)
    var cache = Cache()
    assert_equal(cache.get(kg).num_entities(), 2)
    assert_true(cache.is_warm())
    assert_equal(cache.cached_head_seq(), kg.head_seq())
    cache.get(kg).entities[0].summary = "resident edit"
    assert_equal(cache.get(kg).entities[0].summary, "resident edit")
    assert_equal(SnapshotWorkingSet.load_latest(kg).entities[0].summary, "")


def test_a_foreign_delta_makes_the_next_get_merge_again() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "g")
    _seed(kg)
    var cache = Cache()
    cache.get(kg).entities[0].summary = "resident edit"

    var other = Kg(backend.clone(), "g")
    var head = _add(other, "gamma", "p1")
    # A handle that has not read the head before lists it; a handle that has
    # may only see its own commits (see the cache's header).
    var reader = Kg(backend.clone(), "g")
    assert_equal(cache.get(reader).num_entities(), 3)
    assert_equal(cache.get(reader).entities[0].summary, "")
    assert_equal(cache.cached_head_seq(), head)


def test_a_fold_and_an_erasure_make_the_next_get_merge_again() raises:
    var kg = Kg(Backend(), "g")
    _seed(kg)
    _ = _add(kg, "gamma", "p1")
    var cache = Cache()
    cache.get(kg).entities[0].summary = "resident edit"
    var before = cache.cached_head_seq()

    _ = compact_chain(kg, 1000)
    assert_equal(cache.get(kg).entities[0].summary, "")
    assert_equal(cache.get(kg).num_entities(), 3)
    assert_true(cache.cached_head_seq() > before)

    cache.get(kg).entities[0].summary = "resident edit"
    _ = erase_kg_partition(kg, "p1", 2000)
    assert_equal(cache.get(kg).num_entities(), 1)
    assert_equal(cache.get(kg).entities[0].name, "beta")
    assert_equal(cache.cached_head_seq(), kg.head_seq())


def test_invalidate_drops_the_resident_set() raises:
    var kg = Kg(Backend(), "g")
    _seed(kg)
    var cache = Cache()
    cache.get(kg).entities[0].summary = "resident edit"
    cache.invalidate()
    assert_false(cache.is_warm())
    assert_equal(cache.cached_head_seq(), -1)
    assert_equal(cache.get(kg).entities[0].summary, "")


def test_a_single_writer_commits_and_takes_its_own_set_back() raises:
    var kg = Kg(Backend(), "g")
    _seed(kg)
    var cache = Cache()

    var ws = cache.take_current(kg, DIM)
    assert_false(cache.is_warm())
    assert_equal(ws.num_entities(), 2)
    # 0.1 is not exact in f32: the resident vector must be what a reload holds.
    var inexact = _vec(0.1, 0.2)
    ws.add_entity(WorkingEntity(ws.next_nid(), "u-new", "p1", "gamma", inexact^, "", "{}"))
    _ = kg.append_delta(ws.delta_tables(), ws.name_index_delta())
    cache.commit(ws^, kg.head_seq())
    assert_true(cache.is_warm())
    assert_equal(cache.cached_head_seq(), kg.head_seq())

    var resident = cache.take_current(kg, DIM)
    var reloaded = SnapshotWorkingSet.load_latest(kg)
    assert_false(resident.has_delta())
    assert_equal(resident.num_entities(), 3)
    assert_equal(resident.entities[2].name_embedding[0], reloaded.entities[2].name_embedding[0])
    assert_equal(resident.entities[2].name_embedding[1], reloaded.entities[2].name_embedding[1])
    assert_true(resident.entities[2].name_embedding[0] != 0.1)
    # The next id continues past the largest.
    assert_equal(resident.next_nid(), 3)

    # What came back is the resident set: an edit the store does not hold
    # survives a commit at the same head and the next take.
    resident.entities[0].summary = "unpersisted"
    cache.commit(resident^, kg.head_seq())
    var again = cache.take_current(kg, DIM)
    assert_equal(again.entities[0].summary, "unpersisted")
    assert_equal(SnapshotWorkingSet.load_latest(kg).entities[0].summary, "")


def test_a_head_another_writer_moved_is_merged_again_and_loses_nothing() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "g")
    _seed(kg)
    var cache = Cache()
    var ws = cache.take_current(kg, DIM)
    cache.commit(ws^, kg.head_seq())

    var other = Kg(backend.clone(), "g")
    _ = _add(other, "foreign", "p2")

    var reader = Kg(backend.clone(), "g")
    var taken = cache.take_current(reader, DIM)
    assert_equal(taken.num_entities(), 3)
    assert_equal(taken.entities[2].name, "foreign")
    assert_false(cache.is_warm())


def test_an_empty_lineage_gives_an_empty_set_of_the_stated_dimension() raises:
    var kg = Kg(Backend(), "g")
    var cache = Cache()
    var ws = cache.take_current(kg, 5)
    assert_equal(ws.embedding_dim, 5)
    assert_equal(ws.num_entities(), 0)
    with assert_raises(contains="dimension must be positive"):
        _ = cache.take_current(kg, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
