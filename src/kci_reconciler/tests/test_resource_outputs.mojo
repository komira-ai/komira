# =============================================================================
# test_resource_outputs.mojo — APPLY-TIME VALUE FLOW through the real engine.
# =============================================================================
#
# What is pinned, each a separate test:
#
#   1. THE ERASED FACADE FORWARDS ALL FOUR NEW VERBS. The graph holds only
#      `ErasedResource`, so a verb the facade does not forward is answered by the
#      trait DEFAULT for every node, silently. A probe overrides `input_refs`,
#      `bind_inputs`, `outputs` and `owner` and is driven only through the
#      erased facade; any entry left on the default fails here.
#   2. A REFERENCE IS AN EDGE: the producer is ordered first with no
#      `depends_on`; a reference to a missing producer and a cycle through
#      references are refused, naming the field.
#   3. THE DIGEST RULE, end to end over a fake cloud: a dry run before the
#      producer exists reports the consumer as "known after apply", never as a
#      no-op, and never reads it; apply binds the producer's real output before
#      the consumer is read; a re-apply is a no-op for both; a changed producer
#      output makes the consumer an UPDATE; outputs are persisted in state.
#   4. AN UNRESOLVED REFERENCE IS REFUSED, never hashed: a consumer read before
#      it is bound raises UNBOUND, and a producer that does not report the
#      output stops the apply before the consumer is created.
#   5. THE DESCRIPTOR LAYER: `DescribedResource` binds into its own spec before
#      the digest is taken, forwards `outputs` and stamps `owner`.
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
    InputRef,
    Outputs,
    ResolvedInputs,
    UNBOUND_TOKEN,
    unbound_error,
    topo_sort,
    plan_graph,
    apply_graph,
    RES_ABSENT,
    RETAIN_DELETE,
    VERB_CREATE,
    VERB_UPDATE,
    VERB_NOOP,
    VERB_KNOWN_AFTER_APPLY,
)
from kci_reconciler.described_resource import ResourceDescriptor, make_described_node


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# ---- 1. the erased probe -----------------------------------------------------


struct _ProbeLog(Movable):
    var bound: String
    var outputs_calls: Int

    def __init__(out self):
        self.bound = String("")
        self.outputs_calls = 0


struct _Probe(Resource, Movable, Deinitable):
    """Overrides the four value-flow verbs; every other verb is inert."""

    var _log: ArcPointer[_ProbeLog]

    def __init__(out self, log: ArcPointer[_ProbeLog]):
        self._log = log.copy()

    def logical_id(mut self) -> String:
        return String("probe")

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        return ResourceStatus.absent()

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return ChangeAction(String("probe"), VERB_NOOP, String(""), RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        return String("pid-probe")

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 0

    def input_refs(mut self) -> List[InputRef]:
        var out = List[InputRef]()
        out.append(InputRef(String("db"), String("ADDRESS"), String("env.DB")))
        return out^

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        self._log[].bound = resolved.value_at(0)

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        self._log[].outputs_calls += 1
        var o = Outputs()
        o.set(String("URL"), String("https://") + physical_id)
        return o^

    def owner(mut self) -> String:
        return String("author-api")


def test_erased_facade_forwards_all_four_value_flow_verbs() raises:
    var log = ArcPointer[_ProbeLog](_ProbeLog())
    var node = ErasedResource.erase(_Probe(log))

    var refs = node.input_refs()
    assert_equal(len(refs), 1, "input_refs reached the probe, not the default")
    assert_equal(refs[0].producer, "db")
    assert_equal(refs[0].output, "ADDRESS")
    assert_equal(refs[0].field, "env.DB")

    var resolved = ResolvedInputs()
    resolved.add(refs[0], String("10.0.0.7:5432"))
    node.bind_inputs(resolved)
    assert_equal(log[].bound, "10.0.0.7:5432", "bind_inputs reached the probe")

    var outs = node.outputs(String("api-1"), Creds.none())
    assert_equal(log[].outputs_calls, 1, "outputs reached the probe")
    assert_equal(outs.get(String("URL")).value(), "https://api-1")

    assert_equal(node.owner(), "author-api", "owner reached the probe")
    print("  test_erased_facade_forwards_all_four_value_flow_verbs: PASS")


# ---- a fake cloud and a node over it --------------------------------------------


struct _Cloud(Movable):
    """What exists: per logical id, its digest and the URL it serves."""

    var ids: List[String]
    var digests: List[String]
    var urls: List[String]
    var reads: List[String]

    def __init__(out self):
        self.ids = List[String]()
        self.digests = List[String]()
        self.urls = List[String]()
        self.reads = List[String]()

    def find(self, id: String) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def put(mut self, id: String, digest: String, url: String):
        var i = self.find(id)
        if i < 0:
            self.ids.append(id)
            self.digests.append(digest)
            self.urls.append(url)
        else:
            self.digests[i] = digest
            self.urls[i] = url

    def read_count(self, id: String) -> Int:
        var n = 0
        for i in range(len(self.reads)):
            if self.reads[i] == id:
                n += 1
        return n


struct _Node(Resource, Movable, Deinitable):
    """A node that serves `https://<id>/<version>` and may read one value
    from another node. Its desired digest covers its version AND the bound
    value, so a changed input is drift; with an unbound input it has no digest."""

    var _cloud: ArcPointer[_Cloud]
    var _id: String
    var _version: String
    var _refs: List[InputRef]
    var _bound: Optional[String]
    var _owner: String
    var _report_outputs: Bool

    def __init__(
        out self,
        cloud: ArcPointer[_Cloud],
        id: String,
        version: String,
        var refs: List[InputRef],
        owner: String = String(""),
        report_outputs: Bool = True,
    ):
        self._cloud = cloud.copy()
        self._id = id
        self._version = version
        self._refs = refs^
        self._bound = None
        self._owner = owner
        self._report_outputs = report_outputs

    def _desired_digest(self) raises -> String:
        if len(self._refs) > 0 and not self._bound:
            raise unbound_error(self._id, self._refs[0])
        var d = self._version.copy()
        if self._bound:
            d += String("|") + self._bound.value()
        return d^

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        self._cloud[].reads.append(self._id)
        var want = self._desired_digest()
        var i = self._cloud[].find(self._id)
        if i < 0:
            return ResourceStatus.absent()
        var pid = String("pid-") + self._id
        if self._cloud[].digests[i] == want:
            return ResourceStatus.matched(pid, want)
        return ResourceStatus.drifted(pid, self._cloud[].digests[i])

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var verb = VERB_UPDATE
        if live.phase == RES_ABSENT:
            verb = VERB_CREATE
        elif live.is_matched():
            verb = VERB_NOOP
        return ChangeAction(self._id.copy(), verb, String(""), RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        self._cloud[].put(self._id, self._desired_digest(), self._url())
        return String("pid-") + self._id

    def update(mut self, creds: Creds) raises:
        self._cloud[].put(self._id, self._desired_digest(), self._url())

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1  # CONVERGE_IN_PLACE

    def _url(self) -> String:
        return String("https://") + self._id + String("/") + self._version

    def input_refs(mut self) -> List[InputRef]:
        return self._refs.copy()

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        self._bound = resolved.value_of(
            self._id, self._refs[0].producer, self._refs[0].output
        )

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        var o = Outputs()
        if not self._report_outputs:
            return o^
        var i = self._cloud[].find(self._id)
        if i >= 0:
            o.set(String("URL"), self._cloud[].urls[i])
        return o^

    def owner(mut self) -> String:
        return self._owner.copy()


def _reads_a(field: String = String("env.A_URL")) -> List[InputRef]:
    var r = List[InputRef]()
    r.append(InputRef(String("a"), String("URL"), field))
    return r^


def _graph(cloud: ArcPointer[_Cloud], a_version: String) raises -> ResourceGraph:
    """b reads a's URL; b is added FIRST and names no depends_on."""
    var g = ResourceGraph()
    g.add(
        ErasedResource.erase(
            _Node(cloud, String("b"), String("b1"), _reads_a(), String("author-b"))
        )
    )
    g.add(
        ErasedResource.erase(
            _Node(cloud, String("a"), a_version, List[InputRef](), String("author-a"))
        )
    )
    return g^


def _verb_of(actions: List[ChangeAction], id: String) -> Int:
    for i in range(len(actions)):
        if actions[i].logical_id == id:
            return actions[i].verb
    return -1


def _reason_of(actions: List[ChangeAction], id: String) -> String:
    for i in range(len(actions)):
        if actions[i].logical_id == id:
            return actions[i].reason
    return String("")


# ---- 2. references are edges ------------------------------------------------------


def test_a_reference_orders_the_producer_first() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var g = _graph(cloud, String("v1"))
    var order = topo_sort(g)
    assert_equal(len(order), 2)
    assert_equal(g.node(order[0]).logical_id(), "a", "the producer runs first")
    assert_equal(g.node(order[1]).logical_id(), "b")
    print("  test_a_reference_orders_the_producer_first: PASS")


def test_a_reference_to_a_missing_producer_is_refused() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var g = ResourceGraph()
    g.add(
        ErasedResource.erase(
            _Node(cloud, String("b"), String("b1"), _reads_a(String("service.env.A_URL")))
        )
    )
    var raised = False
    try:
        _ = topo_sort(g)
    except e:
        raised = True
        var msg = String(e)
        assert_true(_has(msg, "ref to a missing resource"), msg)
        assert_true(_has(msg, "service.env.A_URL"), "names the field: " + msg)
        assert_true(_has(msg, "'a'"), "names the producer: " + msg)
    assert_true(raised, "a reference to a missing producer is refused")
    print("  test_a_reference_to_a_missing_producer_is_refused: PASS")


def test_a_cycle_through_references_is_refused() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var reads_b = List[InputRef]()
    reads_b.append(InputRef(String("b"), String("URL"), String("env.B_URL")))
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Node(cloud, String("a"), String("v1"), reads_b^)))
    g.add(ErasedResource.erase(_Node(cloud, String("b"), String("b1"), _reads_a())))
    var raised = False
    try:
        _ = topo_sort(g)
    except e:
        raised = True
        assert_true(_has(String(e), "CYCLE"), String(e))
    assert_true(raised, "a cycle through references is refused")
    print("  test_a_cycle_through_references_is_refused: PASS")


# ---- 3. the digest rule -----------------------------------------------------------


def test_the_digest_rule_end_to_end() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var creds = Creds.none()

    # (a) dry run, nothing exists: a creates, b is KNOWN AFTER APPLY and unread.
    var g0 = _graph(cloud, String("v1"))
    var p0 = plan_graph(g0, creds)
    assert_equal(_verb_of(p0, "a"), VERB_CREATE)
    assert_equal(
        _verb_of(p0, "b"),
        VERB_KNOWN_AFTER_APPLY,
        "a consumer of a producer that will be created is never a no-op",
    )
    var why = _reason_of(p0, "b")
    assert_true(_has(why, "known after apply"), why)
    assert_true(_has(why, "env.A_URL <- a.URL"), "names field and source: " + why)
    assert_equal(cloud[].read_count("b"), 0, "b is not read before it can be bound")
    for i in range(len(p0)):
        if p0[i].logical_id == "b":
            assert_equal(p0[i].owner, "author-b", "plan_graph stamps the owner")

    # (b) apply: a is created first, b is bound to a's REAL url, then created.
    var store = InMemoryStateStore()
    var g1 = _graph(cloud, String("v1"))
    var applied = apply_graph(g1, creds, store)
    assert_equal(len(applied), 2)
    assert_equal(applied[0].logical_id, "a")
    assert_equal(applied[0].verb, VERB_CREATE)
    assert_equal(applied[1].logical_id, "b")
    assert_equal(applied[1].verb, VERB_CREATE)
    var bi = cloud[].find(String("b"))
    assert_equal(
        cloud[].digests[bi], "b1|https://a/v1", "b was created over a's real URL"
    )
    assert_equal(
        store.outputs_for(String("a")).get(String("URL")).value(),
        "https://a/v1",
        "a's outputs are persisted beside its physical id",
    )

    # (c) re-apply, nothing changed: NOOP for both, in plan and in apply.
    var g2 = _graph(cloud, String("v1"))
    var p2 = plan_graph(g2, creds)
    assert_equal(_verb_of(p2, "a"), VERB_NOOP)
    assert_equal(_verb_of(p2, "b"), VERB_NOOP, "an unchanged producer: b is NOOP")
    var g3 = _graph(cloud, String("v1"))
    var again = apply_graph(g3, creds, store)
    assert_equal(again[0].verb, VERB_NOOP)
    assert_equal(again[1].verb, VERB_NOOP)

    # (d) the producer's output changes: plan says may-change, apply UPDATEs b.
    var g4 = _graph(cloud, String("v2"))
    var p4 = plan_graph(g4, creds)
    assert_equal(_verb_of(p4, "a"), VERB_UPDATE)
    assert_equal(_verb_of(p4, "b"), VERB_KNOWN_AFTER_APPLY)
    var g5 = _graph(cloud, String("v2"))
    var changed = apply_graph(g5, creds, store)
    assert_equal(changed[0].verb, VERB_UPDATE)
    assert_equal(changed[1].verb, VERB_UPDATE, "a changed output is drift for b")
    bi = cloud[].find(String("b"))
    assert_equal(cloud[].digests[bi], "b1|https://a/v2")
    assert_equal(
        store.outputs_for(String("a")).get(String("URL")).value(),
        "https://a/v2",
        "the persisted outputs follow the live value",
    )

    # (e) and settles.
    var g6 = _graph(cloud, String("v2"))
    var settled = apply_graph(g6, creds, store)
    assert_equal(settled[0].verb, VERB_NOOP)
    assert_equal(settled[1].verb, VERB_NOOP)
    print("  test_the_digest_rule_end_to_end: PASS")


# ---- 4. unresolved references -------------------------------------------------------


def test_an_unbound_consumer_has_no_digest() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var b = _Node(cloud, String("b"), String("b1"), _reads_a())
    var raised = False
    try:
        _ = b.read_status(Creds.none())
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.startswith(UNBOUND_TOKEN), msg)
        assert_true(_has(msg, "env.A_URL"), msg)
    assert_true(raised, "reading an unbound consumer raises UNBOUND")
    print("  test_an_unbound_consumer_has_no_digest: PASS")


def test_a_missing_output_stops_the_apply_before_the_consumer() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Node(cloud, String("b"), String("b1"), _reads_a())))
    g.add(
        ErasedResource.erase(
            _Node(
                cloud,
                String("a"),
                String("v1"),
                List[InputRef](),
                String(""),
                report_outputs=False,
            )
        )
    )
    var store = InMemoryStateStore()
    var raised = False
    try:
        _ = apply_graph(g, Creds.none(), store)
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.startswith(UNBOUND_TOKEN), msg)
        assert_true(_has(msg, "node 'b'"), msg)
        assert_true(_has(msg, "output 'URL' of 'a'"), msg)
    assert_true(raised, "a producer that reports no URL stops the apply")
    assert_true(cloud[].find(String("a")) >= 0, "a was applied")
    assert_equal(cloud[].find(String("b")), -1, "b was never created")
    assert_equal(cloud[].read_count("b"), 0, "b was never read")
    print("  test_a_missing_output_stops_the_apply_before_the_consumer: PASS")


# ---- 5. the descriptor layer ----------------------------------------------------------


struct _Spec(Copyable, Movable, Deinitable):
    var name: String
    var reads: Optional[InputRef]
    var bound: Optional[String]

    def __init__(out self, name: String, var reads: Optional[InputRef]):
        self.name = name
        self.reads = reads^
        self.bound = None

    def __init__(out self, *, copy: Self):
        self.name = copy.name.copy()
        self.reads = copy.reads.copy()
        self.bound = copy.bound.copy()


struct _View(Copyable, Movable, Deinitable):
    var found: Bool
    var digest: String
    var url: String

    def __init__(out self, found: Bool, digest: String, url: String):
        self.found = found
        self.digest = digest
        self.url = url

    def __init__(out self, *, copy: Self):
        self.found = copy.found
        self.digest = copy.digest.copy()
        self.url = copy.url.copy()


struct _Desc(ResourceDescriptor, Movable, Deinitable):
    comptime Spec = _Spec
    comptime View = _View

    var _cloud: ArcPointer[_Cloud]

    def __init__(out self, cloud: ArcPointer[_Cloud]):
        self._cloud = cloud.copy()

    def read(mut self, spec: _Spec, token: String) raises -> _View:
        var i = self._cloud[].find(spec.name)
        if i < 0:
            raise Error("NotFound: " + spec.name)
        return _View(True, self._cloud[].digests[i], self._cloud[].urls[i])

    def is_not_found(self, msg: String) -> Bool:
        return msg.startswith("NotFound")

    def exists(self, view: _View) -> Bool:
        return view.found

    def physical_id(self, view: _View) -> String:
        return view.url

    def desired_digest(self, spec: _Spec) raises -> String:
        if spec.reads and not spec.bound:
            raise unbound_error(spec.name, spec.reads.value())
        var d = spec.name.copy()
        if spec.bound:
            d += String("|") + spec.bound.value()
        return d^

    def live_digest(self, spec: _Spec, view: _View) raises -> String:
        return view.digest

    def retention(self, spec: _Spec) -> Int:
        return RETAIN_DELETE

    def reason(self, spec: _Spec, verb: Int, live: ResourceStatus) raises -> String:
        return String("")

    def create(mut self, spec: _Spec, token: String) raises -> String:
        var url = String("https://") + spec.name
        self._cloud[].put(spec.name, self.desired_digest(spec), url)
        return url

    def update(mut self, spec: _Spec, token: String) raises:
        self._cloud[].put(
            spec.name, self.desired_digest(spec), String("https://") + spec.name
        )

    def delete(mut self, spec: _Spec, physical_id: String, token: String) raises:
        pass

    def input_refs(self, spec: _Spec) -> List[InputRef]:
        var out = List[InputRef]()
        if spec.reads:
            out.append(spec.reads.value().copy())
        return out^

    def bind_inputs(self, mut spec: _Spec, resolved: ResolvedInputs) raises:
        var r = spec.reads.value().copy()
        spec.bound = resolved.value_of(spec.name, r.producer, r.output)

    def outputs(self, spec: _Spec, view: _View) -> Outputs:
        var o = Outputs()
        o.set(String("URL"), view.url)
        return o^


def _described_graph(cloud: ArcPointer[_Cloud]) raises -> ResourceGraph:
    var g = ResourceGraph()
    g.add(
        make_described_node(
            _Desc(cloud),
            _Spec(
                String("web"),
                InputRef(String("api"), String("URL"), String("site.routes.api")),
            ),
            String("web"),
            List[String](),
            String("author-web"),
        )
    )
    g.add(
        make_described_node(
            _Desc(cloud),
            _Spec(String("api"), None),
            String("api"),
            List[String](),
            String("author-api"),
        )
    )
    return g^


def test_the_descriptor_layer_binds_before_the_digest() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var store = InMemoryStateStore()
    var g = _described_graph(cloud)
    var applied = apply_graph(g, Creds.none(), store)
    assert_equal(applied[0].logical_id, "api", "the producer is applied first")
    assert_equal(applied[1].logical_id, "web")
    var wi = cloud[].find(String("web"))
    assert_equal(
        cloud[].digests[wi],
        "web|https://api",
        "the descriptor's spec was bound before its digest was taken",
    )
    assert_equal(
        store.outputs_for(String("api")).get(String("URL")).value(),
        "https://api",
        "outputs are forwarded through DescribedResource",
    )
    var g2 = _described_graph(cloud)
    var plan = plan_graph(g2, Creds.none())
    assert_equal(_verb_of(plan, "api"), VERB_NOOP)
    assert_equal(_verb_of(plan, "web"), VERB_NOOP, "a re-plan over bound values")
    for i in range(len(plan)):
        if plan[i].logical_id == "web":
            assert_equal(plan[i].owner, "author-web", "owner forwarded and stamped")
    print("  test_the_descriptor_layer_binds_before_the_digest: PASS")


def main() raises:
    print("test_resource_outputs: apply-time value flow")
    test_erased_facade_forwards_all_four_value_flow_verbs()
    test_a_reference_orders_the_producer_first()
    test_a_reference_to_a_missing_producer_is_refused()
    test_a_cycle_through_references_is_refused()
    test_the_digest_rule_end_to_end()
    test_an_unbound_consumer_has_no_digest()
    test_a_missing_output_stops_the_apply_before_the_consumer()
    test_the_descriptor_layer_binds_before_the_digest()
    print("ALL VALUE-FLOW TESTS PASSED")
