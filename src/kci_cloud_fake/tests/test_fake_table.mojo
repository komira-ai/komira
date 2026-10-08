# =============================================================================
# test_fake_table.mojo
# =============================================================================
#
# The `table` primitive on the fake clouds.
#
# 1. A GOLDEN LOWERING PER SHAPE of a table (a key with an order, two
#    indexes, a TTL) and a service that reads its NAME and uses it
#    READ_WRITE: per node its kind, wanted, retention, dependencies and, for
#    the table's nodes, every desired field. generic, aws and azure lower ONE
#    `table` node with the indexes and the TTL as fields; gcp lowers the
#    key's index as `table`, one `ix-<h>` per index and a `ttl` policy; the
#    grant to the table is the shape's (azure: a Cosmos role assignment).
#    The table is KEEP by default, and so is every node it lowers. The full
#    JSON of the generic lowering is pinned too.
# 2. THE KIT ON EVERY SHAPE THAT HOSTS A TABLE: the kci_cloud conformance kit
#    (all eleven steps) passes on generic, aws, gcp and azure, each under a
#    random id, on a graph with a table (retention DELETE, so the kit's
#    destroy may remove it).
# 3. ONPREM DECLARES THE TABLE NOT_YET: the same graph is refused on onprem
#    before anything is created, by one coverage finding naming the type and
#    the open question (Q17), and the clouds that do host it (pinned
#    refusal text).
# 4. FAKE-LIMITED DECLARES THE TABLE NOT_YET, and refuses a table graph.
# 5. A CHANGED KEY IS REFUSED on aws, gcp and generic: after an apply, a
#    plan and an apply asking for another key are refused naming the old and
#    the new key, and mutate nothing; the stored key again is all NOOP.
# 6. A KEPT TABLE OUTLIVES A DESTROY: a table with the default retention is
#    skipped by destroy and keeps its `kci-retention=retain` mark.
# 7. GCP REFUSES TWO INDEX NAMES WHOSE ROLES COLLIDE (`ix5155` and `ix8061`
#    are both `ix-5upe7`) as a limit, before anything is created; aws, whose
#    indexes are fields, lowers the same file.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    Provenance,
    VERB_NOOP,
)
from kci_cloud import (
    FIELD_TABLE,
    NOT_YET,
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    LoweredNode,
    apply_resources,
    describe,
    destroy_resources,
    lower_data,
    lowering_json,
    plan_resources,
    retention_name,
    run_conformance,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, FakeLimitedCloud, ProviderShape


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


comptime _KEY_TWO = (
    '{"name":"pk","partition":{"name":"customer","type":"STRING"},'
    '"order":{"name":"placed","type":"NUMBER"}}'
)
comptime _KEY_ONE = '{"name":"pk","partition":{"name":"customer","type":"STRING"}}'
comptime _INDEXES = (
    '[{"name":"by-state","partition":{"name":"state","type":"STRING"},'
    '"order":{"name":"placed","type":"NUMBER"}},'
    '{"name":"by-sku","partition":{"name":"sku","type":"BYTES"}}]'
)


def _graph(
    port: String = String("8080"),
    uses: Bool = True,
    ttl: Bool = True,
    retention: String = String(""),
    key: String = String(_KEY_TWO),
    indexes: String = String(_INDEXES),
) -> String:
    var u = String('"uses":[{"target":{"resource":"orders"},"access":"READ_WRITE"}]')
    if not uses:
        u = String('"uses":[]')
    var ret = String("")
    if retention.byte_length() > 0:
        ret = String('"retention":"') + retention + String('",')
    var t = String("")
    if ttl:
        t = String(',"ttlField":"expires"')
    return (
        String('{"resource":[')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":') + port
        + String(',"internal":{},"scale":{"min":1,"max":2},"env":{"ORDERS":{"ref":{"resource":"orders","standard":"NAME"}}}},')
        + u + String("},")
        + String('{"id":"orders",') + ret + String('"table":{"key":') + key
        + String(',"indexes":') + indexes + t + String("}}")
        + String("]}")
    )


# ---- 1. a golden lowering per shape ------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per node: id, kind, wanted (+ or -), retention, dependencies,
    and every desired field of the table's nodes."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
        s += n.id + String(" ") + n.kind + String(" ") + (String("+") if n.wanted else String("-"))
        s += String(" ") + retention_name(n.retention)
        for k in range(len(n.depends_on)):
            s += (String(" <") if k == 0 else String(",")) + n.depends_on[k]
        if n.owner == "orders":
            s += String(" {")
            for k in range(len(n.desired)):
                if k > 0:
                    s += String(";")
                s += n.desired[k].key + String("=") + n.desired[k].value
            s += String("}")
        s += String("\n")
    return s^


def _lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-3t"), shape=shape.copy())
    var got = _summary(lower_data(cloud, _list(_graph())))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


comptime _ONE_NODE_TABLE = (
    "key=customer:STRING/placed:NUMBER;index.by-state=state:STRING/placed:NUMBER;"
    "index.by-sku=sku:BYTES;ttl=expires;named=true}\n"
)


def _api(identity: String, run: String, public: String, data_grant: String, grant: String) -> String:
    var s = String("api/identity ") + identity + String(" + delete\n")
    s += String("api/run ") + run + String(" + delete <api/identity\n")
    if public.byte_length() > 0:
        s += String("api/public ") + public + String(" - delete <api/run\n")
    s += String("api/u-zuukgx ") + data_grant + String(" + delete <api/identity,orders/table\n")
    s += String("api/u-gktqg5 ") + grant + String(" + delete <api/identity\n")
    return s^


def test_golden_lowering_per_shape() raises:
    var generic = _api(
        String("identity"), String("run"), String("public"), String("grant"), String("grant")
    ) + String("orders/table table + keep {") + String(_ONE_NODE_TABLE)
    assert_equal(_lowered(ProviderShape.generic()), generic, "generic")

    var aws = _api(
        String("AWS::IAM::Role"),
        String("AWS::Lambda::Function"),
        String("AWS::Lambda::Url"),
        String("AWS::IAM::RolePolicy"),
        String("AWS::IAM::RolePolicy"),
    ) + String("orders/table AWS::DynamoDB::Table + keep {") + String(_ONE_NODE_TABLE)
    assert_equal(_lowered(ProviderShape.aws()), aws, "aws")

    var gcp = (
        _api(
            String("iam.googleapis.com/ServiceAccount"),
            String("run.googleapis.com/Service"),
            String("setIamPolicy"),
            String("setIamPolicy"),
            String("setIamPolicy"),
        )
        + String("orders/table firestore.googleapis.com/Index + keep {key=customer:STRING/placed:NUMBER;named=true}\n")
        + String("orders/ix-4cad7 firestore.googleapis.com/Index + keep {index=by-state;path=state:STRING/placed:NUMBER}\n")
        + String("orders/ix-ffjrg firestore.googleapis.com/Index + keep {index=by-sku;path=sku:BYTES}\n")
        + String("orders/ttl firestore.googleapis.com/Field + keep <orders/table {ttl=expires}\n")
    )
    assert_equal(_lowered(ProviderShape.gcp()), gcp, "gcp")

    var azure = _api(
        String("Microsoft.ManagedIdentity/userAssignedIdentities"),
        String("Microsoft.App/containerApps"),
        String(""),
        String("Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments"),
        String("Microsoft.Authorization/roleAssignments"),
    ) + String("orders/table Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers + keep {") + String(
        _ONE_NODE_TABLE
    )
    assert_equal(_lowered(ProviderShape.azure()), azure, "azure")

    # The generic lowering of the table alone, as JSON.
    var cloud = FakeCloud()
    var table_only = _list(
        String('{"resource":[{"id":"orders","table":{"key":') + String(_KEY_ONE) + String("}}]}")
    )
    assert_equal(
        lowering_json(lower_data(cloud, table_only)),
        String('[\n  {"id":"orders/table","owner":"orders","kind":"table","wanted":true,')
        + String('"retention":"keep","depends_on":[],"inputs":[],')
        + String('"desired":{"key":"customer:STRING","ttl":"none","named":"true"}}\n]'),
    )
    print("  test_golden_lowering_per_shape: PASS")


# ---- 2. the kit on every shape that hosts a table --------------------------------------------


def test_the_kit_on_every_shape_that_hosts_a_table() raises:
    var shapes = List[ProviderShape]()
    shapes.append(ProviderShape.generic())
    shapes.append(ProviderShape.aws())
    shapes.append(ProviderShape.gcp())
    shapes.append(ProviderShape.azure())
    var ids = List[String]()
    ids.append(String("p-e1"))
    ids.append(String("p-5f9c02"))
    ids.append(String("p-a7d4"))
    ids.append(String("p-30bb"))
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shapes[s].copy())))
        var cloud = FakeCloud(ids[s], shape=shapes[s].copy())
        var d = String("DELETE")
        try:
            run_conformance(
                reg,
                cloud,
                _ctx(),
                _list(_graph(retention=d)),
                _list(_graph(String("9090"), retention=d)),
                _list(_graph(String("9090"), uses=False, ttl=False, retention=d)),
                String("orders/table"),
            )
        except e:
            raise Error(shapes[s].name + String(" shape: ") + String(e))
    print("  test_the_kit_on_every_shape_that_hosts_a_table: PASS")


# ---- 3. onprem declares the table NOT_YET ----------------------------------------------------


def test_onprem_refuses_a_table_naming_q17() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-onp"), shape=ProviderShape.onprem())))
    reg.add(describe(FakeCloud(String("p-aws"), shape=ProviderShape.aws())))
    var cloud = FakeCloud(String("p-onp"), shape=ProviderShape.onprem())
    assert_true(not cloud.complete(), "a cloud with a NOT_YET type is not complete")
    var absent = cloud.absences()
    assert_equal(
        len(absent),
        12,
        "the table, the three messaging types (test_fake_messaging), the three name types (test_fake_dns), the"
        + " event trigger (test_fake_triggers), the three network types (test_fake_network) and the registry"
        + " (test_fake_registry)",
    )
    assert_equal(absent[0].field, FIELD_TABLE)
    assert_equal(absent[0].kind, NOT_YET)
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st)
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "p-onp". Nothing was created.\n')
            + String('  resource "orders": table (PORTABLE): no adapter in cloud "p-onp" (NOT_YET: ')
            + String("the onprem datastore that backs a table is an open question (Q17: PostgreSQL")
            + String(" via CloudNativePG, CockroachDB, ScyllaDB or FoundationDB))\n")
            + String("      clouds built into this kci that implement it: p-aws"),
        )
    assert_true(raised, "a table is refused on onprem")
    assert_equal(cloud.mutations(), 0, "nothing was created")
    print("  test_onprem_refuses_a_table_naming_q17: PASS")


# ---- 4. fake-limited declares the table NOT_YET ------------------------------------------------


def test_fake_limited_declares_the_table_not_yet() raises:
    var limited = FakeLimitedCloud()
    var found = False
    var absent = limited.absences()
    for i in range(len(absent)):
        if absent[i].field == FIELD_TABLE:
            found = True
            assert_equal(absent[i].kind, NOT_YET)
    assert_true(found, "fake-limited declares table NOT_YET")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeLimitedCloud()))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(
            reg,
            limited,
            _ctx(),
            _list(String('{"resource":[{"id":"orders","table":{"key":') + String(_KEY_ONE) + String("}}]}")),
            Creds.none(),
            st,
        )
    except e:
        raised = True
        assert_true(String(e).find("table (PORTABLE): no adapter") >= 0, String(e))
        assert_true(String(e).find("fake-limited has no tables") >= 0, String(e))
    assert_true(raised, "a table graph is refused on fake-limited")
    assert_equal(limited.mutations(), 0)
    print("  test_fake_limited_declares_the_table_not_yet: PASS")


# ---- 5. a changed key is refused ---------------------------------------------------------------


def test_a_changed_key_is_refused() raises:
    var shapes = List[ProviderShape]()
    shapes.append(ProviderShape.generic())
    shapes.append(ProviderShape.aws())
    shapes.append(ProviderShape.gcp())
    for s in range(len(shapes)):
        var name = shapes[s].name.copy()
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(String("p-k"), shape=shapes[s].copy())))
        var cloud = FakeCloud(String("p-k"), shape=shapes[s].copy())
        var st = InMemoryStateStore()
        _ = _done(apply_resources(reg, cloud, _ctx(), _list(_graph(key=String(_KEY_ONE))), Creds.none(), st))
        var before = cloud.mutations()
        var refused = 0
        try:
            _ = plan_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st)
        except e:
            refused += 1
            var t = String(e)
            assert_true(t.find('resource "orders" field table.key') >= 0, name + ": " + t)
            assert_true(
                t.find("the key changed from customer:STRING to customer:STRING/placed:NUMBER") >= 0,
                name + ": " + t,
            )
        try:
            _ = apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st)
        except e:
            refused += 1
            assert_true(String(e).find("a new key is a new table") >= 0, name + ": " + String(e))
        assert_equal(refused, 2, name + ": the plan and the apply are refused")
        assert_equal(cloud.mutations(), before, name + ": nothing was mutated")
        var again = plan_resources(reg, cloud, _ctx(), _list(_graph(key=String(_KEY_ONE))), Creds.none(), st)
        for i in range(len(again)):
            assert_equal(again[i].verb, VERB_NOOP, name + ": the stored key again: " + again[i].logical_id)
    print("  test_a_changed_key_is_refused: PASS")


# ---- 6. a kept table outlives a destroy -----------------------------------------------------------


def test_a_kept_table_outlives_a_destroy() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var graph = _list(_graph())
    _ = _done(apply_resources(reg, cloud, _ctx(), graph, Creds.none(), st))
    _ = destroy_resources(reg, cloud, _ctx(), graph, Creds.none(), st)
    var labels = cloud.live_labels(String("orders/table"))
    var kept = False
    for i in range(len(labels)):
        if labels[i].key == "kci-retention" and labels[i].value == "retain":
            kept = True
    assert_true(kept, "the table is still there, marked kci-retention=retain")
    assert_equal(cloud.live_count(), 1, "everything else was destroyed")
    print("  test_a_kept_table_outlives_a_destroy: PASS")


# ---- 7. gcp refuses colliding index roles -----------------------------------------------------------


def test_gcp_refuses_colliding_index_roles() raises:
    var clash = String(
        '[{"name":"ix5155","partition":{"name":"a","type":"STRING"}},'
        '{"name":"ix8061","partition":{"name":"b","type":"STRING"}}]'
    )
    var graph = _list(_graph(indexes=clash))
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-g"), shape=ProviderShape.gcp())))
    reg.add(describe(FakeCloud(String("p-a"), shape=ProviderShape.aws())))
    var gcp = FakeCloud(String("p-g"), shape=ProviderShape.gcp())
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, gcp, _ctx(), graph, Creds.none(), st)
    except e:
        raised = True
        assert_true(
            String(e).find('index "ix8061" has the role ix-5upe7 of an earlier index') >= 0, String(e)
        )
    assert_true(raised, "gcp refuses two index roles that collide")
    assert_equal(gcp.mutations(), 0)
    var aws = FakeCloud(String("p-a"), shape=ProviderShape.aws())
    var st = InMemoryStateStore()
    _ = _done(apply_resources(reg, aws, _ctx(), graph, Creds.none(), st))
    print("  test_gcp_refuses_colliding_index_roles: PASS")


def main() raises:
    print("test_fake_table")
    test_golden_lowering_per_shape()
    test_the_kit_on_every_shape_that_hosts_a_table()
    test_onprem_refuses_a_table_naming_q17()
    test_fake_limited_declares_the_table_not_yet()
    test_a_changed_key_is_refused()
    test_a_kept_table_outlives_a_destroy()
    test_gcp_refuses_colliding_index_roles()
    print("ALL kci_cloud_fake TABLE TESTS PASSED")
