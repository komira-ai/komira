# =============================================================================
# test_mem_conformance.mojo
# =============================================================================
#
# 1. "mem" passes the kci_cloud conformance kit on a graph with every v1
#    shape: a public service, an internal service reading the first one's URL
#    and HOST, a scheduled job, and two `Uses` grants.
# 2. RENAME INVARIANCE: the same kit passes with mem registered under a
#    random id, so nothing above the cloud adapter keyed on the spelling "mem".
# 3. "mem-lite" passes the kit on the graph it can host.
# 4. VALUE FLOW through a real cloud: a dry run on nothing reports the
#    consumer as known after apply; after apply the consumer was created over
#    the producer's real URL and HOST, and a changed producer port is an
#    update for the producer only (its URL does not depend on the port).
# 5. EVERY MODELLED FIELD IS IN THE DIGEST: a job's `env` and `secret_env`
#    (a reference: store, name, version) are updates when they change;
#    writing the default image platform out is not a change.
# 6. THE FAULTY VARIANT: a cloud call refused mid-apply leaves a PARTIAL
#    outcome (what landed, what is pending); the next apply finishes the
#    graph without re-creating what landed, and the one after is a no-op.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    Creds,
    InMemoryStateStore,
    VERB_KNOWN_AFTER_APPLY,
    VERB_CREATE,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    Clouds,
    apply_resources,
    describe,
    plan_resources,
    run_conformance,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_mem import MemLiteCloud, MemCloud


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    """The applied nodes of an apply that must have finished."""
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _full(api_port: String) -> String:
    return (
        String('{"resource":[')
        + String('{"id":"web","service":{"image":{"digest":"sha256:c3"},"port":8080,"internal":{},')
        + String('"env":{"API_URL":{"ref":{"resource":"api","standard":"URL"}},')
        + String('"API_HOST":{"ref":{"resource":"api","standard":"HOST"}},')
        + String('"MODE":{"literal":"fast"}}},')
        + String('"uses":[{"target":{"resource":"api"},"access":"CALL"}]},')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":')
        + api_port
        + String(',"public":{},"requestTimeout":"30s","scale":{"min":0,"max":3}},')
        + String('"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]},')
        + String('{"id":"nightly","job":{"image":{"digest":"sha256:b2"},"maxRetries":1,')
        + String('"schedule":{"cron":"0 3 * * *","timezone":"UTC"}}}')
        + String("]}")
    )


def _lite(api_port: String) -> String:
    return (
        String('{"resource":[')
        + String('{"id":"web","service":{"image":{"digest":"sha256:c3"},"internal":{},')
        + String('"env":{"API_URL":{"ref":{"resource":"api","standard":"URL"}}}},')
        + String('"uses":[{"target":{"resource":"api"},"access":"CALL"}]},')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":')
        + api_port
        + String(',"internal":{}}}')
        + String("]}")
    )


def test_mem_passes_the_kit() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(MemCloud()))
    var mem = MemCloud()
    run_conformance(reg, mem, _list(_full("8080")), _list(_full("9090")), String("api/run"))
    print("  test_mem_passes_the_kit: PASS")


def test_mem_under_a_random_id_passes_the_kit() raises:
    var id = String("p-4b1d9e07")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(MemCloud(id)))
    reg.add(describe(MemLiteCloud(String("q-90c2"))))
    var renamed = MemCloud(id)
    run_conformance(reg, renamed, _list(_full("8080")), _list(_full("9090")), String("web/run"))
    print("  test_mem_under_a_random_id_passes_the_kit: PASS")


def test_mem_lite_passes_the_kit_on_what_it_hosts() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(MemLiteCloud()))
    var lite = MemLiteCloud()
    run_conformance(reg, lite, _list(_lite("8080")), _list(_lite("9090")), String("api/run"))
    print("  test_mem_lite_passes_the_kit_on_what_it_hosts: PASS")




def test_values_flow_through_mem() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(MemCloud()))
    var mem = MemCloud()
    var creds = Creds.none()
    var store = InMemoryStateStore()

    var plan = plan_resources(reg, mem, _list(_full("8080")), creds)
    for i in range(len(plan)):
        if plan[i].logical_id == "web/run":
            assert_equal(plan[i].verb, VERB_KNOWN_AFTER_APPLY, "web reads api's URL")
        elif plan[i].logical_id == "api/run":
            assert_equal(plan[i].verb, VERB_CREATE)

    _ = _done(apply_resources(reg, mem, _list(_full("8080")), creds, store))
    var w = mem.store[].find(String("web/run"))
    var d = mem.store[].digests[w].copy()
    assert_true(_has(d, "|service.env.API_HOST=api.mem"), d)
    assert_true(_has(d, "|service.env.API_URL=mem://api"), d)
    assert_true(_has(d, "|service.env.MODE=fast"), d)
    assert_equal(
        store.outputs_for(String("api/run")).get(String("URL")).value(), "mem://api"
    )

    var again = _done(apply_resources(reg, mem, _list(_full("9090")), creds, store))
    for i in range(len(again)):
        if again[i].logical_id == "api/run":
            assert_equal(again[i].verb, VERB_UPDATE, "the port changed")
        else:
            assert_equal(again[i].verb, VERB_NOOP, again[i].logical_id + " is unaffected")
    print("  test_values_flow_through_mem: PASS")


def _job(env_mode: String, secret_version: String, platform: String) -> String:
    var img = String('"image":{"digest":"sha256:b2"')
    if platform.byte_length() > 0:
        img += String(',"platform":"') + platform + String('"')
    img += String("}")
    return (
        String('{"resource":[{"id":"nightly","job":{')
        + img
        + String(',"env":{"MODE":{"literal":"')
        + env_mode
        + String('"}},"secretEnv":{"TOKEN":{"name":"tok","version":"')
        + secret_version
        + String('"}},"onDemand":{}}}]}')
    )


def _verb_of(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def test_job_env_and_secrets_are_modelled() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(MemCloud()))
    var mem = MemCloud()
    var creds = Creds.none()
    var store = InMemoryStateStore()
    _ = _done(apply_resources(reg, mem, _list(_job("a", "1", "")), creds, store))
    var i = mem.store[].find(String("nightly/run"))
    var d = mem.store[].digests[i].copy()
    assert_true(_has(d, "|job.env.MODE=a"), d)
    assert_true(_has(d, "|job.secret_env.TOKEN=tok@1"), d)
    assert_true(_has(d, "@linux/amd64"), d)

    var same = _done(
        apply_resources(reg, mem, _list(_job("a", "1", "linux/amd64")), creds, store)
    )
    assert_equal(
        _verb_of(same, String("nightly/run")),
        VERB_NOOP,
        "writing the default platform out is not a change",
    )
    var env = _done(apply_resources(reg, mem, _list(_job("b", "1", "")), creds, store))
    assert_equal(_verb_of(env, String("nightly/run")), VERB_UPDATE, "a job env change is an update")
    var sec = _done(apply_resources(reg, mem, _list(_job("b", "2", "")), creds, store))
    assert_equal(
        _verb_of(sec, String("nightly/run")), VERB_UPDATE, "a new secret version is an update"
    )
    print("  test_job_env_and_secrets_are_modelled: PASS")


def test_a_fault_mid_apply_is_partial_then_recovers() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(MemCloud()))
    # The second mutating call is refused once.
    var mem = MemCloud(fail_at_call=2)
    var creds = Creds.none()
    var store = InMemoryStateStore()
    var graph = _list(_full("8080"))
    var first = apply_resources(reg, mem, graph, creds, store)
    assert_true(first.partial(), "one node landed, then the cloud refused a call")
    assert_true(_has(first.error.value(), "mem: injected fault on call 2"), first.error.value())
    assert_equal(len(first.landed), 1)
    assert_true(len(first.pending) >= 1)
    assert_equal(mem.live_count(), 1, "what landed is live, nothing else")
    var landed_id = first.landed[0].logical_id.copy()

    var second = _done(apply_resources(reg, mem, graph, creds, store))
    for k in range(len(second)):
        if second[k].logical_id == landed_id:
            assert_equal(second[k].verb, VERB_NOOP, landed_id + " is not re-created")
        else:
            assert_equal(second[k].verb, VERB_CREATE, second[k].logical_id)
    var third = _done(apply_resources(reg, mem, graph, creds, store))
    for k in range(len(third)):
        assert_equal(third[k].verb, VERB_NOOP, third[k].logical_id + " settled")
    print("  test_a_fault_mid_apply_is_partial_then_recovers: PASS")


def main() raises:
    print("test_mem_conformance")
    test_mem_passes_the_kit()
    test_mem_under_a_random_id_passes_the_kit()
    test_mem_lite_passes_the_kit_on_what_it_hosts()
    test_values_flow_through_mem()
    test_job_env_and_secrets_are_modelled()
    test_a_fault_mid_apply_is_partial_then_recovers()
    print("ALL kci_cloud_mem CONFORMANCE TESTS PASSED")
