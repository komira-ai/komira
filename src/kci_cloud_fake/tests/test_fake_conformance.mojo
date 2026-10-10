# =============================================================================
# test_fake_conformance.mojo
# =============================================================================
#
# 1. "fake" passes the kci_cloud conformance kit (all twelve steps: label
#    stamping, an idempotent re-apply under a new provenance, the tamper
#    pair, failed then fixed, role removal, destroy of a graph with a
#    reference, foreign refusal and adoption, two interleaved applies, the
#    validation-run tag under the kit's own run id and under none) on a
#    graph with every v1 shape: a public service, an internal service reading
#    the first one's URL and HOST, a container job, and two `Uses` grants;
#    the roles turned off are api's public ingress and web's grant.
# 2. RENAME INVARIANCE: the same kit passes with fake registered under a
#    random id, so nothing above the cloud adapter keyed on the spelling "fake".
# 3. "fake-limited" passes the kit on the graph it can host.
# 4. VALUE FLOW through a real cloud: a dry run on nothing reports the
#    consumer as known after apply; after apply the consumer was created over
#    the producer's real URL and HOST, and a changed producer port is an
#    update for the producer only (its URL does not depend on the port).
# 5. EVERY MODELLED FIELD IS IN THE DIGEST: a container job's `env` and
#    `secret_env` (a reference: store, name, version) are updates when they
#    change;
#    writing the default image platform out is not a change.
# 6. THE FAULTY VARIANT, failure at call k: a cloud call refused mid-apply
#    leaves a PARTIAL outcome (what landed, what is pending); the next apply
#    finishes the graph without re-creating what landed, and the one after is
#    a no-op. (Read lag and a pre-existing foreign object:
#    test_fake_faulty_variant.)
# 7. LOWERING IS DATA: the golden JSON of a small lowering, every modelled
#    field with its default filled in, each private identity, and each
#    identity's implicit cell LOGS WRITE grant (a container job lowers no
#    trigger).
# 8. A DEFAULT WRITTEN OUT IS NOT A CHANGE (port 8080, scale 0..10).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    Provenance,
    ResourceKey,
    VERB_KNOWN_AFTER_APPLY,
    VERB_CREATE,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    apply_resources,
    describe,
    lower_data,
    lowering_json,
    plan_resources,
    run_conformance,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeLimitedCloud, FakeCloud


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    """The applied nodes of an apply that must have finished."""
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _full(api_port: String, roles_on: Bool = True) -> String:
    """`roles_on` False turns two roles off: api's public ingress (api is made
    internal) and web's grant on api."""
    var web_uses = String('"uses":[{"target":{"resource":"api"},"access":"CALL"}]},')
    var exposure = String('"public":{}')
    if not roles_on:
        web_uses = String('"uses":[]},')
        exposure = String('"internal":{}')
    return (
        String('{"resource":[')
        + String('{"id":"web","service":{"image":{"digest":"sha256:c3"},"port":8080,"internal":{},')
        + String('"env":{"API_URL":{"ref":{"resource":"api","standard":"URL"}},')
        + String('"API_HOST":{"ref":{"resource":"api","standard":"HOST"}},')
        + String('"MODE":{"literal":"fast"}}},')
        + web_uses
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":')
        + api_port
        + String(",")
        + exposure
        + String(',"requestTimeout":"30s","scale":{"min":0,"max":3}},')
        + String('"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]},')
        + String('{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"},"maxRetries":1}}')
        + String("]}")
    )


def _limited(api_port: String, roles_on: Bool = True) -> String:
    """`roles_on` False removes web's grant on api (fake-limited has no public
    ingress to turn off)."""
    var web_uses = String('"uses":[{"target":{"resource":"api"},"access":"CALL"}]},')
    if not roles_on:
        web_uses = String('"uses":[]},')
    return (
        String('{"resource":[')
        + String('{"id":"web","service":{"image":{"digest":"sha256:c3"},"internal":{},')
        + String('"env":{"API_URL":{"ref":{"resource":"api","standard":"URL"}}}},')
        + web_uses
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":')
        + api_port
        + String(',"internal":{}}}')
        + String("]}")
    )


def test_fake_passes_the_kit() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var fake = FakeCloud()
    run_conformance(
        reg, fake, _ctx(), _list(_full("8080")), _list(_full("9090")),
        _list(_full("9090", False)), String("api/run"),
    )
    print("  test_fake_passes_the_kit: PASS")


def test_fake_under_a_random_id_passes_the_kit() raises:
    var id = String("p-4b1d9e07")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(id)))
    reg.add(describe(FakeLimitedCloud(String("q-90c2"))))
    var renamed = FakeCloud(id)
    run_conformance(
        reg, renamed, _ctx(), _list(_full("8080")), _list(_full("9090")),
        _list(_full("9090", False)), String("web/run"),
    )
    print("  test_fake_under_a_random_id_passes_the_kit: PASS")


def test_fake_limited_passes_the_kit_on_what_it_hosts() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeLimitedCloud()))
    var limited = FakeLimitedCloud()
    run_conformance(
        reg, limited, _ctx(), _list(_limited("8080")), _list(_limited("9090")),
        _list(_limited("9090", False)), String("api/run"),
    )
    print("  test_fake_limited_passes_the_kit_on_what_it_hosts: PASS")




def test_values_flow_through_fake() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var fake = FakeCloud()
    var creds = Creds.none()
    var store = InMemoryStateStore()

    var plan = plan_resources(reg, fake, _ctx(), _list(_full("8080")), creds, store)
    for i in range(len(plan)):
        if plan[i].logical_id == "web/run":
            assert_equal(plan[i].verb, VERB_KNOWN_AFTER_APPLY, "web reads api's URL")
        elif plan[i].logical_id == "api/run":
            assert_equal(plan[i].verb, VERB_CREATE)

    _ = _done(apply_resources(reg, fake, _ctx(), _list(_full("8080")), creds, store))
    var w = fake.store[].find(String("web/run"))
    var d = fake.store[].digests[w].copy()
    assert_true(_has(d, "|service.env.API_HOST=api.fake"), d)
    assert_true(_has(d, "|service.env.API_URL=fake://api"), d)
    assert_true(_has(d, "|service.env.MODE=fast"), d)
    assert_equal(
        store.outputs_for(ResourceKey(String("shop"), String("blue"), String("api/run")))
        .get(String("URL"))
        .value(),
        "fake://api",
    )

    var again = _done(apply_resources(reg, fake, _ctx(), _list(_full("9090")), creds, store))
    for i in range(len(again)):
        if again[i].logical_id == "api/run":
            assert_equal(again[i].verb, VERB_UPDATE, "the port changed")
        else:
            assert_equal(again[i].verb, VERB_NOOP, again[i].logical_id + " is unaffected")
    print("  test_values_flow_through_fake: PASS")


def _job(env_mode: String, secret_version: String, platform: String) -> String:
    var img = String('"image":{"digest":"sha256:b2"')
    if platform.byte_length() > 0:
        img += String(',"platform":"') + platform + String('"')
    img += String("}")
    return (
        String('{"resource":[{"id":"nightly","containerJob":{')
        + img
        + String(',"env":{"MODE":{"literal":"')
        + env_mode
        + String('"}},"secretEnv":{"TOKEN":{"name":"tok","version":"')
        + secret_version
        + String('"}}}}]}')
    )


def _verb_of(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def test_job_env_and_secrets_are_modelled() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var fake = FakeCloud()
    var creds = Creds.none()
    var store = InMemoryStateStore()
    _ = _done(apply_resources(reg, fake, _ctx(), _list(_job("a", "1", "")), creds, store))
    var i = fake.store[].find(String("nightly/run"))
    var d = fake.store[].digests[i].copy()
    assert_true(_has(d, "|container_job.env.MODE=a"), d)
    assert_true(_has(d, "|container_job.secret_env.TOKEN=tok@1"), d)
    assert_true(_has(d, "@linux/amd64"), d)

    var same = _done(
        apply_resources(reg, fake, _ctx(), _list(_job("a", "1", "linux/amd64")), creds, store)
    )
    assert_equal(
        _verb_of(same, String("nightly/run")),
        VERB_NOOP,
        "writing the default platform out is not a change",
    )
    var env = _done(apply_resources(reg, fake, _ctx(), _list(_job("b", "1", "")), creds, store))
    assert_equal(_verb_of(env, String("nightly/run")), VERB_UPDATE, "a job env change is an update")
    var sec = _done(apply_resources(reg, fake, _ctx(), _list(_job("b", "2", "")), creds, store))
    assert_equal(
        _verb_of(sec, String("nightly/run")), VERB_UPDATE, "a new secret version is an update"
    )
    print("  test_job_env_and_secrets_are_modelled: PASS")


def test_a_fault_mid_apply_is_partial_then_recovers() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    # The second mutating call is refused once.
    var fake = FakeCloud(fail_at_call=2)
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var graph = _list(_full("8080"))
    var first = apply_resources(reg, fake, _ctx(), graph, creds, store)
    assert_true(first.partial(), "one node landed, then the cloud refused a call")
    assert_true(_has(first.error.value(), "fake: injected fault on call 2"), first.error.value())
    var landed_id = String("")
    var created = 0
    for k in range(len(first.landed)):
        if first.landed[k].verb == VERB_CREATE:
            created += 1
            landed_id = first.landed[k].logical_id.copy()
    assert_equal(created, 1, "exactly one create landed")
    assert_true(len(first.pending) >= 1)
    assert_equal(fake.live_count(), 1, "what landed is live, nothing else")

    var second = _done(apply_resources(reg, fake, _ctx(), graph, creds, store))
    for k in range(len(second)):
        if second[k].logical_id == landed_id:
            assert_equal(second[k].verb, VERB_NOOP, landed_id + " is not re-created")
    assert_equal(fake.store[].creates_of(landed_id), 1, "created once")
    var third = _done(apply_resources(reg, fake, _ctx(), graph, creds, store))
    for k in range(len(third)):
        assert_equal(third[k].verb, VERB_NOOP, third[k].logical_id + " settled")
    print("  test_a_fault_mid_apply_is_partial_then_recovers: PASS")


def test_lowering_is_data_golden() raises:
    var fake = FakeCloud()
    var json = String(
        '{"resource":['
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"public":{}}},'
        '{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"}}}'
        "]}"
    )
    var got = lowering_json(lower_data(fake, _list(json)))
    var want = (
        String("[\n")
        + String('  {"id":"api/identity","owner":"api","kind":"identity","wanted":true,"retention":"delete",')
        + String('"depends_on":[],"inputs":[],"desired":{}},\n')
        + String('  {"id":"api/run","owner":"api","kind":"run","wanted":true,"retention":"delete","depends_on":["api/identity"],"inputs":[],')
        + String('"desired":{"img":"sha256:a1@linux/amd64","port":"8080","size":"1000m/512MB","scale":"0..10",')
        + String('"health":"","timeout":"60s0n","concurrency":"0","serves":"true"}},\n')
        + String('  {"id":"api/public","owner":"api","kind":"public","wanted":true,"retention":"delete","depends_on":["api/run"],')
        + String('"inputs":[],"desired":{"mechanism":"invoker"}},\n')
        + String('  {"id":"api/u-gktqg5","owner":"api","kind":"grant","wanted":true,"retention":"delete",')
        + String('"depends_on":["api/identity"],"inputs":[],"desired":{"principal":"api","cell":"LOGS","access":"WRITE"}},\n')
        + String('  {"id":"nightly/identity","owner":"nightly","kind":"identity","wanted":true,"retention":"delete",')
        + String('"depends_on":[],"inputs":[],"desired":{}},\n')
        + String('  {"id":"nightly/run","owner":"nightly","kind":"run","wanted":true,"retention":"delete","depends_on":["nightly/identity"],"inputs":[],')
        + String('"desired":{"img":"sha256:b2@linux/amd64","size":"1000m/512MB","retries":"0",')
        + String('"timeout":"600s0n","serves":"false"}},\n')
        + String('  {"id":"nightly/u-g2ewtg","owner":"nightly","kind":"grant","wanted":true,"retention":"delete",')
        + String('"depends_on":["nightly/identity"],"inputs":[],"desired":{"principal":"nightly","cell":"LOGS","access":"WRITE"}}\n')
        + String("]")
    )
    assert_equal(got, want)
    assert_equal(fake.live_count(), 0, "lowering touched nothing")
    print("  test_lowering_is_data_golden: PASS")


def test_a_default_written_out_is_not_a_change() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var fake = FakeCloud()
    var store = InMemoryStateStore()
    var bare = String('{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{}}}]}')
    var spelled = String(
        '{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1","platform":"linux/amd64"},'
        '"port":8080,"scale":{"min":0,"max":10},"requestTimeout":"60s","internal":{}}}]}'
    )
    _ = _done(apply_resources(reg, fake, _ctx(), _list(bare), Creds.none(), store))
    var again = _done(apply_resources(reg, fake, _ctx(), _list(spelled), Creds.none(), store))
    for k in range(len(again)):
        assert_equal(again[k].verb, VERB_NOOP, again[k].logical_id + ": a default written out")
    print("  test_a_default_written_out_is_not_a_change: PASS")


def main() raises:
    print("test_fake_conformance")
    test_fake_passes_the_kit()
    test_fake_under_a_random_id_passes_the_kit()
    test_fake_limited_passes_the_kit_on_what_it_hosts()
    test_values_flow_through_fake()
    test_job_env_and_secrets_are_modelled()
    test_a_fault_mid_apply_is_partial_then_recovers()
    test_lowering_is_data_golden()
    test_a_default_written_out_is_not_a_change()
    print("ALL kci_cloud_fake CONFORMANCE TESTS PASSED")
