# =============================================================================
# test_ownership_and_cell_keys.mojo — the owned scope of the engine.
# =============================================================================
#
# What is pinned, each a separate test:
#
#   1. THE ERASED FACADE FORWARDS THE FOUR OWNERSHIP VERBS (`stamps_ownership`,
#      `create_owned`, `adopt_owned`, `wanted`) and the status carries `stamp`
#      and `unmanaged`. A verb left on the trait default fails here.
#   2. THE STORE IS KEYED (machine, cell, resource): one logical id in two
#      cells is two records, and a cell never adopts another cell's intent or
#      object (an object stamped for cell "blue" refuses an apply in "green").
#   3. THE STAMP RIDES THE CREATE CALL: an owned apply creates every object
#      with `create_owned` (no separate label call), the write-ahead intent
#      carries the same identity, provenance is written as an annotation, and
#      a re-apply under a NEW run id and revision mutates nothing.
#   4. A FOREIGN OBJECT REFUSES THE WHOLE RUN BEFORE ANY CHANGE, in apply,
#      plan and destroy; a resource that writes `adopt` stamps and records it instead.
#   5. A CONFLICT (a recorded node whose stamp was stripped, or an object
#      stamped for another owner) refuses apply and destroy; nothing is
#      deleted.
#   6. AN OWNED CELL REFUSES A NODE THAT CANNOT STAMP, before any change.
#   7. THE CLOSED WORLD: a role the file turned off is deleted when the store
#      recorded it and it carries the stamp; one only the stamp vouches for
#      (a lost store) is left and planned as leftover.
#   8. AN UNMANAGED DIFFERENCE is planned beside a NOOP and never converged.
#   9. A CRASH AFTER THE CREATE recovers by the stamp: the re-apply finds the
#      object stamped as this node's, adopts it, and creates nothing twice.
#  10. `ModelledDigest` refuses a provenance field.
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
    ResourceKey,
    ModelledDigest,
    REFUSED_TOKEN,
    RES_ABSENT,
    RES_PRESENT_MATCHED,
    RETAIN_DELETE,
    VERB_CREATE,
    VERB_DELETE,
    VERB_NOOP,
    VERB_UPDATE,
    apply_graph_owned,
    destroy_graph_owned,
    plan_graph_owned,
)


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# ---- a fake cloud that keeps a stamp per object -------------------------------


struct _Cloud(Movable):
    var ids: List[String]
    var digests: List[String]
    var stamps: List[String]
    var annotations: List[String]
    var extras: List[String]
    var calls: List[String]
    # Simulates a process killed right after the cloud acted on a create.
    var crash_after_create: Bool

    def __init__(out self):
        self.ids = List[String]()
        self.digests = List[String]()
        self.stamps = List[String]()
        self.annotations = List[String]()
        self.extras = List[String]()
        self.calls = List[String]()
        self.crash_after_create = False

    def find(self, id: String) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def plant(mut self, id: String, digest: String, stamp: String):
        """An object made outside this run (out of band, or by another
        owner)."""
        self.ids.append(id)
        self.digests.append(digest)
        self.stamps.append(stamp)
        self.annotations.append(String(""))
        self.extras.append(String(""))

    def mutations(self) -> Int:
        return len(self.calls)

    def count(self, verb: String) -> Int:
        var n = 0
        for i in range(len(self.calls)):
            if self.calls[i].startswith(verb + String(" ")):
                n += 1
        return n


struct _Node(Resource, Movable, Deinitable):
    var _cloud: ArcPointer[_Cloud]
    var _id: String
    var _owner: String
    var _digest: String
    var _wanted: Bool
    var _stamps: Bool

    def __init__(
        out self,
        cloud: ArcPointer[_Cloud],
        id: String,
        owner: String,
        digest: String,
        wanted: Bool = True,
        stamps: Bool = True,
    ):
        self._cloud = cloud.copy()
        self._id = id
        self._owner = owner
        self._digest = digest
        self._wanted = wanted
        self._stamps = stamps

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        var i = self._cloud[].find(self._id)
        if i < 0:
            return ResourceStatus.absent()
        var pid = String("pid-") + self._id
        ref c = self._cloud[]
        if c.digests[i] == self._digest:
            return ResourceStatus.matched(
                pid, c.digests[i], String(""), String(""), c.stamps[i], c.extras[i]
            )
        return ResourceStatus.drifted(
            pid, c.digests[i], String(""), String(""), c.stamps[i], c.extras[i]
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var verb = VERB_UPDATE
        if live.phase == RES_ABSENT:
            verb = VERB_CREATE
        elif live.is_matched():
            verb = VERB_NOOP
        return ChangeAction(self._id.copy(), verb, String(""), RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        self._cloud[].calls.append(String("create ") + self._id)
        self._cloud[].plant(self._id, self._digest, String(""))
        return String("pid-") + self._id

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        if self._cloud[].find(self._id) >= 0:
            raise Error(String("ALREADY_EXISTS: ") + self._id)
        self._cloud[].calls.append(String("create_owned ") + self._id)
        self._cloud[].plant(self._id, self._digest, stamp.identity())
        var i = self._cloud[].find(self._id)
        self._cloud[].annotations[i] = (
            stamp.provenance.run_id + String("@") + stamp.provenance.revision
        )
        if self._cloud[].crash_after_create:
            raise Error(String("the process died after the create"))
        return String("pid-") + self._id

    def adopt_owned(
        mut self, stamp: OwnerStamp, physical_id: String, creds: Creds
    ) raises:
        var i = self._cloud[].find(self._id)
        self._cloud[].calls.append(String("adopt ") + self._id)
        self._cloud[].stamps[i] = stamp.identity()

    def update(mut self, creds: Creds) raises:
        var i = self._cloud[].find(self._id)
        self._cloud[].calls.append(String("update ") + self._id)
        self._cloud[].digests[i] = self._digest

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._cloud[].calls.append(String("delete ") + self._id)
        var i = self._cloud[].find(self._id)
        if i < 0:
            return
        _ = self._cloud[].ids.pop(i)
        _ = self._cloud[].digests.pop(i)
        _ = self._cloud[].stamps.pop(i)
        _ = self._cloud[].annotations.pop(i)
        _ = self._cloud[].extras.pop(i)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1

    def owner(mut self) -> String:
        return self._owner.copy()

    def stamps_ownership(mut self) -> Bool:
        return self._stamps

    def wanted(mut self) -> Bool:
        return self._wanted


def _graph(
    cloud: ArcPointer[_Cloud],
    public_wanted: Bool = True,
    api_stamps: Bool = True,
) raises -> ResourceGraph:
    """db/run, api/run and the api/public role."""
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Node(cloud, String("db/run"), String("db"), String("db-v1"))))
    g.add(
        ErasedResource.erase(
            _Node(cloud, String("api/run"), String("api"), String("api-v1"), True, api_stamps)
        )
    )
    g.add(
        ErasedResource.erase(
            _Node(cloud, String("api/public"), String("api"), String("allow-all"), public_wanted)
        )
    )
    return g^


def _cell(run: String = String("run-1")) -> CellScope:
    return CellScope(String("shop"), String("blue"), Provenance(run, String("rev-") + run))


def _apply(
    mut g: ResourceGraph, cell: CellScope, mut store: InMemoryStateStore
) raises -> List[AppliedNode]:
    var landed = List[AppliedNode]()
    var pending = List[String]()
    return apply_graph_owned(g, Creds.none(), cell, store, landed, pending)


def _verb_of(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def _plan_verb(actions: List[ChangeAction], id: String) -> Int:
    for i in range(len(actions)):
        if actions[i].logical_id == id:
            return actions[i].verb
    return -1


# ---- 1. the erased probe ---------------------------------------------------------


struct _ProbeLog(Movable):
    var created_with: String
    var adopted_with: String

    def __init__(out self):
        self.created_with = String("")
        self.adopted_with = String("")


struct _Probe(Resource, Movable, Deinitable):
    var _log: ArcPointer[_ProbeLog]

    def __init__(out self, log: ArcPointer[_ProbeLog]):
        self._log = log.copy()

    def logical_id(mut self) -> String:
        return String("probe/run")

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        return ResourceStatus.matched(
            String("p"), String("d"), String(""), String(""), String("S"), String("U")
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return ChangeAction(String("probe/run"), VERB_NOOP, String(""), RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        return String("")

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1

    def stamps_ownership(mut self) -> Bool:
        return True

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        self._log[].created_with = stamp.identity()
        return String("pid-owned")

    def adopt_owned(
        mut self, stamp: OwnerStamp, physical_id: String, creds: Creds
    ) raises:
        self._log[].adopted_with = physical_id + String(" ") + stamp.identity()

    def wanted(mut self) -> Bool:
        return False


def test_erased_facade_forwards_the_ownership_verbs() raises:
    var log = ArcPointer[_ProbeLog](_ProbeLog())
    var node = ErasedResource.erase(_Probe(log))
    var stamp = _cell().stamp(String("probe"), String("probe/run"))
    assert_true(node.stamps_ownership(), "stamps_ownership reached the probe")
    assert_equal(node.create_owned(stamp, Creds.none()), "pid-owned")
    assert_equal(log[].created_with, "kci:v1 owner=shop/blue/probe/run")
    node.adopt_owned(stamp, String("pid-x"), Creds.none())
    assert_equal(log[].adopted_with, "pid-x kci:v1 owner=shop/blue/probe/run")
    assert_false(node.wanted(), "wanted reached the probe")
    var st = node.read_status(Creds.none())
    assert_equal(st.stamp, "S")
    assert_equal(st.unmanaged, "U")
    print("  test_erased_facade_forwards_the_ownership_verbs: PASS")


# ---- 2. the store key ------------------------------------------------------------


def test_the_store_is_keyed_by_machine_cell_and_resource() raises:
    var store = InMemoryStateStore()
    var blue = ResourceKey(String("shop"), String("blue"), String("api/run"))
    var green = ResourceKey(String("shop"), String("green"), String("api/run"))
    var t = store.record_or_adopt_intent(blue, String("kci:v1 owner=shop/blue/api/run"))
    store.confirm(t, String("pid-blue"))
    var t2 = store.record_or_adopt_intent(green, String(""))
    assert_false(t2.already_confirmed, "green did not adopt blue's confirmed intent")
    assert_equal(store.physical_id_for(green), "", "green has no confirmed id")
    assert_equal(store.physical_id_for(blue), "pid-blue")
    assert_equal(store.total_intents(blue), 1)
    assert_equal(store.total_intents(green), 1)

    # And a cell never takes another cell's object: the same graph, applied
    # in "green" against what "blue" made, is refused before any change.
    var cloud = ArcPointer[_Cloud](_Cloud())
    var g = _graph(cloud)
    var s1 = InMemoryStateStore()
    _ = _apply(g, _cell(), s1)
    var made = cloud[].mutations()
    var g2 = _graph(cloud)
    var s2 = InMemoryStateStore()
    var msg = String("")
    try:
        _ = _apply(g2, CellScope(String("shop"), String("green")), s2)
    except e:
        msg = String(e)
    assert_true(_has(msg, REFUSED_TOKEN), msg)
    assert_true(_has(msg, "stamped for another owner"), msg)
    assert_equal(cloud[].mutations(), made, "nothing changed in green's refused apply")
    print("  test_the_store_is_keyed_by_machine_cell_and_resource: PASS")


# ---- 3. the stamp rides the create call ------------------------------------------


def test_the_stamp_rides_the_create_call() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var g = _graph(cloud)
    var store = InMemoryStateStore()
    var a = _apply(g, _cell(), store)
    assert_equal(len(a), 3)
    assert_equal(cloud[].count(String("create_owned")), 3, "every create carried the stamp")
    assert_equal(cloud[].count(String("create")), 0, "no unstamped create")
    var i = cloud[].find(String("api/public"))
    assert_equal(cloud[].stamps[i], "kci:v1 owner=shop/blue/api/public")
    assert_equal(cloud[].annotations[i], "run-1@rev-run-1", "provenance as an annotation")
    var key = ResourceKey(String("shop"), String("blue"), String("api/public"))
    assert_equal(store.intent_stamp(key), "kci:v1 owner=shop/blue/api/public")
    assert_equal(store.count_confirmed(key), 1)

    # A new run and revision: nothing is a diff, nothing is written.
    var before = cloud[].mutations()
    var g2 = _graph(cloud)
    var a2 = _apply(g2, _cell(String("run-2")), store)
    for k in range(len(a2)):
        assert_equal(a2[k].verb, VERB_NOOP, a2[k].logical_id)
    assert_equal(cloud[].mutations(), before, "a new provenance mutates nothing")
    print("  test_the_stamp_rides_the_create_call: PASS")


# ---- 4. foreign --------------------------------------------------------------------


def test_a_foreign_object_refuses_the_run_before_any_change() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    cloud[].plant(String("api/run"), String("api-v1"), String(""))
    var store = InMemoryStateStore()

    # plan says so
    var gp = _graph(cloud)
    var pmsg = String("")
    try:
        _ = plan_graph_owned(gp, Creds.none(), _cell(), store)
    except e:
        pmsg = String(e)
    assert_true(_has(pmsg, "REFUSED plan"), pmsg)

    # apply refuses before ANY change: db/run (first in order) is not made
    var g = _graph(cloud)
    var landed = List[AppliedNode]()
    var pending = List[String]()
    var msg = String("")
    try:
        _ = apply_graph_owned(g, Creds.none(), _cell(), store, landed, pending)
    except e:
        msg = String(e)
    assert_true(_has(msg, "REFUSED apply"), msg)
    assert_true(_has(msg, "api/run: foreign"), msg)
    assert_true(_has(msg, "unless its resource writes adopt (which puts api/run in the run's adopt list)"), msg)
    assert_equal(cloud[].mutations(), 0, "nothing was created")
    assert_equal(len(landed), 0)
    assert_equal(len(pending), 3)

    # destroy never deletes it
    var gd = _graph(cloud)
    var dmsg = String("")
    try:
        _ = destroy_graph_owned(gd, Creds.none(), _cell(), store)
    except e:
        dmsg = String(e)
    assert_true(_has(dmsg, "REFUSED destroy"), dmsg)
    assert_true(cloud[].find(String("api/run")) >= 0, "the foreign object stands")

    # a resource that writes adopt stamps it and records it
    var adopt = List[String]()
    adopt.append(String("api/run"))
    var cell = CellScope(String("shop"), String("blue"), Provenance.none(), adopt^)
    var ga = _graph(cloud)
    var a = _apply(ga, cell, store)
    assert_equal(_verb_of(a, String("api/run")), VERB_UPDATE, "adopted = stamped")
    assert_equal(cloud[].count(String("adopt")), 1)
    var i = cloud[].find(String("api/run"))
    assert_equal(cloud[].stamps[i], "kci:v1 owner=shop/blue/api/run")
    var g3 = _graph(cloud)
    var a3 = _apply(g3, _cell(), store)
    assert_equal(_verb_of(a3, String("api/run")), VERB_NOOP, "then it is ours")
    print("  test_a_foreign_object_refuses_the_run_before_any_change: PASS")


# ---- 5. conflict -------------------------------------------------------------------


def test_a_conflict_refuses_apply_and_destroy() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var store = InMemoryStateStore()
    var g = _graph(cloud)
    _ = _apply(g, _cell(), store)
    var i = cloud[].find(String("api/run"))
    cloud[].stamps[i] = String("")  # the label was stripped
    var made = cloud[].mutations()

    var g2 = _graph(cloud)
    var msg = String("")
    try:
        _ = _apply(g2, _cell(), store)
    except e:
        msg = String(e)
    assert_true(_has(msg, "api/run: conflict"), msg)
    assert_true(_has(msg, "no kci stamp"), msg)

    cloud[].stamps[i] = String("kci:v1 owner=other/blue/api/run")
    var g3 = _graph(cloud)
    var dmsg = String("")
    try:
        _ = destroy_graph_owned(g3, Creds.none(), _cell(), store)
    except e:
        dmsg = String(e)
    assert_true(_has(dmsg, "REFUSED destroy"), dmsg)
    assert_true(_has(dmsg, "another owner"), dmsg)
    assert_equal(cloud[].mutations(), made, "nothing was changed or deleted")
    print("  test_a_conflict_refuses_apply_and_destroy: PASS")


# ---- 6. a node that cannot stamp -----------------------------------------------------


def test_an_owned_cell_refuses_a_node_that_cannot_stamp() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var store = InMemoryStateStore()
    var g = _graph(cloud, True, False)
    var msg = String("")
    try:
        _ = _apply(g, _cell(), store)
    except e:
        msg = String(e)
    assert_true(_has(msg, "api/run: its conformer does not stamp ownership"), msg)
    assert_equal(cloud[].mutations(), 0)
    print("  test_an_owned_cell_refuses_a_node_that_cannot_stamp: PASS")


# ---- 7. the closed world -------------------------------------------------------------


def test_the_closed_world_removes_a_turned_off_role() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var store = InMemoryStateStore()
    var g = _graph(cloud)
    _ = _apply(g, _cell(), store)

    var gp = _graph(cloud, False)
    var plan = plan_graph_owned(gp, Creds.none(), _cell(), store)
    assert_equal(_plan_verb(plan, String("api/public")), VERB_DELETE)
    assert_equal(_plan_verb(plan, String("api/run")), VERB_NOOP)

    var g2 = _graph(cloud, False)
    var a = _apply(g2, _cell(), store)
    assert_equal(_verb_of(a, String("api/public")), VERB_DELETE)
    assert_true(cloud[].find(String("api/public")) < 0, "the role is gone")
    var key = ResourceKey(String("shop"), String("blue"), String("api/public"))
    assert_equal(store.count_reaped(key), 1, "its record was retired")
    var g3 = _graph(cloud, False)
    var a3 = _apply(g3, _cell(), store)
    assert_equal(_verb_of(a3, String("api/public")), VERB_NOOP, "absent stays absent")

    # Only the stamp vouches for it (the store was lost): left, as leftover.
    var g4 = _graph(cloud)
    _ = _apply(g4, _cell(), store)
    var lost = InMemoryStateStore()
    var deletes = cloud[].count(String("delete"))
    var g5 = _graph(cloud, False)
    var p5 = plan_graph_owned(g5, Creds.none(), _cell(), lost)
    assert_equal(_plan_verb(p5, String("api/public")), VERB_NOOP)
    for k in range(len(p5)):
        if p5[k].logical_id == "api/public":
            assert_true(_has(p5[k].reason, "leftover"), p5[k].reason)
    var g6 = _graph(cloud, False)
    _ = _apply(g6, _cell(), lost)
    assert_equal(cloud[].count(String("delete")), deletes, "nothing deleted on one source")
    assert_true(cloud[].find(String("api/public")) >= 0)
    print("  test_the_closed_world_removes_a_turned_off_role: PASS")


# ---- 8. unmanaged ------------------------------------------------------------------------


def test_an_unmanaged_difference_is_planned_never_converged() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var store = InMemoryStateStore()
    var g = _graph(cloud)
    _ = _apply(g, _cell(), store)
    var i = cloud[].find(String("api/run"))
    cloud[].extras[i] = String("label team=payments (added in the console)")
    var before = cloud[].mutations()
    var gp = _graph(cloud)
    var plan = plan_graph_owned(gp, Creds.none(), _cell(), store)
    for k in range(len(plan)):
        if plan[k].logical_id == "api/run":
            assert_equal(plan[k].verb, VERB_NOOP)
            assert_true(_has(plan[k].unmanaged, "team=payments"), plan[k].unmanaged)
    var g2 = _graph(cloud)
    _ = _apply(g2, _cell(), store)
    assert_equal(cloud[].mutations(), before, "an unmodelled field is never touched")
    assert_equal(cloud[].extras[i], "label team=payments (added in the console)")
    print("  test_an_unmanaged_difference_is_planned_never_converged: PASS")


# ---- 9. crash after create -----------------------------------------------------------------


def test_a_crash_after_the_create_recovers_by_the_stamp() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var store = InMemoryStateStore()
    cloud[].crash_after_create = True
    var g = _graph(cloud)
    var raised = False
    try:
        _ = _apply(g, _cell(), store)
    except e:
        raised = True
    assert_true(raised, "the first create died after the cloud acted")
    var key = ResourceKey(String("shop"), String("blue"), String("db/run"))
    assert_equal(store.count_provisioning(key), 1, "the write-ahead intent survived")
    assert_equal(store.intent_stamp(key), "kci:v1 owner=shop/blue/db/run")

    cloud[].crash_after_create = False
    var g2 = _graph(cloud)
    var a = _apply(g2, _cell(), store)
    assert_equal(_verb_of(a, String("db/run")), VERB_NOOP, "found stamped as ours, adopted")
    assert_equal(cloud[].count(String("create_owned")), 3, "db/run was created once")
    assert_equal(store.total_intents(key), 1, "one intent, adopted")
    assert_equal(store.count_confirmed(key), 1)
    print("  test_a_crash_after_the_create_recovers_by_the_stamp: PASS")


# ---- 10. the digest rule --------------------------------------------------------------------


def test_modelled_digest_refuses_provenance() raises:
    var d = ModelledDigest(String("service"))
    d.field(String("port"), String("8080"))
    d.field(String("min"), String("0"))
    assert_equal(d.text(), "service|port=8080|min=0")
    var refused = False
    try:
        d.field(String("kci_provenance.run_id"), String("run-7"))
    except e:
        refused = _has(String(e), "provenance")
    assert_true(refused, "a provenance field is refused")
    assert_equal(d.fields(), 2)
    print("  test_modelled_digest_refuses_provenance: PASS")


def main() raises:
    print("test_ownership_and_cell_keys: the owned scope")
    test_erased_facade_forwards_the_ownership_verbs()
    test_the_store_is_keyed_by_machine_cell_and_resource()
    test_the_stamp_rides_the_create_call()
    test_a_foreign_object_refuses_the_run_before_any_change()
    test_a_conflict_refuses_apply_and_destroy()
    test_an_owned_cell_refuses_a_node_that_cannot_stamp()
    test_the_closed_world_removes_a_turned_off_role()
    test_an_unmanaged_difference_is_planned_never_converged()
    test_a_crash_after_the_create_recovers_by_the_stamp()
    test_modelled_digest_refuses_provenance()
    print("ALL OWNERSHIP TESTS PASSED")
