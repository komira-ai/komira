# =============================================================================
# test_engine_apply_failure_paths.mojo — the apply verb's failure arms.
# =============================================================================
#
# What is pinned, each a separate test, over scripted nodes whose reads are a
# queue (the owned pre-flight read and the per-node read can disagree):
#
#   1. AN OWNED APPLY REFUSES THE UNOWNED SCOPE before any read.
#   2. A FAILED READ, UPDATE OR ADOPT IS NAMED: node, verb, the conformer's
#      fault domain for that verb, and the backend text verbatim.
#   3. A ROLE TURNED OFF WHOSE DELETE FAILS stops the apply naming the delete,
#      and the store keeps the record (it is retired only on a confirmed gone).
#   4. OWNERSHIP THAT CHANGES BETWEEN THE PRE-FLIGHT AND THE NODE'S OWN READ
#      stops the apply before any create or adopt.
#   5. A NON-STEADY PHASE (converging) is refused, never converged.
#   6. A MATCHED NODE THAT REPORTS NO PHYSICAL ID keeps the one the store
#      confirmed, and the store is not overwritten with an empty id.
#   7. ROLLBACK DOES NOT UNWIND A CREATE WHOSE INTENT A PRIOR APPLY CONFIRMED
#      (the node was gone out of band and recreated); a fresh create in the
#      same apply is still unwound.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from kci_reconciler import (
    Resource,
    ResourceStatus,
    ChangeAction,
    Creds,
    ErasedResource,
    ResourceGraph,
    InMemoryStateStore,
    AppliedNode,
    CellScope,
    OwnerStamp,
    Provenance,
    InputRef,
    ResolvedInputs,
    RES_CONVERGING,
    RETAIN_DELETE,
    CONVERGE_IN_PLACE,
    VERB_CREATE,
    VERB_NOOP,
    VERB_UPDATE,
    FAULT_UNSET,
    FAULT_USER,
    FAULT_PROVIDER,
    FAULT_OURS,
    apply_graph,
    apply_graph_owned,
    rollback_create,
)


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# ---- a scripted node ------------------------------------------------------------
#
# Each node owns a `_World`: the statuses its reads return (a queue; the last one
# repeats, so a test scripts "the pre-flight read sees X, the next read sees Y"),
# the calls it received, and which verb raises. `create` and `delete` move the
# queue to what the cloud now holds, so the engine's confirming re-read is real.


struct _World(Movable):
    var reads: List[ResourceStatus]
    var calls: List[String]
    var fail_read: String
    var fail_update: String
    var fail_adopt: String
    var fail_delete: String
    var report_pid: Bool
    var wanted: Bool
    var retention: Int
    var fault_verb: String
    var fault: Int

    def __init__(out self, var first: ResourceStatus):
        self.reads = List[ResourceStatus]()
        self.reads.append(first^)
        self.calls = List[String]()
        self.fail_read = String("")
        self.fail_update = String("")
        self.fail_adopt = String("")
        self.fail_delete = String("")
        self.report_pid = True
        self.wanted = True
        self.retention = RETAIN_DELETE
        self.fault_verb = String("")
        self.fault = FAULT_UNSET

    def next_read(mut self, var next: ResourceStatus):
        self.reads.append(next^)

    def now(mut self, var only: ResourceStatus):
        self.reads.clear()
        self.reads.append(only^)

    def count(self, prefix: String) -> Int:
        var n = 0
        for i in range(len(self.calls)):
            if self.calls[i].startswith(prefix):
                n += 1
        return n


def _world(var first: ResourceStatus) -> ArcPointer[_World]:
    return ArcPointer[_World](_World(first^))


struct _Scripted(Resource, Movable, Deinitable):
    var _w: ArcPointer[_World]
    var _id: String
    var _owner: String
    var _deps: List[String]
    var _refs: List[InputRef]

    def __init__(
        out self,
        w: ArcPointer[_World],
        id: String,
        owner: String = String(""),
        var refs: List[InputRef] = List[InputRef](),
    ):
        self._w = w.copy()
        self._id = id
        self._owner = owner
        self._deps = List[String]()
        self._refs = refs^

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return self._deps.copy()

    def retention(mut self) -> Int:
        return self._w[].retention

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        self._w[].calls.append(String("read"))
        if self._w[].fail_read.byte_length() > 0:
            raise Error(self._w[].fail_read)
        if len(self._w[].reads) > 1:
            return self._w[].reads.pop(0)
        return self._w[].reads[0].copy()

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var verb = VERB_UPDATE
        if live.is_absent():
            verb = VERB_CREATE
        elif live.is_matched():
            verb = VERB_NOOP
        return ChangeAction(self._id.copy(), verb, String(""), self._w[].retention)

    def create(mut self, creds: Creds) raises -> String:
        var pid = String("pid-") + self._id
        self._w[].calls.append(String("create ") + pid)
        var shown = pid.copy() if self._w[].report_pid else String("")
        self._w[].now(ResourceStatus.matched(shown, String("d")))
        return pid^

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        var pid = String("pid-") + self._id
        self._w[].calls.append(String("create_owned ") + pid)
        var shown = pid.copy() if self._w[].report_pid else String("")
        self._w[].now(
            ResourceStatus.matched(
                shown, String("d"), String(""), String(""), stamp.identity()
            )
        )
        return pid^

    def adopt_owned(
        mut self, stamp: OwnerStamp, physical_id: String, creds: Creds
    ) raises:
        self._w[].calls.append(String("adopt ") + physical_id)
        if self._w[].fail_adopt.byte_length() > 0:
            raise Error(self._w[].fail_adopt)

    def update(mut self, creds: Creds) raises:
        self._w[].calls.append(String("update"))
        if self._w[].fail_update.byte_length() > 0:
            raise Error(self._w[].fail_update)

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._w[].calls.append(String("delete ") + physical_id)
        if self._w[].fail_delete.byte_length() > 0:
            raise Error(self._w[].fail_delete)
        self._w[].now(ResourceStatus.absent())

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE

    def fault_domain(mut self, verb: String) raises -> Int:
        if verb == self._w[].fault_verb:
            return self._w[].fault
        return FAULT_UNSET

    def input_refs(mut self) -> List[InputRef]:
        return self._refs.copy()

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        pass

    def owner(mut self) -> String:
        return self._owner.copy()

    def stamps_ownership(mut self) -> Bool:
        return True

    def wanted(mut self) -> Bool:
        return self._w[].wanted


def _graph1(w: ArcPointer[_World], id: String, owner: String = String("")) raises -> ResourceGraph:
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Scripted(w, id, owner)))
    return g^



def _cell() -> CellScope:
    return CellScope(String("shop"), String("blue"), Provenance(String("r1"), String("v1")))


def _cell_adopting(id: String) -> CellScope:
    var adopt = List[String]()
    adopt.append(id)
    return CellScope(
        String("shop"), String("blue"), Provenance(String("r1"), String("v1")), adopt^
    )


def _apply_err(mut g: ResourceGraph, mut store: InMemoryStateStore) -> String:
    try:
        _ = apply_graph(g, Creds.none(), store)
    except e:
        return String(e)
    return String("")


def _owned_err(
    mut g: ResourceGraph, cell: CellScope, mut store: InMemoryStateStore
) -> String:
    var landed = List[AppliedNode]()
    var pending = List[String]()
    try:
        _ = apply_graph_owned(g, Creds.none(), cell, store, landed, pending)
    except e:
        return String(e)
    return String("")


# ---- 1. the owned form refuses the unowned scope -------------------------------


def test_owned_apply_refuses_the_unowned_scope() raises:
    var w = _world(ResourceStatus.absent())
    var g = _graph1(w, String("n"))
    var store = InMemoryStateStore()
    var msg = _owned_err(g, CellScope.unowned(), store)
    assert_equal(
        msg,
        "apply_graph_owned: the scope names no machine and cell;"
        " use apply_graph_tracked for the unowned scope",
    )
    assert_equal(len(w[].calls), 0, "nothing was read or created")
    print("  test_owned_apply_refuses_the_unowned_scope: PASS")


# ---- 2. a failed read, update or adopt is named ----------------------------------


def test_a_failed_read_names_the_node_the_verb_and_the_fault() raises:
    var w = _world(ResourceStatus.absent())
    w[].fail_read = String("AccessDenied: cannot read n")
    w[].fault_verb = String("read_status")
    w[].fault = FAULT_USER
    var g = _graph1(w, String("n"))
    var store = InMemoryStateStore()
    assert_equal(
        _apply_err(g, store),
        "[fault=user] apply node 'n' verb=read_status failed:"
        " AccessDenied: cannot read n",
    )
    assert_equal(w[].count(String("create")), 0, "an unread node is not created")
    print("  test_a_failed_read_names_the_node_the_verb_and_the_fault: PASS")


def test_a_failed_update_names_the_node_the_verb_and_the_fault() raises:
    var w = _world(ResourceStatus.drifted(String("pid-n"), String("old")))
    w[].fail_update = String("Throttling: slow down")
    w[].fault_verb = String("update")
    w[].fault = FAULT_PROVIDER
    var g = _graph1(w, String("n"))
    var store = InMemoryStateStore()
    assert_equal(
        _apply_err(g, store),
        "[fault=provider] apply node 'n' verb=update failed: Throttling: slow down",
    )
    assert_equal(w[].count(String("update")), 1)
    print("  test_a_failed_update_names_the_node_the_verb_and_the_fault: PASS")


def test_a_failed_adopt_names_the_node_the_verb_and_the_fault() raises:
    # Present, unstamped, and the run adopts it: the pre-flight passes, the
    # adopt is issued and fails.
    var w = _world(ResourceStatus.matched(String("pid-n"), String("d")))
    w[].fail_adopt = String("PermissionDenied: cannot label")
    w[].fault_verb = String("adopt")
    w[].fault = FAULT_USER
    var g = _graph1(w, String("api/run"), String("api"))
    var store = InMemoryStateStore()
    assert_equal(
        _owned_err(g, _cell_adopting(String("api/run")), store),
        "[fault=user] apply node 'api/run' verb=adopt failed:"
        " PermissionDenied: cannot label",
    )
    assert_equal(w[].count(String("adopt pid-n")), 1)
    assert_equal(w[].count(String("create")), 0)
    print("  test_a_failed_adopt_names_the_node_the_verb_and_the_fault: PASS")


# ---- 3. a role turned off whose delete fails -------------------------------------


def test_a_failed_closed_world_delete_is_named_and_keeps_the_record() raises:
    var w = _world(ResourceStatus.absent())
    var store = InMemoryStateStore()
    var g = _graph1(w, String("n"))
    _ = apply_graph(g, Creds.none(), store)
    assert_equal(store.physical_id_for(String("n")), "pid-n")

    w[].wanted = False
    w[].fail_delete = String("Conflict: still in use")
    w[].fault_verb = String("delete")
    w[].fault = FAULT_OURS
    var g2 = _graph1(w, String("n"))
    assert_equal(
        _apply_err(g2, store),
        "[fault=ours] apply node 'n' verb=delete failed: Conflict: still in use",
    )
    assert_equal(w[].count(String("delete pid-n")), 1, "the delete was issued")
    assert_equal(
        store.physical_id_for(String("n")), "pid-n", "the record was not retired"
    )
    print("  test_a_failed_closed_world_delete_is_named_and_keeps_the_record: PASS")


# ---- 4. ownership that changes during the run ------------------------------------


def test_ownership_changed_between_preflight_and_read_stops_the_apply() raises:
    # The pre-flight read sees nothing; the node's own read then sees an object
    # stamped for another owner.
    var w = _world(ResourceStatus.absent())
    w[].next_read(
        ResourceStatus.matched(
            String("pid-x"),
            String("d"),
            String(""),
            String(""),
            String("kci:v1 owner=shop/green/api/run"),
        )
    )
    var g = _graph1(w, String("api/run"), String("api"))
    var store = InMemoryStateStore()
    assert_equal(
        _owned_err(g, _cell(), store),
        "apply node 'api/run': ownership changed during the run: conflict: the"
        " live object is stamped for another owner"
        " (kci:v1 owner=shop/green/api/run)",
    )
    assert_equal(w[].count(String("read")), 2, "the pre-flight read and the node's")
    assert_equal(w[].count(String("create")), 0)
    assert_equal(w[].count(String("adopt")), 0)
    print("  test_ownership_changed_between_preflight_and_read_stops_the_apply: PASS")


# ---- 5. a non-steady phase ------------------------------------------------------------


def test_a_converging_phase_is_refused_not_converged() raises:
    var w = _world(
        ResourceStatus(
            RES_CONVERGING, String("pid-n"), String("d"), String("rollout 2 of 3")
        )
    )
    var g = _graph1(w, String("n"))
    var store = InMemoryStateStore()
    var msg = _apply_err(g, store)
    assert_true(
        msg.startswith(
            "apply_graph: node 'n' read a non-steady live phase ("
            + String(RES_CONVERGING)
            + ")"
        ),
        msg,
    )
    assert_true(msg.endswith(" apply. rollout 2 of 3"), msg)
    assert_equal(w[].count(String("update")), 0, "a converging node is not updated")
    assert_equal(w[].count(String("create")), 0)
    print("  test_a_converging_phase_is_refused_not_converged: PASS")


# ---- 6. a matched node that reports no physical id -------------------------------


def test_an_empty_live_id_keeps_the_confirmed_one() raises:
    var w = _world(ResourceStatus.absent())
    w[].report_pid = False
    var store = InMemoryStateStore()
    var g = _graph1(w, String("n"))
    var first = apply_graph(g, Creds.none(), store)
    assert_equal(first[0].verb, VERB_CREATE)
    assert_equal(first[0].physical_id, "pid-n")

    var g2 = _graph1(w, String("n"))
    var second = apply_graph(g2, Creds.none(), store)
    assert_equal(second[0].verb, VERB_NOOP)
    assert_true(second[0].already_confirmed)
    assert_equal(second[0].physical_id, "pid-n", "the confirmed id, not empty")
    assert_equal(store.physical_id_for(String("n")), "pid-n", "not overwritten")
    print("  test_an_empty_live_id_keeps_the_confirmed_one: PASS")


# ---- 7. rollback and a create over a confirmed intent ----------------------------


def test_rollback_skips_a_create_over_a_confirmed_intent() raises:
    var wn = _world(ResourceStatus.absent())
    var store = InMemoryStateStore()
    var g = _graph1(wn, String("n"))
    _ = apply_graph(g, Creds.none(), store)

    # n is deleted out of band; the next apply creates it again over the
    # intent the first apply confirmed, and creates `fresh` for the first time.
    wn[].now(ResourceStatus.absent())
    var wf = _world(ResourceStatus.absent())
    var g2 = ResourceGraph()
    g2.add(ErasedResource.erase(_Scripted(wn, String("n"))))
    g2.add(ErasedResource.erase(_Scripted(wf, String("fresh"))))
    var applied = apply_graph(g2, Creds.none(), store)
    assert_equal(applied[0].logical_id, "n")
    assert_equal(applied[0].verb, VERB_CREATE)
    assert_true(applied[0].already_confirmed, "the intent predates this apply")
    assert_equal(applied[1].verb, VERB_CREATE)
    assert_false(applied[1].already_confirmed)

    rollback_create(g2, applied, Creds.none(), store)
    assert_equal(wf[].count(String("delete pid-fresh")), 1, "a fresh create is unwound")
    assert_equal(wn[].count(String("delete")), 0, "a confirmed intent is not unwound")
    assert_equal(store.physical_id_for(String("n")), "pid-n")
    assert_equal(store.physical_id_for(String("fresh")), "")
    print("  test_rollback_skips_a_create_over_a_confirmed_intent: PASS")


def main() raises:
    print("test_engine_apply_failure_paths:")
    test_owned_apply_refuses_the_unowned_scope()
    test_a_failed_read_names_the_node_the_verb_and_the_fault()
    test_a_failed_update_names_the_node_the_verb_and_the_fault()
    test_a_failed_adopt_names_the_node_the_verb_and_the_fault()
    test_a_failed_closed_world_delete_is_named_and_keeps_the_record()
    test_ownership_changed_between_preflight_and_read_stops_the_apply()
    test_a_converging_phase_is_refused_not_converged()
    test_an_empty_live_id_keeps_the_confirmed_one()
    test_rollback_skips_a_create_over_a_confirmed_intent()
    print("ALL APPLY FAILURE-PATH TESTS PASSED")
