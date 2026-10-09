# =============================================================================
# test_fake_validation_run_tag.mojo
# =============================================================================
#
# The validation-run tag and the retention mark on the fake clouds: every
# object an apply CREATES in a scope with a validation run id carries
# `kci-run-id=<id>`, and every object carries `kci-retention=<retain|delete>`,
# the keys, values and id rule being komira_validation_run's. Every test runs
# the same code on every fake cloud (the generic, aws, gcp, azure and onprem
# shapes of `FakeCloud`, and `FakeLimitedCloud`): a cloud is a value here,
# never a name to branch on. The fakes have no composite resources; "every
# depth" is every node of the lowering, nested roles included (`<id>/u-<h>`,
# onprem's `<id>/r-<h>`, gcp's table nodes `<id>/ix-<h>` and `<id>/ttl`).
#
# 1. CREATED UNDER A RUN: on a graph holding every catalog type the cloud
#    hosts (checked against `implemented()`, so a type the lowering skipped
#    is seen) with a KEEP bucket, a default-KEEP table and a queue, a topic
#    and a subscription (where hosted), a default-KEEP secret, a zone, a
#    CNAME and a certificate (where hosted; gcp adds the certificate's DNS
#    authorization and its record), a schedule that starts the container
#    job, an event trigger on the DELETE bucket (where hosted), a network, a
#    subnet of it and an IP address (where hosted), a registry (where
#    hosted) and a DELETE
#    bucket, every wanted node's live object carries exactly one
#    run-id label, with the key `validation_run_tag_key("kci")` (spelled
#    `kci-run-id`) and the run id verbatim, and exactly one retention mark
#    with `resource_retention_tag_key("kci")` and `retention_tag_value` of
#    the node's retention (`retain` and `delete` both seen); every resource
#    owns at least one checked node (except a gcp subscription, which has no
#    object: its one node is turned off, and a schedule an azure or onprem
#    job holds as its own setting: its nodes are turned off and the job's
#    run carries it); `list_owned` reports the same id for
#    every object; the provenance run id is a different value and does not
#    leak into the tag. Catches: the create path dropping the tag or the
#    mark, a second spelling of a key, the provenance id written instead, a
#    KEEP object created under a run with no `retain` mark (a leak checker
#    would delete it).
# 2. OUTSIDE A RUN: no object carries a run-id label (not an empty one, not a
#    default) and `list_owned` reports None; the retention mark is still
#    there. Catches: a create path that stamps unconditionally, which would
#    let a cleanup claim a production object.
# 3. AN INVALID ID IS REFUSED BEFORE ANY CREATE: empty, uppercase, 64 bytes,
#    `/`, `.`: the plan and the apply raise the one refusal text naming
#    `validation_run_id`, and the cloud served no call. A destroy under an
#    invalid id is NOT refused (it writes no tag; a cleanup is never blocked
#    by a mark it does not write) and deletes the cell's objects. A 63-byte
#    id holding `_` is accepted and stamped verbatim (the node-id `/` -> `_`
#    encoding is not applied to it). Below kci_cloud's verbs,
#    `create_labels` itself raises on an invalid id, so an engine driven
#    directly cannot stamp one. Catches: the refusal moving after the first
#    create, a rewrite, a destroy blocked by a typo.
# 4. THE TAG SAYS WHO CREATED IT: a later run under another id updates an
#    object and leaves its tag as the creator's; the objects that later run
#    creates carry its own id. Catches: an update rewriting the tag.
# 5. AN ADOPTED OBJECT CARRIES NO TAG: an object made outside kci and adopted
#    by name under a validation run is stamped with the identity and the
#    retention mark and no run id; the objects the run created carry it.
#    Catches: adoption claiming an object the run did not create.
# 6. THE KIT UNDER A RUN: the kci_cloud conformance kit, whose label steps
#    check the run-id label against the scope and whose step 12 runs its own
#    pass under a run id it picks, passes in a scope with a validation run
#    id.
# 7. THE KEY RULE: `label_problems` accepts the two marks' keys and the
#    `[a-z_]` identity keys, and refuses `-` in any other key, an uppercase
#    or digit-led key and a 64-byte key. Catches: the key rule widened for
#    every key, or narrowed so a mark is refused.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import decode_json
from komira_validation_run.validation_run_tag import (
    RETENTION_TAG_VALUE_DELETE,
    RETENTION_TAG_VALUE_RETAIN,
    VALIDATION_RUN_ID_MAX_LEN,
    is_valid_validation_run_id,
    resource_retention_tag_key,
    validation_run_tag_key,
)
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    Label,
    OwnerStamp,
    Provenance,
    RETAIN_DELETE,
    VERB_CREATE,
    VERB_DELETE,
    VERB_UPDATE,
)
from kci_cloud import (
    FIELD_GRANT,
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    ConformanceTarget,
    FIELD_QUEUE,
    FIELD_DNS_ZONE,
    FIELD_EVENT_TRIGGER,
    FIELD_NETWORK,
    FIELD_REGISTRY,
    FIELD_SCHEDULE,
    FIELD_SUBSCRIPTION,
    FIELD_TABLE,
    LoweredNode,
    OwnedRecord,
    apply_resources,
    body_field,
    create_labels,
    describe,
    destroy_resources,
    label_problems,
    lower_data,
    plan_resources,
    retention_label_value,
    run_conformance,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, FakeLimitedCloud, ProviderShape

comptime _RUN = "vr-7f3a91c2"
"""A legal id that is not a round number: an assertion that cannot tell it
from a default is satisfied by a create that stamps a constant."""
comptime _OTHER_RUN = "ship-0000000001"
comptime _PROVENANCE_RUN = "run-1"


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx(run: Optional[String]) -> CellContext:
    return CellContext(
        CellScope(
            String("shop"),
            String("blue"),
            Provenance(String(_PROVENANCE_RUN), String("rev-1")),
            validation_run_id=run,
        )
    )


def _run(id: String) -> Optional[String]:
    return Optional[String](id)


def _key() raises -> String:
    return validation_run_tag_key(String("kci"))


comptime _TABLE = (
    '{"id":"orders","table":{"key":{"name":"pk","partition":{"name":"customer","type":"STRING"},'
    '"order":{"name":"placed","type":"NUMBER"}},'
    '"indexes":[{"name":"by-state","partition":{"name":"state","type":"STRING"}}],'
    '"ttlField":"expires"}}'
)
"""A table with the default retention (KEEP), an index and a TTL field: gcp
lowers it to `orders/table`, `orders/ix-<h>` and `orders/ttl`."""

comptime _MESSAGING = (
    '{"id":"jobs","queue":{}},{"id":"news","topic":{}},'
    '{"id":"news-jobs","subscription":{"topic":{"resource":"news"},"queue":{"resource":"jobs"}}}'
)
"""A queue, a topic and the subscription between them: aws adds the
queue's `jobs/policy`; gcp lowers the queue as `jobs/topic` (turned off:
the queue is fed) and `jobs/queue`, and the subscription's one node turned
off."""

comptime _NAMES = (
    '{"id":"site","dnsZone":{"name":"example.com"}},'
    '{"id":"www","dnsRecord":{"name":"www.example.com","zone":{"resource":"site"},"type":"CNAME",'
    '"values":[{"ref":{"resource":"api","standard":"HOST"}}]}},'
    '{"id":"tls","certificate":{"domains":["example.com"],"zone":{"resource":"site"}}}'
)
"""A zone, a CNAME that follows `api`'s HOST, and a certificate: gcp adds
`tls/dnsauth` and `tls/authrec`."""

comptime _NETWORKS = (
    '{"id":"core","network":{"ipv4Cidr":"10.20.0.0/16"}},'
    '{"id":"edge","subnet":{"network":{"resource":"core"},"ipv4Cidr":"10.20.4.0/24","zone":1}},'
    '{"id":"ingress-ip","ipAddress":{}}'
)
"""A network, a subnet of it (in a zone, which aws needs) and an IP
address, each with the default retention (DELETE)."""

comptime _REGISTRY = '{"id":"images","registry":{"format":"OCI"}}'
"""A registry with the default retention (KEEP)."""


def _full(
    api_port: String,
    roles_on: Bool = True,
    kept: Bool = False,
    table: Bool = False,
    messaging: Bool = False,
    secret: Bool = False,
    names: Bool = False,
    schedule: Bool = False,
    events: Bool = False,
    networks: Bool = False,
    registry: Bool = False,
    derived: Bool = False,
) -> String:
    """A public service with a `uses` grant, an internal service reading its
    URL (each keeping one instance, as onprem requires until Q21), a
    container job running as an account, an account, a grant resource, a
    worker with its own identity and a DELETE bucket. `kept` adds a bucket with the default
    retention (KEEP); `table` adds `_TABLE`; `messaging` adds `_MESSAGING`;
    `secret` adds a secret with the default retention (KEEP); `names` adds
    `_NAMES`; `schedule` adds a schedule that starts `nightly`; `events`
    adds an event trigger delivering `store`'s new objects to `api`;
    `networks` adds `_NETWORKS`; `registry` adds `_REGISTRY`.
    `roles_on` False makes api
    internal and removes web's grant on api. `derived`: the graph a shape
    whose grants are DERIVED reads: the grant `see` written as `uses runner
    DESCRIBE` on web (kept when the roles are off)."""
    var see = String('{"target":{"resource":"runner"},"access":"DESCRIBE"}')
    var call = String('{"target":{"resource":"api"},"access":"CALL"}')
    var web_uses = String('"uses":[') + call + ((String(",") + see) if derived else String("")) + String("]},")
    var exposure = String('"public":{}')
    if not roles_on:
        web_uses = String('"uses":[') + (see if derived else String("")) + String("]},")
        exposure = String('"internal":{}')
    var grant = String('{"id":"see","grant":{"principal":{"resource":"web"},')
    grant += String('"target":{"resource":"runner"},"access":"DESCRIBE"}},')
    if derived:
        grant = String("")
    return (
        String('{"resource":[')
        + String('{"id":"web","service":{"image":{"digest":"sha256:c3"},"port":8080,"internal":{},')
        + String('"scale":{"min":1,"max":2},"env":{"API_URL":{"ref":{"resource":"api","standard":"URL"}}}},')
        + web_uses
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":')
        + api_port
        + String(",")
        + exposure
        + String(',"scale":{"min":1,"max":3}},')
        + String('"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]},')
        + String('{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"},')
        + String('"runAs":{"resource":"runner"}}},')
        + String('{"id":"runner","serviceAccount":{}},')
        + grant
        + String('{"id":"relay","worker":{"image":{"digest":"sha256:d4"},"command":["/bin/relay"],"replicas":2}},')
        + String('{"id":"store","retention":"DELETE","bucket":{"versioning":true}}')
        + (String(',{"id":"vault","bucket":{}}') if kept else String(""))
        + ((String(",") + String(_TABLE)) if table else String(""))
        + ((String(",") + String(_MESSAGING)) if messaging else String(""))
        + (String(',{"id":"creds","secret":{}}') if secret else String(""))
        + ((String(",") + String(_NAMES)) if names else String(""))
        + (String(',{"id":"tick","schedule":{"cron":"0 3 * * *","target":{"resource":"nightly"}}}') if schedule else String(""))
        + (
            String(',{"id":"on-store","eventTrigger":{"source":{"resource":"store"},"event":"OBJECT_CREATED",')
            + String('"target":{"resource":"api"}}}') if events else String("")
        )
        + ((String(",") + String(_NETWORKS)) if networks else String(""))
        + ((String(",") + String(_REGISTRY)) if registry else String(""))
        + String("]}")
    )


def _hosts_table[S: ConformanceTarget](cloud: S) -> Bool:
    var l = cloud.implemented()
    for i in range(len(l)):
        if l[i] == FIELD_TABLE:
            return True
    return False


def _hosts_messaging[S: ConformanceTarget](cloud: S) -> Bool:
    var l = cloud.implemented()
    for i in range(len(l)):
        if l[i] == FIELD_QUEUE:
            return True
    return False


def _hosts_events[S: ConformanceTarget](cloud: S) -> Bool:
    var l = cloud.implemented()
    for i in range(len(l)):
        if l[i] == FIELD_EVENT_TRIGGER:
            return True
    return False


def _hosts_networks[S: ConformanceTarget](cloud: S) -> Bool:
    var l = cloud.implemented()
    for i in range(len(l)):
        if l[i] == FIELD_NETWORK:
            return True
    return False


def _hosts_registry[S: ConformanceTarget](cloud: S) -> Bool:
    var l = cloud.implemented()
    for i in range(len(l)):
        if l[i] == FIELD_REGISTRY:
            return True
    return False


def _hosts_names[S: ConformanceTarget](cloud: S) -> Bool:
    var l = cloud.implemented()
    for i in range(len(l)):
        if l[i] == FIELD_DNS_ZONE:
            return True
    return False


def _limited(api_port: String) -> String:
    """What fake-limited hosts: one internal service (with its identity and
    its cell LOGS grant `api/u-<h>`)."""
    return (
        String('{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":')
        + api_port
        + String(',"internal":{}}}]}')
    )


def _shapes() -> List[ProviderShape]:
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    l.append(ProviderShape.onprem())
    return l^


def _reg() raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    reg.add(describe(FakeLimitedCloud()))
    return reg^


def _reg_for(cloud: FakeCloud) raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    return reg^


def _ok(outcome: ApplyOutcome, what: String) raises:
    if outcome.error:
        raise Error(what + String(": the apply stopped: ") + outcome.error.value())


def _run_labels(labels: List[Label], key: String) -> List[String]:
    """Every value of a label whose key is the run-id key, or that names a
    run id at all (so a second spelling is seen too)."""
    var out = List[String]()
    for i in range(len(labels)):
        if labels[i].key == key or _has(labels[i].key, "run-id") or _has(labels[i].key, "run_id"):
            out.append(labels[i].value.copy())
    return out^


def _tag_of[S: ConformanceTarget](cloud: S, id: String) raises -> String:
    """The run-id label of node `id`'s live object; "(none)" when it has
    none; raises when it has more than one."""
    var vals = _run_labels(cloud.live_labels(id), _key())
    if len(vals) == 0:
        return String("(none)")
    if len(vals) > 1:
        raise Error(id + String(" carries ") + String(len(vals)) + String(" run-id labels"))
    return vals[0].copy()


def _mark(labels: List[Label]) raises -> String:
    """The one `kci-retention` value of `labels`; "(none)" when absent;
    raises on two."""
    var key = resource_retention_tag_key(String("kci"))
    var got = String("(none)")
    var n = 0
    for i in range(len(labels)):
        if labels[i].key == key:
            got = labels[i].value.copy()
            n += 1
    if n > 1:
        raise Error(String(n) + String(" retention marks"))
    return got^


def _record_run(rec: OwnedRecord) -> String:
    if rec.validation_run_id:
        return rec.validation_run_id.value().copy()
    return String("(none)")


def _check_every_node[
    S: ConformanceTarget
](
    mut cloud: S,
    nodes: List[LoweredNode],
    want: String,
    where: String,
) raises -> Int:
    """Every wanted node of `nodes` carries `want` ("(none)": no label) and
    its retention mark, and so does every `list_owned` record. Returns the
    wanted count."""
    var wanted = 0
    for k in range(len(nodes)):
        if not nodes[k].wanted:
            continue
        wanted += 1
        var got = _tag_of(cloud, nodes[k].id)
        assert_equal(got, want, where + String(": ") + nodes[k].id + String(" live label"))
        assert_equal(
            _mark(cloud.live_labels(nodes[k].id)),
            retention_label_value(nodes[k].retention),
            where + String(": ") + nodes[k].id + String(" retention mark"),
        )
    var owned = cloud.list_owned(Creds.none(), _ctx(None).scope)
    assert_equal(len(owned), wanted, where + String(": list_owned names every object"))
    for i in range(len(owned)):
        assert_equal(_record_run(owned[i]), want, where + String(": ") + owned[i].owner_node + String(" record"))
        assert_equal(owned[i].run_id, _PROVENANCE_RUN, where + String(": provenance is reported apart"))
    return wanted


def _apply_and_check[
    S: ConformanceTarget
](mut cloud: S, json: String, run: Optional[String], want: String, where: String) raises -> Int:
    var reg = _reg()
    var store = InMemoryStateStore()
    var resources = _list(json)
    _ok(apply_resources(reg, cloud, _ctx(run), resources, Creds.none(), store), where)
    return _check_every_node(cloud, lower_data(cloud, resources), want, where)


# ---- 1. created under a run --------------------------------------------------------


def _covers_every_hosted_type[
    S: ConformanceTarget
](cloud: S, resources: List[Resource], nodes: List[LoweredNode], where: String, derived: Bool = False) raises:
    """The graph holds exactly the types `cloud` hosts, and every resource
    owns at least one wanted node (so each type's nodes were checked). On a
    shape whose grants are DERIVED (`derived`, read from the shape) a grant
    resource is refused, so the graph holds none and `grant` is not
    counted."""
    var hosted = List[Int]()
    var all = cloud.implemented()
    for k in range(len(all)):
        if not (derived and all[k] == FIELD_GRANT):
            hosted.append(all[k])
    var used = List[Int]()
    for i in range(len(resources)):
        var f = body_field(resources[i])
        var seen = False
        for k in range(len(used)):
            if used[k] == f:
                seen = True
        if not seen:
            used.append(f)
        var owns = False
        var off = False
        for k in range(len(nodes)):
            if nodes[k].owner == resources[i].id:
                if nodes[k].wanted:
                    owns = True
                else:
                    off = True
        # A subscription with no object of its own (gcp: it is the topic its
        # queue's subscription is on) lowers one node, turned off; so does a
        # schedule its job holds as a setting (azure, onprem) lower its nodes.
        assert_true(
            owns or ((f == FIELD_SUBSCRIPTION or f == FIELD_SCHEDULE) and off),
            where + String(": ") + resources[i].id + String(" owns a checked node"),
        )
    assert_equal(len(used), len(hosted), where + String(": one resource per hosted type"))
    for k in range(len(hosted)):
        var found = False
        for i in range(len(used)):
            if used[i] == hosted[k]:
                found = True
        assert_true(found, where + String(": hosted type ") + String(hosted[k]) + String(" is in the graph"))


def _both_marks_seen[S: ConformanceTarget](cloud: S, nodes: List[LoweredNode], where: String) raises:
    var retain = 0
    var delete = 0
    for k in range(len(nodes)):
        if not nodes[k].wanted:
            continue
        var m = _mark(cloud.live_labels(nodes[k].id))
        if m == RETENTION_TAG_VALUE_RETAIN:
            retain += 1
        elif m == RETENTION_TAG_VALUE_DELETE:
            delete += 1
    assert_true(retain >= 1, where + String(": a KEEP node is marked retain"))
    assert_true(delete >= 1, where + String(": a DELETE node is marked delete"))


def test_every_object_created_under_a_run_carries_the_tag_on_every_cloud() raises:
    assert_equal(_key(), "kci-run-id", "the key is komira_validation_run's, for the prefix kci")
    assert_equal(resource_retention_tag_key(String("kci")), "kci-retention")
    assert_true(is_valid_validation_run_id(String(_RUN)))
    assert_true(String(_RUN) != String(_PROVENANCE_RUN))
    var shapes = _shapes()
    for s in range(len(shapes)):
        var cloud = FakeCloud(shape=shapes[s].copy())
        var where = shapes[s].name
        var json = _full(
            "8080",
            kept=True,
            table=_hosts_table(cloud),
            messaging=_hosts_messaging(cloud),
            secret=True,
            names=_hosts_names(cloud),
            schedule=True,
            events=_hosts_events(cloud),
            networks=_hosts_networks(cloud),
            registry=_hosts_registry(cloud),
            derived=shapes[s].grants_derived(),
        )
        _ = _apply_and_check(cloud, json, _run(String(_RUN)), String(_RUN), where)
        var resources = _list(json)
        var nodes = lower_data(cloud, resources)
        _covers_every_hosted_type(cloud, resources, nodes, where, shapes[s].grants_derived())
        _both_marks_seen(cloud, nodes, where)
        if _hosts_table(cloud):
            assert_equal(_mark(cloud.live_labels(String("orders/table"))), "retain", where + ": a default table")
        if _hosts_registry(cloud):
            assert_equal(_mark(cloud.live_labels(String("images/registry"))), "retain", where + ": a default registry")
    var limited = FakeLimitedCloud()
    var n = _apply_and_check(limited, _limited("8080"), _run(String(_RUN)), String(_RUN), String("fake-limited"))
    assert_equal(n, 3, "fake-limited: identity, run and the cell LOGS grant")
    var lres = _list(_limited("8080"))
    _covers_every_hosted_type(limited, lres, lower_data(limited, lres), String("fake-limited"))
    print("  test_every_object_created_under_a_run_carries_the_tag_on_every_cloud: PASS")


# ---- 2. outside a run --------------------------------------------------------------


def test_outside_a_run_no_object_carries_a_tag() raises:
    var shapes = _shapes()
    for s in range(len(shapes)):
        var cloud = FakeCloud(shape=shapes[s].copy())
        var json = _full(
            "8080",
            kept=True,
            table=_hosts_table(cloud),
            messaging=_hosts_messaging(cloud),
            secret=True,
            names=_hosts_names(cloud),
            derived=shapes[s].grants_derived(),
        )
        _ = _apply_and_check(cloud, json, None, String("(none)"), shapes[s].name)
    var limited = FakeLimitedCloud()
    _ = _apply_and_check(limited, _limited("8080"), None, String("(none)"), String("fake-limited"))
    print("  test_outside_a_run_no_object_carries_a_tag: PASS")


# ---- 3. an invalid id is refused before any create -----------------------------------


def _bad_ids() -> List[String]:
    var l = List[String]()
    l.append(String(""))
    l.append(String("Vr-1"))
    var long = String("")
    for _ in range(VALIDATION_RUN_ID_MAX_LEN + 1):
        long += String("a")
    l.append(long^)
    l.append(String("vr/1"))
    l.append(String("vr.1"))
    return l^


def _refused_before_any_create[
    S: ConformanceTarget
](mut cloud: S, json: String, bad: String, where: String) raises:
    var reg = _reg()
    var store = InMemoryStateStore()
    var what = where + String(" id \"") + bad + String("\"")
    assert_false(is_valid_validation_run_id(bad), what + String(" is invalid by the rule"))
    var planned = False
    try:
        _ = plan_resources(reg, cloud, _ctx(_run(bad)), _list(json), Creds.none(), store)
        planned = True
    except e:
        assert_true(_has(String(e), "validation_run_id"), what + String(": ") + String(e))
        assert_true(_has(String(e), "Nothing was created"), what + String(": ") + String(e))
    assert_false(planned, what + String(": the plan was refused"))
    var applied = False
    try:
        _ = apply_resources(reg, cloud, _ctx(_run(bad)), _list(json), Creds.none(), store)
        applied = True
    except e:
        assert_true(_has(String(e), "validation_run_id"), what + String(": ") + String(e))
    assert_false(applied, what + String(": the apply was refused"))
    assert_equal(cloud.mutations(), 0, what + String(": the cloud served no call"))
    assert_equal(cloud.live_count(), 0, what + String(": nothing exists"))


def test_an_invalid_run_id_is_refused_before_any_create() raises:
    var bad = _bad_ids()
    var shapes = _shapes()
    for b in range(len(bad)):
        for s in range(len(shapes)):
            var cloud = FakeCloud(shape=shapes[s].copy())
            _refused_before_any_create(cloud, _full("8080"), bad[b], shapes[s].name)
        var limited = FakeLimitedCloud()
        _refused_before_any_create(limited, _limited("8080"), bad[b], String("fake-limited"))

    # A destroy under an invalid id is not refused: it writes no tag.
    for s in range(len(shapes)):
        var reg = _reg()
        var cloud = FakeCloud(shape=shapes[s].copy())
        var store = InMemoryStateStore()
        var graph = _list(_full("8080", derived=shapes[s].grants_derived()))
        _ok(apply_resources(reg, cloud, _ctx(_run(String(_RUN))), graph, Creds.none(), store), shapes[s].name)
        assert_true(cloud.live_count() > 0)
        _ = destroy_resources(reg, cloud, _ctx(_run(String("Vr-1"))), graph, Creds.none(), store)
        assert_equal(cloud.live_count(), 0, shapes[s].name + String(": the destroy under a bad id ran"))

    # The longest legal id, holding `_`: stamped verbatim, never encoded.
    var edge = String("vr_")
    while edge.byte_length() < VALIDATION_RUN_ID_MAX_LEN:
        edge += String("9")
    assert_true(is_valid_validation_run_id(edge))
    var cloud = FakeCloud()
    _ = _apply_and_check(cloud, _full("8080"), _run(edge), edge, String("63-byte id"))

    # Below kci_cloud's verbs: the create labels refuse an invalid id too.
    var stamp = OwnerStamp(
        String("shop"), String("blue"), String("api"), String("run"),
        validation_run_id=_run(String("Vr-1")),
    )
    var raised = False
    try:
        _ = create_labels(stamp, RETAIN_DELETE)
    except e:
        raised = _has(String(e), "validation run id")
    assert_true(raised, "create_labels refuses an invalid id")
    print("  test_an_invalid_run_id_is_refused_before_any_create: PASS")


# ---- 4. the tag says who created it --------------------------------------------------


def _verb(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def test_the_tag_names_the_run_that_created_the_object() raises:
    var shapes = _shapes()
    for s in range(len(shapes)):
        var where = shapes[s].name
        var reg = _reg_for(FakeCloud(shape=shapes[s].copy()))
        var cloud = FakeCloud(shape=shapes[s].copy())
        var store = InMemoryStateStore()
        var d = shapes[s].grants_derived()
        var first = _list(_full("8080", False, derived=d))
        _ok(apply_resources(reg, cloud, _ctx(_run(String(_RUN))), first, Creds.none(), store), where)
        var before = lower_data(cloud, first)
        var created_first = List[String]()
        for k in range(len(before)):
            if before[k].wanted:
                created_first.append(before[k].id.copy())

        var second = _list(_full("9090", True, derived=d))
        var after = lower_data(cloud, second)
        var o = apply_resources(reg, cloud, _ctx(_run(String(_OTHER_RUN))), second, Creds.none(), store)
        _ok(o, where)
        var updated = 0
        var created = 0
        for i in range(len(o.applied)):
            ref a = o.applied[i]
            var mine = False
            for k in range(len(created_first)):
                if created_first[k] == a.logical_id:
                    mine = True
            if a.verb == VERB_CREATE:
                created += 1
                assert_false(mine, where + String(": ") + a.logical_id + String(" re-created"))
                # A member binding (a DERIVED shape's grant) carries no label:
                # it reads the run id of the identity it binds (or, public,
                # of its target), which the first run created.
                var want = String(_OTHER_RUN)
                for k in range(len(after)):
                    if after[k].id == a.logical_id and shapes[s].is_binding(after[k].kind):
                        want = String(_RUN)
                assert_equal(
                    _tag_of(cloud, a.logical_id),
                    want,
                    where + String(": ") + a.logical_id + String(" created by the second run"),
                )
            elif a.verb == VERB_UPDATE and mine:
                updated += 1
                assert_equal(
                    _tag_of(cloud, a.logical_id),
                    _RUN,
                    where + String(": ") + a.logical_id + String(" updated, keeps its creator"),
                )
        assert_true(updated >= 1, where + String(": the second run updated an object the first created"))
        assert_true(created >= 1, where + String(": the second run created objects of its own"))
        # Every object the first run created and the second kept still says so.
        for k in range(len(created_first)):
            if cloud.store[].find(created_first[k]) >= 0:
                assert_equal(_tag_of(cloud, created_first[k]), _RUN, where + String(": ") + created_first[k])
    print("  test_the_tag_names_the_run_that_created_the_object: PASS")


# ---- 5. an adopted object carries no tag ---------------------------------------------


def test_an_adopted_object_carries_no_tag() raises:
    var reg = _reg()
    var foreign = List[String]()
    foreign.append(String("api/run"))
    var cloud = FakeCloud(foreign=foreign)
    var store = InMemoryStateStore()
    var ctx = _ctx(_run(String(_RUN)))
    ctx.scope.adopt.append(String("api/run"))
    var resources = _list(_full("8080"))
    _ok(apply_resources(reg, cloud, ctx, resources, Creds.none(), store), String("adopt"))
    assert_equal(cloud.store[].creates_of(String("api/run")), 0, "adopted, never created")
    assert_equal(_tag_of(cloud, String("api/run")), "(none)", "the run did not create it")
    var nodes = lower_data(cloud, resources)
    var tagged = 0
    for k in range(len(nodes)):
        if not nodes[k].wanted or nodes[k].id == "api/run":
            continue
        assert_equal(_tag_of(cloud, nodes[k].id), _RUN, nodes[k].id)
        tagged += 1
    assert_true(tagged >= 8, "the objects the run created carry it")
    var owned = cloud.list_owned(Creds.none(), ctx.scope)
    for i in range(len(owned)):
        var want = String("(none)") if owned[i].owner_node == "api/run" else String(_RUN)
        assert_equal(_record_run(owned[i]), want, owned[i].owner_node)
    print("  test_an_adopted_object_carries_no_tag: PASS")


# ---- 6. the kit under a run ----------------------------------------------------------


def test_the_kit_passes_under_a_validation_run() raises:
    var cloud = FakeCloud()
    var reg = _reg_for(FakeCloud())
    run_conformance(
        reg, cloud, _ctx(_run(String(_RUN))), _list(_full("8080")), _list(_full("9090")),
        _list(_full("9090", False)), String("api/run"),
    )
    print("  test_the_kit_passes_under_a_validation_run: PASS")


# ---- 7. the key rule ----------------------------------------------------------------


def _problems(key: String) raises -> Int:
    var l = List[Label]()
    l.append(Label(key, String("v")))
    return len(label_problems(l))


def test_the_key_rule_admits_the_two_marks_and_no_other_hyphen() raises:
    assert_equal(_problems(String("kci-run-id")), 0, "the run-id mark")
    assert_equal(_problems(String("kci-retention")), 0, "the retention mark")
    assert_equal(_problems(String("kci_role")), 0, "an identity key")
    assert_equal(_problems(String("kci-other")), 1, "a hyphen outside the two marks")
    assert_equal(_problems(String("-x")), 1, "a leading hyphen")
    assert_equal(_problems(String("1abc")), 1, "a digit")
    assert_equal(_problems(String("Kci_role")), 1, "an uppercase letter")
    var long = String("")
    for _ in range(64):
        long += String("a")
    assert_equal(_problems(long), 1, "a 64-byte key")
    print("  test_the_key_rule_admits_the_two_marks_and_no_other_hyphen: PASS")


def main() raises:
    print("test_fake_validation_run_tag")
    test_every_object_created_under_a_run_carries_the_tag_on_every_cloud()
    test_outside_a_run_no_object_carries_a_tag()
    test_an_invalid_run_id_is_refused_before_any_create()
    test_the_tag_names_the_run_that_created_the_object()
    test_an_adopted_object_carries_no_tag()
    test_the_kit_passes_under_a_validation_run()
    test_the_key_rule_admits_the_two_marks_and_no_other_hyphen()
    print("ALL kci_cloud_fake VALIDATION RUN TAG TESTS PASSED")
