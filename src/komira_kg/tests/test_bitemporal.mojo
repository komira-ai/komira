# =============================================================================
# test_bitemporal.mojo -- a replaced fact is closed, never erased.
# =============================================================================
#
#   candidates   an existing edge with the same node pair whose interval
#                overlaps the new edge's is flagged; a different pair, an edge
#                that ended before or exactly when the new one starts, and an
#                empty interval are not; the predicate counts only on request;
#                indices come back in order.
#   invalidation a confirmed supersession ends the old edge's event time at the
#                new edge's start and stamps the system time it was learned,
#                keeps the row and every other field, and reproduces both
#                "what held at E" and "what did the graph believe at S about E".
#   guards       applying a verdict twice, to an edge already closed earlier, or
#                with a new edge that starts before the old one, never widens or
#                inverts an interval and never rewrites when the edge first
#                expired.
#   open edge    a new edge is open on both axes and carries what it is given.
#   sentinel     an end at a large finite timestamp is closed; only
#                TS_OPEN_SENTINEL is open.
# No test reads a clock: every `now` is an argument.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_kg import (
    WorkingEdge,
    apply_invalidation,
    open_edge,
    overlapping_contradiction_candidates,
)
from komira_kg_format import TS_OPEN_SENTINEL

comptime _A: Int64 = 1
comptime _B: Int64 = 3
comptime _FACT_OLD: String = "node 1 relates to node 3 by method A"
comptime _FACT_NEW: String = "node 1 relates to node 3 by method B"


def _old_open() -> WorkingEdge:
    """Learned at system time 100, holding from event time 100, still open."""
    return open_edge(_A, _B, "", _FACT_OLD, valid_at=100, now=100, reference_time=100)


def _new_open() -> WorkingEdge:
    """Holding from event time 300, learned at system time 500."""
    return open_edge(_A, _B, "", _FACT_NEW, valid_at=300, now=500, reference_time=300)


def _live_at_event(edges: List[WorkingEdge], t: Int64) -> List[String]:
    """The facts whose stored event interval covers `t`."""
    var out = List[String]()
    for i in range(len(edges)):
        ref e = edges[i]
        if e.valid_at <= t and e.invalid_at > t:
            out.append(e.fact)
    return out^


def _known_live(
    edges: List[WorkingEdge], event_t: Int64, system_t: Int64
) -> List[String]:
    """The facts the graph, as it stood at system time `system_t`, held true at
    event time `event_t`. A row not yet created is unknown; a row not yet
    expired was still believed open."""
    var out = List[String]()
    for i in range(len(edges)):
        ref e = edges[i]
        if e.created_at > system_t:
            continue
        var end = e.invalid_at
        if e.expired_at > system_t:
            end = TS_OPEN_SENTINEL
        if e.valid_at <= event_t and event_t < end:
            out.append(e.fact)
    return out^


def _only(facts: List[String], fact: String) -> Bool:
    return len(facts) == 1 and facts[0] == fact


def test_overlapping_open_edge_is_a_candidate() raises:
    var existing = List[WorkingEdge]()
    existing.append(_old_open())
    var cands = overlapping_contradiction_candidates(_new_open(), existing)
    assert_equal(len(cands), 1)
    assert_equal(cands[0], 0)


def test_candidates_come_back_in_input_order() raises:
    var existing = List[WorkingEdge]()
    existing.append(_old_open())
    existing.append(
        open_edge(Int64(9), Int64(9), "", "other pair", 100, 100, 100)
    )
    existing.append(
        open_edge(_A, _B, "", "second", valid_at=250, now=260, reference_time=250)
    )
    var cands = overlapping_contradiction_candidates(_new_open(), existing)
    assert_equal(len(cands), 2)
    assert_equal(cands[0], 0)
    assert_equal(cands[1], 2)


def test_edges_that_cannot_contradict_are_not_candidates() raises:
    var existing = List[WorkingEdge]()
    # Ended before the new edge starts.
    existing.append(
        WorkingEdge(_A, _B, "", "ended early", 100, 200, 250, 100, 100, "")
    )
    # Ended exactly when the new edge starts: a clean hand-off.
    existing.append(
        WorkingEdge(_A, _B, "", "abutting", 100, 300, 300, 100, 100, "")
    )
    # Same time span, another node pair (and the reverse direction).
    existing.append(open_edge(Int64(4), _A, "", "other pair", 200, 200, 200))
    existing.append(open_edge(_B, _A, "", "reverse direction", 200, 200, 200))
    # An empty interval holds at no instant.
    existing.append(
        WorkingEdge(_A, _B, "", "empty", 400, 400, 450, 400, 400, "")
    )
    assert_equal(len(overlapping_contradiction_candidates(_new_open(), existing)), 0)

    # The same list with one genuine overlap added flags exactly that one.
    existing.append(_old_open())
    var cands = overlapping_contradiction_candidates(_new_open(), existing)
    assert_equal(len(cands), 1)
    assert_equal(cands[0], 5)


def test_an_edge_still_open_at_the_new_start_overlaps_when_closed_later() raises:
    var existing = List[WorkingEdge]()
    existing.append(
        WorkingEdge(_A, _B, "", "ends later", 100, 301, 301, 100, 100, "")
    )
    assert_equal(len(overlapping_contradiction_candidates(_new_open(), existing)), 1)


def test_predicate_counts_only_when_asked() raises:
    var existing = List[WorkingEdge]()
    existing.append(open_edge(_A, _B, "uses", "uses", 100, 100, 100))
    existing.append(open_edge(_A, _B, "avoids", "avoids", 100, 100, 100))
    var new_edge = open_edge(_A, _B, "avoids", "avoids now", 300, 500, 300)

    assert_equal(
        len(overlapping_contradiction_candidates(new_edge, existing)), 2
    )
    var by_predicate = overlapping_contradiction_candidates(
        new_edge, existing, match_predicate=True
    )
    assert_equal(len(by_predicate), 1)
    assert_equal(by_predicate[0], 1)


def test_invalidation_closes_the_old_edge_and_keeps_its_row() raises:
    var old_edge = open_edge(
        _A, _B, "rel", _FACT_OLD, valid_at=100, now=100, reference_time=90, source="src-1"
    )
    var new_edge = _new_open()
    apply_invalidation(old_edge, new_edge, now=500)

    assert_equal(old_edge.invalid_at, Int64(300))
    assert_equal(old_edge.expired_at, Int64(500))
    assert_false(old_edge.is_open())
    assert_true(old_edge.is_expired())
    # Everything else is untouched: the row is history, not a rewrite.
    assert_equal(old_edge.valid_at, Int64(100))
    assert_equal(old_edge.created_at, Int64(100))
    assert_equal(old_edge.reference_time, Int64(90))
    assert_equal(old_edge.fact, _FACT_OLD)
    assert_equal(old_edge.predicate, "rel")
    assert_equal(old_edge.source, "src-1")
    assert_equal(old_edge.src_nid, _A)
    assert_equal(old_edge.dst_nid, _B)
    # The new edge is only read.
    assert_equal(new_edge.valid_at, Int64(300))
    assert_true(new_edge.is_open())
    assert_false(new_edge.is_expired())


def test_event_time_answers_after_a_supersession() raises:
    var old_edge = _old_open()
    var new_edge = _new_open()
    apply_invalidation(old_edge, new_edge, now=500)
    var ws = List[WorkingEdge]()
    ws.append(old_edge^)
    ws.append(new_edge^)
    assert_equal(len(ws), 2)

    assert_true(_only(_live_at_event(ws, 200), _FACT_OLD))
    assert_true(_only(_live_at_event(ws, 400), _FACT_NEW))
    # The hand-off instant belongs to the new edge only.
    assert_true(_only(_live_at_event(ws, 300), _FACT_NEW))
    assert_equal(len(_live_at_event(ws, 99)), 0)


def test_system_time_answers_keep_what_the_graph_believed() raises:
    var old_edge = _old_open()
    var new_edge = _new_open()
    apply_invalidation(old_edge, new_edge, now=500)
    var ws = List[WorkingEdge]()
    ws.append(old_edge^)
    ws.append(new_edge^)

    # Before the graph learned of the change, event time 400 still read A.
    assert_true(_only(_known_live(ws, 400, 400), _FACT_OLD))
    # After, it reads B.
    assert_true(_only(_known_live(ws, 400, 600), _FACT_NEW))
    # Event time 200 reads A at either system time.
    assert_true(_only(_known_live(ws, 200, 400), _FACT_OLD))
    assert_true(_only(_known_live(ws, 200, 600), _FACT_OLD))
    # Before the first row was created the graph knew nothing.
    assert_equal(len(_known_live(ws, 200, 50)), 0)


def test_a_candidate_not_confirmed_leaves_both_facts() raises:
    var kept = _old_open()
    var new_edge = open_edge(_A, _B, "", "a complementary fact", 300, 500, 300)
    var existing = List[WorkingEdge]()
    existing.append(kept.copy())
    assert_equal(len(overlapping_contradiction_candidates(new_edge, existing)), 1)

    # The caller judged "no contradiction" and did not call apply_invalidation.
    assert_true(kept.is_open())
    assert_false(kept.is_expired())
    var ws = List[WorkingEdge]()
    ws.append(kept^)
    ws.append(new_edge^)
    assert_equal(len(_live_at_event(ws, 400)), 2)


def test_applying_a_verdict_twice_keeps_the_first_expiry() raises:
    var old_edge = _old_open()
    var new_edge = _new_open()
    apply_invalidation(old_edge, new_edge, now=500)
    apply_invalidation(old_edge, new_edge, now=900)
    assert_equal(old_edge.invalid_at, Int64(300))
    assert_equal(old_edge.expired_at, Int64(500))


def test_invalidation_never_widens_an_edge_closed_earlier() raises:
    var old_edge = WorkingEdge(_A, _B, "", "closed", 100, 250, 260, 100, 100, "")
    apply_invalidation(old_edge, _new_open(), now=900)
    assert_equal(old_edge.invalid_at, Int64(250))
    assert_equal(old_edge.expired_at, Int64(260))


def test_invalidation_never_inverts_an_interval() raises:
    # The new fact starts before the old one: the old interval becomes empty at
    # its own start, not [100, 50).
    var old_edge = _old_open()
    var earlier = open_edge(_A, _B, "", "earlier", valid_at=50, now=500, reference_time=50)
    apply_invalidation(old_edge, earlier, now=500)
    assert_equal(old_edge.valid_at, Int64(100))
    assert_equal(old_edge.invalid_at, Int64(100))
    assert_true(old_edge.is_expired())

    # An empty interval is never a candidate again.
    var existing = List[WorkingEdge]()
    existing.append(old_edge^)
    assert_equal(len(overlapping_contradiction_candidates(_new_open(), existing)), 0)


def test_open_edge_is_open_on_both_axes_and_carries_its_inputs() raises:
    var e = open_edge(
        Int64(7), Int64(8), "rel", "a fact", valid_at=40, now=55, reference_time=44, source="src-2"
    )
    assert_equal(e.src_nid, Int64(7))
    assert_equal(e.dst_nid, Int64(8))
    assert_equal(e.predicate, "rel")
    assert_equal(e.fact, "a fact")
    assert_equal(e.valid_at, Int64(40))
    assert_equal(e.created_at, Int64(55))
    assert_equal(e.reference_time, Int64(44))
    assert_equal(e.source, "src-2")
    assert_equal(e.invalid_at, TS_OPEN_SENTINEL)
    assert_equal(e.expired_at, TS_OPEN_SENTINEL)
    assert_true(e.is_open())
    assert_false(e.is_expired())

    var unattributed = open_edge(_A, _B, "", "f", 1, 2, 3)
    assert_equal(unattributed.source, "")


def test_only_the_sentinel_is_open() raises:
    # A large finite timestamp is a closed end, whatever unit a writer uses.
    var e = WorkingEdge(
        _A, _B, "", "f", 5, Int64(999999999999), TS_OPEN_SENTINEL, 5, 5, ""
    )
    assert_false(e.is_open())
    assert_false(e.is_expired())
    var e2 = WorkingEdge(_A, _B, "", "f", 5, TS_OPEN_SENTINEL, Int64(999999999999), 5, 5, "")
    assert_true(e2.is_open())
    assert_true(e2.is_expired())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
