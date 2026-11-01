# =============================================================================
# test_rewrite_repair.mojo -- a rewrite (a fold or an erasure) that stops after
#   its head commit, and a writer that appends before its bootstrap (an
#   in-memory object store; no network, no wall clock, no environment).
# =============================================================================
#
# `compact_commit_at` and `erase_commit_at` stop where a crash would: the new base
# is the head and no index delta follows. `finish_rewrite` is the rest.
#
#   crash, fold   after a fold that stopped, a repeated `compact_chain` writes no
#                 base and appends the bootstrap: the graph, the names and the
#                 nearest entities equal an uninterrupted fold's, and a third
#                 call writes nothing.
#   crash, erase  the same for an erasure: the repeated call reports nothing to
#                 erase and appends the bootstrap.
#   writer first  a writer delta that lands between the commit and the bootstrap
#                 wins over it: its rename and its re-embedding are what a
#                 lookup returns, once.
#   replaced      if another fold replaced the base before the bootstrap, no
#                 bootstrap is appended and the folded deltas are still retired.
#   not current   a repair of a head that is not the head now does nothing.
#   nothing left  erasing the only partition twice writes nothing the second time
#                 (a base with no entity has nothing to index).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from komira_kg import (
    ErasureReport,
    SnapshotWorkingSet,
    WorkingEntity,
    WorkingEpisode,
    compact_chain,
    compact_commit_at,
    erase_commit_at,
    erase_kg_partition,
    finish_rewrite,
    open_edge,
    repair_missing_bootstrap,
    resolve_embedding_topk,
)
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


def _ent(nid: Int64, name: String, part: String, a: Float64, b: Float64) -> WorkingEntity:
    return WorkingEntity(nid, "u-" + String(nid), part, name, _vec(a, b), "", "{}")


def _append(mut kg: Kg, ws: SnapshotWorkingSet) raises:
    _ = kg.append_delta(ws.delta_tables(), ws.name_index_delta())


def _lineage(mut kg: Kg) raises:
    """A base (alpha 0 of p1, beta 1 of p2) and three deltas (gamma 2 of p1,
    delta 3 of p2, edits and closures)."""
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


def _same_graph(a: SnapshotWorkingSet, b: SnapshotWorkingSet) raises:
    assert_equal(len(a.entities), len(b.entities))
    for i in range(len(a.entities)):
        assert_equal(a.entities[i].nid, b.entities[i].nid)
        assert_equal(a.entities[i].name, b.entities[i].name)
        assert_equal(a.entities[i].summary, b.entities[i].summary)
        assert_equal(a.entities[i].name_embedding[0], b.entities[i].name_embedding[0])
        assert_equal(a.entities[i].name_embedding[1], b.entities[i].name_embedding[1])
    assert_equal(len(a.edges), len(b.edges))
    for i in range(len(a.edges)):
        assert_equal(a.edges[i].fact, b.edges[i].fact)
        assert_equal(a.edges[i].invalid_at, b.edges[i].invalid_at)
    assert_equal(len(a.episodes), len(b.episodes))


def _same_index(a: Kg, b: Kg) raises:
    """The two heads resolve the same names and rank the same entities."""
    var ca = a.open_latest_chain()
    var cb = b.open_latest_chain()
    var names = List[String]()
    names.append("alpha")
    names.append("beta")
    names.append("gamma")
    names.append("delta")
    names.append("absent")
    for i in range(len(names)):
        assert_equal(ca.resolve_name_index(names[i]), cb.resolve_name_index(names[i]))
    var ra = resolve_embedding_topk(ca, _vec(1.0, 0.5), 10)
    var rb = resolve_embedding_topk(cb, _vec(1.0, 0.5), 10)
    assert_equal(len(ra), len(rb))
    for i in range(len(ra)):
        assert_equal(ra[i].nid, rb[i].nid)
        assert_equal(ra[i].score, rb[i].score)


def test_a_fold_that_stopped_after_its_commit_is_finished_by_a_retry() raises:
    var whole = Kg(Backend(), "g")
    _lineage(whole)
    _ = compact_chain(whole, 9000)

    var crashed = Kg(Backend(), "g")
    _lineage(crashed)
    var held = compact_commit_at(crashed, crashed.head_seq())
    assert_true(held.wrote())
    var committed = held.head
    # The head is the new base and nothing indexes it.
    assert_equal(crashed.head_seq(), committed)
    assert_equal(crashed.open_latest_chain().num_deltas(), 0)
    assert_equal(crashed.open_latest_chain().resolve_name_index("alpha"), -1)
    assert_equal(
        len(resolve_embedding_topk(crashed.open_latest_chain(), _vec(1.0, 0.0), 5)), 0
    )

    var again = compact_chain(crashed, 9500)
    assert_false(again.compacted)
    assert_equal(again.new_base_seq, -1)
    assert_true(again.new_head_seq > committed)
    assert_equal(again.new_head_seq, crashed.head_seq())
    _same_graph(
        SnapshotWorkingSet.load_latest(whole),
        SnapshotWorkingSet.load_latest(crashed),
    )
    _same_index(whole, crashed)
    assert_equal(crashed.open_latest_chain().num_deltas(), 1)

    var third = compact_chain(crashed, 9600)
    assert_false(third.compacted)
    assert_equal(third.new_head_seq, again.new_head_seq)
    assert_equal(crashed.head_seq(), again.new_head_seq)


def test_an_erasure_that_stopped_after_its_commit_is_finished_by_a_retry() raises:
    var whole = Kg(Backend(), "g")
    _lineage(whole)
    _ = erase_kg_partition(whole, "p1", 9000)

    var crashed = Kg(Backend(), "g")
    _lineage(crashed)
    var report = ErasureReport(0, 0, 0)
    var held = erase_commit_at(crashed, crashed.head_seq(), "p1", 4, report)
    assert_true(held.wrote())
    assert_equal(report.entities, 2)
    var committed = held.head
    assert_equal(crashed.open_latest_chain().num_deltas(), 0)
    assert_equal(crashed.open_latest_chain().resolve_name_index("beta"), -1)

    var again = erase_kg_partition(crashed, "p1", 9500)
    assert_true(again.is_empty())
    assert_true(crashed.head_seq() > committed)
    _same_graph(
        SnapshotWorkingSet.load_latest(whole),
        SnapshotWorkingSet.load_latest(crashed),
    )
    _same_index(whole, crashed)
    assert_equal(crashed.open_latest_chain().resolve_name_index("alpha"), -1)
    assert_equal(crashed.open_latest_chain().resolve_name_index("beta"), 1)

    var head = crashed.head_seq()
    assert_true(erase_kg_partition(crashed, "p1", 9600).is_empty())
    assert_equal(crashed.head_seq(), head)


def test_a_writer_between_the_commit_and_the_bootstrap_wins_over_it() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var held = compact_commit_at(kg, kg.head_seq())

    # Entity 0 is renamed and re-embedded after the head moved, before the
    # bootstrap is appended.
    var late = SnapshotWorkingSet.load_latest(kg)
    late.entities[0].name = "alpha prime"
    late.entities[0].name_embedding = _vec(0.0, -1.0)
    _append(kg, late)
    _ = finish_rewrite(kg, held^, 9000)

    var chain = kg.open_latest_chain()
    assert_equal(chain.num_deltas(), 2)
    assert_equal(chain.resolve_name_index("alpha prime"), 0)
    assert_equal(chain.resolve_name_index("beta"), 1)
    var all = resolve_embedding_topk(chain, _vec(0.0, -1.0), 10)
    assert_equal(len(all), 4)
    assert_equal(all[0].nid, 0)
    assert_equal(all[0].score, 1.0)
    var seen = 0
    for i in range(len(all)):
        if all[i].nid == 0:
            seen += 1
    assert_equal(seen, 1)


def test_a_fold_that_replaced_the_base_meanwhile_leaves_the_bootstrap_to_it() raises:
    var kg = Kg(Backend(), "g")
    _lineage(kg)
    var folded = kg.open_latest_chain().delta_seqs.copy()
    var held = compact_commit_at(kg, kg.head_seq())

    var late = SnapshotWorkingSet.load_latest(kg)
    late.add_entity(_ent(late.next_nid(), "omega", "p1", 0.0, 3.0))
    _append(kg, late)
    var second = compact_chain(kg, 9000)
    assert_true(second.compacted)
    var head = kg.head_seq()
    assert_equal(kg.open_latest_chain().num_deltas(), 1)

    var done = finish_rewrite(kg, held^, 9500)
    assert_equal(done, head)
    assert_equal(kg.head_seq(), head)
    assert_equal(kg.open_latest_chain().num_deltas(), 1)
    assert_equal(kg.open_latest_chain().resolve_name_index("omega"), 4)
    for i in range(len(folded)):
        assert_equal(kg.retired_age_ms(folded[i], 9500), 0)


def test_a_repair_of_a_head_that_is_not_the_head_now_does_nothing() raises:
    var kg = Kg(Backend(), "g")
    var base = SnapshotWorkingSet(DIM)
    base.add_entity(_ent(base.next_nid(), "alpha", "p1", 1.0, 0.0))
    var old = kg.write_snapshot(base.to_tables(), DIM)
    var next = SnapshotWorkingSet.load_latest(kg)
    next.add_entity(_ent(next.next_nid(), "beta", "p1", 0.0, 1.0))
    _append(kg, next)
    var head = kg.head_seq()
    assert_true(head > old)

    assert_equal(repair_missing_bootstrap(kg, old), old)
    assert_equal(kg.head_seq(), head)
    # The delta there carries an index, so the head itself needs no repair.
    assert_equal(repair_missing_bootstrap(kg, head), head)
    assert_equal(kg.head_seq(), head)


def test_erasing_the_only_partition_twice_writes_nothing_the_second_time() raises:
    var kg = Kg(Backend(), "g")
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_ent(ws.next_nid(), "alpha", "p1", 1.0, 0.0))
    _ = kg.write_snapshot(ws.to_tables(), DIM)
    assert_equal(erase_kg_partition(kg, "p1", 9000).entities, 1)
    var head = kg.head_seq()
    assert_true(erase_kg_partition(kg, "p1", 9100).is_empty())
    assert_equal(kg.head_seq(), head)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
