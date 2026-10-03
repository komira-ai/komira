# =============================================================================
# test_resource_outputs_after_mutation.mojo — the value flow AROUND a mutation:
#   what is recorded after an update, what is reported when the outputs read
#   fails, and what teardown needs.
# =============================================================================
#
# What is pinned, each a separate test:
#
#   1. AN UPDATE PUBLISHES THE NEW VALUE (descriptor layer). After an UPDATE of
#      a producer built on `DescribedResource`, the recorded output and the
#      value bound into its consumer are the POST-update ones, in ONE apply. The
#      pre-update read is the old resource and must not answer `outputs`.
#   2. A FAILED OUTPUTS READ AFTER A CREATE STILL REPORTS THE CREATE. The
#      resource is live and confirmed, so it is in `landed` (and the error names
#      the node and the `outputs` verb); otherwise nothing would tell a teardown
#      it exists.
#   3. TEARDOWN NEEDS NO BOUND INPUTS. A descriptor consumer whose producer
#      outputs were never persisted (a fresh store) is torn down without
#      `UNBOUND`, dependent first.
#   4. A HAND-WRITTEN consumer that keeps the default `read_presence` (which is
#      `read_status`, and raises UNBOUND unbound) is bound from the producers'
#      persisted outputs at teardown, and torn down.
#   5. THE ERASED FACADE FORWARDS `read_presence` (the graph only holds erased
#      nodes; a facade answering the trait default would read through the
#      digest).
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
    AppliedNode,
    unbound_error,
    apply_graph,
    apply_graph_tracked,
    destroy_graph,
    RES_ABSENT,
    RETAIN_DELETE,
    VERB_CREATE,
    VERB_UPDATE,
    VERB_NOOP,
)
from kci_reconciler.described_resource import ResourceDescriptor, make_described_node


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# ---- a fake cloud --------------------------------------------------------------


struct _Cloud(Movable):
    var ids: List[String]
    var digests: List[String]
    var urls: List[String]
    var events: List[String]

    def __init__(out self):
        self.ids = List[String]()
        self.digests = List[String]()
        self.urls = List[String]()
        self.events = List[String]()

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

    def remove(mut self, id: String):
        var i = self.find(id)
        if i >= 0:
            _ = self.ids.pop(i)
            _ = self.digests.pop(i)
            _ = self.urls.pop(i)

    def deletes(self) -> List[String]:
        var out = List[String]()
        for i in range(len(self.events)):
            if self.events[i].startswith("delete "):
                out.append(self.events[i])
        return out^


# ---- a descriptor over it: the URL carries the VERSION, so an update changes it --


struct _Spec(Copyable, Movable, Deinitable):
    var name: String
    var version: String
    var reads: Optional[InputRef]
    var bound: Optional[String]

    def __init__(
        out self, name: String, version: String, var reads: Optional[InputRef]
    ):
        self.name = name
        self.version = version
        self.reads = reads^
        self.bound = None

    def __init__(out self, *, copy: Self):
        self.name = copy.name.copy()
        self.version = copy.version.copy()
        self.reads = copy.reads.copy()
        self.bound = copy.bound.copy()


struct _View(Copyable, Movable, Deinitable):
    var digest: String
    var url: String

    def __init__(out self, digest: String, url: String):
        self.digest = digest
        self.url = url

    def __init__(out self, *, copy: Self):
        self.digest = copy.digest.copy()
        self.url = copy.url.copy()


struct _Desc(ResourceDescriptor, Movable, Deinitable):
    comptime Spec = _Spec
    comptime View = _View
    var _cloud: ArcPointer[_Cloud]

    def __init__(out self, cloud: ArcPointer[_Cloud]):
        self._cloud = cloud.copy()

    def _url(self, spec: _Spec) -> String:
        return String("https://") + spec.name + String("/") + spec.version

    def read(mut self, spec: _Spec, token: String) raises -> _View:
        var i = self._cloud[].find(spec.name)
        if i < 0:
            raise Error("NotFound: " + spec.name)
        return _View(self._cloud[].digests[i], self._cloud[].urls[i])

    def is_not_found(self, msg: String) -> Bool:
        return msg.startswith("NotFound")

    def exists(self, view: _View) -> Bool:
        return True

    def physical_id(self, view: _View) -> String:
        return view.url

    def desired_digest(self, spec: _Spec) raises -> String:
        # The digest rule: an unresolved reference has no digest.
        if spec.reads and not spec.bound:
            raise unbound_error(spec.name, spec.reads.value())
        var d = spec.name + String("@") + spec.version
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
        var url = self._url(spec)
        self._cloud[].put(spec.name, self.desired_digest(spec), url)
        self._cloud[].events.append(String("create ") + spec.name)
        return url

    def update(mut self, spec: _Spec, token: String) raises:
        self._cloud[].put(spec.name, self.desired_digest(spec), self._url(spec))
        self._cloud[].events.append(String("update ") + spec.name)

    def delete(mut self, spec: _Spec, physical_id: String, token: String) raises:
        self._cloud[].remove(spec.name)
        self._cloud[].events.append(String("delete ") + spec.name)

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


def _described(cloud: ArcPointer[_Cloud], api_version: String) raises -> ResourceGraph:
    """`web` reads `api`'s URL; listed consumer-first so only the reference
    orders them."""
    var g = ResourceGraph()
    g.add(
        make_described_node(
            _Desc(cloud),
            _Spec(
                String("web"),
                String("w1"),
                InputRef(String("api"), String("URL"), String("env.API_URL")),
            ),
            String("web"),
            List[String](),
        )
    )
    g.add(
        make_described_node(
            _Desc(cloud),
            _Spec(String("api"), api_version, None),
            String("api"),
            List[String](),
        )
    )
    return g^


def test_an_update_publishes_the_post_update_output() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var store = InMemoryStateStore()
    var g1 = _described(cloud, String("v1"))
    _ = apply_graph(g1, Creds.none(), store)
    assert_equal(
        store.outputs_for(String("api")).get(String("URL")).value(),
        "https://api/v1",
    )

    # The producer's version changes, so its UPDATE changes its URL.
    var g2 = _described(cloud, String("v2"))
    var applied = apply_graph(g2, Creds.none(), store)
    assert_equal(applied[0].logical_id, "api")
    assert_equal(applied[0].verb, VERB_UPDATE, "the producer was updated")
    assert_equal(
        store.outputs_for(String("api")).get(String("URL")).value(),
        "https://api/v2",
        "the output recorded after an UPDATE is the post-update value",
    )
    assert_equal(applied[1].logical_id, "web")
    assert_equal(
        applied[1].verb,
        VERB_UPDATE,
        "the consumer converges onto the new value in the SAME apply",
    )
    var wi = cloud[].find(String("web"))
    assert_equal(
        cloud[].digests[wi],
        "web@w1|https://api/v2",
        "the consumer was bound to the post-update value",
    )

    # One pass converged: a re-apply changes nothing.
    var g3 = _described(cloud, String("v2"))
    var again = apply_graph(g3, Creds.none(), store)
    assert_equal(again[0].verb, VERB_NOOP)
    assert_equal(again[1].verb, VERB_NOOP, "no second pass is needed")
    print("  test_an_update_publishes_the_post_update_output: PASS")


# ---- a hand-written node (default `read_presence`) -----------------------------


struct _Node(Resource, Movable, Deinitable):
    var _cloud: ArcPointer[_Cloud]
    var _id: String
    var _refs: List[InputRef]
    var _bound: List[String]
    var _outputs_raise: Bool

    def __init__(
        out self,
        cloud: ArcPointer[_Cloud],
        id: String,
        var refs: List[InputRef],
        outputs_raise: Bool = False,
    ):
        self._cloud = cloud.copy()
        self._id = id
        self._refs = refs^
        self._bound = List[String]()
        self._outputs_raise = outputs_raise

    def _want(self) raises -> String:
        if len(self._refs) > 0 and len(self._bound) != len(self._refs):
            raise unbound_error(self._id, self._refs[0])
        var d = self._id.copy()
        for i in range(len(self._bound)):
            d += String("|") + self._bound[i]
        return d^

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        var want = self._want()
        var i = self._cloud[].find(self._id)
        if i < 0:
            return ResourceStatus.absent()
        if self._cloud[].digests[i] == want:
            return ResourceStatus.matched(String("pid-") + self._id, want)
        return ResourceStatus.drifted(
            String("pid-") + self._id, self._cloud[].digests[i]
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var v = VERB_UPDATE
        if live.phase == RES_ABSENT:
            v = VERB_CREATE
        elif live.is_matched():
            v = VERB_NOOP
        return ChangeAction(self._id.copy(), v, String(""), RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        self._cloud[].put(
            self._id, self._want(), String("https://") + self._id
        )
        self._cloud[].events.append(String("create ") + self._id)
        return String("pid-") + self._id

    def update(mut self, creds: Creds) raises:
        self._cloud[].put(
            self._id, self._want(), String("https://") + self._id
        )
        self._cloud[].events.append(String("update ") + self._id)

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._cloud[].remove(self._id)
        self._cloud[].events.append(String("delete ") + self._id)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1

    def input_refs(mut self) -> List[InputRef]:
        return self._refs.copy()

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        self._bound = List[String]()
        for i in range(resolved.count()):
            self._bound.append(resolved.value_at(i))

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        if self._outputs_raise:
            raise Error("read after create failed: transient")
        var o = Outputs()
        var i = self._cloud[].find(self._id)
        if i >= 0:
            o.set(String("URL"), self._cloud[].urls[i])
        return o^


def _reads_a() -> List[InputRef]:
    var out = List[InputRef]()
    out.append(InputRef(String("a"), String("URL"), String("env.A_URL")))
    return out^


def test_a_failed_outputs_read_after_create_still_reports_the_create() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Node(cloud, String("a"), List[InputRef](), True)))
    var store = InMemoryStateStore()
    var landed = List[AppliedNode]()
    var pending = List[String]()
    var msg = String("")
    try:
        _ = apply_graph_tracked(g, Creds.none(), store, landed, pending)
    except e:
        msg = String(e)
    assert_true(msg.byte_length() > 0, "the outputs failure still surfaces")
    assert_true(_has(msg, "'a'"), "the error names the node: " + msg)
    assert_true(_has(msg, "verb=outputs"), "the error names the verb: " + msg)
    assert_true(_has(msg, "transient"), "the inner error is kept: " + msg)
    assert_true(cloud[].find(String("a")) >= 0, "the resource is live")
    assert_equal(len(landed), 1, "a created-and-confirmed node is in landed")
    assert_equal(landed[0].logical_id, "a")
    assert_equal(landed[0].verb, VERB_CREATE)
    assert_equal(landed[0].physical_id, "pid-a")
    assert_equal(len(pending), 0, "landed + pending is the whole graph")
    assert_equal(
        store.physical_id_for(String("a")),
        "pid-a",
        "the create is recorded, so a teardown can find it",
    )
    print("  test_a_failed_outputs_read_after_create_still_reports_the_create: PASS")


def test_teardown_of_an_unbound_descriptor_consumer() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var store = InMemoryStateStore()
    var g1 = _described(cloud, String("v1"))
    _ = apply_graph(g1, Creds.none(), store)
    assert_equal(len(cloud[].ids), 2)

    # A freshly loaded graph and a store that holds NO outputs: nothing can
    # bind `web`, and teardown must not need it to.
    var g2 = _described(cloud, String("v1"))
    var fresh = InMemoryStateStore()
    var skipped = destroy_graph(g2, Creds.none(), fresh)
    assert_equal(len(skipped), 0)
    var dels = cloud[].deletes()
    assert_equal(len(dels), 2, "both nodes were deleted")
    assert_equal(dels[0], "delete web", "the consumer first")
    assert_equal(dels[1], "delete api")
    assert_equal(len(cloud[].ids), 0, "nothing is left live")
    print("  test_teardown_of_an_unbound_descriptor_consumer: PASS")


def _hand_graph(cloud: ArcPointer[_Cloud]) raises -> ResourceGraph:
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Node(cloud, String("b"), _reads_a())))
    g.add(ErasedResource.erase(_Node(cloud, String("a"), List[InputRef]())))
    return g^


def test_teardown_binds_a_hand_written_consumer_from_recorded_outputs() raises:
    var cloud = ArcPointer[_Cloud](_Cloud())
    var store = InMemoryStateStore()
    var g1 = _hand_graph(cloud)
    _ = apply_graph(g1, Creds.none(), store)
    var g2 = _hand_graph(cloud)
    _ = destroy_graph(g2, Creds.none(), store)
    var dels = cloud[].deletes()
    assert_equal(len(dels), 2)
    assert_equal(dels[0], "delete b", "the consumer first")
    assert_equal(dels[1], "delete a")
    print("  test_teardown_binds_a_hand_written_consumer_from_recorded_outputs: PASS")


# ---- the erased facade forwards `read_presence` ----------------------------------


struct _PresenceProbe(Resource, Movable, Deinitable):
    """`read_status` raises; `read_presence` answers. Reached only through the
    erased facade."""

    def __init__(out self):
        pass

    def logical_id(mut self) -> String:
        return String("probe")

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        raise Error("read_status must not be used for teardown")

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

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        return ResourceStatus.drifted(String("pid-probe"), String(""))


def test_the_erased_facade_forwards_read_presence() raises:
    var node = ErasedResource.erase(_PresenceProbe())
    var live = node.read_presence(Creds.none())
    assert_true(live.is_present(), "read_presence reached the probe")
    assert_equal(live.physical_id, "pid-probe")
    print("  test_the_erased_facade_forwards_read_presence: PASS")


def _run(
    name: String, mut fails: List[String], f: def () raises thin -> None
):
    try:
        f()
    except e:
        fails.append(name + String(": ") + String(e))


def main() raises:
    print("test_resource_outputs_after_mutation")
    var fails = List[String]()
    _run(
        "update_publishes_post_update_output",
        fails,
        test_an_update_publishes_the_post_update_output,
    )
    _run(
        "failed_outputs_read_still_reports_the_create",
        fails,
        test_a_failed_outputs_read_after_create_still_reports_the_create,
    )
    _run(
        "teardown_of_an_unbound_descriptor_consumer",
        fails,
        test_teardown_of_an_unbound_descriptor_consumer,
    )
    _run(
        "teardown_binds_hand_written_consumer",
        fails,
        test_teardown_binds_a_hand_written_consumer_from_recorded_outputs,
    )
    _run(
        "erased_facade_forwards_read_presence",
        fails,
        test_the_erased_facade_forwards_read_presence,
    )
    for i in range(len(fails)):
        print("FAILED " + fails[i])
    if len(fails) > 0:
        raise Error(String(len(fails)) + String(" test(s) failed"))
    print("ALL OUTPUTS-AFTER-MUTATION TESTS PASSED")
