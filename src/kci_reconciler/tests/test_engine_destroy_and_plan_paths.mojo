# =============================================================================
# test_engine_destroy_and_plan_paths.mojo — teardown and dry-run arms.
# =============================================================================
#
# What is pinned, each a separate test, over scripted nodes whose reads are a
# queue (the owned pre-flight read and the per-node read can disagree):
#
#   1. THE OWNED PLAN AND DESTROY REFUSE THE UNOWNED SCOPE before any read.
#   2. THE OWNED DESTROY'S PRE-FLIGHT CHECKS ONLY WHAT IT MAY DELETE: a node
#      outside the scope, an undeletable node and a kept node (without
#      `force_delete_data`) are not read, so their foreign stamps refuse
#      nothing; with `force_delete_data` the kept node is a target and its
#      foreign stamp refuses the whole teardown.
#   3. A NODE ALREADY GONE AT DESTROY is retired with no delete.
#   4. A PRESENT NODE THAT REPORTS NO PHYSICAL ID is deleted by the id the
#      store confirmed.
#   5. A STAMP THAT CHANGES BETWEEN THE PRE-FLIGHT AND THE NODE'S OWN READ
#      stops the teardown before the delete.
#   6. A CONSUMER WAITING ON TWO PRODUCERS names both in its "known after
#      apply" reason, in reference order, and is not read.
#   7. "KNOWN AFTER APPLY" IS TRANSITIVE: in a chain a(create) -> b -> c, b
#      waits on a, and c waits on b because b is itself waiting; neither is
#      read, and c is not refused as unbound.
#   8. A TURNED-OFF PRODUCER PRODUCES NOTHING: its consumer is refused as
#      UNBOUND by the dry run, never reported as "known after apply". That
#      holds for a producer that is absent and for one that is present and
#      would report outputs: the consumer is never bound to the outputs of an
#      object the file turned off.
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
    CellScope,
    OwnerStamp,
    Provenance,
    InputRef,
    ResolvedInputs,
    Outputs,
    REFUSED_TOKEN,
    UNBOUND_TOKEN,
    RETAIN_DELETE,
    RETAIN_KEEP,
    RETAIN_UNDELETABLE,
    CONVERGE_IN_PLACE,
    VERB_CREATE,
    VERB_NOOP,
    VERB_UPDATE,
    VERB_KNOWN_AFTER_APPLY,
    FAULT_UNSET,
    apply_graph,
    plan_graph,
    plan_graph_owned,
    destroy_graph,
    destroy_graph_owned,
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
    var out_url: String

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
        self.out_url = String("")

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

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        # Empty unless the test gives this node a URL to report.
        var o = Outputs()
        if self._w[].out_url.byte_length() > 0:
            o.set(String("URL"), self._w[].out_url)
        return o^


def _graph1(w: ArcPointer[_World], id: String, owner: String = String("")) raises -> ResourceGraph:
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Scripted(w, id, owner)))
    return g^



def _cell() -> CellScope:
    return CellScope(String("shop"), String("blue"), Provenance(String("r1"), String("v1")))


def _ours(id: String, owner: String) -> String:
    return _cell().stamp(owner, id).identity()


def _stamped(pid: String, stamp: String) -> ResourceStatus:
    return ResourceStatus.matched(pid, String("d"), String(""), String(""), stamp)


comptime _FOREIGN = "kci:v1 owner=shop/green/x/run"


# ---- 1. the owned forms refuse the unowned scope --------------------------------


def test_owned_plan_and_destroy_refuse_the_unowned_scope() raises:
    var w = _world(ResourceStatus.absent())
    var store = InMemoryStateStore()
    var g = _graph1(w, String("n"))
    var plan_msg = String("")
    try:
        _ = plan_graph_owned(g, Creds.none(), CellScope.unowned(), store)
    except e:
        plan_msg = String(e)
    assert_equal(
        plan_msg,
        "plan_graph_owned: the scope names no machine and cell;"
        " use plan_graph for the unowned scope",
    )
    var destroy_msg = String("")
    try:
        _ = destroy_graph_owned(g, Creds.none(), CellScope.unowned(), store)
    except e:
        destroy_msg = String(e)
    assert_equal(
        destroy_msg,
        "destroy_graph_owned: the scope names no machine and cell;"
        " use destroy_graph for the unowned scope",
    )
    assert_equal(len(w[].calls), 0, "nothing was read")
    print("  test_owned_plan_and_destroy_refuse_the_unowned_scope: PASS")


# ---- 2. the owned destroy's pre-flight targets -----------------------------------


def _filter_graph(
    w_in: ArcPointer[_World],
    w_out: ArcPointer[_World],
    w_undel: ArcPointer[_World],
    w_keep: ArcPointer[_World],
) raises -> ResourceGraph:
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Scripted(w_in, String("in/run"), String("in"))))
    g.add(ErasedResource.erase(_Scripted(w_out, String("out/run"), String("out"))))
    g.add(ErasedResource.erase(_Scripted(w_undel, String("undel/run"), String("undel"))))
    g.add(ErasedResource.erase(_Scripted(w_keep, String("keep/run"), String("keep"))))
    return g^


def test_owned_destroy_preflight_reads_only_its_targets() raises:
    var w_in = _world(_stamped(String("pid-in"), _ours(String("in/run"), String("in"))))
    var w_out = _world(_stamped(String("pid-out"), String(_FOREIGN)))
    var w_undel = _world(_stamped(String("pid-undel"), String(_FOREIGN)))
    w_undel[].retention = RETAIN_UNDELETABLE
    var w_keep = _world(_stamped(String("pid-keep"), String(_FOREIGN)))
    w_keep[].retention = RETAIN_KEEP
    var scope = List[String]()
    scope.append(String("in/run"))
    scope.append(String("undel/run"))
    scope.append(String("keep/run"))

    var store = InMemoryStateStore()
    var g = _filter_graph(w_in, w_out, w_undel, w_keep)
    var skipped = destroy_graph_owned(
        g, Creds.none(), _cell(), store, False, scope.copy()
    )
    assert_equal(w_in[].count(String("delete pid-in")), 1, "the target was deleted")
    assert_equal(len(w_out[].calls), 0, "out of scope: not read")
    assert_equal(len(w_undel[].calls), 0, "undeletable: not read")
    assert_equal(len(w_keep[].calls), 0, "kept: not read")
    assert_equal(len(skipped), 1)
    assert_equal(skipped[0].logical_id, "undel/run")

    # With force_delete_data the kept node is a target: its foreign stamp
    # refuses the whole teardown before any delete.
    var w_in2 = _world(_stamped(String("pid-in"), _ours(String("in/run"), String("in"))))
    var g2 = _filter_graph(w_in2, w_out, w_undel, w_keep)
    var msg = String("")
    try:
        _ = destroy_graph_owned(g2, Creds.none(), _cell(), store, True, scope.copy())
    except e:
        msg = String(e)
    assert_true(msg.startswith(String(REFUSED_TOKEN) + " destroy"), msg)
    assert_true(_has(msg, "keep/run: conflict"), msg)
    assert_false(_has(msg, "out/run"), msg)
    assert_false(_has(msg, "undel/run"), msg)
    assert_equal(w_in2[].count(String("delete")), 0, "refused before any delete")
    print("  test_owned_destroy_preflight_reads_only_its_targets: PASS")


# ---- 3. a node already gone at destroy ------------------------------------------


def test_a_node_gone_before_destroy_is_retired_without_a_delete() raises:
    var w = _world(ResourceStatus.absent())
    var store = InMemoryStateStore()
    var g = _graph1(w, String("n"))
    _ = apply_graph(g, Creds.none(), store)
    assert_equal(store.count_confirmed(String("n")), 1)

    w[].now(ResourceStatus.absent())
    var g2 = _graph1(w, String("n"))
    _ = destroy_graph(g2, Creds.none(), store)
    assert_equal(w[].count(String("delete")), 0, "nothing to delete")
    assert_equal(store.count_reaped(String("n")), 1, "the record is retired")
    assert_equal(store.physical_id_for(String("n")), "")
    print("  test_a_node_gone_before_destroy_is_retired_without_a_delete: PASS")


# ---- 4. a present node with no physical id --------------------------------------


def test_destroy_deletes_by_the_confirmed_id_when_the_read_has_none() raises:
    var w = _world(ResourceStatus.absent())
    w[].report_pid = False
    var store = InMemoryStateStore()
    var g = _graph1(w, String("n"))
    _ = apply_graph(g, Creds.none(), store)

    var g2 = _graph1(w, String("n"))
    _ = destroy_graph(g2, Creds.none(), store)
    assert_equal(w[].count(String("delete pid-n")), 1, "deleted by the stored id")
    assert_equal(w[].count(String("delete")), 1)
    assert_equal(store.count_reaped(String("n")), 1)
    print("  test_destroy_deletes_by_the_confirmed_id_when_the_read_has_none: PASS")


# ---- 5. a stamp that changes during the teardown ------------------------------


def test_a_stamp_changed_during_destroy_stops_before_the_delete() raises:
    var w = _world(_stamped(String("pid-n"), _ours(String("api/run"), String("api"))))
    w[].next_read(_stamped(String("pid-n"), String(_FOREIGN)))
    var store = InMemoryStateStore()
    var g = _graph1(w, String("api/run"), String("api"))
    var msg = String("")
    try:
        _ = destroy_graph_owned(g, Creds.none(), _cell(), store)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "destroy_graph: node 'api/run': ownership changed during the run; the"
        " live object no longer carries this node's stamp, so it is not deleted",
    )
    assert_equal(w[].count(String("read")), 2, "the pre-flight read and the node's")
    assert_equal(w[].count(String("delete")), 0)
    print("  test_a_stamp_changed_during_destroy_stops_before_the_delete: PASS")


# ---- 6. a consumer waiting on two producers --------------------------------------


def test_known_after_apply_names_every_pending_producer() raises:
    var w1 = _world(ResourceStatus.absent())
    var w2 = _world(ResourceStatus.drifted(String("pid-p2"), String("old")))
    var wc = _world(ResourceStatus.absent())
    var refs = List[InputRef]()
    refs.append(InputRef(String("p1"), String("URL"), String("env.A")))
    refs.append(InputRef(String("p2"), String("ADDR"), String("env.B")))
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Scripted(wc, String("c"), String("app"), refs^)))
    g.add(ErasedResource.erase(_Scripted(w1, String("p1"))))
    g.add(ErasedResource.erase(_Scripted(w2, String("p2"))))
    var plan = plan_graph(g, Creds.none())
    assert_equal(len(plan), 3)
    assert_equal(plan[2].logical_id, "c", "the consumer is planned last")
    assert_equal(plan[2].verb, VERB_KNOWN_AFTER_APPLY)
    assert_equal(
        plan[2].reason,
        "(known after apply): env.A <- p1.URL (create), env.B <- p2.ADDR (update)",
    )
    assert_equal(plan[2].owner, "app")
    assert_equal(len(wc[].calls), 0, "the consumer is not read")
    print("  test_known_after_apply_names_every_pending_producer: PASS")


# ---- 7. a consumer waiting on a producer that is itself waiting ----------------


def test_known_after_apply_flows_down_a_chain() raises:
    var wa = _world(ResourceStatus.absent())
    var wb = _world(ResourceStatus.absent())
    var wc = _world(ResourceStatus.absent())
    var b_refs = List[InputRef]()
    b_refs.append(InputRef(String("a"), String("URL"), String("env.A")))
    var c_refs = List[InputRef]()
    c_refs.append(InputRef(String("b"), String("ADDR"), String("env.B")))
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Scripted(wc, String("c"), String(""), c_refs^)))
    g.add(ErasedResource.erase(_Scripted(wb, String("b"), String(""), b_refs^)))
    g.add(ErasedResource.erase(_Scripted(wa, String("a"))))
    var plan = plan_graph(g, Creds.none())
    assert_equal(len(plan), 3)
    assert_equal(plan[0].logical_id, "a")
    assert_equal(plan[0].verb, VERB_CREATE)
    assert_equal(plan[1].logical_id, "b")
    assert_equal(plan[1].verb, VERB_KNOWN_AFTER_APPLY)
    assert_equal(plan[1].reason, "(known after apply): env.A <- a.URL (create)")
    assert_equal(plan[2].logical_id, "c")
    assert_equal(plan[2].verb, VERB_KNOWN_AFTER_APPLY)
    assert_equal(
        plan[2].reason,
        "(known after apply): env.B <- b.ADDR (known after apply)",
    )
    assert_equal(len(wb[].calls), 0, "b is not read")
    assert_equal(len(wc[].calls), 0, "c is not read")
    print("  test_known_after_apply_flows_down_a_chain: PASS")


# ---- 8. a consumer of a turned-off producer --------------------------------------


def test_a_consumer_of_a_turned_off_producer_is_refused_as_unbound() raises:
    var wp = _world(ResourceStatus.absent())
    wp[].wanted = False
    var wc = _world(ResourceStatus.absent())
    var refs = List[InputRef]()
    refs.append(InputRef(String("p"), String("URL"), String("env.A")))
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Scripted(wc, String("c"), String(""), refs^)))
    g.add(ErasedResource.erase(_Scripted(wp, String("p"))))
    var msg = String("")
    try:
        _ = plan_graph(g, Creds.none())
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            String(UNBOUND_TOKEN)
            + ": node 'c' (field env.A) reads output 'URL' of 'p'"
        ),
        msg,
    )
    assert_equal(len(wc[].calls), 0, "the consumer is not read")
    print("  test_a_consumer_of_a_turned_off_producer_is_refused_as_unbound: PASS")


def test_a_present_turned_off_producer_with_outputs_binds_nothing() raises:
    # The producer is live and its conformer would report a URL; the file has
    # turned it off, so the dry run must not hand that URL to the consumer.
    var wp = _world(ResourceStatus.matched(String("pid-pp"), String("d")))
    wp[].wanted = False
    wp[].out_url = String("https://pp.example.com")
    var wc = _world(ResourceStatus.absent())
    var refs = List[InputRef]()
    refs.append(InputRef(String("pp"), String("URL"), String("env.A")))
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Scripted(wc, String("c"), String(""), refs^)))
    g.add(ErasedResource.erase(_Scripted(wp, String("pp"))))
    var msg = String("")
    try:
        _ = plan_graph(g, Creds.none())
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            String(UNBOUND_TOKEN)
            + ": node 'c' (field env.A) reads output 'URL' of 'pp'"
        ),
        msg,
    )
    assert_equal(len(wc[].calls), 0, "the consumer is not read")
    print("  test_a_present_turned_off_producer_with_outputs_binds_nothing: PASS")


def main() raises:
    print("test_engine_destroy_and_plan_paths:")
    test_owned_plan_and_destroy_refuse_the_unowned_scope()
    test_owned_destroy_preflight_reads_only_its_targets()
    test_a_node_gone_before_destroy_is_retired_without_a_delete()
    test_destroy_deletes_by_the_confirmed_id_when_the_read_has_none()
    test_a_stamp_changed_during_destroy_stops_before_the_delete()
    test_known_after_apply_names_every_pending_producer()
    test_known_after_apply_flows_down_a_chain()
    test_a_consumer_of_a_turned_off_producer_is_refused_as_unbound()
    test_a_present_turned_off_producer_with_outputs_binds_nothing()
    print("ALL DESTROY AND PLAN PATH TESTS PASSED")
