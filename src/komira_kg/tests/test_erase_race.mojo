# =============================================================================
# test_erase_race.mojo -- erasing a partition while a writer appends (an
#   in-memory object store; no network, no wall clock, no environment).
# =============================================================================
#
# A writer that read the graph before the erasure may append a delta after the
# erasure read its chain and before the erasure commits its head. `erase_kg_
# partition_at` is named a head, so a test appends after that head is read.
#
#   erased too    a concurrent delta that holds an entity, an edge to it, an
#                 episode and a tombstone of an edge of the erased partition
#                 leaves none of them on the head; the counts include them, the
#                 head still merges, and the delta's rows of another partition
#                 survive the fold.
#   kept intact   a concurrent delta that holds rows of another partition only
#                 stays on the chain as it is: not folded, not retired, and its
#                 names and embeddings still resolve.
#   index only    a concurrent delta that holds nothing but a name-index entry and
#                 a projection row of an erased node leaves neither on the head.
#   refused       a writer that still holds the partition's rows after the
#                 allowed commits makes the call raise, naming the partition and
#                 the count of rows; the head still merges, and a repeated call
#                 erases the rest.
#   counted once  an erased entity that a later delta edited is one entity in the
#                 report.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_collections.slab import Slab
from komira_kg import (
    ErasureReport,
    SnapshotWorkingSet,
    WorkingEntity,
    WorkingEpisode,
    erase_commit_at,
    erase_kg_partition,
    erase_kg_partition_at,
    open_edge,
    resolve_embedding_topk,
)
from komira_kg.working_codec import (
    TABLE_ENTITIES_EMBEDDING,
    build_embedding_projection_batch,
)
from komira_kg_format import (
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    SCHEMA_VERSION_ENTITIES_EMBEDDING,
)
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


def _lineage(mut kg: Kg) raises:
    """Entities 0 (xa) and 1 (ya) in the base, 2 (xb) and 3 (yb) in a delta; the
    edges (0,1), (2,3) and (3,1); the last of them and the first closed by a
    second delta."""
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
    d2.edges[0].invalid_at = 10
    d2.edges[0].expired_at = 11
    d2.edges[2].invalid_at = 12
    d2.edges[2].expired_at = 13
    _ = kg.append_delta(d2.delta_tables(), d2.name_index_delta())


def _contaminated_delta(mut kg: Kg, with_tombstone: Bool, with_y: Bool) raises:
    """What a writer holding the graph from before the erasure appends: a new
    x entity (node 4), an edge from it, an episode of x, optionally a closure of
    the open edge (2,3), and optionally a y entity (node 5) with an edge."""
    var late = SnapshotWorkingSet.load_latest(kg)
    late.add_entity(_ent(late.next_nid(), "xc", "x", 0.5, 0.5))
    late.add_edge(open_edge(4, 1, "", "x late", 20, 21, 20))
    late.append_episode(WorkingEpisode("ep-x3", "x", "late x", 30, 29))
    if with_tombstone:
        late.edges[1].invalid_at = 20
        late.edges[1].expired_at = 21
    if with_y:
        late.add_entity(_ent(late.next_nid(), "yc", "y", 0.0, 2.0))
        late.add_edge(open_edge(5, 3, "", "y late", 20, 21, 20))
    _ = kg.append_delta(late.delta_tables(), late.name_index_delta())


def _is_retired(kg: Kg, seq: Int64) raises -> Bool:
    try:
        _ = kg.retired_age_ms(seq, 0)
        return True
    except:
        return False


def test_a_concurrent_delta_with_the_erased_partitions_rows_is_erased_too() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var head = kg.head_seq()
    _contaminated_delta(kg, True, True)
    var late_seq = kg.open_latest_chain().delta_seqs[2]

    var report = erase_kg_partition_at(kg, head, "x", 8000)
    # xa, xb and the late xc; the edges (0,1), (2,3) and the late one; the two
    # episodes of x and the late one. The closure of (2,3) is not an edge.
    assert_equal(report.entities, 3)
    assert_equal(report.edges, 3)
    assert_equal(report.episodes, 3)

    # The head merges, and holds the y rows only, the late y rows included.
    var live = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(live.entities), 3)
    for i in range(len(live.entities)):
        assert_equal(live.entities[i].partition_id, "y")
    assert_equal(len(live.edges), 2)
    assert_equal(live.edges[0].fact, "y to y")
    assert_equal(live.edges[0].invalid_at, 12)
    assert_equal(live.edges[1].fact, "y late")
    assert_equal(len(live.episodes), 1)
    assert_equal(live.episodes[0].uuid, "ep-y1")

    var chain = kg.open_latest_chain()
    for d in range(chain.num_deltas()):
        assert_false(chain.deltas[d].has_table("entities"))
        assert_false(chain.deltas[d].has_table("edges"))
        assert_false(chain.deltas[d].has_table("episodes"))
        assert_false(chain.deltas[d].has_table("edges_tombstone"))
    assert_equal(chain.resolve_name_index("xa"), -1)
    assert_equal(chain.resolve_name_index("xc"), -1)
    assert_equal(chain.resolve_name_index("yc"), 5)
    var near = resolve_embedding_topk(chain, _vec(1.0, 1.0), 10)
    assert_equal(len(near), 3)
    for i in range(len(near)):
        assert_true(near[i].nid == 1 or near[i].nid == 3 or near[i].nid == 5)
    # The late delta was folded, so it is retired like the others.
    assert_equal(kg.retired_age_ms(late_seq, 8250), 250)


def test_a_concurrent_delta_of_another_partition_is_kept_intact() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var head = kg.head_seq()
    var late = SnapshotWorkingSet.load_latest(kg)
    late.add_entity(_ent(late.next_nid(), "yc", "y", 3.0, 0.5))
    late.add_edge(open_edge(4, 3, "", "y late", 20, 21, 20))
    late.append_episode(WorkingEpisode("ep-y2", "y", "late y", 30, 29))
    _ = kg.append_delta(late.delta_tables(), late.name_index_delta())
    var late_seq = kg.open_latest_chain().delta_seqs[2]

    var report = erase_kg_partition_at(kg, head, "x", 8000)
    assert_equal(report.entities, 2)
    assert_equal(report.edges, 2)
    assert_equal(report.episodes, 2)

    # The late delta is carried: on the chain as it was, before the bootstrap,
    # and not retired.
    var chain = kg.open_latest_chain()
    assert_equal(chain.num_deltas(), 2)
    assert_equal(chain.delta_seqs[0], late_seq)
    assert_true(chain.deltas[0].has_table("entities"))
    assert_true(chain.deltas[0].has_table("edges"))
    assert_true(chain.deltas[0].has_table("episodes"))
    assert_false(_is_retired(kg, late_seq))
    var live = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(live.entities), 3)
    assert_equal(live.entities[2].name, "yc")
    assert_equal(len(live.edges), 2)
    assert_equal(len(live.episodes), 2)
    assert_equal(chain.resolve_name_index("yc"), 4)
    assert_equal(chain.resolve_name_index("xb"), -1)
    var near = resolve_embedding_topk(chain, _vec(3.0, 0.5), 1)
    assert_equal(near[0].nid, 4)


def test_a_concurrent_name_and_projection_row_of_an_erased_node_are_removed() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var head = kg.head_seq()
    # A delta with no graph table: a name-index entry and a projection row for
    # node 0, which belongs to the erased partition.
    var held = List[WorkingEntity]()
    held.append(_ent(0, "xa", "x", 1.0, 0.0))
    var idxs = List[Int]()
    idxs.append(0)
    var tables = Slab[KgTable]()
    tables.append(
        KgTable(
            String(TABLE_ENTITIES_EMBEDDING),
            build_embedding_projection_batch(held, idxs, DIM),
            SCHEMA_VERSION_ENTITIES_EMBEDDING,
        )
    )
    var names = KgNameIndexBody()
    names.add("xa", 0)
    _ = kg.append_delta(tables^, names^)

    var report = erase_kg_partition_at(kg, head, "x", 8000)
    assert_equal(report.entities, 2)
    var chain = kg.open_latest_chain()
    assert_equal(chain.resolve_name_index("xa"), -1)
    assert_equal(chain.resolve_name_index("ya"), 1)
    var near = resolve_embedding_topk(chain, _vec(1.0, 0.0), 10)
    assert_equal(len(near), 2)
    for i in range(len(near)):
        assert_true(near[i].nid != 0)


def test_a_writer_that_keeps_adding_the_partition_makes_the_call_raise() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var head = kg.head_seq()
    _contaminated_delta(kg, False, False)

    var report = ErasureReport(0, 0, 0)
    with assert_raises(contains="partition 'x': 5 row(s)"):
        _ = erase_commit_at(kg, head, "x", 1, report)
    # The first commit stands and the head merges; the late rows are on it.
    var live = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(live.entities), 3)
    assert_equal(live.entities[2].name, "xc")

    # A repeated call finds them and erases them.
    var again = erase_kg_partition(kg, "x", 9000)
    assert_equal(again.entities, 1)
    assert_equal(again.edges, 1)
    assert_equal(again.episodes, 1)
    var clean = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(clean.entities), 2)
    assert_equal(kg.open_latest_chain().resolve_name_index("xc"), -1)


def test_an_erased_entity_that_a_later_delta_edited_is_counted_once() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var edit = SnapshotWorkingSet.load_latest(kg)
    edit.entities[0].summary = "xa, edited"
    _ = kg.append_delta(edit.delta_tables(), edit.name_index_delta())
    var report = erase_kg_partition(kg, "x", 8000)
    assert_equal(report.entities, 2)
    assert_equal(len(SnapshotWorkingSet.load_latest(kg).entities), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
