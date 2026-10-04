# =============================================================================
# kci_reconciler/cell_walk.mojo: the parts of a walk that read the cell's
#   ownership and the store, shared by plan / apply / destroy (engine.mojo).
# =============================================================================
#
#   * `refuse_unless_owned` — the OWNED scope's pre-flight. Before any change,
#     every node must stamp ownership (`Resource.stamps_ownership`) and every
#     PRESENT object must be this node's by the rule of ownership.mojo. Every
#     problem is collected and the whole run is refused with one text naming
#     them all (a driver maps `kci: REFUSED` to exit 3). The reads are
#     presence reads (`read_presence`), so nothing has to be bound yet.
#   * `removal_is_ours` — the closed-world rule for a node the file no longer
#     wants (`Resource.wanted` is False): its object is deleted only when the
#     STORE recorded it with the same physical id AND, in an owned scope, it
#     carries this node's stamp. Either source alone is not enough (kci
#     deletes only where both say the object is its own); an object only
#     one of them vouches for is left and reported as leftover.
#   * `delete_confirmed` — delete, re-read, and retire the record only when the
#     object is provably gone (the confirmed-gone gate destroy_graph has
#     always had, now shared with the closed-world removal).
#   * `bind_from_recorded_outputs` — teardown's best-effort bind from the
#     outputs the store persisted, keyed by the cell.
#
# Value-typed surface only; no pointer crosses it. Mojo 1.0.0b2.
# =============================================================================

from kci_reconciler.resource import ResourceStatus, Creds, RETAIN_DELETE
from kci_reconciler.outputs import ResolvedInputs
from kci_reconciler.ownership import (
    CellScope,
    ResourceKey,
    ownership_problem,
    refusal_text,
)
from kci_reconciler.state import StateStore
from kci_reconciler.graph import ResourceGraph


def bind_from_recorded_outputs[
    S: StateStore
](mut graph: ResourceGraph, idx: Int, cell: CellScope, mut store: S) raises:
    """Best-effort bind for a presence read: bind node `idx`'s `input_refs`
    from the outputs `store` recorded for its producers (in `cell`), iff every
    one is recorded. A missing value binds nothing and refuses nothing (a
    presence read needs no bound value); it is never an empty string."""
    var refs = graph.node(idx).input_refs()
    if len(refs) == 0:
        return
    var resolved = ResolvedInputs()
    for r in range(len(refs)):
        var v = store.outputs_for(cell.key(refs[r].producer)).get(refs[r].output)
        if not v:
            return
        resolved.add(refs[r], v.value())
    graph.node(idx).bind_inputs(resolved)


def refuse_unless_owned[
    S: StateStore
](
    mut graph: ResourceGraph,
    order: List[Int],
    creds: Creds,
    cell: CellScope,
    mut store: S,
    verb: String,
    adopt_allowed: Bool,
) raises:
    """The owned scope's pre-flight; a no-op in the unowned scope. Raises one
    `kci: REFUSED <verb> ...` text naming every node that cannot stamp and
    every present object that is not this node's. `adopt_allowed` is False for
    destroy (an adoption is never a reason to delete)."""
    if not cell.owned():
        return
    var problems = List[String]()
    for oi in range(len(order)):
        var idx = order[oi]
        var lid = graph.node(idx).logical_id()
        if not graph.node(idx).stamps_ownership():
            problems.append(
                lid
                + String(": its conformer does not stamp ownership")
                + String(" (no create_owned); an owned cell refuses it")
            )
            continue
        bind_from_recorded_outputs(graph, idx, cell, store)
        var live = graph.node(idx).read_presence(creds)
        if not live.is_present():
            continue
        var identity = cell.stamp(graph.node(idx).owner(), lid).identity()
        var recorded = store.physical_id_for(cell.key(lid))
        var why = ownership_problem(
            lid,
            identity,
            True,
            live.physical_id,
            live.stamp,
            recorded,
            adopt_allowed and cell.adopts(lid),
        )
        if why.byte_length() > 0:
            problems.append(lid + String(": ") + why)
    if len(problems) > 0:
        raise Error(refusal_text(cell, verb, problems))


def removal_is_ours(
    cell: CellScope,
    identity: String,
    retention: Int,
    live: ResourceStatus,
    recorded_physical_id: String,
) -> Bool:
    """True iff a node the file no longer wants may have its live object
    deleted: present, RETAIN_DELETE, recorded by the store with the same
    physical id, and (owned scope) stamped with this node's identity."""
    if not live.is_present() or retention != RETAIN_DELETE:
        return False
    if recorded_physical_id.byte_length() == 0:
        return False
    if (
        live.physical_id.byte_length() > 0
        and live.physical_id != recorded_physical_id
    ):
        return False
    if cell.owned() and live.stamp != identity:
        return False
    return True


def delete_confirmed[
    S: StateStore
](
    mut graph: ResourceGraph,
    idx: Int,
    lid: String,
    key: ResourceKey,
    physical_id: String,
    creds: Creds,
    mut store: S,
) raises:
    """Delete node `idx`'s object `physical_id`, re-read it, and retire the
    record ONLY when the re-read is ABSENT. A re-read that still shows it
    leaves the record and RAISES, so the next run re-drives: a record is never
    retired over a live (billable) object."""
    graph.node(idx).delete(physical_id, creds)
    var after = graph.node(idx).read_presence(creds)
    if after.is_present():
        raise Error(
            String("destroy_graph: node '")
            + lid
            + String("' is STILL PRESENT after its delete was issued — the")
            + String(" reap did NOT converge (an eventually-consistent backend,")
            + String(" a partial delete, or a swallowed-but-transient delete")
            + String(" outcome). The intent is LEFT INTACT (NOT reaped) so the")
            + String(" level-triggered reconcile re-drives on the next tick —")
            + String(" a record is never retired over a live (billable)")
            + String(" resource. ")
            + after.message
        )
    store.mark_reaped(key)
