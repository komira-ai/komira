# =============================================================================
# test_graph_and_value_types.mojo — the graph's refusals, the Kahn primitive,
# and the value types the engine passes around.
# =============================================================================
#
# What is pinned, each a separate test:
#
#   1. THE GRAPH REFUSES A DUPLICATE KEY, including a second node keyed like
#      the FIRST one (index 0), and keeps the first.
#   2. `topo_sort` OF AN EMPTY GRAPH IS EMPTY; a node that depends on itself,
#      or reads its own output, is refused as a self-cycle naming it; a
#      reference to a producer already named in `depends_on` (or read twice)
#      is one edge, not a cycle; a producer with another dependent still
#      orders this consumer after it.
#   3. `dag_topo_order` orders lowest index first among the ready nodes,
#      refuses a cycle naming exactly the nodes left, and a self-dependency.
#   4. `Outputs.set` replaces a name's value in place; `ResolvedInputs`
#      answers by producer AND output, refuses an unresolved one as UNBOUND
#      without a field, and copies whole; `unbound_error` names the field only
#      when it has one.
#   5. `ResourceKey.text`, the six identity labels and their decoding (any
#      order; a missing label or a foreign manager decodes to no identity),
#      the stamp and scope copies, and `ownership_problem` for an absent
#      object and a recorded id that differs from the stamped object's.
#   6. `removal_is_ours` refuses an object whose live id is not the recorded
#      one.
#   7. `ChangeAction` verb names and predicates, and `ResourceStatus.is_drifted`.
#   8. THE `Resource` TRAIT DEFAULTS a minimal conformer gets, directly and
#      through the erased facade, and the `StateStore` defaults (outputs not
#      persisted).
#   9. `InMemoryStateStore.confirm` of an unknown ticket is refused, naming it.
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
    StateStore,
    IntentTicket,
    InputRef,
    Outputs,
    ResolvedInputs,
    UNBOUND_TOKEN,
    unbound_error,
    Label,
    ResourceKey,
    Provenance,
    OwnerStamp,
    CellScope,
    LABEL_MANAGED_BY,
    LABEL_MACHINE,
    LABEL_CELL,
    LABEL_RESOURCE,
    LABEL_ROLE,
    LABEL_SCHEME,
    ownership_problem,
    topo_sort,
    dag_topo_order,
    RES_ABSENT,
    RES_PRESENT_DRIFTED,
    RETAIN_DELETE,
    VERB_NOOP,
    VERB_CREATE,
    VERB_UPDATE,
    VERB_REPLACE,
    VERB_DELETE,
    VERB_KNOWN_AFTER_APPLY,
    FAULT_UNSET,
)
from kci_reconciler.cell_walk import removal_is_ours


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# ---- a minimal conformer: only the required verbs -------------------------------


struct _Bare(Resource, Movable, Deinitable):
    var _id: String
    var _deps: List[String]
    var _refs: List[InputRef]

    def __init__(
        out self,
        id: String,
        var deps: List[String] = List[String](),
        var refs: List[InputRef] = List[InputRef](),
    ):
        self._id = id
        self._deps = deps^
        self._refs = refs^

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return self._deps.copy()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        return ResourceStatus.drifted(String("pid-") + self._id, String("d"))

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return ChangeAction(self._id.copy(), VERB_NOOP, String(""), RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        return String("pid-") + self._id

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1


struct _Reads(Resource, Movable, Deinitable):
    """`_Bare` with `input_refs` (the trait default has none)."""

    var _id: String
    var _deps: List[String]
    var _refs: List[InputRef]

    def __init__(out self, id: String, var deps: List[String], var refs: List[InputRef]):
        self._id = id
        self._deps = deps^
        self._refs = refs^

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return self._deps.copy()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        return ResourceStatus.absent()

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return ChangeAction(self._id.copy(), VERB_NOOP, String(""), RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        return String("")

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1

    def input_refs(mut self) -> List[InputRef]:
        return self._refs.copy()


def _one(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _ref(producer: String, output: String, field: String) -> List[InputRef]:
    var out = List[InputRef]()
    out.append(InputRef(producer, output, field))
    return out^


def _topo_err(mut g: ResourceGraph) -> String:
    try:
        _ = topo_sort(g)
    except e:
        return String(e)
    return String("")


def _dag_err(deps: List[List[Int]]) -> String:
    try:
        _ = dag_topo_order(deps)
    except e:
        return String(e)
    return String("")


# ---- 1. a duplicate key -----------------------------------------------------------


def test_a_duplicate_key_is_refused_and_the_first_kept() raises:
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Bare(String("a"))))
    var msg = String("")
    try:
        g.add(ErasedResource.erase(_Bare(String("a"))))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "ResourceGraph.add: duplicate logical_id 'a' — every graph node must"
        " have a unique key",
    )
    assert_equal(g.num_nodes(), 1)
    g.add(ErasedResource.erase(_Bare(String("b"))))
    var again = String("")
    try:
        g.add(ErasedResource.erase(_Bare(String("b"))))
    except e:
        again = String(e)
    assert_true(_has(again, "duplicate logical_id 'b'"), again)
    assert_equal(g.num_nodes(), 2)
    print("  test_a_duplicate_key_is_refused_and_the_first_kept: PASS")


# ---- 2. topo_sort's self-cycles and the one-edge rule ------------------------------


def test_topo_sort_empty_and_self_cycles() raises:
    var empty = ResourceGraph()
    assert_equal(len(topo_sort(empty)), 0)

    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Bare(String("z"))))
    g.add(ErasedResource.erase(_Bare(String("a"), _one(String("a")))))
    assert_equal(
        _topo_err(g), "topo_sort: node 'a' depends on itself (a self-cycle)"
    )

    var g2 = ResourceGraph()
    g2.add(ErasedResource.erase(_Bare(String("z"))))
    g2.add(
        ErasedResource.erase(
            _Reads(String("b"), List[String](), _ref(String("b"), String("URL"), String("env.SELF")))
        )
    )
    assert_equal(
        _topo_err(g2),
        "topo_sort: node 'b' field env.SELF reads its own output 'URL' (a"
        " self-cycle through a reference)",
    )
    print("  test_topo_sort_empty_and_self_cycles: PASS")


def test_a_reference_to_a_named_dependency_is_one_edge() raises:
    var refs = List[InputRef]()
    refs.append(InputRef(String("p"), String("URL"), String("env.URL")))
    refs.append(InputRef(String("p"), String("PORT"), String("env.PORT")))
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_Reads(String("c"), _one(String("p")), refs^)))
    g.add(ErasedResource.erase(_Bare(String("p"))))
    var order = topo_sort(g)
    assert_equal(len(order), 2)
    assert_equal(order[0], 1, "the producer first")
    assert_equal(order[1], 0)

    # A producer that already has ANOTHER dependent still gets this consumer's
    # edge: d depends on p, c only reads p.
    var g2 = ResourceGraph()
    g2.add(ErasedResource.erase(_Bare(String("d"), _one(String("p")))))
    g2.add(
        ErasedResource.erase(
            _Reads(String("c"), List[String](), _ref(String("p"), String("URL"), String("env.URL")))
        )
    )
    g2.add(ErasedResource.erase(_Bare(String("p"))))
    var order2 = topo_sort(g2)
    assert_equal(len(order2), 3)
    assert_equal(order2[0], 2, "p first")
    assert_equal(order2[1], 0, "then d")
    assert_equal(order2[2], 1, "then c, after its producer")
    print("  test_a_reference_to_a_named_dependency_is_one_edge: PASS")


# ---- 3. dag_topo_order ------------------------------------------------------------


def test_dag_topo_order_is_lowest_index_first() raises:
    assert_equal(len(dag_topo_order(List[List[Int]]())), 0)
    # 0 <- 2, 3 <- {0, 1}: ready at the start are 1 and 2.
    var deps = List[List[Int]]()
    deps.append([2])
    deps.append(List[Int]())
    deps.append(List[Int]())
    deps.append([0, 1])
    var order = dag_topo_order(deps)
    assert_equal(len(order), 4)
    assert_equal(order[0], 1)
    assert_equal(order[1], 2)
    assert_equal(order[2], 0)
    assert_equal(order[3], 3)
    print("  test_dag_topo_order_is_lowest_index_first: PASS")


def test_dag_topo_order_refuses_cycles_naming_the_nodes_left() raises:
    # 3 is free; 0 <-> 1 is a cycle; 2 waits on 1.
    var deps = List[List[Int]]()
    deps.append([1])
    deps.append([0])
    deps.append([1])
    deps.append(List[Int]())
    assert_equal(
        _dag_err(deps),
        "dag_topo_order: the DAG has a CYCLE among node indices [0, 1, 2] — it"
        " cannot be topologically ordered",
    )
    var selfdep = List[List[Int]]()
    selfdep.append(List[Int]())
    selfdep.append([1])
    assert_equal(
        _dag_err(selfdep),
        "dag_topo_order: the DAG has a CYCLE among node indices [1] — it cannot"
        " be topologically ordered",
    )
    print("  test_dag_topo_order_refuses_cycles_naming_the_nodes_left: PASS")


# ---- 4. outputs and resolved inputs --------------------------------------------------


def test_outputs_replace_in_place_and_inputs_answer_by_both_names() raises:
    var o = Outputs()
    o.set(String("URL"), String("u1"))
    o.set(String("PORT"), String("80"))
    o.set(String("URL"), String("u2"))
    assert_equal(o.count(), 2, "a re-set name is not appended")
    assert_equal(o.name_at(0), "URL")
    assert_equal(o.value_at(0), "u2")
    assert_equal(o.name_at(1), "PORT")
    assert_equal(o.value_at(1), "80")

    var r = ResolvedInputs()
    r.add(InputRef(String("p"), String("URL"), String("env.URL")), String("https://p.example.com"))
    r.add(InputRef(String("q"), String("ADDR"), String("env.ADDR")), String("db.example.com:5432"))
    var c = r.copy()
    assert_equal(c.count(), 2)
    assert_equal(c.ref_at(1).producer, "q")
    assert_equal(c.ref_at(1).field, "env.ADDR")
    assert_equal(c.value_of(String("app"), String("q"), String("ADDR")), "db.example.com:5432")
    var msg = String("")
    try:
        _ = c.value_of(String("app"), String("p"), String("ADDR"))
    except e:
        msg = String(e)
    assert_true(msg.startswith(String(UNBOUND_TOKEN) + ": node 'app' reads output 'ADDR' of 'p'"), msg)
    assert_false(_has(msg, "(field"), msg)
    var with_field = String(unbound_error(String("app"), InputRef(String("p"), String("URL"), String("env.URL"))))
    assert_true(_has(with_field, "node 'app' (field env.URL) reads output 'URL'"), with_field)
    print("  test_outputs_replace_in_place_and_inputs_answer_by_both_names: PASS")


# ---- 5. keys, labels, stamps, scopes ------------------------------------------------


def _labels_without(labels: List[Label], skip: Int) -> List[Label]:
    var out = List[Label]()
    for i in range(len(labels)):
        if i != skip:
            out.append(labels[i].copy())
    return out^


def test_keys_labels_and_stamps() raises:
    assert_equal(ResourceKey(String(""), String(""), String("db")).text(), "db")
    assert_equal(ResourceKey(String("shop"), String("blue"), String("db")).text(), "shop/blue/db")
    assert_equal(ResourceKey(String("shop"), String(""), String("db")).text(), "shop//db")
    assert_equal(ResourceKey(String(""), String("blue"), String("db")).text(), "/blue/db")

    var cell = CellScope(String("shop"), String("blue"), Provenance(String("r9"), String("v9")))
    var stamp = cell.stamp(String("api"), String("api/run"))
    var labels = stamp.labels()
    assert_equal(len(labels), 6)
    assert_equal(labels[0].key, LABEL_MANAGED_BY)
    assert_equal(labels[0].value, "kci")
    assert_equal(labels[1].key, LABEL_MACHINE)
    assert_equal(labels[1].value, "shop")
    assert_equal(labels[2].key, LABEL_CELL)
    assert_equal(labels[2].value, "blue")
    assert_equal(labels[3].key, LABEL_RESOURCE)
    assert_equal(labels[3].value, "api")
    assert_equal(labels[4].key, LABEL_ROLE)
    assert_equal(labels[4].value, "run")
    assert_equal(labels[5].key, LABEL_SCHEME)
    assert_equal(labels[5].value, "1")
    assert_equal(OwnerStamp.identity_of_labels(labels), stamp.identity())
    assert_equal(stamp.identity(), "kci:v1 owner=shop/blue/api/run")

    # Any order, and a label kci does not write is ignored.
    var shuffled = List[Label]()
    shuffled.append(Label(String("team"), String("payments")))
    var i = len(labels) - 1
    while i >= 0:
        shuffled.append(labels[i].copy())
        i -= 1
    assert_equal(OwnerStamp.identity_of_labels(shuffled), stamp.identity())

    # Each of the six is required.
    for skip in range(6):
        assert_equal(
            OwnerStamp.identity_of_labels(_labels_without(labels, skip)),
            "",
            String("decoded without label ") + String(skip),
        )
    var foreign = labels.copy()
    foreign[0] = Label(String(LABEL_MANAGED_BY), String("terraform"))
    assert_equal(OwnerStamp.identity_of_labels(foreign), "")

    var sc = stamp.copy()
    assert_equal(sc.identity(), stamp.identity())
    assert_equal(sc.provenance.run_id, "r9")
    assert_equal(sc.provenance.revision, "v9")

    var adopt = List[String]()
    adopt.append(String("api/run"))
    var scope = CellScope(
        String("shop"), String("blue"), Provenance(String("r1"), String("v1")), adopt^, String("val-7")
    )
    var copied = scope.copy()
    assert_true(copied.adopts(String("api/run")), "the adopt list is copied")
    assert_false(copied.adopts(String("db/run")))
    assert_equal(copied.validation_run_id.value(), "val-7")
    assert_equal(copied.provenance.run_id, "r1")
    assert_equal(copied.key(String("x")).text(), "shop/blue/x")
    print("  test_keys_labels_and_stamps: PASS")


def test_ownership_problem_absent_and_moved_object() raises:
    var ours = String("kci:v1 owner=shop/blue/api/run")
    assert_equal(
        ownership_problem(String("api/run"), ours, False, String(""), String("kci:v1 owner=x/y/z/w"), String("pid-a"), False),
        "",
        "an absent object is no problem whatever stamp it had",
    )
    assert_equal(
        ownership_problem(String("api/run"), ours, True, String("pid-b"), ours, String("pid-a"), False),
        "conflict: the ledger records physical id \"pid-a\" but the object"
        " stamped for this node is \"pid-b\"",
    )
    assert_equal(
        ownership_problem(String("api/run"), ours, True, String("pid-a"), ours, String("pid-a"), False),
        "",
    )
    assert_equal(
        ownership_problem(String("api/run"), ours, True, String(""), ours, String("pid-a"), False),
        "",
        "a live read with no id does not contradict the ledger",
    )
    assert_equal(
        ownership_problem(String("api/run"), ours, True, String("pid-b"), ours, String(""), False),
        "",
        "nothing recorded: nothing to contradict",
    )
    print("  test_ownership_problem_absent_and_moved_object: PASS")


# ---- 6. removal_is_ours --------------------------------------------------------------


def test_removal_refuses_an_object_that_is_not_the_recorded_one() raises:
    var cell = CellScope.unowned()
    var moved = ResourceStatus.drifted(String("pid-new"), String("d"))
    assert_false(removal_is_ours(cell, String(""), RETAIN_DELETE, moved, String("pid-old")))
    var same = ResourceStatus.drifted(String("pid-old"), String("d"))
    assert_true(removal_is_ours(cell, String(""), RETAIN_DELETE, same, String("pid-old")))
    var no_id = ResourceStatus.drifted(String(""), String("d"))
    assert_true(removal_is_ours(cell, String(""), RETAIN_DELETE, no_id, String("pid-old")))
    print("  test_removal_refuses_an_object_that_is_not_the_recorded_one: PASS")


# ---- 7. ChangeAction and ResourceStatus -------------------------------------------


def test_change_action_names_and_predicates() raises:
    var verbs: List[Int] = [VERB_NOOP, VERB_CREATE, VERB_UPDATE, VERB_REPLACE, VERB_DELETE, VERB_KNOWN_AFTER_APPLY]
    var names: List[String] = ["noop", "create", "update", "replace", "delete", "known after apply"]
    for i in range(len(verbs)):
        var a = ChangeAction(String("n"), verbs[i], String("why"), RETAIN_DELETE, String("own"), String("extra"))
        var c = a.copy()
        assert_equal(String(c.verb_name()), names[i])
        assert_equal(c.is_noop(), i == 0)
        assert_equal(c.is_create(), i == 1)
        assert_equal(c.is_update(), i == 2)
        assert_equal(c.is_replace(), i == 3)
        assert_equal(c.is_delete(), i == 4)
        assert_equal(c.is_known_after_apply(), i == 5)
        assert_equal(c.reason, "why")
        assert_equal(c.owner, "own")
        assert_equal(c.unmanaged, "extra")
    assert_true(ResourceStatus.drifted(String("p"), String("d")).is_drifted())
    assert_false(ResourceStatus.matched(String("p"), String("d")).is_drifted())
    assert_false(ResourceStatus.absent().is_drifted())
    print("  test_change_action_names_and_predicates: PASS")


# ---- 8. trait defaults --------------------------------------------------------------


struct _BareStore(StateStore, Movable, Deinitable):
    """Only the four required verbs, over an in-memory store."""

    var _inner: InMemoryStateStore

    def __init__(out self):
        self._inner = InMemoryStateStore()

    def record_or_adopt_intent(mut self, key: ResourceKey, stamp: String) raises -> IntentTicket:
        return self._inner.record_or_adopt_intent(key, stamp)

    def confirm(mut self, ticket: IntentTicket, physical_id: String) raises:
        self._inner.confirm(ticket, physical_id)

    def mark_reaped(mut self, key: ResourceKey) raises:
        self._inner.mark_reaped(key)

    def physical_id_for(mut self, key: ResourceKey) raises -> String:
        return self._inner.physical_id_for(key)


def test_resource_trait_defaults() raises:
    var b = _Bare(String("bare"))
    assert_equal(b.undeletable_reason(), "")
    assert_equal(len(b.input_refs()), 0)
    b.bind_inputs(ResolvedInputs())
    assert_equal(b.outputs(String("pid-bare"), Creds.none()).count(), 0)
    assert_equal(b.owner(), "")
    assert_false(b.stamps_ownership())
    assert_true(b.wanted())
    assert_equal(b.fault_domain(String("create")), FAULT_UNSET)
    b.prune(Creds.none())
    var presence = b.read_presence(Creds.none())
    assert_equal(presence.phase, RES_PRESENT_DRIFTED, "read_presence is read_status")
    assert_equal(presence.physical_id, "pid-bare")
    var stamp = CellScope(String("shop"), String("blue")).stamp(String(""), String("bare"))
    var created = String("")
    try:
        _ = b.create_owned(stamp, Creds.none())
    except e:
        created = String(e)
    assert_equal(created, "create_owned: node 'bare' does not stamp ownership")
    var adopted = String("")
    try:
        b.adopt_owned(stamp, String("pid-bare"), Creds.none())
    except e:
        adopted = String(e)
    assert_equal(adopted, "adopt_owned: node 'bare' cannot adopt an existing object")

    # The same answers through the erased facade.
    var n = ErasedResource.erase(_Bare(String("bare")))
    assert_equal(n.undeletable_reason(), "")
    assert_false(n.stamps_ownership())
    assert_true(n.wanted())
    assert_equal(n.read_presence(Creds.none()).physical_id, "pid-bare")
    print("  test_resource_trait_defaults: PASS")


def test_state_store_defaults_persist_no_outputs() raises:
    var s = _BareStore()
    var key = ResourceKey(String("shop"), String("blue"), String("db"))
    var o = Outputs()
    o.set(String("URL"), String("https://db.example.com"))
    s.record_outputs(key, o)
    assert_equal(s.outputs_for(key).count(), 0, "a store that does not override keeps none")
    var t = s.record_or_adopt_intent(key, String(""))
    s.confirm(t, String("pid-db"))
    assert_equal(s.physical_id_for(key), "pid-db")
    print("  test_state_store_defaults_persist_no_outputs: PASS")


# ---- 9. confirm of an unknown ticket ----------------------------------------------


def test_confirm_of_an_unknown_ticket_is_refused() raises:
    var s = InMemoryStateStore()
    var key = ResourceKey(String("shop"), String("blue"), String("db"))
    var t = s.record_or_adopt_intent(key, String(""))
    s.confirm(t, String("pid-db"))
    assert_equal(s.physical_id_for(key), "pid-db")
    var msg = String("")
    try:
        s.confirm(IntentTicket(String("intent-99"), key.copy(), False), String("pid-x"))
    except e:
        msg = String(e)
    assert_equal(msg, "InMemoryStateStore.confirm: no intent intent-99 for 'shop/blue/db'")
    assert_equal(s.physical_id_for(key), "pid-db", "the known intent is untouched")
    print("  test_confirm_of_an_unknown_ticket_is_refused: PASS")


def main() raises:
    print("test_graph_and_value_types:")
    test_a_duplicate_key_is_refused_and_the_first_kept()
    test_topo_sort_empty_and_self_cycles()
    test_a_reference_to_a_named_dependency_is_one_edge()
    test_dag_topo_order_is_lowest_index_first()
    test_dag_topo_order_refuses_cycles_naming_the_nodes_left()
    test_outputs_replace_in_place_and_inputs_answer_by_both_names()
    test_keys_labels_and_stamps()
    test_ownership_problem_absent_and_moved_object()
    test_removal_refuses_an_object_that_is_not_the_recorded_one()
    test_change_action_names_and_predicates()
    test_resource_trait_defaults()
    test_state_store_defaults_persist_no_outputs()
    test_confirm_of_an_unknown_ticket_is_refused()
    print("ALL GRAPH AND VALUE-TYPE TESTS PASSED")
