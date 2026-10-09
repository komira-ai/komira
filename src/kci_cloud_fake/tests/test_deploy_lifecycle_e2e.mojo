# =============================================================================
# test_deploy_lifecycle_e2e.mojo: one authored graph through the whole deploy
#   lifecycle, on the fake clouds, in one process with no external service.
# =============================================================================
#
# The graph is the checked-in fixture `test_data/deploy_lifecycle_graph.json`,
# read as an author writes it (proto3 JSON, `kci.resource.v1.ResourceList`)
# through `kci_resource_proto`: a public service `api`, a consumer `web` of
# its URL and HOST (and a CALL on it), a container job `nightly` running as
# the service account `runner`, a KEEP bucket `media` (`api` uses it
# READ_WRITE), a table `orders` (retention DELETE) and a grant resource
# `reads` (runner READ media). Every assertion below runs on the aws, gcp and
# azure shapes of `FakeCloud` through ONE loop: clouds are values. A shape
# whose grants are DERIVED (gcp) refuses a grant resource, so it reads the
# second fixture, `test_data/deploy_lifecycle_graph_derived.json`: the same
# graph with `reads` written as the `uses` line it is equivalent to, `uses
# media READ` on its principal `runner` (same target, same access).
#
# 1. LIFECYCLE (`test_lifecycle_on_every_shape`), per shape:
#    a. validate: the graph has no finding on the shape; a copy whose
#       consumer reads a resource the file does not name has a finding on
#       the consumer naming it, and plan refuses that copy.
#    b. plan on an empty cell: every wanted node is a CREATE (or, for a
#       consumer whose value comes from a node still to be created, known
#       after apply), every turned-off role a NOOP, nothing else; and the
#       plan makes ZERO mutating calls and writes nothing to the ledger.
#    c. apply: every wanted node is live with the shape's provider kind
#       (pinned per shape, not read back from the shape table), stamped with
#       labels the standard rule accepts that decode to its own node, with
#       the run that made it (provenance run id); the consumer's run object
#       was created over the producer's real URL and HOST, and the producer's
#       outputs are recorded in the ledger; every node belongs to its
#       resource at every depth (resource -> role -> grant helper), and every
#       dependency resolves to a lowered node. A re-apply under a new run id
#       is NOOP everywhere and mutates nothing.
#    d. update: a changed image is an in-place UPDATE of that one run object
#       (the call log holds one `update`, no create, no delete); a changed
#       table key, which would need a REPLACE, is refused (plan and apply)
#       with nothing mutated, because the model says a new key is a new table.
#    e. closed world, in apply: a `uses` line dropped from a resource still
#       in the file turns its grant edge (and helper) off, and the apply
#       deletes exactly those and nothing else; a resource dropped from the
#       file is LEFTOVER: reported in the outcome, still live, never named
#       in a call.
#    f. destroy: `list_owned` is empty but for the KEEP bucket, which is
#       still live and labelled kept; every non-KEEP ledger record is
#       retired; a second destroy is a no-op. (The foreign object and the
#       other cell's object planted at names the graph never lowers are
#       checked untouched too, but that holds by construction: destroy only
#       walks lowered names. The ownership gate is 3.)
# 2. A FAULT AT CALL k (`test_a_fault_at_call_k_converges_without_a_double_
#    create`), per shape and for EVERY k from the first create to the last
#    and on every delete of the teardown: the faulted run stops at that call
#    with exactly k-1 calls landed and reports it (partial when k > 1, the
#    k-1 landed creates, the faulted node first in pending); the re-run
#    converges, every node created exactly once, one ledger intent per node
#    and none left provisioning, and nothing owned that the file does not
#    lower (no orphan); a teardown faulted at its k-th delete re-runs to the
#    same end state as (1f). The fake's fault REFUSES the call before it
#    acts, so the faulted create never lands. The case the provisioning
#    intent exists for (the create landed, the answer was lost) is the
#    fake's `race_next_create`: after the fault at k, the k-th create lands
#    with this cell's stamp and this apply is told ALREADY_EXISTS; the next
#    apply adopts it (NOOP), still one create.
# 3. OWNERSHIP (`test_an_object_kci_does_not_own_at_a_lowered_name_is_
#    refused`), per shape, for an unstamped object made outside kci and for
#    another cell's object, each at `orders/table` (a name the graph lowers)
#    after the rest of the graph is live: plan, apply and destroy are each
#    refused with the `kci: REFUSED <verb>` pre-flight naming it, with ZERO
#    calls, and the object is unchanged; a destroy of a file that does not
#    name it tears the rest down and leaves it.
#
# Not here, and named so nobody assumes otherwise:
#   * COMPOSITES. The catalog holds `Resource.body` 80 for a composite
#     instance but does not declare it yet, so no authored graph can hold
#     one. The depth exercised is a primitive's own: resource -> fixed roles
#     -> grant edges and their helpers, each owned by its resource.
#   * The validation-run tag on each object a validation creates: asserted
#     where the run id is (1c) once the deploy path stamps it.
#   * The CLI contract (exit codes, `KCI-E-*` ids, the result and summary
#     files): that is the `kci` binary's own test; this file drives the
#     library (`ApplyOutcome` is what the CLI maps to its exit codes).
#
# Mutants planted on the farm, each red here, reverted (never committed):
#   * `destroy_resources` passes `force_delete_data=True` (the KEEP gate of
#     destroy skipped): red at 1f (the KEEP bucket is deleted);
#   * `plan_resources` applies the graph after planning it: red at 1b (plan
#     made mutating calls);
#   * `_graph_for` adds the LEFTOVER nodes as turned-off roles to remove:
#     red at 1e (the leftover table is deleted). (The same defect planted in
#     `removals` itself is caught first by kci_cloud's own tests.)
#   * `_destroy_impl` skips its owned pre-flight: red at 3 (the destroy is
#     not refused by the `kci: REFUSED destroy` pre-flight). kci_reconciler's
#     own `test_ownership_and_cell_keys` catches this first, so it was run
#     with that one test also taken out of kci_reconciler's test_srcs.
#   * FAKE-SIDE, not product code: after an injected fault, the fake node's
#     existence reads ignore the object already there and the store accepts
#     a create of an existing name: red at 2 (a re-run creates more than what
#     was missing). No product mutant reaches this file for a double create:
#     the existing-object check is the engine's, and the same mutant there (a
#     matched object treated as absent) is caught first by `kci_reconciler`'s
#     own tests, so a build of this package never gets to run it.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    ChangeAction,
    Creds,
    InMemoryStateStore,
    Provenance,
    REFUSED_TOKEN,
    VERB_CREATE,
    VERB_DELETE,
    VERB_KNOWN_AFTER_APPLY,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    LoweredNode,
    OwnedRecord,
    apply_resources,
    describe,
    destroy_resources,
    label_problems,
    lower_data,
    owner_of_node,
    plan_resources,
    retained_by,
    validate_for,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, ProviderShape, fake_host, fake_url, shape_named

comptime _FIXTURE = "src/kci_cloud_fake/tests/test_data/deploy_lifecycle_graph.json"
comptime _DERIVED_FIXTURE = "src/kci_cloud_fake/tests/test_data/deploy_lifecycle_graph_derived.json"
comptime _MACHINE = "shop"
comptime _CELL = "blue"
comptime _OTHER_CELL = "green"
# Made outside kci before it ever ran: a name no node of the graph has.
comptime _FOREIGN = "legacy/run"
# Another cell's object on the same cloud.
comptime _OTHER = "archive/bucket"
comptime _OTHER_GRAPH = '{"resource":[{"id":"archive","retention":"DELETE","bucket":{}}]}'
# The fixture's `uses` line of `api` (a grant edge to the KEEP bucket).
comptime _API_USES_MEDIA = '"uses": [{"target": {"resource": "media"}, "access": "READ_WRITE"}]'
# The fixture's `orders` resource, exactly as written there.
comptime _ORDERS = (
    '{\n      "id": "orders",\n      "retention": "DELETE",\n'
    + '      "table": {"key": {"name": "pk", "partition": {"name": "customer", "type": "STRING"}}}\n    }'
)


# ---- helpers ------------------------------------------------------------------------


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _fixture(shape: ProviderShape) raises -> String:
    """The authored graph `shape` reads: the fixture, or on a shape whose
    grants are DERIVED, its rewrite (the file header)."""
    var text = String("")
    var path = String(_DERIVED_FIXTURE) if shape.grants_derived() else String(_FIXTURE)
    with open(path, "r") as f:
        text = f.read()
    assert_equal(_has(text, '"id": "reads"'), not shape.grants_derived(), "the grant reads, or its uses line")
    assert_true(_has(text, '"id": "api"'), "the fixture is the authored graph")
    return text^


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx(cell: String, run: String) -> CellContext:
    return CellContext(CellScope(String(_MACHINE), cell, Provenance(run, String("rev-") + run)))


def _blue(run: String = String("run-1")) -> CellContext:
    return _ctx(String(_CELL), run)


def _reg(id: String, shape: ProviderShape) raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(id, shape=shape.copy())))
    return reg^


def _is_derived(shape: String) raises -> Bool:
    """Whether the built-in cloud called `shape` derives its grants' stamp,
    read from the shape (never from the name alone). An unknown name
    raises: it never reads as "not derived"."""
    return shape_named(shape).grants_derived()


def _shapes() -> List[ProviderShape]:
    var l = List[ProviderShape]()
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    return l^


def _contains(l: List[String], s: String) -> Bool:
    for i in range(len(l)):
        if l[i] == s:
            return True
    return False


def _wanted_ids(nodes: List[LoweredNode]) -> List[String]:
    var out = List[String]()
    for i in range(len(nodes)):
        if nodes[i].wanted:
            out.append(nodes[i].id.copy())
    return out^


def _grant_of(nodes: List[LoweredNode], owner: String, target: String, access: String) raises -> String:
    """The node id of `owner`'s grant edge to `target` with `access` (its
    role is a hash kci derives, so it is found, not spelled)."""
    for i in range(len(nodes)):
        ref n = nodes[i]
        if n.owner == owner and n.field(String("target")) == target and n.field(String("access")) == access:
            return n.id.copy()
    raise Error(String("no grant of ") + owner + String(" on ") + target + String(" ") + access)


def _without_orders(json: String) raises -> String:
    """`json` with the `orders` resource dropped from the file."""
    var out = json.replace(String(_ORDERS) + String(",\n    "), String(""))
    assert_true(out != json and not _has(out, '"orders"'), "orders was dropped from the file")
    return out^


def _faulted_id(error: String) -> String:
    """The node an injected fault names: `... (create <id>)`."""
    var at = error.find("(create ")
    if at < 0:
        return String("")
    var start = at + 8
    var stop = error.find(")", start)
    if stop < 0:
        return String("")
    return String(error[byte=start:stop])


def _done(outcome: ApplyOutcome, what: String) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(what + String(": the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _verb(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def _calls_since(fake: FakeCloud, start: Int) -> List[String]:
    var out = List[String]()
    for i in range(start, len(fake.store[].calls)):
        out.append(fake.store[].calls[i].copy())
    return out^


def _kind(fake: FakeCloud, id: String) raises -> String:
    var i = fake.store[].find(id)
    if i < 0:
        raise Error(id + String(" is not live"))
    return fake.store[].kinds[i].copy()


def _digest(fake: FakeCloud, id: String) raises -> String:
    var i = fake.store[].find(id)
    if i < 0:
        raise Error(id + String(" is not live"))
    return fake.store[].digests[i].copy()


@fieldwise_init
struct _Pin(Copyable, Movable):
    var node: String
    var kind: String


def _pins(shape: String, call_grant: String, data_grant: String, reads: String) -> List[_Pin]:
    """The provider kind each primary node and grant lowers to, per shape,
    written out here (an independent oracle; not read from shapes.mojo).
    An empty kind: the shape lowers no such node (azure folds a public
    ingress into the run object)."""
    var p = List[_Pin]()
    if shape == "aws":
        p.append(_Pin(String("api/identity"), String("AWS::IAM::Role")))
        p.append(_Pin(String("api/run"), String("AWS::Lambda::Function")))
        p.append(_Pin(String("api/public"), String("AWS::Lambda::Url")))
        p.append(_Pin(String("web/run"), String("AWS::Lambda::Function")))
        p.append(_Pin(String("nightly/run"), String("AWS::ECS::TaskDefinition")))
        p.append(_Pin(String("runner/identity"), String("AWS::IAM::Role")))
        p.append(_Pin(String("media/bucket"), String("AWS::S3::Bucket")))
        p.append(_Pin(String("orders/table"), String("AWS::DynamoDB::Table")))
        p.append(_Pin(call_grant, String("AWS::Lambda::Permission")))
        p.append(_Pin(data_grant, String("AWS::IAM::RolePolicy")))
        p.append(_Pin(reads, String("AWS::IAM::RolePolicy")))
    elif shape == "gcp":
        p.append(_Pin(String("api/identity"), String("iam.googleapis.com/ServiceAccount")))
        p.append(_Pin(String("api/run"), String("run.googleapis.com/Service")))
        p.append(_Pin(String("api/public"), String("setIamPolicy")))
        p.append(_Pin(String("web/run"), String("run.googleapis.com/Service")))
        p.append(_Pin(String("nightly/run"), String("run.googleapis.com/Job")))
        p.append(_Pin(String("runner/identity"), String("iam.googleapis.com/ServiceAccount")))
        p.append(_Pin(String("media/bucket"), String("storage.googleapis.com/Bucket")))
        p.append(_Pin(String("orders/table"), String("firestore.googleapis.com/Index")))
        p.append(_Pin(call_grant, String("setIamPolicy")))
        p.append(_Pin(data_grant, String("setIamPolicy")))
        p.append(_Pin(reads, String("setIamPolicy")))
    else:
        p.append(_Pin(String("api/identity"), String("Microsoft.ManagedIdentity/userAssignedIdentities")))
        p.append(_Pin(String("api/run"), String("Microsoft.App/containerApps")))
        p.append(_Pin(String("api/public"), String("")))
        p.append(_Pin(String("web/run"), String("Microsoft.App/containerApps")))
        p.append(_Pin(String("nightly/run"), String("Microsoft.App/jobs")))
        p.append(_Pin(String("runner/identity"), String("Microsoft.ManagedIdentity/userAssignedIdentities")))
        p.append(_Pin(String("media/bucket"), String("Microsoft.Storage/storageAccounts/blobServices/containers")))
        p.append(
            _Pin(String("orders/table"), String("Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers"))
        )
        p.append(_Pin(call_grant, String("Microsoft.Authorization/roleAssignments")))
        p.append(_Pin(data_grant, String("Microsoft.Authorization/roleAssignments")))
        p.append(_Pin(reads, String("Microsoft.Authorization/roleAssignments")))
    return p^


# ---- 1a. validate --------------------------------------------------------------------


def _validate(reg: Clouds, mut fake: FakeCloud, json: String, tag: String) raises:
    var findings = validate_for(reg, fake, _list(json))
    if len(findings) > 0:
        raise Error(tag + String(": the authored graph has a finding: ") + findings[0].reason)
    var before = fake.mutations()
    var ghost = json.replace(
        String('"resource": "api", "standard": "URL"'), String('"resource": "ghost", "standard": "URL"')
    )
    assert_true(ghost != json, tag + ": the consumer's reference was rewritten")
    # Validation itself flags the dangling reference, on the consumer.
    var dangling = validate_for(reg, fake, _list(ghost))
    var on_web = 0
    for i in range(len(dangling)):
        if dangling[i].resource_id == "web" and _has(dangling[i].reason, "ghost"):
            on_web += 1
    assert_true(on_web > 0, tag + ": validate names the consumer's reference to no resource")
    var store = InMemoryStateStore()
    var refused = String("")
    try:
        _ = plan_resources(reg, fake, _blue(), _list(ghost), Creds.none(), store)
    except e:
        refused = String(e)
    assert_true(_has(refused, "ghost"), tag + ": a reference to no resource is refused: " + refused)
    assert_equal(fake.mutations(), before, tag + ": a refused graph makes no call")
    assert_equal(fake.live_count(), 2, tag + ": a refused graph creates nothing")


# ---- 1b. plan on an empty cell -----------------------------------------------------------


def _plan_on_empty_cell(
    reg: Clouds, mut fake: FakeCloud, json: String, nodes: List[LoweredNode], mut store: InMemoryStateStore,
    tag: String,
) raises:
    var calls_before = fake.mutations()
    var live_before = fake.live_count()
    var actions = plan_resources(reg, fake, _blue(), _list(json), Creds.none(), store)
    assert_equal(fake.mutations(), calls_before, tag + ": plan made ZERO mutating calls")
    assert_equal(fake.live_count(), live_before, tag + ": plan created and deleted nothing")
    assert_equal(len(actions), len(nodes), tag + ": one action per lowered node")
    var creates = 0
    var later = 0
    for i in range(len(nodes)):
        ref n = nodes[i]
        assert_equal(store.total_intents(_blue().scope.key(n.id)), 0, tag + ": plan wrote no intent: " + n.id)
        var found = False
        for k in range(len(actions)):
            ref a = actions[k]
            if a.logical_id != n.id:
                continue
            found = True
            assert_equal(a.owner, n.owner, tag + ": the action names its resource: " + n.id)
            if not n.wanted:
                assert_equal(a.verb, VERB_NOOP, tag + ": a turned-off role, absent: " + n.id)
            elif a.verb == VERB_CREATE:
                creates += 1
            elif a.verb == VERB_KNOWN_AFTER_APPLY:
                later += 1
            else:
                raise Error(tag + String(": an empty cell plans only creates; ") + n.id + String(": ") + a.reason)
        assert_true(found, tag + ": planned: " + n.id)
    assert_equal(creates + later, len(_wanted_ids(nodes)), tag + ": every wanted node is created")
    for k in range(len(actions)):
        if actions[k].logical_id == "web/run":
            assert_equal(actions[k].verb, VERB_KNOWN_AFTER_APPLY, tag + ": web/run waits for api's URL")
            assert_true(_has(actions[k].reason, "api/run.URL"), tag + ": " + actions[k].reason)


# ---- 1c. apply ------------------------------------------------------------------------


def _owned_by_node(owned: List[OwnedRecord], id: String) -> Int:
    for i in range(len(owned)):
        if owned[i].owner_node == id:
            return i
    return -1


def _apply_and_check(
    reg: Clouds, mut fake: FakeCloud, json: String, nodes: List[LoweredNode], mut store: InMemoryStateStore,
    shape: String, tag: String,
) raises:
    var calls_before = fake.mutations()
    var applied = _done(apply_resources(reg, fake, _blue(), _list(json), Creds.none(), store), tag)
    var wanted = _wanted_ids(nodes)
    assert_equal(fake.mutations() - calls_before, len(wanted), tag + ": one create per wanted node, nothing else")
    var scope = _blue().scope.copy()
    var owned = fake.list_owned(Creds.none(), scope)
    assert_equal(len(owned), len(wanted), tag + ": the cell owns exactly the wanted nodes")

    for i in range(len(nodes)):
        ref n = nodes[i]
        # Every depth belongs to its resource: the node id's first segment is
        # the resource that lowered it, and every dependency resolves to a
        # node of the lowering.
        assert_equal(owner_of_node(n.id), n.owner, tag + ": owned by its resource: " + n.id)
        for d in range(len(n.depends_on)):
            var dep_known = False
            for m in range(len(nodes)):
                if nodes[m].id == n.depends_on[d]:
                    dep_known = True
            assert_true(dep_known, tag + ": " + n.id + " depends on a lowered node: " + n.depends_on[d])
        if not n.wanted:
            assert_true(fake.store[].find(n.id) < 0, tag + ": a turned-off role is not created: " + n.id)
            continue
        assert_equal(_verb(applied, n.id), VERB_CREATE, tag + ": created: " + n.id)
        assert_equal(fake.creates_of(n.id), 1, tag + ": created once: " + n.id)
        assert_equal(_kind(fake, n.id), n.kind, tag + ": the live kind is the lowered kind: " + n.id)
        var labels = fake.live_labels(n.id)
        assert_equal(len(label_problems(labels)), 0, tag + ": labels obey the standard rule: " + n.id)
        assert_equal(
            fake.identity_of(labels),
            scope.stamp(n.owner, n.id).identity(),
            tag + ": the stamp decodes to this node: " + n.id,
        )
        assert_equal(retained_by(labels), n.id == "media/bucket", tag + ": kept iff the KEEP bucket: " + n.id)
        var o = _owned_by_node(owned, n.id)
        assert_true(o >= 0, tag + ": list_owned names " + n.id)
        assert_equal(owned[o].run_id, "run-1", tag + ": provenance names the run that made " + n.id)
        # (the validation-run tag of an object a validation creates is
        # asserted here once the deploy path stamps it)
        assert_equal(owned[o].kind, n.kind, tag + ": list_owned reads the kind back: " + n.id)
        assert_equal(store.count_confirmed(scope.key(n.id)), 1, tag + ": one confirmed record: " + n.id)

    # The provider kinds, pinned per shape.
    # On a DERIVED shape `reads` is runner's own `uses` line: its edge node
    # is runner's, `runner/u-<h>`.
    var reads_owner = String("runner") if _is_derived(shape) else String("reads")
    var reads = _grant_of(nodes, reads_owner, String("media"), String("READ"))
    var pins = _pins(
        shape,
        _grant_of(nodes, String("web"), String("api"), String("CALL")),
        _grant_of(nodes, String("api"), String("media"), String("READ_WRITE")),
        reads,
    )
    if _is_derived(shape):
        assert_true(reads.startswith("runner/u-"), tag + ": reads is runner's edge node: " + reads)
    else:
        assert_equal(reads, "reads/grant")
    for p in range(len(pins)):
        if pins[p].kind.byte_length() == 0:
            assert_true(fake.store[].find(pins[p].node) < 0, tag + ": folded, no node: " + pins[p].node)
            continue
        assert_equal(_kind(fake, pins[p].node), pins[p].kind, tag + ": provider kind of " + pins[p].node)
    assert_true(fake.store[].find(String("nightly/identity")) < 0, tag + ": nightly runs as runner")

    # Values flow: the consumer was created over the producer's real outputs.
    var web = _digest(fake, String("web/run"))
    assert_true(_has(web, String("service.env.API_URL=") + fake_url(String("api"))), tag + ": " + web)
    assert_true(_has(web, String("service.env.API_HOST=") + fake_host(String("api"))), tag + ": " + web)
    var outs = store.outputs_for(scope.key(String("api/run")))
    assert_true(Bool(outs.get(String("URL"))), tag + ": api/run's URL is recorded")
    assert_equal(outs.get(String("URL")).value(), fake_url(String("api")), tag + ": the recorded URL")

    # A re-apply under another run is NOOP everywhere and mutates nothing.
    var calls = fake.mutations()
    var again = _done(apply_resources(reg, fake, _blue(String("run-2")), _list(json), Creds.none(), store), tag)
    for k in range(len(again)):
        assert_equal(again[k].verb, VERB_NOOP, tag + ": settled: " + again[k].logical_id)
    assert_equal(fake.mutations(), calls, tag + ": a settled re-apply makes no call")
    var owned2 = fake.list_owned(Creds.none(), scope)
    for i in range(len(owned2)):
        assert_equal(owned2[i].run_id, "run-1", tag + ": provenance is never a field: " + owned2[i].owner_node)


# ---- 1d. update in place; a replace is refused ------------------------------------------------


def _update_then_refused_replace(
    reg: Clouds, mut fake: FakeCloud, json: String, mut store: InMemoryStateStore, tag: String
) raises -> String:
    var changed = json.replace(String("sha256:a1"), String("sha256:a9"))
    assert_true(changed != json, tag + ": the image was rewritten")
    var calls_before = fake.mutations()
    var applied = _done(apply_resources(reg, fake, _blue(String("run-3")), _list(changed), Creds.none(), store), tag)
    for k in range(len(applied)):
        ref a = applied[k]
        if a.logical_id == "api/run":
            assert_equal(a.verb, VERB_UPDATE, tag + ": a changed image is an UPDATE")
            # In place is proven by the call log below (one `update`, no
            # delete, no create): the fake's physical id is its logical id.
        else:
            assert_equal(a.verb, VERB_NOOP, tag + ": unchanged: " + a.logical_id)
    var calls = _calls_since(fake, calls_before)
    assert_equal(len(calls), 1, tag + ": one call")
    assert_equal(calls[0], "update api/run", tag + ": updated, never deleted and re-created")
    assert_equal(fake.creates_of(String("api/run")), 1, tag + ": api/run was created once, ever")
    assert_true(_has(_digest(fake, String("api/run")), "sha256:a9"), tag + ": the new image is live")

    # A table's key cannot change in place: the model refuses (a new key is
    # a new table) rather than replace it, and nothing is touched.
    var rekeyed = changed.replace(String('"name": "customer"'), String('"name": "buyer"'))
    assert_true(rekeyed != changed, tag + ": the key was rewritten")
    var before = fake.mutations()
    var refused = 0
    try:
        _ = plan_resources(reg, fake, _blue(), _list(rekeyed), Creds.none(), store)
    except e:
        refused += 1
        assert_true(_has(String(e), "a new key is a new table"), tag + ": " + String(e))
    try:
        _ = apply_resources(reg, fake, _blue(), _list(rekeyed), Creds.none(), store)
    except e:
        refused += 1
        assert_true(_has(String(e), "a new key is a new table"), tag + ": " + String(e))
    assert_equal(refused, 2, tag + ": the plan and the apply are refused")
    assert_equal(fake.mutations(), before, tag + ": a refused replace makes no call")
    return changed^


# ---- 1e. the closed world, in apply ---------------------------------------------------------


def _closed_world(
    reg: Clouds, mut fake: FakeCloud, json: String, nodes: List[LoweredNode], mut store: InMemoryStateStore,
    tag: String,
) raises:
    var scope = _blue().scope.copy()
    # (i) A `uses` line dropped from `api`, which stays in the file: its grant
    # edge (and the helper, on a shape whose row names one) is a turned-off
    # role, and the apply deletes exactly those.
    var no_uses = json.replace(String(_API_USES_MEDIA), String('"uses": []'))
    assert_true(no_uses != json, tag + ": api's uses line was dropped")
    var grant = _grant_of(nodes, String("api"), String("media"), String("READ_WRITE"))
    var fewer = _wanted_ids(lower_data(fake, _list(no_uses)))
    var dropped = List[String]()
    for i in range(len(nodes)):
        if nodes[i].wanted and not _contains(fewer, nodes[i].id):
            dropped.append(nodes[i].id.copy())
            assert_equal(nodes[i].owner, "api", tag + ": only api's edge is dropped: " + nodes[i].id)
    assert_true(_contains(dropped, grant), tag + ": the READ_WRITE grant is no longer lowered")
    var calls_before = fake.mutations()
    var turned_off = apply_resources(reg, fake, _blue(String("run-6")), _list(no_uses), Creds.none(), store)
    var applied = _done(turned_off, tag)
    assert_equal(len(turned_off.leftover), 0, tag + ": nothing leftover")
    assert_equal(len(turned_off.left_behind), 0, tag + ": nothing left behind")
    var calls = _calls_since(fake, calls_before)
    assert_equal(len(calls), len(dropped), tag + ": one delete per dropped node, nothing else")
    for i in range(len(calls)):
        assert_true(calls[i].startswith("delete "), tag + ": a turned-off role is deleted: " + calls[i])
        assert_true(_contains(dropped, String(calls[i][byte=7:])), tag + ": deleted a dropped node: " + calls[i])
    var owned = fake.list_owned(Creds.none(), scope)
    for i in range(len(dropped)):
        assert_equal(_verb(applied, dropped[i]), VERB_DELETE, tag + ": removed: " + dropped[i])
        assert_true(fake.store[].find(dropped[i]) < 0, tag + ": gone: " + dropped[i])
        assert_true(_owned_by_node(owned, dropped[i]) < 0, tag + ": no longer owned: " + dropped[i])
        assert_equal(store.count_confirmed(scope.key(dropped[i])), 0, tag + ": record retired: " + dropped[i])
    for k in range(len(applied)):
        if not _contains(dropped, applied[k].logical_id):
            assert_equal(applied[k].verb, VERB_NOOP, tag + ": untouched: " + applied[k].logical_id)

    # (ii) `orders` dropped from the file: its table is LEFTOVER, reported,
    # still live, and never named in a call.
    var no_orders = _without_orders(no_uses)
    var digest = _digest(fake, String("orders/table"))
    var before = fake.mutations()
    var gone = apply_resources(reg, fake, _blue(String("run-7")), _list(no_orders), Creds.none(), store)
    var applied2 = _done(gone, tag)
    assert_equal(fake.mutations(), before, tag + ": a leftover is never deleted (no call at all)")
    assert_true(_contains(gone.leftover, String("orders/table")), tag + ": orders/table is reported leftover")
    assert_equal(len(gone.left_behind), 0, tag + ": nothing left behind")
    assert_equal(_digest(fake, String("orders/table")), digest, tag + ": the leftover is live and unchanged")
    assert_true(_owned_by_node(fake.list_owned(Creds.none(), scope), String("orders/table")) >= 0, tag + ": still owned")
    assert_equal(store.count_confirmed(scope.key(String("orders/table"))), 1, tag + ": its record stays")
    for k in range(len(applied2)):
        assert_equal(applied2[k].verb, VERB_NOOP, tag + ": settled: " + applied2[k].logical_id)


# ---- 1f. destroy --------------------------------------------------------------------------


def _check_torn_down(
    mut fake: FakeCloud, nodes: List[LoweredNode], store: InMemoryStateStore, tag: String
) raises:
    var scope = _blue().scope.copy()
    var owned = fake.list_owned(Creds.none(), scope)
    assert_equal(len(owned), 1, tag + ": nothing owned is left but the KEEP bucket")
    assert_equal(owned[0].owner_node, "media/bucket", tag + ": the KEEP bucket survives")
    assert_true(owned[0].retained, tag + ": and is reported kept")
    assert_true(retained_by(fake.live_labels(String("media/bucket"))), tag + ": kci_retain=keep")
    for i in range(len(nodes)):
        ref n = nodes[i]
        if n.id == "media/bucket":
            assert_equal(store.count_confirmed(scope.key(n.id)), 1, tag + ": the kept record stays")
            continue
        assert_true(fake.store[].find(n.id) < 0, tag + ": deleted: " + n.id)
        assert_equal(store.count_confirmed(scope.key(n.id)), 0, tag + ": record retired: " + n.id)
        assert_equal(store.count_provisioning(scope.key(n.id)), 0, tag + ": no pending record: " + n.id)


def _check_others_untouched(fake: FakeCloud, tag: String) raises:
    """The foreign object and the other cell's object are live, unchanged,
    and no call ever named them (beyond the other cell's own create). Both
    sit at names the graph never lowers, so this holds by construction; the
    ownership gate itself is test 3."""
    assert_equal(_digest(fake, String(_FOREIGN)), "made-outside-kci", tag + ": the foreign object is untouched")
    assert_equal(len(fake.live_labels(String(_FOREIGN))), 0, tag + ": and still unstamped")
    assert_true(fake.store[].find(String(_OTHER)) >= 0, tag + ": the other cell's object is live")
    for i in range(len(fake.store[].calls)):
        ref c = fake.store[].calls[i]
        assert_false(_has(c, String(_FOREIGN)), tag + ": a call named the foreign object: " + c)
        if _has(c, String(_OTHER)):
            assert_equal(c, String("create ") + String(_OTHER), tag + ": only the other cell's own create: " + c)


def _destroy_and_check(
    reg: Clouds, mut fake: FakeCloud, json: String, nodes: List[LoweredNode], mut store: InMemoryStateStore,
    tag: String,
) raises:
    var calls_before = fake.mutations()
    var skipped = destroy_resources(reg, fake, _blue(String("run-4")), _list(json), Creds.none(), store)
    assert_equal(len(skipped), 0, tag + ": nothing undeletable")
    var calls = _calls_since(fake, calls_before)
    for i in range(len(calls)):
        assert_true(calls[i].startswith("delete "), tag + ": a destroy only deletes: " + calls[i])
        assert_true(calls[i] != "delete media/bucket", tag + ": the KEEP bucket is never deleted")
    _check_torn_down(fake, nodes, store, tag)
    _check_others_untouched(fake, tag)
    # Idempotent: everything is gone or kept, so a second destroy makes no call.
    var before = fake.mutations()
    _ = destroy_resources(reg, fake, _blue(String("run-5")), _list(json), Creds.none(), store)
    assert_equal(fake.mutations(), before, tag + ": a second destroy makes no call")
    _check_torn_down(fake, nodes, store, tag)


# ---- 1. the lifecycle on every shape ------------------------------------------------------------


def test_lifecycle_on_every_shape() raises:
    var shapes = _shapes()
    for s in range(len(shapes)):
        var shape = shapes[s].copy()
        var json = _fixture(shape)
        var tag = shape.name.copy()
        var id = String("p-e2e-") + shape.name
        var reg = _reg(id, shape)
        var foreign = List[String]()
        foreign.append(String(_FOREIGN))
        var fake = FakeCloud(id, foreign=foreign, shape=shape.copy())
        # Another cell of the same machine already holds an object here.
        var other_store = InMemoryStateStore()
        _ = _done(
            apply_resources(
                reg, fake, _ctx(String(_OTHER_CELL), String("run-0")), _list(String(_OTHER_GRAPH)),
                Creds.none(), other_store,
            ),
            tag + String(" (other cell)"),
        )
        assert_equal(fake.live_count(), 2, tag + ": the foreign object and the other cell's")

        var nodes = lower_data(fake, _list(json))
        _validate(reg, fake, json, tag)
        var store = InMemoryStateStore()
        _plan_on_empty_cell(reg, fake, json, nodes, store, tag)
        _apply_and_check(reg, fake, json, nodes, store, shape.name, tag)
        var changed = _update_then_refused_replace(reg, fake, json, store, tag)
        _closed_world(reg, fake, changed, nodes, store, tag)
        _destroy_and_check(reg, fake, changed, nodes, store, tag)
        assert_equal(fake.live_count(), 3, tag + ": the KEEP bucket, the foreign object, the other cell's")
    print("  test_lifecycle_on_every_shape: PASS")


# ---- 2. a fault at call k ---------------------------------------------------------------------------


def _converged(
    mut fake: FakeCloud, nodes: List[LoweredNode], store: InMemoryStateStore, tag: String
) raises:
    """No double create and no orphan: every wanted node live, created once,
    one intent confirmed and none provisioning; nothing owned that the
    lowering does not want."""
    var scope = _blue().scope.copy()
    var wanted = _wanted_ids(nodes)
    for i in range(len(wanted)):
        assert_equal(fake.creates_of(wanted[i]), 1, tag + ": created once: " + wanted[i])
        assert_true(fake.store[].find(wanted[i]) >= 0, tag + ": live: " + wanted[i])
        assert_equal(store.total_intents(scope.key(wanted[i])), 1, tag + ": one intent: " + wanted[i])
        assert_equal(store.count_confirmed(scope.key(wanted[i])), 1, tag + ": confirmed: " + wanted[i])
    var owned = fake.list_owned(Creds.none(), scope)
    for i in range(len(owned)):
        assert_true(_contains(wanted, owned[i].owner_node), tag + ": an orphan: " + owned[i].owner_node)
    assert_equal(len(owned), len(wanted), tag + ": owned == wanted")
    assert_equal(fake.live_count(), len(wanted), tag + ": nothing else is live")


def test_a_fault_at_call_k_converges_without_a_double_create() raises:
    var shapes = _shapes()
    for s in range(len(shapes)):
        var shape = shapes[s].copy()
        var json = _fixture(shape)
        var id = String("p-k-") + shape.name
        var reg = _reg(id, shape)
        var nodes = lower_data(FakeCloud(id, shape=shape.copy()), _list(json))
        var n = len(_wanted_ids(nodes))
        assert_true(n >= 12, shape.name + ": a graph worth faulting")
        # A fault on each create of the first apply.
        for k in range(1, n + 1):
            var tag = shape.name + String(" fault at create ") + String(k)
            var fake = FakeCloud(id, fail_at_call=k, shape=shape.copy())
            var store = InMemoryStateStore()
            var first = apply_resources(reg, fake, _blue(), _list(json), Creds.none(), store)
            assert_true(Bool(first.error), tag + ": the run stops")
            assert_true(
                _has(first.error.value(), String("injected fault on call ") + String(k) + String(" ")),
                tag + ": " + first.error.value(),
            )
            assert_equal(fake.mutations(), k - 1, tag + ": exactly the calls before the fault landed")
            # What a driver reports (the CLI's PARTIAL): the landed nodes, and
            # the faulted node first among the pending.
            # (`landed` also holds the turned-off roles walked before the
            # fault, each a NOOP, so `partial()` is not "a call landed".)
            if k > 1:
                assert_true(first.partial(), tag + ": a partial apply is reported partial")
            assert_false(first.refused(), tag + ": a fault is not an ownership refusal")
            var landed_creates = 0
            for a in range(len(first.landed)):
                if first.landed[a].verb == VERB_CREATE:
                    landed_creates += 1
                else:
                    assert_equal(first.landed[a].verb, VERB_NOOP, tag + ": landed: " + first.landed[a].logical_id)
            assert_equal(landed_creates, k - 1, tag + ": the k-1 landed creates are reported")
            assert_true(len(first.pending) > 0, tag + ": the faulted node is pending")
            assert_equal(first.pending[0], _faulted_id(first.error.value()), tag + ": pending starts at the fault")
            var second = _done(apply_resources(reg, fake, _blue(), _list(json), Creds.none(), store), tag)
            var created = 0
            for a in range(len(second)):
                if second[a].verb == VERB_CREATE:
                    created += 1
                else:
                    assert_equal(second[a].verb, VERB_NOOP, tag + ": " + second[a].logical_id)
            assert_equal(created, n - (k - 1), tag + ": the re-run creates only what is missing")
            _converged(fake, nodes, store, tag)
        # The create lands but its answer is lost: after a fault at k, the
        # k-th create is served (with this cell's stamp) and this apply is
        # told ALREADY_EXISTS; the next apply adopts it, never a second create.
        for k in range(1, n + 1):
            var tag = shape.name + String(" lost answer at create ") + String(k)
            var fake = FakeCloud(id, fail_at_call=k, shape=shape.copy())
            var store = InMemoryStateStore()
            var first = apply_resources(reg, fake, _blue(), _list(json), Creds.none(), store)
            assert_true(Bool(first.error), tag + ": the fault stops the run")
            var lost = first.pending[0].copy()
            fake.race_next_create()
            var second = apply_resources(reg, fake, _blue(), _list(json), Creds.none(), store)
            assert_true(Bool(second.error), tag + ": the apply whose answer was lost stops")
            assert_equal(fake.raced(), lost, tag + ": the create that landed is the pending node")
            assert_equal(fake.creates_of(lost), 1, tag + ": it landed once")
            var third = _done(apply_resources(reg, fake, _blue(), _list(json), Creds.none(), store), tag)
            assert_equal(_verb(third, lost), VERB_NOOP, tag + ": the re-run adopts it, no create")
            _converged(fake, nodes, store, tag)
        # A fault on each delete of the teardown.
        var deletes = n - 1  # every wanted node but the KEEP bucket
        for k in range(1, deletes + 1):
            var tag = shape.name + String(" fault at delete ") + String(k)
            var fake = FakeCloud(id, fail_at_call=n + k, shape=shape.copy())
            var store = InMemoryStateStore()
            _ = _done(apply_resources(reg, fake, _blue(), _list(json), Creds.none(), store), tag)
            var raised = String("")
            try:
                _ = destroy_resources(reg, fake, _blue(), _list(json), Creds.none(), store)
            except e:
                raised = String(e)
            assert_true(_has(raised, "injected fault on call"), tag + ": the teardown stops: " + raised)
            assert_equal(fake.live_count(), n - (k - 1), tag + ": exactly the deletes before the fault landed")
            _ = destroy_resources(reg, fake, _blue(), _list(json), Creds.none(), store)
            _check_torn_down(fake, nodes, store, tag)
            assert_equal(fake.live_count(), 1, tag + ": only the KEEP bucket is live")
    print("  test_a_fault_at_call_k_converges_without_a_double_create: PASS")


# ---- 3. an object kci does not own, at a lowered name --------------------------------------------


def _intruder_is_refused(shape: ProviderShape, by_other_cell: Bool) raises:
    var who = String("another cell's object") if by_other_cell else String("a foreign object")
    var tag = shape.name + String(": ") + who
    var id = String("p-own-") + shape.name
    var reg = _reg(id, shape)
    var fake = FakeCloud(id, shape=shape.copy())
    var json = _fixture(shape)
    var rest = _without_orders(json)
    var store = InMemoryStateStore()
    _ = _done(apply_resources(reg, fake, _blue(), _list(rest), Creds.none(), store), tag)
    var live_rest = fake.live_count()
    var target = String("orders/table")
    if by_other_cell:
        var other_store = InMemoryStateStore()
        var other = String('{"resource":[') + String(_ORDERS) + String("]}")
        _ = _done(
            apply_resources(
                reg, fake, _ctx(String(_OTHER_CELL), String("run-0")), _list(other), Creds.none(), other_store
            ),
            tag + String(" (other cell)"),
        )
    else:
        fake.plant_foreign(target)
    var digest = _digest(fake, target)
    var labels = len(fake.live_labels(target))
    var live = fake.live_count()
    assert_equal(live, live_rest + 1, tag + ": the intruder is live")
    var before = fake.mutations()

    var plan_err = String("")
    try:
        _ = plan_resources(reg, fake, _blue(), _list(json), Creds.none(), store)
    except e:
        plan_err = String(e)
    assert_true(plan_err.startswith(String(REFUSED_TOKEN) + " plan"), tag + ": plan is refused: " + plan_err)
    assert_true(_has(plan_err, target), tag + ": the refusal names it: " + plan_err)

    var applied = apply_resources(reg, fake, _blue(String("run-2")), _list(json), Creds.none(), store)
    assert_true(applied.refused(), tag + ": apply is refused before any change")
    assert_true(_has(applied.error.value(), target), tag + ": the refusal names it")
    assert_equal(len(applied.landed), 0, tag + ": nothing landed")

    var destroy_err = String("")
    try:
        _ = destroy_resources(reg, fake, _blue(String("run-3")), _list(json), Creds.none(), store)
    except e:
        destroy_err = String(e)
    assert_true(
        destroy_err.startswith(String(REFUSED_TOKEN) + " destroy"), tag + ": destroy is refused: " + destroy_err
    )
    assert_true(_has(destroy_err, target), tag + ": the refusal names it")

    assert_equal(fake.mutations(), before, tag + ": plan, apply and destroy made ZERO calls")
    assert_equal(fake.live_count(), live, tag + ": nothing created or deleted")
    assert_equal(_digest(fake, target), digest, tag + ": the intruder is unchanged")
    assert_equal(len(fake.live_labels(target)), labels, tag + ": and keeps its labels")

    # A destroy of the file that does not name it tears the rest down only.
    _ = destroy_resources(reg, fake, _blue(String("run-4")), _list(rest), Creds.none(), store)
    assert_equal(_digest(fake, target), digest, tag + ": the intruder survives the teardown")
    var calls = _calls_since(fake, before)
    for i in range(len(calls)):
        assert_false(_has(calls[i], target), tag + ": a call named the intruder: " + calls[i])
    assert_equal(fake.live_count(), 2, tag + ": the intruder and the KEEP bucket")


def test_an_object_kci_does_not_own_at_a_lowered_name_is_refused() raises:
    var shapes = _shapes()
    for s in range(len(shapes)):
        _intruder_is_refused(shapes[s], False)
        _intruder_is_refused(shapes[s], True)
    print("  test_an_object_kci_does_not_own_at_a_lowered_name_is_refused: PASS")


def main() raises:
    print("test_deploy_lifecycle_e2e")
    test_lifecycle_on_every_shape()
    test_a_fault_at_call_k_converges_without_a_double_create()
    test_an_object_kci_does_not_own_at_a_lowered_name_is_refused()
    print("ALL kci_cloud_fake DEPLOY LIFECYCLE E2E TESTS PASSED")
