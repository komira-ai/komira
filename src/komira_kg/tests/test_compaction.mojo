# =============================================================================
# test_compaction.mojo -- folding a delta chain into a base (an in-memory object
#   store; no network, no wall clock, no environment: every time is an argument).
# =============================================================================
#
#   same graph    a base and three deltas (new rows, an edited entity, closed
#                 edges) read back, after the fold, as exactly the rows they
#                 merged to before it; the head is then a base with only an
#                 index delta, which holds no graph table.
#   pinned        a chain opened before the fold still loads to the same rows
#                 after it, and every object it names (base tables and delta
#                 objects) is still in the store: a fold deletes nothing.
#   retirement    each folded delta is stamped with the caller's time and no
#                 other chunk is; a delta carried over is not.
#   idempotent    folding a compact chain writes nothing, and neither does a
#                 base alone; an empty lineage is refused. A second fold after
#                 more deltas works and retires the first bootstrap delta.
#   carry         a delta appended after the head that is folded stays on the new
#                 head, is not retired, and wins over the bootstrap index for
#                 the names and node ids it speaks for.
#   second fold   a fold of a head whose base another fold already replaced is
#                 refused and changes nothing.
#   policy        maybe_compact_chain folds only when the count leg trips.
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
    compact_chain,
    compact_chain_at,
    maybe_compact_chain,
    open_edge,
    resolve_embedding_topk,
)
from komira_kg_format import CompactionPolicy, KgSnapshotStore
from komira_objectstore.path import Path
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
    return WorkingEntity(nid, "u-" + String(nid), part, name, _vec(a, b), "", "{}")


def _append(mut kg: Kg, ws: SnapshotWorkingSet) raises:
    _ = kg.append_delta(ws.delta_tables(), ws.name_index_delta())


def _lineage(mut kg: Kg) raises:
    """A base and three deltas."""
    var ws = SnapshotWorkingSet(DIM)
    var a = ws.next_nid()
    var b = ws.next_nid()
    ws.add_entity(_ent(a, "alpha", "p1", 1.0, 0.0))
    ws.add_entity(_ent(b, "beta", "p2", 0.0, 1.0))
    ws.add_edge(open_edge(a, b, "", "alpha beta v1", 10, 20, 10))
    ws.append_episode(WorkingEpisode("ep-1", "p1", "first", 20, 10, "k"))
    _ = kg.write_snapshot(ws.to_tables(), DIM)

    var d1 = SnapshotWorkingSet.load_latest(kg)
    var c = d1.next_nid()
    d1.add_entity(_ent(c, "gamma", "p1", 1.0, 1.0))
    d1.add_edge(open_edge(a, c, "", "alpha gamma", 30, 40, 30))
    d1.append_episode(WorkingEpisode("ep-2", "p2", "second", 40, 30))
    d1.edges[0].invalid_at = 30
    d1.edges[0].expired_at = 40
    _append(kg, d1)

    var d2 = SnapshotWorkingSet.load_latest(kg)
    d2.entities[1].summary = "beta, edited"
    d2.add_entity(_ent(d2.next_nid(), "delta", "p2", -1.0, 0.0))
    _append(kg, d2)

    var d3 = SnapshotWorkingSet.load_latest(kg)
    d3.edges[1].invalid_at = 50
    d3.edges[1].expired_at = 60
    d3.append_episode(WorkingEpisode("ep-3", "p1", "third", 60, 50))
    _append(kg, d3)


def _same(a: SnapshotWorkingSet, b: SnapshotWorkingSet) raises:
    assert_equal(a.embedding_dim, b.embedding_dim)
    assert_equal(len(a.entities), len(b.entities))
    for i in range(len(a.entities)):
        assert_equal(a.entities[i].nid, b.entities[i].nid)
        assert_equal(a.entities[i].uuid, b.entities[i].uuid)
        assert_equal(a.entities[i].partition_id, b.entities[i].partition_id)
        assert_equal(a.entities[i].name, b.entities[i].name)
        assert_equal(a.entities[i].summary, b.entities[i].summary)
        assert_equal(a.entities[i].attrs, b.entities[i].attrs)
        for k in range(DIM):
            assert_equal(
                a.entities[i].name_embedding[k], b.entities[i].name_embedding[k]
            )
    assert_equal(len(a.edges), len(b.edges))
    for i in range(len(a.edges)):
        assert_equal(a.edges[i].src_nid, b.edges[i].src_nid)
        assert_equal(a.edges[i].dst_nid, b.edges[i].dst_nid)
        assert_equal(a.edges[i].fact, b.edges[i].fact)
        assert_equal(a.edges[i].valid_at, b.edges[i].valid_at)
        assert_equal(a.edges[i].invalid_at, b.edges[i].invalid_at)
        assert_equal(a.edges[i].expired_at, b.edges[i].expired_at)
        assert_equal(a.edges[i].created_at, b.edges[i].created_at)
    assert_equal(len(a.episodes), len(b.episodes))
    for i in range(len(a.episodes)):
        assert_equal(a.episodes[i].uuid, b.episodes[i].uuid)
        assert_equal(a.episodes[i].partition_id, b.episodes[i].partition_id)
        assert_equal(a.episodes[i].body, b.episodes[i].body)
        assert_equal(a.episodes[i].ts, b.episodes[i].ts)


def _is_retired(kg: Kg, seq: Int64) raises -> Bool:
    try:
        _ = kg.retired_age_ms(seq, 0)
        return True
    except:
        return False


def test_a_mutation_then_compaction_reads_back_identically() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var before = SnapshotWorkingSet.load_latest(kg)
    assert_equal(kg.open_latest_chain().num_deltas(), 3)
    var old_head = kg.head_seq()

    var result = compact_chain(kg, 9000)
    assert_true(result.compacted)
    assert_equal(result.num_folded, 3)
    assert_equal(result.num_carried, 0)
    assert_true(result.new_base_seq > old_head)
    assert_equal(result.new_head_seq, kg.head_seq())

    _same(before, SnapshotWorkingSet.load_latest(kg))
    var chain = kg.open_latest_chain()
    assert_equal(chain.base_id(), result.new_base_seq)
    # Only the index delta is left, and it holds no graph table.
    assert_equal(chain.num_deltas(), 1)
    assert_false(chain.deltas[0].has_table("entities"))
    assert_false(chain.deltas[0].has_table("edges"))
    assert_false(chain.deltas[0].has_table("episodes"))
    assert_false(chain.deltas[0].has_table("edges_tombstone"))
    assert_true(chain.deltas[0].has_table("entities_embedding"))
    # The index covers every entity, so the base need not be read for a name.
    assert_equal(chain.resolve_name_index("alpha"), 0)
    assert_equal(chain.resolve_name_index("delta"), 3)
    # And so does the projection: the nearest to alpha's vector is alpha.
    var near = resolve_embedding_topk(chain, _vec(1.0, 0.0), 4)
    assert_equal(len(near), 4)
    assert_equal(near[0].nid, 0)
    assert_equal(near[0].score, 1.0)


def test_a_pinned_chain_still_reads_and_every_object_it_names_stays() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var before = SnapshotWorkingSet.load_latest(kg)
    var pinned = kg.open_latest_chain()

    _ = compact_chain(kg, 9000)

    _same(before, SnapshotWorkingSet.load_merged(pinned))
    for i in range(pinned.base.num_tables()):
        _ = kg.objects_ref().head(Path.parse(pinned.base.body.tables[i].object_key))
    for d in range(pinned.num_deltas()):
        for t in range(pinned.deltas[d].num_tables()):
            _ = kg.objects_ref().head(
                Path.parse(pinned.deltas[d].tables[t].object_key)
            )
    # The old base is a snapshot of its own, readable by its id.
    var old_base = SnapshotWorkingSet.load_from(kg.read_snapshot(pinned.base_id()))
    assert_equal(len(old_base.entities), 2)
    assert_equal(len(old_base.edges), 1)


def test_each_folded_delta_is_stamped_with_the_callers_time() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var folded = kg.open_latest_chain().delta_seqs.copy()
    assert_equal(len(folded), 3)
    _ = compact_chain(kg, 9000)
    for i in range(len(folded)):
        assert_equal(kg.retired_age_ms(folded[i], 9000), 0)
        assert_equal(kg.retired_age_ms(folded[i], 9750), 750)
    # The bootstrap delta, the base and the chain heads are not retired.
    var chain = kg.open_latest_chain()
    assert_false(_is_retired(kg, chain.delta_seqs[0]))
    assert_false(_is_retired(kg, chain.base_id()))


def test_a_compact_chain_and_a_base_alone_are_not_folded_again() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    _ = compact_chain(kg, 9000)
    var head = kg.head_seq()
    var again = compact_chain(kg, 9100)
    assert_false(again.compacted)
    assert_equal(again.new_head_seq, head)
    assert_equal(again.new_base_seq, -1)
    assert_equal(again.num_folded, 0)
    assert_equal(kg.head_seq(), head)

    var alone = Kg(Backend(), "h")
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_ent(ws.next_nid(), "alpha", "p1", 1.0, 0.0))
    var base = alone.write_snapshot(ws.to_tables(), DIM)
    var none = compact_chain(alone, 9000)
    assert_false(none.compacted)
    assert_equal(none.new_head_seq, base)
    assert_equal(alone.head_seq(), base)

    var empty = Kg(Backend(), "e")
    with assert_raises(contains="empty lineage"):
        _ = compact_chain(empty, 9000)


def test_a_second_fold_after_more_deltas_retires_the_first_bootstrap() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    _ = compact_chain(kg, 9000)
    var boot = kg.open_latest_chain().delta_seqs[0]

    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.add_entity(_ent(ws.next_nid(), "epsilon", "p1", 0.0, -1.0))
    _append(kg, ws)
    var before = SnapshotWorkingSet.load_latest(kg)
    assert_equal(kg.open_latest_chain().num_deltas(), 2)

    var result = compact_chain(kg, 12000)
    assert_true(result.compacted)
    assert_equal(result.num_folded, 2)
    _same(before, SnapshotWorkingSet.load_latest(kg))
    assert_equal(kg.retired_age_ms(boot, 12500), 500)
    var chain = kg.open_latest_chain()
    assert_equal(chain.num_deltas(), 1)
    assert_equal(chain.resolve_name_index("epsilon"), 4)


def test_a_delta_appended_after_the_folded_head_is_carried_and_wins() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var pinned_head = kg.head_seq()

    # A writer renames and re-embeds entity 0 after the head the fold started
    # from, and adds two.
    var late = SnapshotWorkingSet.load_latest(kg)
    late.entities[0].name = "alpha prime"
    late.entities[0].name_embedding = _vec(0.0, -1.0)
    late.add_entity(_ent(late.next_nid(), "zeta", "p1", 5.0, 5.0))
    # And a second entity whose normalized name is one the fold also holds.
    late.add_entity(_ent(late.next_nid(), "BETA", "p2", 0.5, 0.5))
    _append(kg, late)
    var carried_seq = kg.open_latest_chain().delta_seqs[3]

    var result = compact_chain_at(kg, pinned_head, 9000)
    assert_true(result.compacted)
    assert_equal(result.num_folded, 3)
    assert_equal(result.num_carried, 1)

    # The late rows are in the live graph, once.
    var live = SnapshotWorkingSet.load_latest(kg)
    assert_equal(len(live.entities), 6)
    assert_equal(live.entities[0].name, "alpha prime")
    assert_equal(live.entities[0].name_embedding[1], -1.0)
    var chain = kg.open_latest_chain()
    assert_equal(chain.num_deltas(), 2)
    assert_equal(chain.delta_seqs[0], carried_seq)
    # It is not retired; the folded ones are.
    assert_false(_is_retired(kg, carried_seq))
    # The bootstrap comes after the carried delta on the chain, and still does
    # not override it: the renamed entity resolves to its new vector, and the
    # name it took is the carried delta's.
    assert_equal(chain.resolve_name_index("alpha prime"), 0)
    assert_equal(chain.resolve_name_index("beta"), 5)  # not the folded entity 1
    assert_equal(chain.resolve_name_index("gamma"), 2)  # unchanged names remain
    var near = resolve_embedding_topk(chain, _vec(0.0, -1.0), 1)
    assert_equal(near[0].nid, 0)
    assert_equal(near[0].score, 1.0)
    var all = resolve_embedding_topk(chain, _vec(0.0, -1.0), 10)
    var seen = 0
    for i in range(len(all)):
        if all[i].nid == 0:
            seen += 1
    assert_equal(seen, 1)


def test_a_fold_of_a_head_another_fold_replaced_is_refused() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var head = kg.head_seq()
    _ = compact_chain_at(kg, head, 9000)
    var after = kg.head_seq()
    var live = SnapshotWorkingSet.load_latest(kg)
    with assert_raises(contains="another compaction committed first"):
        _ = compact_chain_at(kg, head, 9500)
    assert_equal(kg.head_seq(), after)
    _same(live, SnapshotWorkingSet.load_latest(kg))


def test_maybe_compact_folds_only_when_the_policy_trips() raises:
    var kg = Kg(Backend(), "g")
    var empty = maybe_compact_chain(kg, CompactionPolicy(2, Int64(0), Int64(0)), 9000)
    assert_false(empty.compacted)
    assert_equal(empty.new_head_seq, -1)

    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_ent(ws.next_nid(), "alpha", "p1", 1.0, 0.0))
    _ = kg.write_snapshot(ws.to_tables(), DIM)
    var count_only = CompactionPolicy(2, Int64(0), Int64(0))
    assert_false(maybe_compact_chain(kg, count_only, 9000).compacted)  # base alone

    var one = SnapshotWorkingSet.load_latest(kg)
    one.add_entity(_ent(one.next_nid(), "beta", "p1", 0.0, 1.0))
    _append(kg, one)
    var head = kg.head_seq()
    var held = maybe_compact_chain(kg, count_only, 9000)
    assert_false(held.compacted)  # one delta, the limit is two
    assert_equal(held.new_head_seq, head)
    assert_equal(kg.head_seq(), head)

    var two = SnapshotWorkingSet.load_latest(kg)
    two.add_entity(_ent(two.next_nid(), "gamma", "p1", 1.0, 1.0))
    _append(kg, two)
    var before = SnapshotWorkingSet.load_latest(kg)
    var fired = maybe_compact_chain(kg, count_only, 9000)
    assert_true(fired.compacted)
    assert_equal(fired.num_folded, 2)
    _same(before, SnapshotWorkingSet.load_latest(kg))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
