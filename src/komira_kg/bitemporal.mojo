# =============================================================================
# bitemporal -- the interval arithmetic of a fact that is replaced, not erased.
# =============================================================================
#
# Every edge carries two time axes. Event time (`valid_at`, `invalid_at`) is
# when the fact held in the world; system time (`created_at`, `expired_at`) is
# when the graph learned it and when it learned the fact no longer holds. A
# later correction closes the old edge and adds a new one; it never deletes a
# row, so "what did we believe at time T" stays answerable.
#
# This module is the pure part of that: `open_edge` builds a new edge,
# `overlapping_contradiction_candidates` names the existing edges a new edge
# might contradict, and `apply_invalidation` stamps a verdict onto one of them.
# It never decides whether two facts contradict: that judgment belongs to the
# caller (a model, a rule, a person), which is handed the candidate indices and
# calls `apply_invalidation` only for the ones it confirms. No time is read
# here: `now` is always an argument, in whatever unit the graph stamps.
#
# An open interval ends at `TS_OPEN_SENTINEL`. Intervals are half open,
# [valid_at, invalid_at): an edge that ended exactly when the new one begins
# is a clean hand-off, not a contradiction.
# =============================================================================

from komira_kg_format import TS_OPEN_SENTINEL


@fieldwise_init
struct WorkingEdge(Copyable, Movable):
    """One edge of the in-memory working set, with the bi-temporal columns of
    the `edges` table.

    Fields:
        src_nid: The source node's dense id (part of the subject).
        dst_nid: The destination node's dense id (part of the subject).
        predicate: The relation label, "" when unused. Part of the subject only
            when a caller asks for predicate matching.
        fact: The fact as a sentence (payload; passes through).
        valid_at: Event-time start.
        invalid_at: Event-time end; `TS_OPEN_SENTINEL` while the fact holds.
        expired_at: System time the graph learned the fact was replaced;
            `TS_OPEN_SENTINEL` while it believes the fact.
        created_at: System time the row was created.
        reference_time: The reference time of the episode that asserted it.
        source: The id of the source that asserted it, "" when unattributed.
    """

    var src_nid: Int64
    var dst_nid: Int64
    var predicate: String
    var fact: String
    var valid_at: Int64
    var invalid_at: Int64
    var expired_at: Int64
    var created_at: Int64
    var reference_time: Int64
    var source: String

    def is_open(self) -> Bool:
        """True while the fact is not closed in event time."""
        return self.invalid_at == TS_OPEN_SENTINEL

    def is_expired(self) -> Bool:
        """True once the graph has learned the fact was replaced."""
        return self.expired_at != TS_OPEN_SENTINEL


def open_edge(
    src_nid: Int64,
    dst_nid: Int64,
    predicate: String,
    fact: String,
    valid_at: Int64,
    now: Int64,
    reference_time: Int64,
    source: String = String(""),
) -> WorkingEdge:
    """Build a new edge, open on both axes.

    Args:
        src_nid: The resolved source node's dense id.
        dst_nid: The resolved destination node's dense id.
        predicate: The relation label, or "".
        fact: The fact as a sentence.
        valid_at: Event time the fact starts to hold.
        now: The system time of this write, stamped as `created_at`.
        reference_time: The reference time of the asserting episode.
        source: The asserting source's id, or "".

    Returns:
        An edge whose `invalid_at` and `expired_at` are `TS_OPEN_SENTINEL`.
    """
    return WorkingEdge(
        src_nid,
        dst_nid,
        predicate,
        fact,
        valid_at,
        TS_OPEN_SENTINEL,
        TS_OPEN_SENTINEL,
        now,
        reference_time,
        source,
    )


@always_inline
def _same_subject(
    a: WorkingEdge, b: WorkingEdge, match_predicate: Bool
) -> Bool:
    if a.src_nid != b.src_nid or a.dst_nid != b.dst_nid:
        return False
    if match_predicate and a.predicate != b.predicate:
        return False
    return True


@always_inline
def _intervals_overlap(
    a_start: Int64, a_end: Int64, b_start: Int64, b_end: Int64
) -> Bool:
    """Overlap of [a_start, a_end) and [b_start, b_end). An empty interval
    (start >= end) holds at no instant and overlaps nothing."""
    if a_start >= a_end or b_start >= b_end:
        return False
    return a_start < b_end and b_start < a_end


def overlapping_contradiction_candidates(
    new_edge: WorkingEdge,
    existing_edges: List[WorkingEdge],
    match_predicate: Bool = False,
) -> List[Int]:
    """The indices of existing edges that might contradict `new_edge`.

    An edge is a candidate when it has the same subject (same node pair, and
    the same predicate when `match_predicate`) and its interval overlaps the
    new edge's [valid_at, invalid_at), which is [valid_at, open) for an open
    edge. An edge of another subject, an edge that ended
    at or before the new one starts, and an empty interval are not candidates.
    This decides nothing about meaning; the caller judges each index.

    Args:
        new_edge: The edge being added (open, or ended at its `invalid_at`).
        existing_edges: The edges to test; any list is safe, the subject is
            re-checked per edge.
        match_predicate: Require equal predicates as well as equal node pairs.

    Returns:
        Ascending indices into `existing_edges`.
    """
    var out = List[Int]()
    for i in range(len(existing_edges)):
        ref old = existing_edges[i]
        if not _same_subject(old, new_edge, match_predicate):
            continue
        if _intervals_overlap(
            old.valid_at, old.invalid_at, new_edge.valid_at, new_edge.invalid_at
        ):
            out.append(i)
    return out^


def apply_invalidation(
    mut old_edge: WorkingEdge, new_edge: WorkingEdge, now: Int64
):
    """Close `old_edge` because the caller confirmed `new_edge` replaces it.

    The old fact held on [old.valid_at, new.valid_at): its `invalid_at` becomes
    the new edge's `valid_at`, and its `expired_at` becomes `now`, the system
    time the graph learned it. The row is kept with every other field
    untouched. Two guards keep the stamp from corrupting history: an interval
    is only ever shortened (an edge already closed earlier keeps its earlier
    end), never below its own start; and an edge already expired keeps the
    system time it first expired at, so applying a verdict twice is harmless.

    Call it only for indices `overlapping_contradiction_candidates` returned and
    the caller confirmed.

    Args:
        old_edge: The edge being replaced (mutated).
        new_edge: The replacing edge (read for `valid_at`).
        now: The system time of this write.
    """
    var end = new_edge.valid_at
    if end > old_edge.invalid_at:
        end = old_edge.invalid_at
    if end < old_edge.valid_at:
        end = old_edge.valid_at
    old_edge.invalid_at = end
    if old_edge.expired_at == TS_OPEN_SENTINEL:
        old_edge.expired_at = now
