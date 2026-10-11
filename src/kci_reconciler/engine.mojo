# =============================================================================
# kci_reconciler/engine.mojo — the reconcile VERBS of the resource-graph deploy
#   engine, driving a ResourceGraph over a StateStore + Creds (provider-neutral).
# =============================================================================
#
# THE VERBS (over a graph + a write-ahead state store + per-call creds):
#   * plan_graph(graph, creds) -> List[ChangeAction]. Topo order; per node,
#     `plan(read_status())` — READ-ONLY (no mutation). The dry-run.
#   * apply_graph(graph, creds, store) -> List[AppliedNode]. Topo order; per node:
#     record_or_adopt_intent -> read_status -> (MATCHED: adopt / ABSENT: create /
#     DRIFTED or FAILED: converge_mode IN_PLACE -> update, else RAISE "REPLACE
#     unsupported") -> confirm -> append AppliedNode -> outputs. The forward
#     apply, with write-ahead recovery (a crashed apply is re-driven by adopting
#     the surviving intents). A FAILED live resource is updatable: the fix for a
#     bad image is the next apply with a good one.
#   * rollback_create(graph, applied, creds, store). REVERSE order over `applied`;
#     SKIP RETAIN_KEEP (never delete a kept resource) and SKIP RETAIN_UNDELETABLE
#     (no delete capability exists); SKIP every node this apply did not CREATE
#     (VERB_NOOP: we adopted it; VERB_UPDATE: it existed before this apply and we
#     only changed it, so deleting it would destroy a pre-existing resource);
#     SKIP already_confirmed (the node predated us — we did not create it, so we
#     must not delete it); else delete + mark_reaped. A delete failure
#     raises-and-stops (fail-loud). ⚠ The verb skip is NOT redundant with
#     already_confirmed: on a FIRST apply against a pre-existing resource there is
#     no prior intent, so already_confirmed is False while the verb is NOOP or
#     UPDATE.
#   * destroy_graph(graph, creds, store, force_delete_data=False)
#       -> List[UndeletableSkip]. REVERSE topo
#     order; SKIP RETAIN_KEEP (unless force_delete_data — the `--delete-data`
#     whole-project override lifts the skip); SKIP RETAIN_UNDELETABLE
#     UNCONDITIONALLY (no flag lifts a CAPABILITY) and RETURN one record per such
#     node so the caller can NAME the survivors; live-read then delete-if-present;
#     mark_reaped ONLY on a CONFIRMED-GONE outcome (a provable-404 absent read, or
#     a delete-then-reread that comes back ABSENT). A transient/ambiguous read (or a
#     present resource that survives the delete) LEAVES the record intact + fails
#     loud so the level-triggered reconcile re-drives — no partial reap swallowed,
#     no live resource orphaned behind a retired record (the MONEY-LEAK gate). The
#     teardown (the symmetric inverse of apply_graph).
#
# WHY LIVE IS THE ONLY ACTUAL-STATE SOURCE. Every verb reads `read_status` fresh
# (never a cached attribute). apply_graph does NOT replay a prior plan — it
# re-reads live and acts on THAT, so a world that drifted between plan and apply
# converges to the live truth. The state store answers only "did we confirm this
# node + what is its physical id"; the live read answers "what does it look like".
#
# THE RETAIN_KEEP INVARIANT (shared-resource retention).
# rollback_create + destroy_graph SKIP any node whose `retention()` is
# RETAIN_KEEP — the engine NEVER deletes a standing / shared resource (the
# cell-shared bucket, the WIF pool, the VPC). That is the whole reason
# retention is a first-class node property.
#
# ★ AND THE RETAIN_UNDELETABLE INVARIANT, WHICH IS A DIFFERENT ONE.
# RETAIN_KEEP is a POLICY the operator may override with `force_delete_data`.
# RETAIN_UNDELETABLE is a CAPABILITY statement — "this graph cannot delete this
# resource" — and NO flag overrides it. Both are answered by the SAME single
# function, `Resource.retention()`: the engine holds no exempt-list, no per-kind
# branch and no second table, so a conformer that refuses its own `delete` and a
# conformer the engine skips can never be two different sets. Because a skipped
# node is a resource that SURVIVES a teardown the operator asked for,
# `destroy_graph` RETURNS the skipped set (`UndeletableSkip`: the logical id + the
# conformer's own `undeletable_reason()`) instead of continuing silently, and it
# does NOT `mark_reaped` them — the resource is still live, and retiring the
# record would orphan it.
#
# ★ THE CELL SCOPE (kci_reconciler/ownership.mojo). Every verb has an OWNED form
# (`plan_graph_owned`, `apply_graph_owned`, `destroy_graph_owned`) that runs in a
# `CellScope (machine, cell, provenance, adopt, validation_run_id)`; the older
# forms run in the UNOWNED scope and behave exactly as before. In an owned scope:
#   * the store is keyed `(machine, cell, logical id)`;
#   * before ANY change, every node must stamp ownership and every present object
#     must be this node's (stamped with its identity, or explicitly adopted):
#     a FOREIGN or CONFLICT object refuses the whole run (`kci: REFUSED`), and
#     destroy never deletes one;
#   * the write-ahead intent carries the identity, and a create is
#     `create_owned(stamp)`: the object is born stamped, in the same call;
#   * a resource's `adopt` (in `CellScope.adopt`) stamps an unstamped object of a wanted
#     name and records it, instead of refusing it.
# In either scope, a node the file no longer wants (`Resource.wanted` False, the
# closed world) is deleted when the store recorded it (and, owned,
# it carries the stamp), and otherwise left and planned as leftover; a difference
# on a field kci does not model (`ResourceStatus.unmanaged`) is planned beside the
# verb and never converged.
#
# WHAT v1 DOES NOT DO (the typed holes). No REPLACE (a DRIFTED node whose
# converge_mode is not IN_PLACE makes apply RAISE "CONVERGE_REPLACE unsupported in
# v1" — fail-loud, not a surprise teardown). No rollback_update (the digest-revert
# is a provider-spec-specific wrapper concern, NOT here).
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# Value-typed surface only: the verbs take `mut ResourceGraph` + `Creds` + `mut
# StateStore`, return `List[ChangeAction]` / `List[AppliedNode]` / nothing,
# `raises`. ZERO UnsafePointer crosses any boundary (all pointer arithmetic is
# INSIDE the Slab / the erasure, concrete origin), so no stale-pointer hazard
# across destroy and recreate. Mojo 1.0.0b2.
# =============================================================================

from kci_reconciler.resource import (
    ResourceStatus,
    ChangeAction,
    Creds,
    RES_ABSENT,
    RES_PRESENT_MATCHED,
    RES_PRESENT_DRIFTED,
    RES_CONVERGING,
    RES_FAILED,
    RETAIN_DELETE,
    RETAIN_KEEP,
    RETAIN_UNDELETABLE,
    CONVERGE_NOOP,
    CONVERGE_IN_PLACE,
    CONVERGE_REPLACE,
    VERB_NOOP,
    VERB_CREATE,
    VERB_UPDATE,
    VERB_REPLACE,
    VERB_DELETE,
    VERB_KNOWN_AFTER_APPLY,
)
from kci_reconciler.outputs import (
    InputRef,
    Outputs,
    ResolvedInputs,
    unbound_error,
)
from kci_reconciler.fault_domain import (
    FAULT_UNSET,
    fault_error,
    fault_domain_of_error,
    fault_message_of_error,
)
from kci_reconciler.deploy_fault import (
    carry_deploy_fault_mark,
    deploy_fault_message,
)
from kci_reconciler.state import StateStore, IntentTicket, InMemoryStateStore
from kci_reconciler.graph import ResourceGraph, topo_sort, reverse_order
from kci_reconciler.ownership import CellScope, ResourceKey, ownership_problem
from kci_reconciler.cell_walk import (
    bind_from_recorded_outputs,
    delete_confirmed,
    refuse_unless_owned,
    removal_is_ours,
)

# The ambient (process-global) structured-log facade — the no-`ctx`/no-threaded-
# handle reach the best-effort prune swallow uses to emit a breadcrumb WITHOUT
# threading a reporter through apply_graph (the `get_logger` shape). A stuck prune
# (missing revisions.delete IAM, an unimplemented live verb) is thereby SWALLOWED-
# AND-LOGGED, never silent. When no engine is installed (a standalone tool) the
# facade falls back to synchronous stderr; it never crashes.
import komira_log as log
from komira_log import ArgStr, ArgI64


# =============================================================================
# §1 — AppliedNode — the record of what apply_graph did to one node (so the caller
#      can rollback_create the applied set). Flat value POD (no pointer field).
# =============================================================================
@fieldwise_init
struct AppliedNode(Copyable, Movable, Deinitable):
    """One node apply_graph acted on, in APPLY ORDER (so a rollback walks it in
    reverse):
      * `logical_id`        — the node's graph-stable key.
      * `physical_id`       — the provider-assigned id (from create, or the adopted
                              id for a matched/confirmed node).
      * `retention`         — the node's RETAIN_* policy (rollback SKIPS
                              RETAIN_KEEP).
      * `already_confirmed` — True iff the intent PREDATED this apply (the node was
                              already confirmed — we did NOT create it, so rollback
                              SKIPS it: we must not delete what we did not create).
      * `verb`              — the VERB_* the apply issued (create / update / noop /
                              adopt-noop). ⚠ LOAD-BEARING, NOT informational: a
                              VERB_NOOP node was ADOPTED (live already matched; zero
                              mutation) and `rollback_create` MUST NOT delete it.
                              Treating it as informational makes the unwind
                              ignore the field, and the result is a rollback
                              that deletes resources the deploy never created.
      * `served_endpoint`   — the served node's LIVE endpoint (`ResourceStatus.
                              endpoint` == the Cloud Run `uri`), captured off the
                              apply's OWN live read on the no-op / update paths (no
                              extra RPC). EMPTY for a non-served node (its live read
                              carries no endpoint) and for a fresh CREATE (the pre-
                              create live read was ABSENT — the caller's fallback
                              poll fills that case). This is the DEPLOY->VALIDATE
                              handoff source: the served URL surfaced by the apply
                              itself so a no-op re-apply still records it.
      * `key`               — the store key `(machine, cell, logical id)` the
                              node was recorded under (rollback reaps by it).
    A node the file no longer wants appears with VERB_DELETE when its object
    was removed, else VERB_NOOP.
    Flat value POD."""

    var logical_id: String
    var physical_id: String
    var retention: Int
    var already_confirmed: Bool
    var verb: Int
    var served_endpoint: String
    var key: ResourceKey


# =============================================================================
# §1b — UndeletableSkip — one node a teardown SKIPPED because its conformer
#       declares RETAIN_UNDELETABLE. Flat value POD (two Strings, no pointer).
# =============================================================================
@fieldwise_init
struct UndeletableSkip(Copyable, Movable, Deinitable):
    """A resource that SURVIVES a teardown, and why.

    ⛔ THE RETURN VALUE IS THE POINT. A teardown that skips a node the operator
    asked it to remove and exits 0 tells them the account is clean when it is
    not; that is strictly worse than the raise this replaces, because a raise at
    least stopped. So `destroy_graph` hands every skip back — `logical_id` names
    the node, `reason` carries the CONFORMER's own words — and the caller renders
    them. The engine cannot print: `kci_reconciler` is provider- AND IO-neutral by
    construction (no reporter, no logger on the verb surface), so the record is
    the only honest carrier.

    ⚠ `reason` IS THE CONFORMER'S, NEVER THE ENGINE'S. The engine substitutes a
    sentence only when the conformer left it empty, and that sentence says the
    conformer is at fault rather than inventing a plausible reason. A default
    reason that read like a real one would make an unconsidered conformer
    indistinguishable from a considered one."""

    var logical_id: String
    var reason: String


def undeletable_report_lines(
    skips: List[UndeletableSkip],
) raises -> List[String]:
    """The teardown's UNDELETABLE report, as LINES — one shared rendering for
    every caller of `destroy_graph`, and EMPTY when nothing was skipped.

    ⛔ A PURE FUNCTION RETURNING STRINGS, BECAUSE `kci_reconciler` DOES NO IO. The
    engine layer has no reporter, no logger on its verb surface and no cloud; a
    renderer that printed would put an output policy in the neutral layer. It
    lives here anyway rather than in each caller because the sentence an operator
    must not misread — *this teardown did not remove everything* — should be
    written ONCE. Callers `reporter.info` each line.

    ⚠ IT NEVER SAYS "FAILED". The teardown did everything it is capable of; the
    survivors are a capability boundary, not a fault. It also never says the
    resources still EXIST — the walk skipped them without reading, so all it can
    honestly claim is that it did not attempt them."""
    var lines = List[String]()
    if len(skips) == 0:
        return lines^
    lines.append(
        String("  ⛔ ")
        + String(len(skips))
        + String(
            " resource(s) SURVIVE this teardown — this codebase has NO delete"
            " path for them (RETAIN_UNDELETABLE), and no flag overrides that:"
        )
    )
    for i in range(len(skips)):
        lines.append(
            String("    UNDELETABLE  ") + skips[i].logical_id + String(":")
        )
        lines.append(String("        ") + skips[i].reason)
    lines.append(
        String(
            "  ⚠ THE TEARDOWN COMPLETED — every other node was reaped or kept by"
            " policy — but the cell is NOT empty. Each resource above was"
            " SKIPPED WITHOUT BEING READ, so this is a statement about what was"
            " attempted, not about what still exists. Their intent records are"
            " deliberately LEFT INTACT (never marked reaped) so nothing is"
            " orphaned behind a retired record."
        )
    )
    return lines^


# =============================================================================
# §2 — plan_graph — the READ-ONLY dry run. Topo order; per node, plan(read_status).
# =============================================================================
struct _RunOutputs(Movable):
    """The outputs each node produced in THIS walk (apply or dry run), by
    logical id, and, in a dry run, the producers whose values are not known
    until apply."""

    var _ids: List[String]
    var _outs: List[Outputs]
    var _pending_ids: List[String]
    var _pending_verbs: List[String]

    def __init__(out self):
        self._ids = List[String]()
        self._outs = List[Outputs]()
        self._pending_ids = List[String]()
        self._pending_verbs = List[String]()

    def put(mut self, logical_id: String, var outs: Outputs):
        self._ids.append(logical_id)
        self._outs.append(outs^)

    def mark_pending(mut self, logical_id: String, verb: String):
        self._pending_ids.append(logical_id)
        self._pending_verbs.append(verb)

    def pending_verb(self, logical_id: String) -> Optional[String]:
        for i in range(len(self._pending_ids)):
            if self._pending_ids[i] == logical_id:
                return self._pending_verbs[i]
        return None

    def value(self, logical_id: String, output: String) -> Optional[String]:
        for i in range(len(self._ids)):
            if self._ids[i] == logical_id:
                return self._outs[i].get(output)
        return None


def _resolve_inputs(
    lid: String, refs: List[InputRef], run: _RunOutputs
) raises -> ResolvedInputs:
    """One resolved value per ref, or the UNBOUND refusal naming the consumer,
    the field, the producer and the output. Every producer has already been
    walked (topo order), so a missing value means the producer did not report
    it: a refusal, never an empty string."""
    var resolved = ResolvedInputs()
    for r in range(len(refs)):
        var v = run.value(refs[r].producer, refs[r].output)
        if not v:
            raise unbound_error(lid, refs[r])
        resolved.add(refs[r], v.value())
    return resolved^


def plan_graph(mut graph: ResourceGraph, creds: Creds) raises -> List[ChangeAction]:
    """Return the ChangeAction for every node, in topo order, WITHOUT mutating
    anything, in the UNOWNED scope. Per node: `read_status(creds)` (the live
    read) then `plan(live)` (the pure diff). NO create/update/delete is issued
    — this is a dry run. RAISES on a dangling dependency or reference, a cycle
    (via topo_sort), an unresolved reference, or a genuine backend read fault.

    ── VALUES THAT ONLY EXIST AFTER APPLY ──────────────────────────────────────
    A node with `input_refs` is bound to its producers' values BEFORE it is
    read, so it is planned against real values. A dry run cannot create or
    change a producer, so when any producer of a node plans anything but a
    no-op (or is itself waiting on one), the node is reported as
    VERB_KNOWN_AFTER_APPLY ("may change") and is NOT read: its desired digest
    would be over an unresolved reference. It is never reported as a no-op. A
    node whose producers all plan no-ops is bound to their live outputs and
    planned like any other.

    Every action carries the node's `owner()` and the live read's
    `unmanaged` differences.

    ⚠ THIS FORM HAS NO STORE, so a node the file no longer wants is planned as
    leftover even when a store recorded it. `plan_graph_owned` reads the
    store."""
    var store = InMemoryStateStore()
    return _plan_impl(graph, creds, CellScope.unowned(), store)


def plan_graph_owned[
    S: StateStore
](
    mut graph: ResourceGraph, creds: Creds, cell: CellScope, mut store: S
) raises -> List[ChangeAction]:
    """`plan_graph` in `cell`: the same dry run, after the owned pre-flight
    (`kci: REFUSED plan ...` when a node cannot stamp or a present object is
    not this node's, exactly what apply would refuse), with the store read for
    the closed-world rule. Reads only; writes nothing to the store."""
    if not cell.owned():
        raise Error(
            String("plan_graph_owned: the scope names no machine and cell;")
            + String(" use plan_graph for the unowned scope")
        )
    return _plan_impl(graph, creds, cell, store)


def _plan_impl[
    S: StateStore
](
    mut graph: ResourceGraph, creds: Creds, cell: CellScope, mut store: S
) raises -> List[ChangeAction]:
    var order = topo_sort(graph)
    refuse_unless_owned(
        graph, order, creds, cell, store, String("plan"), True
    )
    var actions = List[ChangeAction]()
    var run = _RunOutputs()
    for oi in range(len(order)):
        var idx = order[oi]
        var lid = graph.node(idx).logical_id()
        var owner = graph.node(idx).owner()
        if not graph.node(idx).wanted():
            # THE CLOSED WORLD: a role the file turned off. Deleted when both
            # sources say it is ours, else left and planned as leftover. It
            # produces nothing, so a consumer of it is refused as unbound.
            var retention = graph.node(idx).retention()
            var live = graph.node(idx).read_presence(creds)
            var identity = cell.stamp(owner, lid).identity()
            var recorded = store.physical_id_for(cell.key(lid))
            var verb = VERB_NOOP
            var why = String("not wanted by the file, and absent")
            if live.is_present():
                if removal_is_ours(cell, identity, retention, live, recorded):
                    verb = VERB_DELETE
                    why = String("not wanted by the file (a role turned off) -> delete")
                else:
                    why = String(
                        "leftover: present and not wanted by the file, but not"
                        " proven kci's by both the store and the stamp (or"
                        " kept by retention); left alone"
                    )
            run.put(lid, Outputs())
            actions.append(
                ChangeAction(lid, verb, why, retention, owner, live.unmanaged)
            )
            continue
        var refs = graph.node(idx).input_refs()
        var waiting_on = String("")
        for r in range(len(refs)):
            var pv = run.pending_verb(refs[r].producer)
            if pv:
                if waiting_on.byte_length() > 0:
                    waiting_on += String(", ")
                waiting_on += (
                    refs[r].field
                    + String(" <- ")
                    + refs[r].producer
                    + String(".")
                    + refs[r].output
                    + String(" (")
                    + pv.value()
                    + String(")")
                )
        if waiting_on.byte_length() > 0:
            run.mark_pending(lid, String("known after apply"))
            actions.append(
                ChangeAction(
                    lid,
                    VERB_KNOWN_AFTER_APPLY,
                    String("(known after apply): ") + waiting_on,
                    graph.node(idx).retention(),
                    owner,
                )
            )
            continue
        if len(refs) > 0:
            graph.node(idx).bind_inputs(_resolve_inputs(lid, refs, run))
        var live = graph.node(idx).read_status(creds)
        var action = graph.node(idx).plan(live)
        action.owner = owner
        action.unmanaged = live.unmanaged.copy()
        if action.verb == VERB_NOOP:
            run.put(lid, graph.node(idx).outputs(live.physical_id, creds))
        else:
            run.mark_pending(lid, String(action.verb_name()))
        actions.append(action^)
    return actions^


# =============================================================================
# §3 — apply_graph — the forward apply with write-ahead recovery.
# =============================================================================
def _node_fault_domain(
    mut graph: ResourceGraph, idx: Int, verb: String, inner: String
) -> Int:
    """WHOSE FAULT this node's `verb` failure is — the engine's resolution of the
    two carriers, in precedence order (`kci_reconciler.fault_domain`).

      1. THE RAISE SITE, if it stated one (`fault_error(FAULT_USER, ...)`
         leaves our canonical token on the front of `inner`). A site that knew
         about THIS failure outranks a claim about the verb in general.
      2. THE CONFORMER'S PER-VERB DECLARATION (`Resource.fault_domain(verb)`).
      3. `FAULT_UNSET` — WHICH READS AS OURS.

    ⚠ THIS FUNCTION CANNOT RAISE, AND THAT IS LOAD-BEARING. It runs on a path
    that is ALREADY failing, inside the `except` arm of the verb that raised. A
    classifier that raised here would replace the operator's real backend error
    with a message about attribution — turning a diagnosable deploy failure into
    an undiagnosable one, in exchange for a label. So a conformer override that
    raises is swallowed and the answer is `FAULT_UNSET`: no classification, ours,
    original error intact."""
    var stated = fault_domain_of_error(inner)
    if stated != FAULT_UNSET:
        return stated
    try:
        return graph.node(idx).fault_domain(verb)
    except:
        # A classifier that failed produced no classification. Ours.
        return FAULT_UNSET


def _node_verb_error(
    lid: String, verb: String, inner: String, domain: Int
) -> Error:
    """Enrich a per-node mutation raise with WHICH node + verb failed
    (DIAGNOSABILITY) and WHOSE FAULT it is (ATTRIBUTION).
    The apply drives many nodes; a bare backend raise
    (e.g. a GCP `Invalid service account`) does not say which node/verb produced it,
    so a caller surfacing `String(e)` (for example as an HTTP 502 detail) could not
    pinpoint the culprit. Prefix the node's logical_id + the verb so ONE surfaced
    error names the exact node + operation. Carries the inner backend message
    verbatim (no secret — a GCP RPC status / HTTP body; the caller's token never
    rides an error body).

    ⚠ THE ATTRIBUTION RIDES THE MESSAGE, NOT AN OUT-PARAMETER, AND THE CHOICE IS
    NOT AESTHETIC. `landed` / `pending` are out-parameters because their consumer
    is the deploy caller, ONE frame up. The domain's consumers are a deploy-log
    writer and the operator surface, MANY frames up and possibly across a
    process boundary — and a Mojo `raise` unwinds a `String` and nothing else. An
    out-parameter would have to be threaded through every intermediate signature,
    where the FIRST frame that forgot it would silently drop the classification.
    A prefix token survives every frame that does nothing at all, which is the
    property this needs.

    ⛔ IF THE INNER MESSAGE ALREADY CARRIES A TOKEN, IT IS STRIPPED FIRST — one
    token per error, at the front, always. Two tokens (`[fault=ours] apply node
    ... failed: [fault=user] ...`) would make `fault_domain_of_error` answer
    with the OUTER one, which is right, while leaving a second one mid-message
    for a human to misread. `_node_fault_domain` has already read the inner one
    and given it precedence, so nothing is lost.

    ⚠ AN UNCLASSIFIED FAILURE EMITS **NO TOKEN**, so its message is BYTE-IDENTICAL
    to what this function produced before attribution existed. That is not a
    semantic gap — `fault_domain_of_error` answers `FAULT_UNSET` for an untagged
    message, which is what an unclassified failure means — but it IS the
    difference between a change that touches every deploy error in the tree and
    one that touches only the errors somebody classified. Today that is all of
    them, so a token on every message would be pure churn against every existing
    log grep, dashboard and operator habit, in exchange for the string `unset`.

    ⇒ A CONSEQUENCE, STATED RATHER THAN GLOSSED: at this seam an explicit
    `fault_error(FAULT_UNSET, ...)` from a raise site is INDISTINGUISHABLE from
    no stamp at all. Both mean "no classification", both read as ours, and
    `_node_fault_domain` lets both fall through to the conformer's per-verb
    declaration — which is right, because "I looked and could not tell" must not
    veto a node that CAN tell. The explicit form is a note to the next reader of
    that raise site, not a signal to this function.

    ⚠ A DEPLOY-FAULT MARK ON `inner` MOVES TO THE FRONT (`deploy_fault`). The
    PERMANENT and IN-FLIGHT marks are prefix tests, so left where the inner
    message puts them they would sit mid-message and stop counting, and a
    proven-permanent fault would be retried like any other. This frame carries
    the SAME fault, so it carries the mark; it never adds one, and a mark the
    node's message only QUOTES is not at the front of `inner` and is not
    carried. The result is `[fault=<domain>] <mark>apply node ...`, the one
    order `deploy_fault` reads. An unmarked failure is unchanged."""
    var body = carry_deploy_fault_mark(
        inner,
        String("apply node '")
        + lid
        + String("' verb=")
        + verb
        + String(" failed: ")
        + deploy_fault_message(inner),
    )
    if domain == FAULT_UNSET:
        return Error(body)
    return fault_error(domain, body)


def apply_graph[
    S: StateStore
](mut graph: ResourceGraph, creds: Creds, mut store: S) raises -> List[
    AppliedNode
]:
    """`apply_graph_tracked` with the progress channels discarded — the shape every
    caller that does not report on a PARTIAL apply keeps using, byte-identical.

    ⚠ A CALLER THAT REPORTS ON FAILURE MUST USE `apply_graph_tracked`. On a raise,
    this form's per-node record dies with the frame, so the operator learns only
    WHICH node failed and never which of the earlier ones already landed. See
    `apply_graph_tracked`'s header for why that distinction is the whole point."""
    var landed = List[AppliedNode]()
    var pending = List[String]()
    return apply_graph_tracked[S](graph, creds, store, landed, pending)


def apply_graph_tracked[
    S: StateStore
](
    mut graph: ResourceGraph,
    creds: Creds,
    mut store: S,
    mut landed: List[AppliedNode],
    mut pending: List[String],
) raises -> List[AppliedNode]:
    """Reconcile the graph to its desired state, in topo order, recording a write-
    ahead intent per node so a crash mid-apply is recoverable.

    ── THE PROGRESS CHANNELS, AND WHY THEY ARE OUT-PARAMETERS ──────────────────
    `landed` and `pending` are filled AS THE WALK PROCEEDS and SURVIVE A RAISE.
    That is the entire reason they are `mut` parameters rather than part of the
    return value: a return value does not exist on the failing path, and the
    failing path is the one an operator needs the information on.

    On a raise:
      * `landed`  — every node this apply already acted on, in APPLY ORDER, with
                    the verb it issued. These are the mutations that are LIVE in
                    the cell right now.
      * `pending` — the logical ids the topo order had NOT reached, in the order
                    they would have run. These did NOT land. The failing node is
                    the FIRST entry (it was reached and did not complete).

    ⛔ THERE IS NO ROLLBACK ON THIS PATH, AND THAT IS A STATEMENT ABOUT THE
    ENGINE, NOT AN OMISSION HERE. `rollback_create` exists in this file, but no
    deploy verb calls it to unwind a partial apply. A failed apply therefore
    leaves the cell HALF-CONFIGURED — for example, a service converges
    while the secret-access grants ordered after the failing node never land, so
    the service comes up and is refused on both of its secret reads.

    ⛔ AND ROLLING BACK WOULD BE THE WRONG DEFAULT ANYWAY. These graphs are
    LEVEL-TRIGGERED and idempotent: every node re-reads live state and adopts what
    already matches, so RE-RUNNING the same deploy after fixing the cause
    completes the remainder — that is the recovery path, and the write-ahead
    PROVISIONING intents this walk leaves behind are what make it safe (a re-apply
    ADOPTS them). Tearing down a converged service because a downstream IAM grant
    NOT_FOUNDed would turn a recoverable partial apply into an outage.

    ⇒ So the obligation this engine CAN meet is to say exactly what happened, and
    these two lists are how it says it. An operator must never have to reconstruct
    a partial apply from Cloud Console.

    Per node:

      1. record_or_adopt_intent(logical_id) — write (or adopt) the PROVISIONING
         intent BEFORE the mutation. `already_confirmed` iff the intent predated us.
      2. read_status(creds) — the LIVE read (the sole actual-state source).
      3. dispatch on the live phase:
           * RES_PRESENT_MATCHED -> ADOPT: no mutation. The physical id is the live
             physical_id (or the store's confirmed id if the live read did not
             surface one).
           * RES_ABSENT           -> CREATE: `create(creds)` -> the physical id.
           * RES_PRESENT_DRIFTED / RES_FAILED -> converge_mode(live):
               - CONVERGE_IN_PLACE -> `update(creds)`. The physical id is the live
                 physical_id.
               - else (CONVERGE_REPLACE / a raise) -> RAISE "CONVERGE_REPLACE
                 unsupported in v1" (the typed hole — no surprise teardown).
             A FAILED resource is treated as drifted: it exists, it does not
             run what the file asks, and an update is the way out (a fixed
             image after a bad one). Refusing it would leave a console edit as
             the only recovery.
           * RES_CONVERGING -> RAISE (the live resource is still reconciling
             toward some state; a v1 apply does not wait for it — fail-loud).
      4. confirm(ticket, physical_id) — heal the intent to CONFIRMED.
      5. append AppliedNode(logical_id, physical_id, retention, already_confirmed,
         verb, served_endpoint) — `served_endpoint` is the served node's live
         endpoint (the Cloud Run `uri`) off the apply's own live read on the no-op /
         update paths (empty on create + for a non-served node).

    Returns the applied nodes in APPLY ORDER (so the caller can rollback_create
    them in reverse). RAISES on the typed hole, a non-steady live phase, or a
    genuine backend fault — a raise leaves the surviving PROVISIONING intents for
    a re-apply to adopt (the recovery property)."""
    return _apply_impl(graph, creds, CellScope.unowned(), store, landed, pending)


def apply_graph_owned[
    S: StateStore
](
    mut graph: ResourceGraph,
    creds: Creds,
    cell: CellScope,
    mut store: S,
    mut landed: List[AppliedNode],
    mut pending: List[String],
) raises -> List[AppliedNode]:
    """`apply_graph_tracked` in `cell` (the owned scope; the file header's ★
    section): the store keyed by the cell, the owned pre-flight before any
    change (`kci: REFUSED apply ...`), the identity written with the
    write-ahead intent, every create a `create_owned(stamp)`, and an adopted
    unstamped object stamped by `adopt_owned`. The progress channels behave as
    in `apply_graph_tracked`; a pre-flight refusal raises with `landed` empty
    and `pending` the whole graph (nothing changed)."""
    if not cell.owned():
        raise Error(
            String("apply_graph_owned: the scope names no machine and cell;")
            + String(" use apply_graph_tracked for the unowned scope")
        )
    return _apply_impl(graph, creds, cell, store, landed, pending)


def _apply_impl[
    S: StateStore
](
    mut graph: ResourceGraph,
    creds: Creds,
    cell: CellScope,
    mut store: S,
    mut landed: List[AppliedNode],
    mut pending: List[String],
) raises -> List[AppliedNode]:
    var order = topo_sort(graph)
    var applied = List[AppliedNode]()
    # ---- 0: seed the progress channels BEFORE the first mutation ----
    # `pending` starts as the WHOLE topo order and is drained one entry per node
    # completed, so at every instant — including inside a raise unwinding out of
    # this frame — `landed + pending` is the whole graph and `pending[0]` is the
    # node currently being acted on. Seeding it here (rather than computing a
    # remainder in an except arm) is what makes that true on EVERY raise path,
    # including the ones added later by somebody who never read this comment.
    landed.clear()
    pending.clear()
    for oi in range(len(order)):
        pending.append(graph.node(order[oi]).logical_id())
    # ---- 0a: the owned pre-flight, BEFORE ANY CHANGE ----
    # Every node must stamp ownership and every present object must be this
    # node's (or adopted by name). A refusal raises here with nothing changed.
    refuse_unless_owned(
        graph, order, creds, cell, store, String("apply"), True
    )
    var run = _RunOutputs()
    for oi in range(len(order)):
        var idx = order[oi]
        var lid = graph.node(idx).logical_id()
        var retention = graph.node(idx).retention()
        var key = cell.key(lid)
        var stamp = cell.stamp(graph.node(idx).owner(), lid)
        var identity = stamp.identity() if cell.owned() else String("")

        # ---- 0b: THE CLOSED WORLD — a node the file no longer wants ----
        # Deleted when the store recorded it with the same physical id and
        # (owned) it carries this node's stamp; otherwise left (leftover).
        # It produces nothing.
        if not graph.node(idx).wanted():
            var gone_verb = VERB_NOOP
            var gone_pid = String("")
            var plive = graph.node(idx).read_presence(creds)
            var recorded = store.physical_id_for(key)
            if removal_is_ours(cell, identity, retention, plive, recorded):
                gone_pid = recorded.copy()
                try:
                    delete_confirmed(
                        graph, idx, lid, key, gone_pid, creds, store
                    )
                except de:
                    raise _node_verb_error(
                        lid,
                        String("delete"),
                        String(de),
                        _node_fault_domain(
                            graph, idx, String("delete"), String(de)
                        ),
                    )
                gone_verb = VERB_DELETE
            elif not plive.is_present():
                # Absent: retire any record left by an earlier run.
                store.mark_reaped(key)
            var gone = AppliedNode(
                lid, gone_pid^, retention, False, gone_verb, String(""), key^
            )
            applied.append(gone.copy())
            landed.append(gone^)
            if len(pending) > 0:
                _ = pending.pop(0)
            run.put(lid, Outputs())
            continue

        # ---- 0: BIND BEFORE READ ----
        # Every producer of this node has been applied (topo order) and has
        # reported its outputs, so the node's desired state holds real values
        # before it is read and planned. An unresolved value raises here,
        # before any intent is written for the node.
        var refs = graph.node(idx).input_refs()
        if len(refs) > 0:
            graph.node(idx).bind_inputs(_resolve_inputs(lid, refs, run))

        # ---- 1: write-ahead intent (record or adopt) BEFORE the mutation ----
        # THE WRITE-AHEAD HOOK: the intent names the key AND the identity the
        # create will stamp, so a crash after the create leaves a record of
        # what the orphan object carries.
        var ticket = store.record_or_adopt_intent(key, identity)

        # ---- 2: the LIVE read (the sole actual-state source) ----
        var live: ResourceStatus
        try:
            live = graph.node(idx).read_status(creds)
        except re:
            raise _node_verb_error(
                lid,
                String("read_status"),
                String(re),
                _node_fault_domain(
                    graph, idx, String("read_status"), String(re)
                ),
            )

        # ---- 2b: OWNERSHIP, again at the point of change ----
        # The pre-flight read every node; this re-check catches an object that
        # appeared or changed hands since (another writer in the same cell).
        # An unstamped object this run was told to ADOPT is stamped here, and
        # the node is then converged like any other present object.
        var adopted = False
        if cell.owned() and live.is_present():
            var recorded = store.physical_id_for(key)
            var why = ownership_problem(
                lid,
                identity,
                True,
                live.physical_id,
                live.stamp,
                recorded,
                cell.adopts(lid),
            )
            if why.byte_length() > 0:
                raise Error(
                    String("apply node '")
                    + lid
                    + String("': ownership changed during the run: ")
                    + why
                )
            if live.stamp != identity:
                try:
                    graph.node(idx).adopt_owned(
                        stamp, live.physical_id, creds
                    )
                except ae:
                    raise _node_verb_error(
                        lid,
                        String("adopt"),
                        String(ae),
                        _node_fault_domain(
                            graph, idx, String("adopt"), String(ae)
                        ),
                    )
                adopted = True

        # ---- 3: dispatch on the live phase ----
        var physical_id: String
        var verb: Int
        # The served node's live endpoint (the Cloud Run `uri`) captured off the
        # apply's OWN live read on the no-op / update paths — the DEPLOY->VALIDATE
        # handoff source. EMPTY on the CREATE path (the pre-create live read was
        # ABSENT; the caller's fallback poll fills a fresh create) and for a non-
        # served node (its live read carries no endpoint).
        var served_endpoint = String("")
        if live.phase == RES_PRESENT_MATCHED:
            # ADOPT: the live resource already matches — no mutation.
            physical_id = live.physical_id
            # An adopted object was stamped (a mutation): UPDATE, so a
            # rollback can never delete it (it predates this run).
            verb = VERB_UPDATE if adopted else VERB_NOOP
            # The no-op re-apply STILL surfaces the served URL — off the live read
            # we already did (no extra RPC). So a no-op
            # user-env re-apply records `served_endpoint` without a post-apply
            # poll (which returns NOT_FOUND/CONVERGING on that path).
            served_endpoint = live.endpoint
        elif live.phase == RES_ABSENT:
            # CREATE: the absent branch. A raise is enriched with the node's
            # logical_id + verb (DIAGNOSABILITY) so the surfaced
            # `String(e)` pinpoints WHICH node/verb failed.
            try:
                if cell.owned():
                    # Born stamped: the identity rides the create call itself.
                    physical_id = graph.node(idx).create_owned(stamp, creds)
                else:
                    physical_id = graph.node(idx).create(creds)
            except ce:
                raise _node_verb_error(
                    lid,
                    String("create"),
                    String(ce),
                    _node_fault_domain(
                        graph, idx, String("create"), String(ce)
                    ),
                )
            verb = VERB_CREATE
        elif live.phase == RES_PRESENT_DRIFTED or live.phase == RES_FAILED:
            # DRIFTED, or FAILED (a failed resource is updatable: the next
            # apply with a fixed spec is how it recovers): converge in place,
            # or fail-loud on a replace-needing drift.
            var mode = graph.node(idx).converge_mode(live)
            if mode == CONVERGE_IN_PLACE:
                try:
                    graph.node(idx).update(creds)
                except ue:
                    raise _node_verb_error(
                        lid,
                        String("update"),
                        String(ue),
                        _node_fault_domain(
                            graph, idx, String("update"), String(ue)
                        ),
                    )
                physical_id = live.physical_id
                verb = VERB_UPDATE
                # The pre-update live read carries the CURRENTLY-served uri — the
                # served URL exists (the update is in-place on a live service), so
                # surface it here (no extra RPC) just like the matched path.
                served_endpoint = live.endpoint
            else:
                raise Error(
                    String("apply_graph: node '")
                    + lid
                    + String("' drifted (or failed) and its converge_mode is")
                    + String(" CONVERGE_REPLACE")
                    + String(" — REPLACE (delete-then-create) is UNSUPPORTED in v1")
                    + String(" (the typed hole; the engine refuses to guess a")
                    + String(" destructive teardown). Resolve the drift out of")
                    + String(" band or extend the engine with a replace path.")
                )
        else:
            # CONVERGING (or an unknown phase): not a state a v1 apply acts on.
            raise Error(
                String("apply_graph: node '")
                + lid
                + String("' read a non-steady live phase (")
                + String(live.phase)
                + String(") — the engine reconciles absent/matched/drifted/")
                + String("failed; a converging resource must settle before")
                + String(" apply. ")
                + live.message
            )

        # ---- 3b: BEST-EFFORT retention prune (after a successful create / update) --
        # After the node converged (a CREATE of a fresh version, or an in-place
        # UPDATE that rolled out a new version), prune the older resource VERSIONS
        # the node retains beyond its keep_last_n (e.g. Cloud Run revisions). This is
        # a DIFFERENT axis from RETAIN_* retention (may-delete-on-teardown): it bounds
        # how many versions survive a FORWARD deploy. BEST-EFFORT: a prune fault must
        # NEVER fail the deploy — swallow it and continue (the same posture as the
        # best-effort delete; the level-triggered next deploy re-prunes). A non-
        # versioned node no-ops (the Resource-trait default `prune`). Only fires on
        # create/update (a no-op adopt has no new version; a raise short-circuits
        # before here).
        if verb == VERB_CREATE or verb == VERB_UPDATE:
            try:
                graph.node(idx).prune(creds)
            except prune_err:
                # Best-effort: a prune fault does not fail the apply. The older
                # versions remain; the next forward deploy re-prunes them.
                #
                # SWALLOWED-AND-LOGGED (NOT silent). A persistently-failing prune
                # — a missing `run.revisions.delete` IAM grant, or the live
                # ListRevisions/DeleteRevision cloud-gated stub raising
                # not-implemented — would otherwise accrue revisions FOREVER with
                # ZERO operational signal (the "it never works" == "nothing to
                # prune" trap). Emit a WARN breadcrumb (node + verb + the fault)
                # via the ambient komira_log facade so a stuck prune is
                # observable; the deploy still succeeds.
                log.warn[
                    "retention prune failed (best-effort; deploy continues):"
                    " node={} verb={} err={}",
                    "kci_reconciler",
                ](
                    ArgStr(lid.copy()),
                    ArgI64(Int64(verb)),
                    ArgStr(String(prune_err)),
                )

        # ---- 4: confirm the intent (heal PROVISIONING -> CONFIRMED) ----
        # For an ADOPT of an already-confirmed node, the physical id may be empty
        # from the live read; fall back to the store's confirmed id so confirm is a
        # faithful no-op-shaped re-confirm.
        if physical_id.byte_length() == 0 and ticket.already_confirmed:
            physical_id = store.physical_id_for(key)
        store.confirm(ticket, physical_id)

        # ---- 5: record what we did (for rollback) ----
        var record = AppliedNode(
            lid,
            physical_id,
            retention,
            ticket.already_confirmed,
            verb,
            served_endpoint^,
            key.copy(),
        )
        applied.append(record.copy())
        # ---- 5b: advance the progress channels ----
        # The node's mutation completed and its intent healed, so it moves from
        # `pending` to `landed` NOW, before its outputs are read. It happens
        # AFTER `store.confirm` and after every raise site of the mutation, so
        # a node in `landed` is one whose mutation completed AND whose intent
        # healed, exactly the claim the failure report makes about it.
        #
        # ⛔ NOT AFTER THE OUTPUTS READ. `outputs` may read live (a created
        # node has never been read since its create), and that read can fail.
        # Had the node moved to `landed` only after it, a failing read would
        # leave a LIVE, CONFIRMED resource out of `landed`: the failure report
        # would say nothing was created, and a teardown of what this apply
        # created would not find it.
        landed.append(record^)
        if len(pending) > 0:
            _ = pending.pop(0)

        # ---- 6: what the node produced ----
        # Re-derived on EVERY apply, whatever the verb: an adopted node's values
        # come from its live read, not from state. Persisted beside the physical
        # id as a fallback for readers that cannot read live. A raise is
        # enriched like the mutation verbs' (node + verb + fault domain); the
        # node is already in `landed` (above).
        var outs: Outputs
        try:
            outs = graph.node(idx).outputs(physical_id, creds)
        except oe:
            raise _node_verb_error(
                lid,
                String("outputs"),
                String(oe),
                _node_fault_domain(graph, idx, String("outputs"), String(oe)),
            )
        store.record_outputs(key, outs)
        run.put(lid, outs^)

    return applied^


# =============================================================================
# §4 — rollback_create — undo an apply_graph's creates, in REVERSE order.
# =============================================================================
def rollback_create[
    S: StateStore
](
    mut graph: ResourceGraph,
    applied: List[AppliedNode],
    creds: Creds,
    mut store: S,
) raises:
    """Undo the creates of an `apply_graph` (e.g. a later node failed and the whole
    apply must be unwound), walking `applied` in REVERSE order (a dependent is torn
    down BEFORE the node it depends on). Per applied node:

      * SKIP RETAIN_KEEP — the engine NEVER deletes a kept / shared resource (the
        shared-bucket-retention invariant).
      * SKIP every verb but VERB_CREATE — VERB_NOOP: this apply ADOPTED the
        resource (the live read reported RES_PRESENT_MATCHED and we mutated
        NOTHING); VERB_UPDATE: the resource EXISTED before this apply (the live
        read reported it drifted or failed) and we only changed it. Neither is
        a create of ours, so neither is ours to unwind.
      * SKIP already_confirmed — the intent PREDATED this apply (we did NOT create
        the resource, so we must not delete it; unwinding OUR apply must not reap a
        resource a prior apply owns).
      * else — `delete(physical_id, creds)` (idempotent — a 404 is a no-op) then
        `mark_reaped(logical_id)`.

    ⛔ WHY THE VERB_NOOP SKIP IS SEPARATE FROM already_confirmed, AND WHY OMITTING
    IT DESTROYS USER DATA. `already_confirmed` is a fact about OUR INTENT
    LEDGER — "a prior apply of ours confirmed this key" — NOT about who created the
    resource. On the FIRST apply against a PRE-EXISTING cloud resource there is no
    prior intent, so `record_or_adopt_intent` writes a fresh PROVISIONING row and
    the ticket reports already_confirmed=False, while the live read reports MATCHED
    and §3 ADOPTS with verb=VERB_NOOP. Skipping only already_confirmed would
    therefore issue `delete(physical_id)` against a resource this deploy never
    created — a user's pre-existing bucket / table / secret, destroyed
    because an unrelated node failed later in the same apply. Adoption is the
    ORDINARY `MATCHED` arm of `apply_graph`, not a rare path, so this would reach
    every adopted resource.
    VERB_NOOP is the engine's own record of "live already matched; we mutated
    nothing", which is exactly the question the unwind must ask.
    Falsified by `tests/test_resource_graph_engine.mojo`'s
    `test_rollback_never_deletes_an_adopted_node_on_first_apply`.

    ⛔ AND THE SAME HOLDS FOR VERB_UPDATE. On a first apply against a
    pre-existing resource that DRIFTED, the ticket again reports
    already_confirmed=False and §3 issues `update`; in a run whose state store
    is new (a scratch cell, a lost store) that is every resource the apply
    touched. Deleting it would turn "a later node failed" into "the service
    that was running before this deploy is gone". An updated node's prior
    state is a `rollback_update` concern (a wrapper's), never a delete.
    Falsified by `test_rollback_never_deletes_an_updated_node`.

    ⚠ ONLY A CREATE IS UNWOUND, AND IT STILL IS. A node this apply genuinely
    CREATED (VERB_CREATE) is still deleted — a fix that stopped all rollback
    deletion would replace a data-loss bug with an orphan-resource bug, and that
    node's arm is asserted by both falsifiers.

    A delete failure RAISES and STOPS (fail-loud — a half-rolled-back state is
    surfaced, not silently continued; the surviving reaped/un-reaped intents let a
    re-drive resume). This is rollback of CREATES only — it does NOT revert an
    in-place update to a prior digest (that provider-spec-specific rollback_update
    is a wrapper concern)."""
    var i = len(applied) - 1
    while i >= 0:
        ref node = applied[i]
        if node.retention == RETAIN_KEEP:
            # NEVER delete a kept / shared resource.
            i -= 1
            continue
        if node.retention == RETAIN_UNDELETABLE:
            # ⛔ NO DELETE CAPABILITY EXISTS for this node — its conformer's
            # `delete` would REFUSE. Unwinding an apply must not be the one path
            # that reaches a verb the teardown path is forbidden to reach; the
            # rollback would raise, and a rollback that raises leaves the apply
            # HALF-unwound with no record of which half. `rollback_create` takes
            # no report parameter (its caller is mid-failure and already
            # raising), so this skip is silent HERE and loud in `destroy_graph`,
            # which is the verb an operator invokes deliberately.
            i -= 1
            continue
        if node.verb != VERB_CREATE:
            # NOT A CREATE OF OURS. VERB_NOOP: adopted, nothing mutated.
            # VERB_UPDATE: the resource existed before this apply; we changed
            # it, we did not make it. This arm covers the FIRST apply, where
            # `already_confirmed` is False because no prior intent exists — see
            # the docstring. Deleting here destroys a pre-existing resource.
            i -= 1
            continue
        if node.already_confirmed:
            # The node predated this apply — we did not create it; do not delete it.
            i -= 1
            continue
        # Resolve the node index to drive its (idempotent) delete verb.
        var idx = graph.index_of(node.logical_id)
        if idx >= 0:
            # delete is idempotent (a 404 is a no-op); a real fault raises + stops.
            graph.node(idx).delete(node.physical_id, creds)
        store.mark_reaped(node.key)
        i -= 1


# =============================================================================
# §5 — destroy_graph — tear the whole graph down, in REVERSE topo order.
# =============================================================================
def destroy_graph[
    S: StateStore
](
    mut graph: ResourceGraph,
    creds: Creds,
    mut store: S,
    force_delete_data: Bool = False,
    scope: Optional[List[String]] = None,
) raises -> List[UndeletableSkip]:
    """Tear down every node of the graph in the UNOWNED scope, in REVERSE topo order (a dependent is
    deleted BEFORE the node it depends on). RETURNS the nodes it could not delete
    (see the ⛔ RETAIN_UNDELETABLE block below); an empty list means every node was
    either reaped or kept by policy. Per node:

      * SKIP RETAIN_UNDELETABLE — UNCONDITIONALLY, `force_delete_data` INCLUDED.
        Recorded in the returned list, NOT `mark_reaped`, NOT live-read.
      * SKIP RETAIN_KEEP — the engine NEVER deletes a kept / shared resource (the
        shared-bucket-retention invariant: destroy retains the standing scope) —
        UNLESS `force_delete_data` is set (the `--delete-data` whole-project override,
        below).
      * else — `read_presence(creds)` (the live read, no digest: teardown
        needs no bound inputs); then:
          - ABSENT — the resource is provably already gone (`read_presence` returns
            ABSENT ONLY on a real 404 / NOT_FOUND; a transient / GOAWAY / 5xx RAISES
            out of this loop, it does NOT read as absent). `mark_reaped` retires the
            intent (idempotent already-gone) — NO delete to issue.
          - PRESENT — `delete(physical_id, creds)` (idempotent — a 404 is a no-op),
            THEN a CONFIRMING re-read: `mark_reaped` fires ONLY when that re-read is
            ABSENT (the delete provably removed the resource). If the re-read still
            shows the resource PRESENT (the delete did not take — an eventually-
            consistent backend, a partial delete, a swallowed-but-transient outcome),
            the intent is LEFT INTACT and the destroy RAISES (fail-loud) so the
            level-triggered reconcile re-drives on the next tick. A transient re-read
            RAISES the same way (never a silent retire).

    ⛔ THE CONFIRMED-GONE GATE (the MONEY-LEAK gate). `mark_reaped` is the
    RECORD RETIREMENT — retiring it while the physical resource is still LIVE orphans
    a billable resource forever (no level-triggered re-drive can recover it — the
    record is gone). So the retire is gated on a CONFIRMED-GONE outcome: a provable-
    404 absent read, OR a delete-then-reread that comes back ABSENT. A transient /
    ambiguous read (which `read_presence` surfaces as a RAISE, never as ABSENT) and a
    resource that SURVIVES its delete both LEAVE the record for the re-drive. This is
    the "fail-loud, no partial-reap swallowed" contract. An unconditional
    `mark_reaped` (retire regardless) would violate it: a read that reported
    absent, or a delete that did not actually remove the resource, would retire
    the intent with the service still live.

    THE `force_delete_data` OVERRIDE (the `--delete-data` whole-project teardown).
    DEFAULTS FALSE (the RETAIN_KEEP invariant holds). When TRUE, the
    RETAIN_KEEP skip is LIFTED: a kept resource (the shared bootstrap bucket, the
    signing seed, the AR repo) is ALSO live-read-then-deleted. This is ONLY for
    tearing down a whole project (the operator has explicitly opted into destroying
    data-bearing / shared scope). A per-app `delete` NEVER passes it — RETAIN_KEEP is
    the shared-resource protection a single app teardown must honor.

    ── ⛔ AND WHAT `force_delete_data` MAY **NOT** OVERRIDE: RETAIN_UNDELETABLE ──
    The flag lifts a POLICY. It cannot lift a CAPABILITY, and if the two shared
    one code path the flag would reach both: a `--delete-data` teardown would
    issue the delete for a node whose conformer refuses it under any retention
    (a container registry repository, for example), the raise would propagate
    out of this loop, and the walk would STOP — every node after it surviving
    unreaped and unreported. Overriding a capability cannot make one exist; it
    can only convert "we cannot delete this one resource" into "the teardown
    died here".

    ⇒ SO A RETAIN_UNDELETABLE NODE IS SKIPPED BEFORE THE FLAG IS EVEN CONSULTED,
      and three consequences are deliberate:

      1. NOT `mark_reaped` — the physical resource is LIVE. Retiring its intent
         orphans a billable resource behind a retired record, which is exactly the
         money-leak the CONFIRMED-GONE gate above exists to stop. The intent
         survives, so a future run (or a human) still has the record.
      2. NOT live-read — the node is skipped, and a skipped node costs no API
         call, identically to the RETAIN_KEEP skip. The returned record therefore
         says "this teardown did not attempt it", never "this resource exists".
      3. RETURNED, never swallowed. The walk CONTINUES to the remaining nodes —
         which is the whole fix; a teardown that stops at the first undeletable
         node can never complete — and the caller is handed one `UndeletableSkip`
         per survivor to render. A caller that discards the list has chosen to;
         it cannot happen by omission, because the value is in the signature.

    ⚠ THE ENGINE ASKS ONLY `retention()`. There is no list of exempt kinds here
    and there must never be one: the conformer that owns the `delete` verb is the
    only thing that knows whether it has one, and a second table would be a second
    truth to keep in sync.

    ── ⭐ THE OPTIONAL `scope` — A CEILING ON WHAT MAY BE DELETED ──────────────
    `None` (the default) means the
    whole graph is in scope. A PRESENT list is a set of `logical_id`s this walk is
    PERMITTED to touch; a node absent from it is skipped exactly as a RETAIN_KEEP
    node is — NOT deleted, NOT live-read, and ⛔ NOT `mark_reaped`, because the
    resource may well be live and retiring its record would orphan it behind a
    retired intent.

    ⭐ THIS IS WHY CFN-STYLE ROLLBACK NEEDS NO SECOND TEARDOWN VERB. The graph
    ENUMERATES (a rollback's delete set is derived from two declared manifests,
    which is correct even when the applying process died before any ledger write)
    and the scope only FILTERS — it narrows an already-enumerated walk to the
    nodes this release ADDED, or to the nodes a durable created-set proves this
    attempt made rather than ADOPTED. One mechanism with a parameter, not two
    mechanisms; and because it is the SAME walk, a scoped teardown inherits the
    CONFIRMED-GONE gate below by construction rather than by a promise.

    ⛔ AN EMPTY-BUT-PRESENT LIST MEANS "DELETE NOTHING", AND IT IS HONOURED. It is
    not conflated with `None`: `Optional` is what keeps "the caller stated a scope
    that happens to be empty" distinguishable from "the caller stated no scope",
    which are the two answers a `List[String]()` sentinel would collapse — the
    absent-vs-empty collapse. A
    caller that cannot compute its scope must REFUSE, not pass an empty one.

    ⚠ THE SCOPE IS A CEILING, NEVER A COMMAND. Every gate below still applies to
    an in-scope node: RETAIN_UNDELETABLE is still skipped and reported,
    RETAIN_KEEP is still skipped without `force_delete_data`, and the record is
    still retired only on a CONFIRMED-GONE outcome. A scope can only ever make a
    teardown do LESS.

    A delete failure RAISES and STOPS (fail-loud). Reverse topo order guarantees a
    node is never deleted while a live dependent still references it."""
    return _destroy_impl(
        graph, creds, CellScope.unowned(), store, force_delete_data, scope
    )


def destroy_graph_owned[
    S: StateStore
](
    mut graph: ResourceGraph,
    creds: Creds,
    cell: CellScope,
    mut store: S,
    force_delete_data: Bool = False,
    scope: Optional[List[String]] = None,
) raises -> List[UndeletableSkip]:
    """`destroy_graph` in `cell` (the owned scope). Before ANY delete, every
    node must stamp ownership and every present object must carry this node's
    identity: a FOREIGN or CONFLICT object refuses the whole teardown
    (`kci: REFUSED destroy ...`). An adoption is never a reason to delete, so
    `cell.adopt` is ignored here. The rest is `destroy_graph`."""
    if not cell.owned():
        raise Error(
            String("destroy_graph_owned: the scope names no machine and cell;")
            + String(" use destroy_graph for the unowned scope")
        )
    return _destroy_impl(graph, creds, cell, store, force_delete_data, scope)


def _destroy_impl[
    S: StateStore
](
    mut graph: ResourceGraph,
    creds: Creds,
    cell: CellScope,
    mut store: S,
    force_delete_data: Bool,
    scope: Optional[List[String]],
) raises -> List[UndeletableSkip]:
    var order = topo_sort(graph)
    var rorder = reverse_order(order)
    # The owned pre-flight, BEFORE ANY DELETE: nothing foreign is ever deleted,
    # and an adoption is never a reason to delete. It reads only the nodes
    # this walk would delete (in scope, not UNDELETABLE, not KEEP unless
    # forced), so a skipped node still costs no call.
    if cell.owned():
        var targets = List[Int]()
        for ti in range(len(rorder)):
            var tidx = rorder[ti]
            if scope:
                var tid = graph.node(tidx).logical_id()
                var inside = False
                for si in range(len(scope.value())):
                    if scope.value()[si] == tid:
                        inside = True
                        break
                if not inside:
                    continue
            var tret = graph.node(tidx).retention()
            if tret == RETAIN_UNDELETABLE:
                continue
            if tret == RETAIN_KEEP and not force_delete_data:
                continue
            targets.append(tidx)
        refuse_unless_owned(
            graph, targets, creds, cell, store, String("destroy"), False
        )
    var undeletable = List[UndeletableSkip]()
    for oi in range(len(rorder)):
        var idx = rorder[oi]
        if scope:
            # ⭐ OUT OF SCOPE — skipped BEFORE retention, BEFORE the live read and
            # BEFORE any delete. NOT `mark_reaped`: the resource may be live and a
            # retired record over a live resource is the money leak the
            # CONFIRMED-GONE gate below exists to stop. A scoped walk therefore
            # makes this node invisible to the teardown, which is precisely what a
            # rollback's "destroy only what this release ADDED" means.
            var sid = graph.node(idx).logical_id()
            var permitted = False
            for si in range(len(scope.value())):
                if scope.value()[si] == sid:
                    permitted = True
                    break
            if not permitted:
                continue
        var retention = graph.node(idx).retention()
        if retention == RETAIN_UNDELETABLE:
            # ⛔ NO DELETE CAPABILITY — skipped regardless of `force_delete_data`,
            # recorded so the survivor is NAMED, and NOT reaped (it is still live).
            var ulid = graph.node(idx).logical_id()
            var why = graph.node(idx).undeletable_reason()
            if why.byte_length() == 0:
                why = (
                    String(
                        "the conformer declares RETAIN_UNDELETABLE but states no"
                        " reason — that is a DEFECT in that conformer"
                        " (`undeletable_reason()` was left at the trait default)."
                        " The node is skipped and named here rather than dropped"
                        " from the report, because an unexplained survivor is"
                        " still a survivor. Node: "
                    )
                    + ulid
                )
            undeletable.append(UndeletableSkip(ulid, why^))
            continue
        if retention == RETAIN_KEEP and not force_delete_data:
            # NEVER delete a kept / shared resource — destroy retains the standing
            # scope (the shared bucket / WIF pool / VPC) — unless the operator passed
            # `--delete-data` (force_delete_data), the explicit whole-project override.
            continue
        var lid = graph.node(idx).logical_id()
        # ⛔ TEARDOWN NEEDS NO BOUND INPUTS. It reads with `read_presence`
        # (present or absent + physical id, no digest), so a consumer whose
        # references cannot be bound now is still found and deleted. The
        # references are bound from the producers' PERSISTED outputs when the
        # store has every one of them, for a node that does not override
        # `read_presence`; when it has not, nothing is bound and nothing is
        # refused.
        var key = cell.key(lid)
        bind_from_recorded_outputs(graph, idx, cell, store)
        var live = graph.node(idx).read_presence(creds)
        if not live.is_present():
            # ABSENT — the resource is PROVABLY already gone. `read_presence` returns
            # ABSENT ONLY on a real 404 / NOT_FOUND; a transient (GOAWAY / H2_PROTOCOL
            # / 5xx / DEADLINE / network) RAISES out of this loop rather than reading
            # as absent. So an absent read is a confirmed-gone outcome — retire the
            # intent (idempotent — a never-recorded node no-ops), no delete to issue.
            store.mark_reaped(key)
            continue

        # PRESENT — issue the (idempotent) delete; a real fault raises + stops.
        var pid = live.physical_id
        if pid.byte_length() == 0:
            # the live read did not surface a physical id — fall back to the store's
            # confirmed id (the id the create confirmed).
            pid = store.physical_id_for(key)
        if cell.owned():
            # The pre-flight saw this object as ours; a stamp that changed
            # since (another writer) stops the teardown before the delete.
            var identity = cell.stamp(graph.node(idx).owner(), lid).identity()
            if live.stamp != identity:
                raise Error(
                    String("destroy_graph: node '")
                    + lid
                    + String("': ownership changed during the run; the live")
                    + String(" object no longer carries this node's stamp, so")
                    + String(" it is not deleted")
                )
        # ⛔ CONFIRM-GONE before retiring the record (the money-leak gate):
        # `delete_confirmed` re-reads, and retires the record ONLY when the
        # re-read is ABSENT; still PRESENT leaves the record intact and RAISES
        # so the level-triggered reconcile re-drives (never retire a record
        # over a live resource). A transient re-read RAISES too.
        delete_confirmed(graph, idx, lid, key, pid, creds, store)
    return undeletable^
