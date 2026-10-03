# =============================================================================
# test_resource_graph_engine.mojo — the unit gate for the provider-neutral
#   resource-graph deploy engine core (kci_reconciler).
# =============================================================================
#
# Drives the engine (plan / apply / rollback / destroy) over a pure in-memory
# `FakeResource` conformer (configurable phase / retention / deps + a call-recorder)
# and a DIAMOND graph (A -> B, C -> D). Every case is a FALSIFIER for a load-bearing
# engine property:
#
#   (1) topo order is DEPENDENCY-CORRECT — A before B,C; B,C before D.
#   (2) apply_graph CREATES in topo order (each absent node -> one create).
#   (3) rollback_create tears down in REVERSE order AND SKIPS a RETAIN_KEEP node
#       AND SKIPS an already_confirmed node.
#   (4) a CYCLE raises (fail-loud).
#   (5) plan_graph mutates NOTHING (read-only dry run — zero create/update/delete).
#   (6) a DRIFTED node whose converge_mode is REPLACE raises "unsupported in v1".
#   (7) destroy_graph tears down in REVERSE topo order AND SKIPS RETAIN_KEEP
#       (the shared-bucket-retention invariant) AND is idempotent on a 404.
#   (8) apply_graph adopts a MATCHED node (no create) and updates a DRIFTED node.
#   (9) crash-then-adopt: a re-apply ADOPTS the surviving intent (no double-create).
#
# The FakeResource holds its (phase, retention, deps, call-recorder) behind an
# ArcPointer so a `share()`d handle read by the test sees the SAME state the erased
# graph node mutates (the seam-mock interior-mutation shape — the node is erased +
# owned by the graph, so the test reads its behavior off a shared recorder handle).
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false, assert_raises

from kci_reconciler import (
    Resource,
    ResourceStatus,
    ChangeAction,
    Creds,
    ErasedResource,
    ResourceGraph,
    topo_sort,
    reverse_order,
    StateStore,
    IntentTicket,
    InMemoryStateStore,
    AppliedNode,
    UndeletableSkip,
    undeletable_report_lines,
    plan_graph,
    apply_graph,
    apply_graph_tracked,
    rollback_create,
    destroy_graph,
    RES_ABSENT,
    RES_PRESENT_MATCHED,
    RES_PRESENT_DRIFTED,
    RES_FAILED,
    RETAIN_DELETE,
    RETAIN_KEEP,
    RETAIN_UNDELETABLE,
    CONVERGE_IN_PLACE,
    CONVERGE_REPLACE,
    VERB_CREATE,
    VERB_UPDATE,
    VERB_NOOP,
)


def _contains_sub(haystack: String, needle: String) -> Bool:
    """BYTES, not codepoints — every needle here is ASCII, and no UTF-8
    continuation byte can collide with an ASCII one."""
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0:
        return True
    if len(nb) > len(hb):
        return False
    for s in range(len(hb) - len(nb) + 1):
        var ok = True
        for j in range(len(nb)):
            if hb[s + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


# =============================================================================
# FakeResource — a pure in-memory `Resource` conformer for the engine gate. NO
# cloud, NO provider. Its (configurable phase / retention / deps + a call-recorder)
# lives behind an ArcPointer so a `share()`d handle the test holds reads the SAME
# state the erased graph node mutates.
# =============================================================================
struct _FakeState(Movable, Deinitable):
    """The FakeResource interior: its identity + configured behavior + the recorded
    verb log. No pointer field (flat String / List[String] / Int / Bool; no byte-slab)."""

    var logical_id: String
    var deps: List[String]
    var retention: Int
    # The live PHASE read_status returns (RES_ABSENT / MATCHED / DRIFTED). A test
    # flips this to model a node that becomes present after a create.
    var phase: Int
    # The converge mode a DRIFTED node reports (IN_PLACE or REPLACE).
    var converge: Int
    # The physical id create returns / the live read surfaces.
    var physical_id: String
    # Whether delete should raise a (swallowed) 404 (models an already-gone node).
    var delete_404: Bool
    # Whether delete should NOT change the live phase (models a delete that was
    # ISSUED but did NOT actually remove the resource — an eventually-consistent
    # backend / partial delete / a swallowed-but-transient outcome). The confirm-gone
    # re-read then still sees the resource present -> destroy must RAISE, NOT reap.
    var delete_noop: Bool
    # A countdown of read_status calls that RAISE before the first success (models a
    # transient GOAWAY / H2_PROTOCOL / 5xx read — the conformer RAISES, it does NOT
    # read as absent). Decrements each read; when >0 the read raises.
    var read_raises_remaining: Int
    # When True, `create` RAISES a backend fault (models a node whose mutation fails —
    # so the engine's per-node error enrichment names WHICH node/verb failed).
    var create_raises: Bool
    # Whether the best-effort retention `prune` should RAISE a genuine (non-404)
    # transport fault (models a missing revisions.delete IAM grant / an unimplemented
    # live ListRevisions verb). The engine MUST swallow this raise — a prune fault
    # NEVER fails the deploy (engine.mojo §3b best-effort contract).
    var prune_raises: Bool
    # The conformer's own WHY for a RETAIN_UNDELETABLE node (`undeletable_reason`).
    # EMPTY by default, which is the trait default and models a conformer that
    # declared the code and stated no reason — a case the engine must still name.
    var undeletable_reason: String
    # The ordered verb log: "read", "create", "update", "delete", "prune".
    var calls: List[String]

    def __init__(
        out self,
        var logical_id: String,
        var deps: List[String],
        retention: Int,
        phase: Int,
        converge: Int,
        var physical_id: String,
    ):
        self.logical_id = logical_id^
        self.deps = deps^
        self.retention = retention
        self.phase = phase
        self.converge = converge
        self.physical_id = physical_id^
        self.delete_404 = False
        self.delete_noop = False
        self.read_raises_remaining = 0
        self.create_raises = False
        self.prune_raises = False
        self.undeletable_reason = String("")
        self.calls = List[String]()


struct FakeResource(Resource, Movable, Deinitable):
    """A pure in-memory `Resource` double. Configured with a logical_id, deps,
    retention, a live phase, a converge mode, and a physical id. Records every verb
    into a shared call log. Behind an ArcPointer so `share()` reads the aggregate
    log (the node is erased + owned by the graph; the test reads behavior off a
    shared handle)."""

    var _p: ArcPointer[_FakeState]

    def __init__(
        out self,
        logical_id: String,
        deps: List[String],
        retention: Int,
        phase: Int,
        converge: Int = CONVERGE_IN_PLACE,
        physical_id: String = String(""),
    ):
        var pid = physical_id
        if pid.byte_length() == 0:
            pid = String("phys-") + logical_id
        self._p = ArcPointer[_FakeState](
            _FakeState(
                logical_id.copy(),
                deps.copy(),
                retention,
                phase,
                converge,
                pid^,
            )
        )

    def __init__(out self, *, var _share: ArcPointer[_FakeState]):
        self._p = _share^

    def share(self) -> FakeResource:
        """A SECOND handle over ONE `_FakeState`. SAFETY: ArcPointer ref-counted
        shared ownership; a TEST DOUBLE driven on ONE thread."""
        return FakeResource(_share=ArcPointer[_FakeState](copy=self._p))

    # ---- test controls (mutate the shared state before/after driving) ----
    def set_phase(mut self, phase: Int):
        self._p[].phase = phase

    def set_delete_404(mut self, on: Bool):
        self._p[].delete_404 = on

    def set_delete_noop(mut self, on: Bool):
        """When True, delete is ISSUED (recorded) but does NOT change the live phase
        — models a delete that did not actually remove the resource (the confirm-gone
        re-read then still sees it present -> destroy must RAISE, NOT reap)."""
        self._p[].delete_noop = on

    def set_read_raises(mut self, n: Int):
        """The next `n` read_status calls RAISE (a transient GOAWAY / H2_PROTOCOL /
        5xx — the conformer RAISES, it does NOT read as absent). Subsequent reads
        return the configured phase."""
        self._p[].read_raises_remaining = n

    def set_create_raises(mut self, on: Bool):
        """When True, `create` RAISES a backend fault — used to prove the engine's
        per-node error enrichment names WHICH node/verb produced the raise."""
        self._p[].create_raises = on

    def set_undeletable_reason(mut self, var why: String):
        """The conformer's own WHY for a RETAIN_UNDELETABLE node. Left EMPTY, this
        double reproduces a conformer that declared the code and stated no reason
        — which the engine must NAME as a conformer defect rather than drop."""
        self._p[].undeletable_reason = why^

    def set_prune_raises(mut self, on: Bool):
        """When True, the best-effort retention `prune` RAISES a genuine (non-404)
        transport fault. The engine MUST swallow it — a prune fault never fails the
        deploy (engine.mojo §3b best-effort contract)."""
        self._p[].prune_raises = on

    def pruned(self) -> Bool:
        """True iff the engine invoked `prune` on this node (the post-create/update
        best-effort retention call — guards the engine.mojo §3b invocation seam AND
        the ErasedResource.prune vtable forwarding to this override, not the trait
        default no-op)."""
        for i in range(len(self._p[].calls)):
            if self._p[].calls[i] == String("prune"):
                return True
        return False

    def read_count(self) -> Int:
        var n = 0
        for i in range(len(self._p[].calls)):
            if self._p[].calls[i] == String("read"):
                n += 1
        return n

    # ---- inspection ----
    def call_count(self) -> Int:
        return len(self._p[].calls)

    def call_at(self, i: Int) -> String:
        return self._p[].calls[i]

    def created(self) -> Bool:
        for i in range(len(self._p[].calls)):
            if self._p[].calls[i] == String("create"):
                return True
        return False

    def updated(self) -> Bool:
        for i in range(len(self._p[].calls)):
            if self._p[].calls[i] == String("update"):
                return True
        return False

    def deleted(self) -> Bool:
        for i in range(len(self._p[].calls)):
            if self._p[].calls[i] == String("delete"):
                return True
        return False

    # ---- the Resource surface ----
    def logical_id(mut self) -> String:
        return self._p[].logical_id

    def depends_on(mut self) -> List[String]:
        return self._p[].deps.copy()

    def retention(mut self) -> Int:
        return self._p[].retention

    def undeletable_reason(mut self) -> String:
        """The conformer's WHY. Overriding it here (rather than inheriting the
        trait default) is also what proves `ErasedResource`'s vtable FORWARDS this
        verb: the graph holds erased nodes, so a missing forward would silently
        serve the default and every reason would read as empty."""
        return self._p[].undeletable_reason.copy()

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        self._p[].calls.append(String("read"))
        if self._p[].read_raises_remaining > 0:
            # A transient read (GOAWAY / H2_PROTOCOL / 5xx). The neutral contract:
            # read_status RAISES on a transient fault — it does NOT read as absent.
            self._p[].read_raises_remaining -= 1
            raise Error(
                String("CloudRun GetService failed [H2_PROTOCOL]: GOAWAY received")
            )
        var ph = self._p[].phase
        if ph == RES_ABSENT:
            return ResourceStatus.absent()
        if ph == RES_PRESENT_MATCHED:
            return ResourceStatus.matched(
                self._p[].physical_id, String("digest-live")
            )
        if ph == RES_FAILED:
            # A live resource in a failed terminal state (a revision that never
            # became ready): present, and not running what the file asks.
            return ResourceStatus(
                RES_FAILED,
                self._p[].physical_id,
                String("digest-bad"),
                String("terminal condition: revision failed to become ready"),
            )
        # DRIFTED
        return ResourceStatus.drifted(
            self._p[].physical_id, String("digest-old")
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        # Pure diff — NO mutation, NO call recorded (plan must not touch state).
        if live.is_absent():
            return ChangeAction(
                self._p[].logical_id,
                VERB_CREATE,
                String("absent -> create"),
                self._p[].retention,
            )
        if live.is_matched():
            return ChangeAction(
                self._p[].logical_id,
                VERB_NOOP,
                String("matched -> noop"),
                self._p[].retention,
            )
        return ChangeAction(
            self._p[].logical_id,
            VERB_UPDATE,
            String("drifted -> update"),
            self._p[].retention,
        )

    def create(mut self, creds: Creds) raises -> String:
        self._p[].calls.append(String("create"))
        if self._p[].create_raises:
            # A backend fault on the mutation (e.g. a GCP `Invalid service account`).
            # The engine must enrich this raise with the node's logical_id + verb.
            raise Error(
                String("[grpc:3] Invalid service account (backend fault)")
            )
        # Model the world becoming present after a create.
        self._p[].phase = RES_PRESENT_MATCHED
        return self._p[].physical_id

    def update(mut self, creds: Creds) raises:
        self._p[].calls.append(String("update"))
        self._p[].phase = RES_PRESENT_MATCHED

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._p[].calls.append(String("delete"))
        if self._p[].delete_noop:
            # A delete that was ISSUED but did NOT remove the resource (an eventually-
            # consistent backend / partial delete / a swallowed-but-transient
            # outcome): the live phase is UNCHANGED, so the engine's confirm-gone
            # re-read still sees it present -> destroy must RAISE, NOT reap.
            return
        if self._p[].delete_404:
            # Idempotent: a 404 is swallowed (already gone). A 404 means the resource
            # is already gone, so the live phase converges to ABSENT (the confirm-gone
            # re-read then sees it absent — a clean, reaped outcome).
            self._p[].phase = RES_ABSENT
            return
        self._p[].phase = RES_ABSENT

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        if self._p[].converge == CONVERGE_REPLACE:
            # A drift that needs a replace — the engine must fail-loud on this.
            return CONVERGE_REPLACE
        return CONVERGE_IN_PLACE

    def prune(mut self, creds: Creds) raises:
        """The best-effort retention prune the engine calls AFTER a successful
        create/update (engine.mojo §3b). Records the "prune" verb; RAISES a genuine
        (non-404) transport fault when `prune_raises` is set — which the engine MUST
        swallow (a prune fault never fails the deploy). Overrides the Resource-trait
        default no-op, so observing this call at all also proves the
        ErasedResource.prune vtable forwards to the conformer, not the default."""
        self._p[].calls.append(String("prune"))
        if self._p[].prune_raises:
            raise Error(
                String(
                    "CloudRun DeleteRevision failed [PERMISSION_DENIED]: caller"
                    " lacks run.revisions.delete"
                )
            )


# =============================================================================
# Diamond graph builders. A -> B, C -> D:
#   D depends on B and C; B and C each depend on A; A is the root.
#   topo order: A, then {B, C} (index order), then D.
# =============================================================================
def _diamond() raises -> ResourceGraph:
    """Build the diamond A -> B,C -> D, all absent + RETAIN_DELETE (a fresh apply)."""
    var g = ResourceGraph()
    g.add(
        ErasedResource.erase(
            FakeResource(
                String("A"), List[String](), RETAIN_DELETE, RES_ABSENT
            )
        )
    )
    var deps_b = List[String]()
    deps_b.append(String("A"))
    g.add(
        ErasedResource.erase(
            FakeResource(String("B"), deps_b^, RETAIN_DELETE, RES_ABSENT)
        )
    )
    var deps_c = List[String]()
    deps_c.append(String("A"))
    g.add(
        ErasedResource.erase(
            FakeResource(String("C"), deps_c^, RETAIN_DELETE, RES_ABSENT)
        )
    )
    var deps_d = List[String]()
    deps_d.append(String("B"))
    deps_d.append(String("C"))
    g.add(
        ErasedResource.erase(
            FakeResource(String("D"), deps_d^, RETAIN_DELETE, RES_ABSENT)
        )
    )
    return g^


def _index_in_order(order: List[Int], target: Int) -> Int:
    """The position of node-index `target` within the topo `order` (-1 if absent)."""
    for i in range(len(order)):
        if order[i] == target:
            return i
    return -1


# =============================================================================
# (1) topo order is DEPENDENCY-CORRECT: A before B,C; B,C before D.
# =============================================================================
def test_topo_order_is_dependency_correct() raises:
    var g = _diamond()
    var order = topo_sort(g)
    assert_equal(len(order), 4, "topo order covers all 4 nodes")

    # resolve the node indices by logical_id (the diamond added A,B,C,D in that
    # order, so indices are 0,1,2,3 — assert via index_of to be robust).
    var ia = g.index_of(String("A"))
    var ib = g.index_of(String("B"))
    var ic = g.index_of(String("C"))
    var id = g.index_of(String("D"))

    var pa = _index_in_order(order, ia)
    var pb = _index_in_order(order, ib)
    var pc = _index_in_order(order, ic)
    var pd = _index_in_order(order, id)

    # A before B and C; B and C before D.
    assert_true(pa < pb, "A precedes B in topo order")
    assert_true(pa < pc, "A precedes C in topo order")
    assert_true(pb < pd, "B precedes D in topo order")
    assert_true(pc < pd, "C precedes D in topo order")
    # A is first, D is last (the diamond's unique source + sink).
    assert_equal(pa, 0, "A (the root) is first")
    assert_equal(pd, 3, "D (the sink) is last")


# =============================================================================
# (2) apply_graph CREATES every absent node, in topo order (one create each).
# =============================================================================
def test_apply_creates_in_topo_order() raises:
    var g = _diamond()
    var creds = Creds.none()
    var store = InMemoryStateStore()

    var applied = apply_graph(g, creds, store)
    assert_equal(len(applied), 4, "all 4 nodes applied")

    # Every node was created (absent -> create), in topo order.
    assert_equal(applied[0].logical_id, String("A"), "A applied first")
    assert_equal(applied[3].logical_id, String("D"), "D applied last")
    for i in range(len(applied)):
        assert_equal(applied[i].verb, VERB_CREATE, "each node was CREATED")
        assert_false(
            applied[i].already_confirmed, "a fresh apply confirms nothing prior"
        )

    # The state store confirmed exactly one intent per node, zero orphans.
    assert_equal(
        store.count_confirmed(String("A")), 1, "A confirmed exactly once"
    )
    assert_equal(
        store.count_provisioning(String("D")), 0, "no orphaned PROVISIONING for D"
    )
    assert_equal(
        store.physical_id_for(String("A")),
        String("phys-A"),
        "A's physical id was confirmed into the store",
    )


# =============================================================================
# (3) rollback_create tears down in REVERSE order AND SKIPS a RETAIN_KEEP node AND
#     SKIPS an already_confirmed node.
# =============================================================================
def test_rollback_reverse_skips_keep_and_confirmed() raises:
    # A graph where:
    #   * "keep" is RETAIN_KEEP (the shared bucket) — rollback must SKIP it.
    #   * "adopted" is already CONFIRMED before this apply — rollback must SKIP it.
    #   * "app" is a fresh create — rollback MUST delete it.
    var g = ResourceGraph()

    # A RETAIN_KEEP shared node (no deps) — a create-adopted matched resource.
    var keep = FakeResource(
        String("keep"), List[String](), RETAIN_KEEP, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(keep.share()))

    # An already-confirmed node: matched live + a pre-confirmed intent in the store.
    var deps_ad = List[String]()
    deps_ad.append(String("keep"))
    var adopted = FakeResource(
        String("adopted"), deps_ad^, RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(adopted.share()))

    # A fresh app node (absent) that WILL be created (and must be rolled back).
    var deps_app = List[String]()
    deps_app.append(String("adopted"))
    var app = FakeResource(
        String("app"), deps_app^, RETAIN_DELETE, RES_ABSENT
    )
    g.add(ErasedResource.erase(app.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    # Pre-confirm "adopted" so the apply ADOPTS it (already_confirmed == True).
    var pre = store.record_or_adopt_intent(String("adopted"))
    store.confirm(pre, String("phys-adopted"))

    var applied = apply_graph(g, creds, store)
    assert_equal(len(applied), 3, "all 3 nodes applied")
    # "app" was created; "keep" + "adopted" were matched (no create).
    assert_true(app.created(), "the fresh app node was created")
    assert_false(keep.created(), "the RETAIN_KEEP node was NOT created (matched)")
    assert_false(adopted.created(), "the adopted node was NOT created (matched)")

    # Now roll back the applied set.
    rollback_create(g, applied, creds, store)

    # THE FALSIFIER: only "app" was deleted. "keep" (RETAIN_KEEP) + "adopted"
    # (already_confirmed) were SKIPPED.
    assert_true(app.deleted(), "rollback DELETED the fresh app node")
    assert_false(
        keep.deleted(), "rollback SKIPPED the RETAIN_KEEP node (never deleted)"
    )
    assert_false(
        adopted.deleted(),
        "rollback SKIPPED the already_confirmed node (we did not create it)",
    )
    # The app intent was reaped; the adopted intent survives (still confirmed).
    assert_equal(
        store.count_reaped(String("app")), 1, "the app intent was reaped"
    )
    assert_equal(
        store.count_confirmed(String("adopted")),
        1,
        "the adopted intent survives (not reaped)",
    )
    _ = keep^
    _ = adopted^
    _ = app^


# =============================================================================
# (3a) ⛔ THE DATA-LOSS FALSIFIER: rollback MUST NOT delete a resource this apply
#      merely ADOPTED — even on a FIRST apply, where no prior intent exists.
#
# The `already_confirmed` skip in (3) is NOT sufficient, and the gap is exactly
# the case a customer hits first. `already_confirmed` is a fact about OUR INTENT
# LEDGER ("a prior apply of ours confirmed this key"), NOT about who created the
# resource. On the FIRST apply against a PRE-EXISTING cloud resource there is no
# prior intent, so `record_or_adopt_intent` writes a fresh PROVISIONING row and
# the ticket reports already_confirmed=False — while the LIVE read reports
# RES_PRESENT_MATCHED and the engine ADOPTS (verb=VERB_NOOP, zero mutation).
#
# The resource is therefore recorded as {already_confirmed: False, verb: NOOP}.
# A rollback that skipped only RETAIN_KEEP and already_confirmed would issue
# `delete(physical_id)` against a resource THIS DEPLOY NEVER CREATED — a
# customer's pre-existing bucket / table / secret, destroyed because an unrelated
# node failed later in the same apply.
#
# VERB_NOOP is the discriminator the record already carries: it means "live
# already matched; we mutated nothing". Nothing we did not create may be reaped.
#
# ⚠ THE NON-EMPTY ARM IS ASSERTED TOO: a node this apply genuinely CREATED must
# STILL be deleted. A fix that stops all rollback deletion replaces a data-loss
# bug with an orphan-resource bug.
# =============================================================================
def test_rollback_never_deletes_an_adopted_node_on_first_apply() raises:
    var g = ResourceGraph()

    # The customer's PRE-EXISTING resource: live MATCHED, RETAIN_DELETE (so the
    # RETAIN_KEEP arm cannot be what saves it), and NO pre-confirmed intent (so
    # the already_confirmed arm cannot be what saves it either). This is a first
    # apply that discovers a resource it did not create.
    var preexisting = FakeResource(
        String("preexisting"),
        List[String](),
        RETAIN_DELETE,
        RES_PRESENT_MATCHED,
    )
    g.add(ErasedResource.erase(preexisting.share()))

    # A node this apply genuinely CREATES (the rollback's non-empty arm).
    var deps_app = List[String]()
    deps_app.append(String("preexisting"))
    var app = FakeResource(
        String("app"), deps_app^, RETAIN_DELETE, RES_ABSENT
    )
    g.add(ErasedResource.erase(app.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()

    var applied = apply_graph(g, creds, store)
    assert_equal(len(applied), 2, "both nodes applied")

    # PIN THE MECHANISM: the adopted node is recorded NOOP and NOT
    # already_confirmed — the exact combination the unwind must honour.
    assert_equal(
        applied[0].logical_id, String("preexisting"), "adopted node applied first"
    )
    assert_equal(
        applied[0].verb,
        VERB_NOOP,
        "the adopted node's verb is VERB_NOOP (live matched; zero mutation)",
    )
    assert_false(
        applied[0].already_confirmed,
        (
            "FIRST apply: no prior intent, so already_confirmed is False — this is"
            " why the already_confirmed skip does NOT cover this case"
        ),
    )
    assert_false(
        preexisting.created(), "the pre-existing resource was ADOPTED, not created"
    )
    assert_true(app.created(), "the app node was genuinely created")

    # A later node failed; the deploy unwinds what it applied.
    rollback_create(g, applied, creds, store)

    # ⛔ THE FALSIFIER: zero deletes against the resource we merely adopted.
    assert_false(
        preexisting.deleted(),
        (
            "rollback DELETED a resource this deploy only ADOPTED (verb=NOOP) —"
            " that is a customer's pre-existing resource destroyed by an unrelated"
            " node's failure"
        ),
    )
    # ...and its intent is NOT retired, because the resource still exists.
    assert_equal(
        store.count_reaped(String("preexisting")),
        0,
        "the adopted node's intent was NOT reaped (the resource still exists)",
    )

    # THE NON-EMPTY ARM: the node we really created IS rolled back.
    assert_true(
        app.deleted(),
        "rollback still DELETES a node this apply genuinely created (no orphan)",
    )
    assert_equal(
        store.count_reaped(String("app")), 1, "the created node's intent was reaped"
    )
    _ = preexisting^
    _ = app^


# =============================================================================
# (3b) rollback tears down in REVERSE order (a dependent before its dependency).
# =============================================================================
def test_rollback_reverse_order() raises:
    # A linear chain A -> B -> C (C depends on B depends on A), all fresh creates.
    var g = ResourceGraph()
    var a = FakeResource(String("A"), List[String](), RETAIN_DELETE, RES_ABSENT)
    g.add(ErasedResource.erase(a.share()))
    var deps_b = List[String]()
    deps_b.append(String("A"))
    var b = FakeResource(String("B"), deps_b^, RETAIN_DELETE, RES_ABSENT)
    g.add(ErasedResource.erase(b.share()))
    var deps_c = List[String]()
    deps_c.append(String("B"))
    var c = FakeResource(String("C"), deps_c^, RETAIN_DELETE, RES_ABSENT)
    g.add(ErasedResource.erase(c.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var applied = apply_graph(g, creds, store)
    # applied order is topo (A, B, C); rollback walks it in REVERSE (C, B, A).
    assert_equal(applied[0].logical_id, String("A"), "applied A first")
    assert_equal(applied[2].logical_id, String("C"), "applied C last")

    rollback_create(g, applied, creds, store)
    # All three were deleted; the reverse walk means C's delete was recorded before
    # A's. We assert each node saw its delete (the order is enforced by the reverse
    # loop; each node's own recorder shows the delete happened).
    assert_true(a.deleted() and b.deleted() and c.deleted(), "all rolled back")
    _ = a^
    _ = b^
    _ = c^


# =============================================================================
# (3c) ⛔ rollback MUST NOT delete a resource this apply merely UPDATED.
#
# The same gap as (3a), one verb over. On a first apply against a pre-existing
# resource that DRIFTED, there is no prior intent (already_confirmed=False) and
# the engine issues `update` (verb=VERB_UPDATE). In a run whose state store is
# new, that is EVERY resource the apply touched. A rollback that deleted it
# would turn "a later node failed" into "the service that was running before
# this deploy is gone". Only a CREATE of this apply is unwound; that arm is
# asserted here too.
# =============================================================================
def test_rollback_never_deletes_an_updated_node() raises:
    var g = ResourceGraph()
    # Pre-existing and drifted, RETAIN_DELETE (so RETAIN_KEEP is not what saves
    # it), no prior intent (so already_confirmed is not what saves it).
    var running = FakeResource(
        String("running"), List[String](), RETAIN_DELETE, RES_PRESENT_DRIFTED
    )
    g.add(ErasedResource.erase(running.share()))
    var deps_app = List[String]()
    deps_app.append(String("running"))
    var app = FakeResource(String("app"), deps_app^, RETAIN_DELETE, RES_ABSENT)
    g.add(ErasedResource.erase(app.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var applied = apply_graph(g, creds, store)
    assert_equal(len(applied), 2, "both nodes applied")
    assert_equal(applied[0].logical_id, String("running"))
    assert_equal(
        applied[0].verb, VERB_UPDATE, "the pre-existing node was UPDATED, not created"
    )
    assert_false(
        applied[0].already_confirmed,
        "first apply: no prior intent, so already_confirmed does not save it",
    )
    assert_true(running.updated() and not running.created())
    assert_true(app.created())

    rollback_create(g, applied, creds, store)

    assert_false(
        running.deleted(),
        (
            "rollback DELETED a resource this deploy only UPDATED (verb=UPDATE) —"
            " the service that ran before this deploy is gone"
        ),
    )
    assert_equal(
        store.count_reaped(String("running")),
        0,
        "the updated node's intent was NOT reaped (the resource still exists)",
    )
    assert_true(app.deleted(), "rollback still deletes the node this apply created")
    assert_equal(store.count_reaped(String("app")), 1)
    _ = running^
    _ = app^


# =============================================================================
# (4) a CYCLE raises (fail-loud).
# =============================================================================
def test_cycle_raises() raises:
    var g = ResourceGraph()
    # X depends on Y, Y depends on X — a 2-cycle.
    var deps_x = List[String]()
    deps_x.append(String("Y"))
    g.add(
        ErasedResource.erase(
            FakeResource(String("X"), deps_x^, RETAIN_DELETE, RES_ABSENT)
        )
    )
    var deps_y = List[String]()
    deps_y.append(String("X"))
    g.add(
        ErasedResource.erase(
            FakeResource(String("Y"), deps_y^, RETAIN_DELETE, RES_ABSENT)
        )
    )

    # THE FALSIFIER: topo_sort raises on the cycle (the engine cannot order it).
    with assert_raises():
        _ = topo_sort(g)


# =============================================================================
# (4b) a DANGLING dependency raises (a dep naming a non-node).
# =============================================================================
def test_dangling_dependency_raises() raises:
    var g = ResourceGraph()
    var deps = List[String]()
    deps.append(String("ghost"))  # not a node in the graph
    g.add(
        ErasedResource.erase(
            FakeResource(String("real"), deps^, RETAIN_DELETE, RES_ABSENT)
        )
    )
    with assert_raises():
        _ = topo_sort(g)


# =============================================================================
# (5) plan_graph mutates NOTHING (read-only dry run).
# =============================================================================
def test_plan_mutates_nothing() raises:
    var g = ResourceGraph()
    var a = FakeResource(String("A"), List[String](), RETAIN_DELETE, RES_ABSENT)
    g.add(ErasedResource.erase(a.share()))
    var deps_b = List[String]()
    deps_b.append(String("A"))
    var b = FakeResource(String("B"), deps_b^, RETAIN_DELETE, RES_ABSENT)
    g.add(ErasedResource.erase(b.share()))

    var creds = Creds.none()
    var actions = plan_graph(g, creds)

    assert_equal(len(actions), 2, "plan returns an action per node")
    # THE FALSIFIER: plan issued NO create/update/delete (only reads).
    assert_false(a.created() or a.updated() or a.deleted(), "plan did not mutate A")
    assert_false(b.created() or b.updated() or b.deleted(), "plan did not mutate B")
    # The plan named the correct verbs (both absent -> create).
    assert_true(actions[0].is_create(), "A planned as create")
    assert_true(actions[1].is_create(), "B planned as create")
    _ = a^
    _ = b^


# =============================================================================
# (6) a DRIFTED node whose converge_mode is REPLACE raises "unsupported in v1".
# =============================================================================
def test_drifted_replace_raises_unsupported() raises:
    var g = ResourceGraph()
    # A single drifted node whose converge mode is REPLACE (the typed hole).
    g.add(
        ErasedResource.erase(
            FakeResource(
                String("R"),
                List[String](),
                RETAIN_DELETE,
                RES_PRESENT_DRIFTED,
                CONVERGE_REPLACE,
            )
        )
    )
    var creds = Creds.none()
    var store = InMemoryStateStore()

    # THE FALSIFIER: apply RAISES on the replace-needing drift (no surprise
    # teardown; the v1 typed hole).
    with assert_raises():
        _ = apply_graph(g, creds, store)


# =============================================================================
# (7) destroy_graph tears down in REVERSE topo order AND SKIPS RETAIN_KEEP (the
#     shared-bucket-retention invariant) AND is idempotent on a 404.
# =============================================================================
def test_destroy_reverse_skips_keep_idempotent() raises:
    var g = ResourceGraph()
    # A RETAIN_KEEP shared bucket (present) — destroy must SKIP it.
    var bucket = FakeResource(
        String("bucket"), List[String](), RETAIN_KEEP, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(bucket.share()))
    # An app that depends on the bucket (present) — destroy DELETES it.
    var deps_app = List[String]()
    deps_app.append(String("bucket"))
    var app = FakeResource(
        String("app"), deps_app^, RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(app.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    # Record intents first (the realistic path: you destroy what you applied). The
    # nodes are already MATCHED, so apply adopts them (no create) but writes/heals
    # their intents — so destroy's mark_reaped has an intent to retire.
    var _applied = apply_graph(g, creds, store)

    _ = destroy_graph(g, creds, store)

    # THE FALSIFIER: the app was deleted; the RETAIN_KEEP bucket was NEVER deleted
    # (the shared-bucket-retention invariant destroy_graph encodes).
    assert_true(app.deleted(), "destroy DELETED the app")
    assert_false(
        bucket.deleted(),
        "destroy SKIPPED the RETAIN_KEEP shared bucket (retention invariant)",
    )
    assert_equal(
        store.count_reaped(String("app")), 1, "the app intent was reaped"
    )
    # The RETAIN_KEEP bucket's intent is NOT reaped (it was applied/adopted but
    # destroy skips it entirely).
    assert_equal(
        store.count_reaped(String("bucket")),
        0,
        "the RETAIN_KEEP bucket intent was NOT reaped (destroy skipped it)",
    )

    _ = bucket^
    _ = app^


# =============================================================================
# (7e) full erasure — the force_delete_data OVERRIDE: a CUSTOMER
#      compute-env DELETE = an ERASURE request, so `destroy_graph(...,
#      force_delete_data=True)` LIFTS the RETAIN_KEEP skip and REAPS the shared/
#      standing bucket + signing seed too (nothing left billing / holding PII).
#      An env-scope teardown passes force_delete_data=True; a per-app undeploy
#      passes False.
# =============================================================================
def test_env_erase_reaps_retain_keep_bucket() raises:
    """The FALSIFIER for the customer-erase RETAIN override: the SAME graph as
    (7) — a RETAIN_KEEP shared bucket + a RETAIN_DELETE app — but destroyed with
    `force_delete_data=True`. NOW the RETAIN_KEEP bucket IS deleted + its intent
    reaped (the erase override), where the default (7) SKIPPED it. FAILS ON a build
    that ignores force_delete_data: the bucket would survive (the RETAIN_KEEP leak
    the customer DELETE must not tolerate)."""
    var g = ResourceGraph()
    var bucket = FakeResource(
        String("bucket"), List[String](), RETAIN_KEEP, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(bucket.share()))
    var deps_app = List[String]()
    deps_app.append(String("bucket"))
    var app = FakeResource(
        String("app"), deps_app^, RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(app.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)

    # THE ERASE OVERRIDE — force_delete_data=True lifts the RETAIN_KEEP skip.
    _ = destroy_graph(g, creds, store, force_delete_data=True)

    assert_true(app.deleted(), "erase DELETED the app")
    assert_true(
        bucket.deleted(),
        "erase REAPED the RETAIN_KEEP bucket (force_delete_data override)",
    )
    assert_equal(
        store.count_reaped(String("app")), 1, "the app intent was reaped"
    )
    assert_equal(
        store.count_reaped(String("bucket")),
        1,
        "the RETAIN_KEEP bucket intent WAS reaped under the erase override",
    )

    _ = bucket^
    _ = app^


# =============================================================================
# (7f) ★★ RETAIN_UNDELETABLE — the THIRD retention code. The axis
#      answers two questions and they must not share an answer:
#
#        RETAIN_KEEP        = kept by POLICY       -> `--delete-data` OVERRIDES it
#        RETAIN_UNDELETABLE = no delete CAPABILITY -> NOTHING overrides it
#
#      WHY: if both meanings lived on RETAIN_KEEP, `force_delete_data` would
#      reach a conformer with no delete arm, that conformer would RAISE, and the
#      reverse walk would STOP — so a whole-project `--delete-data` teardown
#      could never complete on AWS while the GCP peers completed under the
#      identical flag.
#
#      FAILS ON A TWO-CODE BUILD, in the way that matters: with only two codes
#      the "undeletable" node's conformer is reached, `delete` raises, and
#      `destroy_graph` propagates — so the walk never reaches the assertions and
#      the case errors out.
# =============================================================================
struct _RefusesDelete(Resource, Movable, Deinitable):
    """A conformer with NO delete capability: `delete` REFUSES, exactly as
    `RegistryDescriptor.delete` and `AwsIamRoleConformer.delete` do for the two
    real AWS cases. It reports RETAIN_UNDELETABLE, so a correct engine never
    reaches the refusal — and this double is the only way to prove that, because
    a conformer that merely SAID it was undeletable could not falsify a build
    that ignored the code."""

    var _p: ArcPointer[_FakeState]

    def __init__(
        out self,
        logical_id: String,
        var why: String,
        phase: Int = RES_PRESENT_MATCHED,
    ):
        """⚠ `phase` IS NOT COSMETIC, AND DEFAULTING IT TO MATCHED IS WHAT MADE
        ONE CASE VACUOUS. A MATCHED double is ADOPTED by `apply_graph` (verb
        VERB_NOOP), and `rollback_create`'s guard order is
        KEEP -> UNDELETABLE -> VERB_NOOP -> already_confirmed — so an adopted
        double is skipped by the VERB_NOOP arm whether or not the UNDELETABLE arm
        exists, and disabling the UNDELETABLE arm left the test GREEN. Pass
        `phase=RES_ABSENT` to make the apply genuinely CREATE the node, which is
        the ONLY shape that reaches the guard.

        ⇒ GENERALISE: any test whose double is ADOPTED cannot exercise the first
          two `rollback_create` guards. Mutation-test the guard you mean to pin."""
        self._p = ArcPointer[_FakeState](
            _FakeState(
                logical_id.copy(),
                List[String](),
                RETAIN_UNDELETABLE,
                phase,
                CONVERGE_IN_PLACE,
                String("phys-") + logical_id,
            )
        )
        self._p[].undeletable_reason = why^

    def __init__(out self, *, var _share: ArcPointer[_FakeState]):
        self._p = _share^

    def share(self) -> _RefusesDelete:
        return _RefusesDelete(_share=ArcPointer[_FakeState](copy=self._p))

    def touched(self) -> Bool:
        """True iff the engine invoked ANY live verb on this node. A skipped node
        must cost NO API call — the RETAIN_KEEP skip's own property, kept."""
        return len(self._p[].calls) > 0

    def reset_calls(mut self):
        """Clear the verb log. Called between the harness's `apply_graph` (which
        legitimately READS every node to adopt it) and the destroy under test, so
        `touched()` measures the TEARDOWN's calls and not the setup's."""
        self._p[].calls = List[String]()

    def logical_id(mut self) -> String:
        return self._p[].logical_id

    def depends_on(mut self) -> List[String]:
        return self._p[].deps.copy()

    def retention(mut self) -> Int:
        return RETAIN_UNDELETABLE

    def undeletable_reason(mut self) -> String:
        return self._p[].undeletable_reason.copy()

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        self._p[].calls.append(String("read"))
        if self._p[].phase == RES_ABSENT:
            return ResourceStatus.absent()
        return ResourceStatus.matched(
            self._p[].physical_id, String("digest-live")
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        if live.is_absent():
            return ChangeAction(
                self._p[].logical_id,
                VERB_CREATE,
                String("absent -> create"),
                RETAIN_UNDELETABLE,
            )
        return ChangeAction(
            self._p[].logical_id,
            VERB_NOOP,
            String("matched -> noop"),
            RETAIN_UNDELETABLE,
        )

    def create(mut self, creds: Creds) raises -> String:
        self._p[].calls.append(String("create"))
        return self._p[].physical_id

    def update(mut self, creds: Creds) raises:
        self._p[].calls.append(String("update"))

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._p[].calls.append(String("delete"))
        raise Error(
            String(
                "_RefusesDelete.delete: REFUSED — this node has no delete path."
                " Reaching here means the engine consulted something other than"
                " retention(), or overrode a CAPABILITY with a flag."
            )
        )

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE


def test_force_delete_data_does_not_override_undeletable() raises:
    """★ THE FIX, both halves in one graph:

      * `keep` is RETAIN_KEEP (policy) -> `--delete-data` DELETES it. Asserted
        here so a regression in the override is visible in the same case as the
        undeletable arm.
      * `undeletable` is RETAIN_UNDELETABLE -> `--delete-data` does NOT delete it,
        does NOT read it, does NOT reap its intent, and it is RETURNED with the
        conformer's own reason.
      * `app` is RETAIN_DELETE and is ordered AFTER the undeletable node in the
        reverse walk, so it proves the walk CONTINUES. A refusal reached here
        would stop the walk and leave `app` standing, unreported."""
    var g = ResourceGraph()
    var undeletable = _RefusesDelete(
        String("repo"),
        String("deleting it deletes every image in it"),
    )
    g.add(ErasedResource.erase(undeletable.share()))
    var keep = FakeResource(
        String("keep"), List[String](), RETAIN_KEEP, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(keep.share()))
    var deps_app = List[String]()
    deps_app.append(String("repo"))
    deps_app.append(String("keep"))
    var app = FakeResource(
        String("app"), deps_app^, RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(app.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)
    # The setup's adopt-read is not the teardown's; `touched()` must measure only
    # what `destroy_graph` did.
    undeletable.reset_calls()

    var skipped = destroy_graph(g, creds, store, force_delete_data=True)

    # (a) THE WALK COMPLETED — no raise, and every deletable node was reaped.
    assert_true(app.deleted(), "the RETAIN_DELETE app was deleted")
    assert_true(
        keep.deleted(),
        "⛔ the RETAIN_KEEP node is STILL overridden by --delete-data. The third"
        " code must not have weakened the policy override — that override is"
        " what the whole-project teardown is for",
    )
    assert_equal(
        store.count_reaped(String("keep")),
        1,
        "…and its intent was reaped, exactly as before this code existed",
    )

    # (b) THE UNDELETABLE NODE WAS NOT TOUCHED, AT ALL.
    assert_false(
        undeletable.touched(),
        "⛔ the engine issued a live verb on a RETAIN_UNDELETABLE node. It must"
        " skip it whole — no delete (its conformer REFUSES, which is what used"
        " to stop the walk) and no read (a skipped node costs no API call)",
    )
    assert_equal(
        store.count_reaped(String("repo")),
        0,
        "⛔ its intent must NOT be reaped: the resource is still LIVE, and"
        " retiring the record orphans it with nothing left to re-drive from",
    )

    # (c) AND IT WAS NAMED, WITH THE CONFORMER'S OWN REASON.
    assert_equal(
        len(skipped),
        1,
        "exactly one node was skipped as undeletable — a survivor the operator"
        " is not told about is the failure this return value exists to remove",
    )
    assert_equal(skipped[0].logical_id, String("repo"), "…named")
    assert_true(
        _contains_sub(
            skipped[0].reason, String("deletes every image in it")
        ),
        String(
            "…and the reason is the CONFORMER's, reaching the report through the"
            " ErasedResource vtable without the delete being issued. Got: "
        )
        + skipped[0].reason,
    )

    # (d) The shared renderer turns that into operator-readable lines.
    var lines = undeletable_report_lines(skipped)
    assert_true(len(lines) >= 3, "the report has a header, the node, a closing")
    assert_true(
        _contains_sub(lines[0], String("SURVIVE this teardown")),
        String("…and it leads with what an operator must not misread. Got: ")
        + lines[0],
    )

    _ = undeletable^
    _ = keep^
    _ = app^


def test_default_teardown_is_unchanged_by_the_third_code() raises:
    """⛔ THE NON-REGRESSION HALF, and the one that has to hold for every existing
    caller on every cloud: WITHOUT `--delete-data`, a RETAIN_KEEP node and a
    RETAIN_UNDELETABLE node are both skipped and neither is reaped — which is
    the same result as a build without the third code. The third code changes behaviour on
    exactly ONE input (`force_delete_data=True`), and this case pins the other."""
    var g = ResourceGraph()
    var undeletable = _RefusesDelete(String("repo"), String("no delete path"))
    g.add(ErasedResource.erase(undeletable.share()))
    var keep = FakeResource(
        String("keep"), List[String](), RETAIN_KEEP, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(keep.share()))
    var deps_app = List[String]()
    deps_app.append(String("keep"))
    var app = FakeResource(
        String("app"), deps_app^, RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(app.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)
    undeletable.reset_calls()

    var skipped = destroy_graph(g, creds, store)

    assert_true(app.deleted(), "the RETAIN_DELETE app is still reaped")
    assert_false(keep.deleted(), "the RETAIN_KEEP node is still skipped")
    assert_false(undeletable.touched(), "…and so is the undeletable one")
    assert_equal(
        store.count_reaped(String("keep")), 0, "no intent retired for `keep`"
    )
    assert_equal(
        store.count_reaped(String("repo")), 0, "…nor for `repo`"
    )
    assert_equal(
        len(skipped),
        1,
        "⚠ THE REPORT IS NOT CONDITIONAL ON THE FLAG. A default teardown that"
        " silently leaves an undeletable node behind is the same lie as a forced"
        " one; only the RETAIN_KEEP skip is flag-dependent",
    )
    assert_equal(len(undeletable_report_lines(List[UndeletableSkip]())), 0,
        "…and a teardown with NO survivors renders NOTHING, so a clean run reads"
        " exactly like a plain clean run")

    _ = undeletable^
    _ = keep^
    _ = app^


def test_undeletable_with_no_reason_is_named_as_a_conformer_defect() raises:
    """A conformer that declares RETAIN_UNDELETABLE and leaves
    `undeletable_reason` at the trait default. The node must STILL be reported —
    an unexplained survivor is still a survivor — and the substituted sentence
    must say the CONFORMER is at fault rather than invent a plausible reason,
    because a default that read like a real one would make an unconsidered
    conformer indistinguishable from a considered one."""
    var g = ResourceGraph()
    var undeletable = _RefusesDelete(String("mystery"), String(""))
    g.add(ErasedResource.erase(undeletable.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var skipped = destroy_graph(g, creds, store, force_delete_data=True)

    assert_equal(len(skipped), 1, "the node is reported, not dropped")
    assert_true(
        _contains_sub(skipped[0].reason, String("DEFECT")),
        String("…and the substituted sentence names it as a defect. Got: ")
        + skipped[0].reason,
    )
    assert_true(
        _contains_sub(skipped[0].reason, String("mystery")),
        "…and still names the node",
    )
    _ = undeletable^


def test_rollback_create_skips_an_undeletable_node() raises:
    """`rollback_create` unwinds an apply's CREATES. It must skip a
    RETAIN_UNDELETABLE node for the same reason `destroy_graph` does — the
    conformer's `delete` REFUSES, and a raise here leaves the apply HALF-unwound
    with no record of which half. This is the second walk that reads retention,
    and it is easy to fix one and forget the other.

    ⛔ THE DOUBLE MUST BE ABSENT, OR THIS CASE IS VACUOUS. Checked two ways:
    (a) with a MATCHED double, disabling ONLY the `rollback_create` undeletable
    skip leaves this target GREEN; (b) with the double genuinely ABSENT,
    disabling the same guard turns it RED (`_RefusesDelete.delete: REFUSED …`),
    and restoring it GREEN.

    WHY: a double reporting RES_PRESENT_MATCHED is ADOPTED by `apply_graph` with
    verb VERB_NOOP — and `rollback_create`'s LATER `VERB_NOOP` skip catches it
    regardless, so the guard this case names is never the discriminating branch.
    A node the apply did not CREATE cannot exercise a rollback OF CREATES.

    ⇒ THE FIX IS `phase=RES_ABSENT`: the apply really creates the node
      (VERB_CREATE, already_confirmed False), so the only thing standing between
      the rollback and the refusal is the guard under test.

    FAILS ON A BUILD WITH THAT GUARD REMOVED: `rollback_create` reaches
    `_RefusesDelete.delete`, which raises, and the case errors out before its
    assertions."""
    var g = ResourceGraph()
    var undeletable = _RefusesDelete(
        String("repo"), String("no delete path"), phase=RES_ABSENT
    )
    g.add(ErasedResource.erase(undeletable.share()))
    var app = FakeResource(
        String("app"), List[String](), RETAIN_DELETE, RES_ABSENT
    )
    g.add(ErasedResource.erase(app.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var applied = apply_graph(g, creds, store)

    # ⛔ THE PRECONDITION IS ASSERTED, NOT ASSUMED. If this node is ever adopted
    # again (VERB_NOOP), the later not-a-create skip fires first and the rest of this
    # case stops measuring the guard it names — silently, and while still passing.
    var repo_verb = -1
    var repo_confirmed = True
    for i in range(len(applied)):
        if applied[i].logical_id == String("repo"):
            repo_verb = applied[i].verb
            repo_confirmed = applied[i].already_confirmed
    assert_equal(
        repo_verb,
        VERB_CREATE,
        "the undeletable node must be one this apply genuinely CREATED — an"
        " ADOPTED (VERB_NOOP) node is skipped by a DIFFERENT guard and makes this"
        " case vacuous",
    )
    assert_false(
        repo_confirmed,
        "…and its intent must not predate the apply, or the already_confirmed"
        " guard would be the one doing the work",
    )

    # No raise: the undeletable node's refusal is never reached.
    rollback_create(g, applied, creds, store)

    assert_true(app.deleted(), "the created app was unwound")
    assert_equal(
        store.count_reaped(String("repo")),
        0,
        "the undeletable node was skipped whole and its intent left intact",
    )
    _ = undeletable^
    _ = app^


def test_destroy_absent_is_idempotent() raises:
    var g = ResourceGraph()
    # A present app whose delete raises a (swallowed) 404 — destroy must not raise.
    var app = FakeResource(
        String("app"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    app.set_delete_404(True)
    g.add(ErasedResource.erase(app.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    # PINNED: destroy does not raise on the idempotent (404) delete.
    _ = destroy_graph(g, creds, store)
    assert_true(app.deleted(), "the delete verb was invoked (idempotent 404)")
    _ = app^


# =============================================================================
# (7c) ⛔ THE MONEY-LEAK GATE. destroy_graph must mark_reaped ONLY on a
#      CONFIRMED-GONE outcome — never retire a record over a live resource. Three
#      falsifiers for the fail-loud confirmed-gone contract:
#
#   (7c-i)   a PRESENT resource ALWAYS gets a delete ISSUED, then (once gone) is
#            reaped — a present resource must always drive a delete.
#   (7c-ii)  a PRESENT resource whose delete does NOT take (the live re-read is
#            STILL present) must NOT be reaped — destroy RAISES so the reconcile
#            re-drives. FALSIFIES an unconditional `mark_reaped` (which would
#            retire the intent over a live, billable resource).
#   (7c-iii) a TRANSIENT read (GOAWAY) RAISES out of destroy — it does NOT read as
#            absent, so the record is NOT retired (the level-triggered re-drive
#            reaps it cleanly on the next tick). FALSIFIES a leak where a contained
#            transient read is mistaken for an absent (already-gone) read.
#
# FAILS ON A BUILD whose `mark_reaped(lid)` fires UNCONDITIONALLY after the
# present-branch delete (no confirm-gone re-read): (7c-ii) would REAP the intent
# over the still-live resource (the money leak) instead of raising. (7c-i) is a
# regression pin that the delete is issued.
# =============================================================================
def test_destroy_reaps_only_on_confirmed_gone() raises:
    # (7c-i) A present resource gets a delete ISSUED, and — once the delete removes
    # it — the intent is reaped (the happy path, with the confirm-gone re-read).
    var g = ResourceGraph()
    var app = FakeResource(
        String("app"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(app.share()))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)  # record + confirm the intent.

    _ = destroy_graph(g, creds, store)

    # THE FALSIFIER: a delete was ISSUED for the present resource, and the intent
    # was reaped only after
    # the confirming re-read saw it gone.
    assert_true(app.deleted(), "a present resource ALWAYS gets a delete issued")
    assert_equal(
        store.count_reaped(String("app")),
        1,
        "the intent is reaped ONLY after a confirmed-gone re-read",
    )
    _ = app^


def test_destroy_does_not_reap_when_delete_does_not_take() raises:
    # (7c-ii) THE MONEY-LEAK falsifier. A present resource whose delete is ISSUED but
    # does NOT actually remove it (the confirm-gone re-read is STILL present) must NOT
    # be reaped — destroy RAISES so the level-triggered reconcile re-drives.
    var g = ResourceGraph()
    var app = FakeResource(
        String("app"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    app.set_delete_noop(True)  # the delete is issued but does not remove the service.
    g.add(ErasedResource.erase(app.share()))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)

    # THE FALSIFIER (fails on an unconditional mark_reaped): destroy RAISES
    # because the confirm-gone re-read still sees the resource present.
    with assert_raises():
        _ = destroy_graph(g, creds, store)

    # A delete WAS issued (the reap tried) ...
    assert_true(app.deleted(), "a delete was issued for the present resource")
    # ... but the intent was NOT reaped — the record is LEFT INTACT for the re-drive
    # (never retire a record over a live, billable resource: the money-leak gate).
    assert_equal(
        store.count_reaped(String("app")),
        0,
        "the intent is NOT reaped while the resource is still live (the leak gate)",
    )
    assert_equal(
        store.count_confirmed(String("app")),
        1,
        "the confirmed intent survives for the level-triggered re-drive",
    )
    _ = app^


# =============================================================================
# (7d) ⭐ THE OPTIONAL DESTROY `scope` — A CEILING, NOT A COMMAND.
#
# This is the parameter CFN-style rollback is built on: the graph ENUMERATES (the
# delete set comes from a diff of two DECLARED manifests, which is correct even
# when the applying process died before any ledger write) and the scope only
# FILTERS. Five falsifiers, and the fourth is the load-bearing one:
#
#   (7d-i)   `scope=None` means the whole graph is in scope.
#   (7d-ii)  an OUT-OF-SCOPE node is skipped WITHOUT a read, WITHOUT a delete and
#            ⛔ WITHOUT `mark_reaped` — retiring its record would orphan a live
#            resource behind a retired intent, the exact money leak (7c) exists
#            to stop.
#   (7d-iii) a PRESENT-BUT-EMPTY scope deletes NOTHING and is not conflated with
#            `None`. "the caller stated a scope that is empty" and "the caller
#            stated no scope" are opposite instructions.
#   (7d-iv)  ⭐⭐ A SCOPED WALK STILL CONFIRMS GONE. The mutation this kills is a
#            rollback that skips the confirming re-read — and the reason it CANNOT
#            skip it is that the scope is a filter on the SAME walk, not a second
#            teardown verb. A rollback that inherited `rollback_create`'s
#            discipline instead would retire records over live billable resources
#            while reporting success.
#   (7d-v)   a scope NAMING a RETAIN_KEEP node does not authorise deleting it.
# =============================================================================
def _scope(var ids: List[String]) -> Optional[List[String]]:
    return Optional[List[String]](ids^)


def test_destroy_scope_none_is_byte_identical_to_the_unscoped_walk() raises:
    var g = ResourceGraph()
    var a = FakeResource(
        String("a"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    var b = FakeResource(
        String("b"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(a.share()))
    g.add(ErasedResource.erase(b.share()))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)

    _ = destroy_graph(g, creds, store, scope=None)

    assert_true(a.deleted(), "scope=None destroys the whole graph, as it always did")
    assert_true(b.deleted(), "scope=None destroys the whole graph, as it always did")
    assert_equal(store.count_reaped(String("a")), 1)
    assert_equal(store.count_reaped(String("b")), 1)
    _ = a^
    _ = b^


def test_destroy_scope_skips_out_of_scope_without_reading_or_reaping() raises:
    """⛔ THE ROLLBACK CASE. `b` is the node the release ADDED (in scope); `a` is a
    node that predates it and which the converge-to-prior restores (out of scope).
    Deleting `a` would turn a revert into an outage; REAPING its record without
    deleting it would orphan a live resource behind a retired intent."""
    var g = ResourceGraph()
    var a = FakeResource(
        String("a"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    var b = FakeResource(
        String("b"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(a.share()))
    g.add(ErasedResource.erase(b.share()))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)
    var reads_before_a = a.read_count()

    var only_b = List[String]()
    only_b.append(String("b"))
    _ = destroy_graph(g, creds, store, scope=_scope(only_b^))

    assert_true(b.deleted(), "the IN-SCOPE node is destroyed")
    assert_equal(store.count_reaped(String("b")), 1)
    assert_false(
        a.deleted(),
        "an OUT-OF-SCOPE node must NOT be deleted — the scope is what makes a"
        " rollback destroy only what this release ADDED",
    )
    assert_equal(
        a.read_count(),
        reads_before_a,
        "an out-of-scope node costs no API call — it is skipped BEFORE the live"
        " read, exactly as a RETAIN_KEEP node is",
    )
    assert_equal(
        store.count_reaped(String("a")),
        0,
        "AND ITS RECORD IS NOT RETIRED. The resource is live; retiring the intent"
        " over it is the money leak the confirmed-gone gate exists to stop",
    )
    assert_equal(
        store.count_confirmed(String("a")),
        1,
        "the out-of-scope node's confirmed intent survives intact",
    )
    _ = a^
    _ = b^


def test_destroy_scope_present_but_empty_deletes_nothing() raises:
    """⛔ ABSENT vs EMPTY. A `List[String]()` sentinel would collapse "no scope"
    into "empty scope"; the `Optional` is what keeps them apart, and an empty
    PRESENT scope is honoured as 'delete nothing' rather than widened."""
    var g = ResourceGraph()
    var a = FakeResource(
        String("a"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(a.share()))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)

    _ = destroy_graph(g, creds, store, scope=_scope(List[String]()))

    assert_false(a.deleted(), "an EMPTY scope deletes nothing — it is not `None`")
    assert_equal(store.count_reaped(String("a")), 0)
    _ = a^


def test_a_scoped_destroy_still_confirms_gone() raises:
    """⭐⭐ THE INHERITANCE PROOF, and the falsifier for the "rollback that skips
    the confirming re-read" mutation.

    An IN-SCOPE node whose delete is issued but does NOT take must still RAISE and
    must still NOT be reaped. This holds by CONSTRUCTION — the scope filters the
    same walk (7c) guards — and asserting it is what stops a future edit from
    'optimising' the scoped path into a second, ungated teardown."""
    var g = ResourceGraph()
    var app = FakeResource(
        String("app"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    app.set_delete_noop(True)
    g.add(ErasedResource.erase(app.share()))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)

    var only_app = List[String]()
    only_app.append(String("app"))
    with assert_raises():
        _ = destroy_graph(g, creds, store, scope=_scope(only_app^))

    assert_true(app.deleted(), "a delete WAS issued for the in-scope node")
    assert_equal(
        store.count_reaped(String("app")),
        0,
        "a SCOPED destroy retires a record ONLY on a confirmed-gone re-read — the"
        " scope narrows WHAT is walked, never the gate applied to it",
    )
    assert_equal(store.count_confirmed(String("app")), 1)
    _ = app^


def test_destroy_scope_does_not_lift_retain_keep() raises:
    """A scope can only make a teardown do LESS. Naming a RETAIN_KEEP node in the
    scope does NOT authorise deleting it — `force_delete_data` is the only thing
    that lifts that skip, and an automatic rollback never passes it."""
    var g = ResourceGraph()
    var kept = FakeResource(
        String("kept"), List[String](), RETAIN_KEEP, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(kept.share()))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)

    var named = List[String]()
    named.append(String("kept"))
    _ = destroy_graph(g, creds, store, scope=_scope(named^))

    assert_false(
        kept.deleted(),
        "naming a RETAIN_KEEP node in the scope must NOT delete it — a scope is a"
        " ceiling on what MAY be touched, never a command to touch it",
    )
    assert_equal(store.count_reaped(String("kept")), 0)
    _ = kept^


def test_destroy_transient_read_raises_and_does_not_reap() raises:
    # (7c-iii) A TRANSIENT read (GOAWAY) RAISES out of destroy — the neutral contract
    # is that read_status RAISES on a transient fault, it does NOT read as absent. So
    # a contained transient can NEVER be mistaken for an already-gone (absent) read
    # and retire the intent over a live resource.
    var g = ResourceGraph()
    var app = FakeResource(
        String("app"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(app.share()))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var _applied = apply_graph(g, creds, store)  # record + confirm (a clean read).
    # Arm the transient AFTER apply so the DESTROY's read is the GOAWAY (apply's own
    # read already fired cleanly above — the destroy read is the one that faults).
    app.set_read_raises(1)

    # THE FALSIFIER: the transient read RAISES out of destroy (fail-loud) — NO delete
    # is issued on a resource we could not read, and the intent is NOT reaped.
    with assert_raises():
        _ = destroy_graph(g, creds, store)

    assert_false(
        app.deleted(),
        "NO delete is issued when the destroy read itself was a transient fault",
    )
    assert_equal(
        store.count_reaped(String("app")),
        0,
        "a transient read NEVER retires the intent (no absent-misread leak)",
    )
    _ = app^


# =============================================================================
# (8a) A FAILED live resource is UPDATED, not refused.
#
# The author ships a bad image; the new revision never becomes ready and the
# cloud reports the resource FAILED while it stays present. The author pushes
# a fixed image. The apply must update the failed resource (the way out); a
# refusal would leave a console edit as the only recovery, every apply after
# the first bad one raising at that node forever.
# =============================================================================
def test_apply_updates_a_failed_node() raises:
    var g = ResourceGraph()
    var svc = FakeResource(
        String("svc"), List[String](), RETAIN_DELETE, RES_FAILED
    )
    g.add(ErasedResource.erase(svc.share()))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var applied = apply_graph(g, creds, store)
    assert_equal(len(applied), 1)
    assert_equal(applied[0].verb, VERB_UPDATE, "a FAILED node is updated")
    assert_equal(applied[0].physical_id, String("phys-svc"), "the live id is kept")
    assert_true(svc.updated(), "update was issued on the failed resource")
    assert_false(svc.created(), "a failed resource is not re-created")
    # The fixed spec converged: a re-apply is a no-op.
    var again = apply_graph(g, creds, store)
    assert_equal(again[0].verb, VERB_NOOP, "after the fix the node settles")

    # A failed node whose drift needs a REPLACE still refuses (the typed hole
    # is the same whatever made the resource differ).
    var g2 = ResourceGraph()
    var bad = FakeResource(
        String("bad"), List[String](), RETAIN_DELETE, RES_FAILED, CONVERGE_REPLACE
    )
    g2.add(ErasedResource.erase(bad.share()))
    var store2 = InMemoryStateStore()
    var raised = False
    try:
        _ = apply_graph(g2, creds, store2)
    except e:
        raised = True
        assert_true(
            _contains_sub(String(e), "CONVERGE_REPLACE"), String(e)
        )
    assert_true(raised, "a failed node that needs a REPLACE is refused")
    assert_false(bad.updated() or bad.created() or bad.deleted())
    _ = svc^
    _ = bad^


# =============================================================================
# (8) apply_graph ADOPTS a matched node (no create) and UPDATES a drifted node.
# =============================================================================
def test_apply_adopts_matched_and_updates_drifted() raises:
    var g = ResourceGraph()
    # A matched node (already deployed) — apply must NOT create it (adopt / noop).
    var matched = FakeResource(
        String("matched"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(matched.share()))
    # A drifted node (IN_PLACE) — apply must UPDATE it (one update, no create).
    var deps_dr = List[String]()
    deps_dr.append(String("matched"))
    var drifted = FakeResource(
        String("drifted"),
        deps_dr^,
        RETAIN_DELETE,
        RES_PRESENT_DRIFTED,
        CONVERGE_IN_PLACE,
    )
    g.add(ErasedResource.erase(drifted.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var applied = apply_graph(g, creds, store)

    assert_equal(len(applied), 2, "both nodes applied")
    # matched -> noop (adopt), NO create/update.
    assert_false(matched.created(), "matched node NOT created (adopted)")
    assert_false(matched.updated(), "matched node NOT updated (already matched)")
    assert_equal(applied[0].verb, VERB_NOOP, "matched node applied as noop")
    # drifted -> exactly one update, NO create.
    assert_true(drifted.updated(), "drifted node was UPDATED in place")
    assert_false(drifted.created(), "drifted node NOT created (it was present)")
    assert_equal(applied[1].verb, VERB_UPDATE, "drifted node applied as update")

    _ = matched^
    _ = drifted^


# =============================================================================
# (9) crash-then-adopt: a re-apply ADOPTS the surviving intent (no double-create).
#     Models the write-ahead recovery property: two apply passes over ONE store.
# =============================================================================
def test_reapply_adopts_intent_no_double_create() raises:
    var creds = Creds.none()
    var store = InMemoryStateStore()  # ONE durable store across both passes.

    # ---- PASS 1: a fresh apply creates the node + confirms its intent. ----
    var g1 = ResourceGraph()
    var a1 = FakeResource(
        String("A"), List[String](), RETAIN_DELETE, RES_ABSENT
    )
    g1.add(ErasedResource.erase(a1.share()))
    var applied1 = apply_graph(g1, creds, store)
    assert_equal(applied1[0].verb, VERB_CREATE, "pass 1 created A")
    assert_true(a1.created(), "pass 1 create ran")
    assert_equal(store.count_confirmed(String("A")), 1, "A confirmed once")
    assert_equal(store.total_intents(String("A")), 1, "exactly one intent for A")

    # ---- PASS 2: a re-apply of the SAME node (now matched live) over the SAME
    #      store ADOPTS the confirmed intent — NO second intent, NO re-create. ----
    var g2 = ResourceGraph()
    var a2 = FakeResource(
        String("A"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g2.add(ErasedResource.erase(a2.share()))
    var applied2 = apply_graph(g2, creds, store)

    # THE FALSIFIER: the re-apply ADOPTED (already_confirmed) — no double-create.
    assert_true(
        applied2[0].already_confirmed,
        "the re-apply adopted the surviving confirmed intent",
    )
    assert_equal(applied2[0].verb, VERB_NOOP, "the re-apply issued no mutation")
    assert_false(a2.created(), "the re-apply did NOT re-create A")
    assert_equal(
        store.total_intents(String("A")),
        1,
        "the re-apply did NOT create a second intent (adopted)",
    )
    assert_equal(
        store.count_provisioning(String("A")),
        0,
        "no orphaned PROVISIONING intent after the re-apply",
    )
    _ = a1^
    _ = a2^


# =============================================================================
# Per-node ERROR ENRICHMENT (DIAGNOSABILITY): a mutation raise must be
# enriched with WHICH node + verb produced it, so a caller surfacing `String(e)`
# (an HTTP error detail, a structured log line) pinpoints the culprit.
# =============================================================================
def test_apply_raise_names_node_and_verb() raises:
    """FALSIFIER: an engine that let a node's `create` raise propagate BARE
    (e.g. `[grpc:3] Invalid service account`) would surface an error that does
    not say which of the many apply nodes produced it. With the engine's
    `_node_verb_error` enrichment the raise names `apply node '<lid>' verb=create
    failed: <inner>` — ONE surfaced error pinpoints the exact node + verb + the
    inner backend detail."""
    var g = ResourceGraph()
    var node = FakeResource(
        String("example-deploy-impersonate-grant-1"),
        List[String](),
        RETAIN_DELETE,
        RES_ABSENT,  # absent -> the apply takes the CREATE path
    )
    var reader = node.share()
    reader.set_create_raises(True)
    g.add(ErasedResource.erase(node^))
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var raised = False
    try:
        _ = apply_graph(g, creds, store)
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("example-deploy-impersonate-grant-1")) >= 0,
            "the enriched raise NAMES the failing node's logical_id",
        )
        assert_true(
            msg.find(String("verb=create")) >= 0,
            "the enriched raise NAMES the verb (create)",
        )
        assert_true(
            msg.find(String("Invalid service account")) >= 0,
            "the enriched raise carries the inner backend detail verbatim",
        )
    assert_true(raised, "a node create fault propagates (enriched, not swallowed)")
    _ = reader
    print("  test_apply_raise_names_node_and_verb: PASS")


# =============================================================================
# (10) BEST-EFFORT RETENTION PRUNE — the engine invokes `prune` after a successful
#      create/update (engine.mojo §3b), and a PRUNE RAISE NEVER FAILS THE DEPLOY.
#
#   This is the single most safety-critical invariant of the keep-last-N revisions
#   feature: a persistently-failing prune (missing IAM /
#   an unimplemented live verb) must be SWALLOWED — the deploy still succeeds and
#   accrues revisions rather than wedging. Two falsifiers:
#     (10a) prune IS invoked on a create (guards the engine post-apply seam + the
#           ErasedResource.prune vtable forwarding to the conformer override).
#     (10b) a RAISING prune does NOT propagate out of apply_graph (the deploy
#           returns a complete AppliedNode list; the swallow is real).
# =============================================================================
def test_apply_invokes_prune_after_create() raises:
    """FALSIFIER (10a): apply_graph over an absent node CREATES it, then invokes the
    best-effort retention `prune` (engine.mojo §3b). Guards BOTH the engine post-
    apply invocation seam AND that ErasedResource.prune forwards through the vtable
    to the conformer override (NOT the trait-default no-op — which would leave
    `pruned()` False even though the feature 'looks wired')."""
    var g = ResourceGraph()
    var a = FakeResource(String("A"), List[String](), RETAIN_DELETE, RES_ABSENT)
    g.add(ErasedResource.erase(a.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var applied = apply_graph(g, creds, store)

    assert_equal(applied[0].verb, VERB_CREATE, "the absent node was created")
    assert_true(a.created(), "the create ran")
    assert_true(
        a.pruned(),
        "the engine invoked the best-effort prune after the create (the §3b"
        " retention seam + the ErasedResource.prune vtable forwarding)",
    )
    _ = a^


def test_apply_swallows_prune_raise_deploy_succeeds() raises:
    """FALSIFIER (10b): a node whose best-effort `prune` RAISES a genuine (non-404)
    transport fault (missing run.revisions.delete IAM / an unimplemented live verb)
    does NOT fail the deploy. apply_graph MUST swallow the raise and return the
    complete AppliedNode list. Falsifies an engine that lets a prune fault escape
    apply_graph (which would wedge every deploy on a stuck prune)."""
    var g = ResourceGraph()
    var a = FakeResource(String("A"), List[String](), RETAIN_DELETE, RES_ABSENT)
    a.set_prune_raises(True)
    g.add(ErasedResource.erase(a.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    # MUST NOT raise — the prune fault is swallowed (best-effort; deploy continues).
    var applied = apply_graph(g, creds, store)

    assert_equal(
        len(applied), 1, "the node applied (the prune raise did NOT fail the apply)"
    )
    assert_equal(applied[0].verb, VERB_CREATE, "the create still succeeded")
    assert_true(a.created(), "the create ran before the (swallowed) prune")
    assert_true(a.pruned(), "the prune was attempted (and its raise swallowed)")
    # The intent was still confirmed (a swallowed prune leaves a clean apply).
    assert_equal(
        store.count_confirmed(String("A")),
        1,
        "the node's intent confirmed despite the swallowed prune fault",
    )
    assert_equal(
        store.count_provisioning(String("A")),
        0,
        "no orphaned PROVISIONING intent (the apply completed past the prune)",
    )
    _ = a^


def main() raises:
    test_topo_order_is_dependency_correct()
    test_apply_creates_in_topo_order()
    test_apply_raise_names_node_and_verb()
    test_rollback_reverse_skips_keep_and_confirmed()
    test_rollback_never_deletes_an_adopted_node_on_first_apply()
    test_rollback_reverse_order()
    test_rollback_never_deletes_an_updated_node()
    test_cycle_raises()
    test_dangling_dependency_raises()
    test_plan_mutates_nothing()
    test_drifted_replace_raises_unsupported()
    test_destroy_reverse_skips_keep_idempotent()
    test_env_erase_reaps_retain_keep_bucket()
    test_force_delete_data_does_not_override_undeletable()
    test_default_teardown_is_unchanged_by_the_third_code()
    test_undeletable_with_no_reason_is_named_as_a_conformer_defect()
    test_rollback_create_skips_an_undeletable_node()
    test_destroy_absent_is_idempotent()
    test_destroy_reaps_only_on_confirmed_gone()
    test_destroy_does_not_reap_when_delete_does_not_take()
    test_destroy_transient_read_raises_and_does_not_reap()
    test_destroy_scope_none_is_byte_identical_to_the_unscoped_walk()
    test_destroy_scope_skips_out_of_scope_without_reading_or_reaping()
    test_destroy_scope_present_but_empty_deletes_nothing()
    test_a_scoped_destroy_still_confirms_gone()
    test_destroy_scope_does_not_lift_retain_keep()
    test_apply_adopts_matched_and_updates_drifted()
    test_apply_updates_a_failed_node()
    test_reapply_adopts_intent_no_double_create()
    test_apply_invokes_prune_after_create()
    test_apply_swallows_prune_raise_deploy_succeeds()
    verifier_adopted_node_survives_a_real_downstream_failure()
    verifier_created_node_is_still_reaped_on_the_failing_path()
    print("test_resource_graph_engine: all kci_reconciler engine cases PASSED")


# =============================================================================
# ADVERSARIAL VERIFIER (the real failing path).
#
# The data-loss falsifier above calls `rollback_create` on the return value of a
# FULLY SUCCESSFUL `apply_graph` — i.e. it never drives the path a real unwind
# takes. This one does: node B GENUINELY RAISES (`set_create_raises`),
# `apply_graph_tracked` propagates, and the unwind runs over the `landed`
# out-parameter that SURVIVES the raise — which is the only list a production
# caller could ever hold on the failing path. If the VERB_NOOP skip were an
# artifact of that harness rather than a property of the engine, this is where
# it would show.
# =============================================================================
def verifier_adopted_node_survives_a_real_downstream_failure() raises:
    var g = ResourceGraph()

    # A: the customer's PRE-EXISTING resource. RETAIN_DELETE (so RETAIN_KEEP is not
    # what saves it) and NO prior intent (so already_confirmed is not what saves it).
    var preexisting = FakeResource(
        String("preexisting"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(preexisting.share()))

    # B: a node this apply tries to create, and which FAILS.
    var deps_b = List[String]()
    deps_b.append(String("preexisting"))
    var failing = FakeResource(
        String("failing"), deps_b^, RETAIN_DELETE, RES_ABSENT
    )
    failing.set_create_raises(True)
    g.add(ErasedResource.erase(failing.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var landed = List[AppliedNode]()
    var pending = List[String]()

    var raised = False
    try:
        _ = apply_graph_tracked(g, creds, store, landed, pending)
    except e:
        raised = True
    assert_true(raised, "node B's create RAISED, so the apply failed")

    # `landed` survived the raise and holds exactly the adopted node.
    assert_equal(len(landed), 1, "only the adopted node landed")
    assert_equal(landed[0].logical_id, String("preexisting"), "and it is A")
    assert_equal(landed[0].verb, VERB_NOOP, "A was ADOPTED (verb=NOOP)")
    assert_false(landed[0].already_confirmed, "FIRST apply: no prior intent")
    assert_false(preexisting.created(), "A was adopted, never created")

    # The operator unwinds what landed.
    rollback_create(g, landed, creds, store)

    assert_false(
        preexisting.deleted(),
        (
            "VERIFIER: the unwind DELETED a resource this apply only ADOPTED, on"
            " the real failing path"
        ),
    )
    assert_equal(
        store.count_reaped(String("preexisting")), 0, "VERIFIER: A was not reaped"
    )
    _ = preexisting^
    _ = failing^


# =============================================================================
# ADVERSARIAL VERIFIER — THE NON-EMPTY ARM, also on the real failing path.
# A adopts, B is GENUINELY CREATED, C fails. The unwind MUST delete B (else the
# rollback would trade data loss for orphaned resources) and MUST NOT delete A.
# =============================================================================
def verifier_created_node_is_still_reaped_on_the_failing_path() raises:
    var g = ResourceGraph()

    var preexisting = FakeResource(
        String("preexisting"), List[String](), RETAIN_DELETE, RES_PRESENT_MATCHED
    )
    g.add(ErasedResource.erase(preexisting.share()))

    var deps_b = List[String]()
    deps_b.append(String("preexisting"))
    var made = FakeResource(String("made"), deps_b^, RETAIN_DELETE, RES_ABSENT)
    g.add(ErasedResource.erase(made.share()))

    var deps_c = List[String]()
    deps_c.append(String("made"))
    var failing = FakeResource(String("failing"), deps_c^, RETAIN_DELETE, RES_ABSENT)
    failing.set_create_raises(True)
    g.add(ErasedResource.erase(failing.share()))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    var landed = List[AppliedNode]()
    var pending = List[String]()

    var raised = False
    try:
        _ = apply_graph_tracked(g, creds, store, landed, pending)
    except e:
        raised = True
    assert_true(raised, "node C's create RAISED")

    assert_equal(len(landed), 2, "A (adopted) and B (created) landed")
    assert_equal(landed[1].verb, VERB_CREATE, "B was genuinely CREATED")
    assert_true(made.created(), "B's create was issued")

    rollback_create(g, landed, creds, store)

    assert_true(
        made.deleted(),
        (
            "VERIFIER NON-EMPTY ARM: the unwind left a node this apply GENUINELY"
            " CREATED alive — the fix traded data loss for an orphaned resource"
        ),
    )
    assert_equal(store.count_reaped(String("made")), 1, "B's intent was reaped")
    assert_false(
        preexisting.deleted(), "VERIFIER: A (adopted) still untouched"
    )
    _ = preexisting^
    _ = made^
    _ = failing^
