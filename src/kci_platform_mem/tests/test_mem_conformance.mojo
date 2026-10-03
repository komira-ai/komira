# =============================================================================
# test_mem_conformance.mojo
# =============================================================================
#
# 1. "mem" passes the kci_platform conformance kit on a graph with every v1
#    shape: a public service, an internal service reading the first one's URL
#    and HOST, a scheduled job, and two `Uses` grants.
# 2. RENAME INVARIANCE: the same kit passes with mem registered under a
#    random id, so nothing above the seam keyed on the spelling "mem".
# 3. "mem-lite" passes the kit on the graph it can host.
# 4. VALUE FLOW through a real platform: a dry run on nothing reports the
#    consumer as known after apply; after apply the consumer was created over
#    the producer's real URL and HOST, and a changed producer port is an
#    update for the producer only (its URL does not depend on the port).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_iac import Creds, InMemoryStateStore, VERB_KNOWN_AFTER_APPLY, VERB_CREATE, VERB_NOOP, VERB_UPDATE
from kci_platform import (
    Catalog,
    Registry,
    apply_resources,
    describe,
    plan_resources,
    run_conformance,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_platform_mem import MemLitePlatform, MemPlatform


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


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
    var reg = Registry(Catalog.v1())
    reg.add(describe(MemPlatform()))
    var mem = MemPlatform()
    run_conformance(reg, mem, _list(_full("8080")), _list(_full("9090")), String("api/run"))
    print("  test_mem_passes_the_kit: PASS")


def test_mem_under_a_random_id_passes_the_kit() raises:
    var id = String("p-4b1d9e07")
    var reg = Registry(Catalog.v1())
    reg.add(describe(MemPlatform(id)))
    reg.add(describe(MemLitePlatform(String("q-90c2"))))
    var renamed = MemPlatform(id)
    run_conformance(reg, renamed, _list(_full("8080")), _list(_full("9090")), String("web/run"))
    print("  test_mem_under_a_random_id_passes_the_kit: PASS")


def test_mem_lite_passes_the_kit_on_what_it_hosts() raises:
    var reg = Registry(Catalog.v1())
    reg.add(describe(MemLitePlatform()))
    var lite = MemLitePlatform()
    run_conformance(reg, lite, _list(_lite("8080")), _list(_lite("9090")), String("api/run"))
    print("  test_mem_lite_passes_the_kit_on_what_it_hosts: PASS")




def test_values_flow_through_mem() raises:
    var reg = Registry(Catalog.v1())
    reg.add(describe(MemPlatform()))
    var mem = MemPlatform()
    var creds = Creds.none()
    var store = InMemoryStateStore()

    var plan = plan_resources(reg, mem, _list(_full("8080")), creds)
    for i in range(len(plan)):
        if plan[i].logical_id == "web/run":
            assert_equal(plan[i].verb, VERB_KNOWN_AFTER_APPLY, "web reads api's URL")
        elif plan[i].logical_id == "api/run":
            assert_equal(plan[i].verb, VERB_CREATE)

    _ = apply_resources(reg, mem, _list(_full("8080")), creds, store)
    var w = mem.cloud[].find(String("web/run"))
    var d = mem.cloud[].digests[w].copy()
    assert_true(_has(d, "|service.env.API_HOST=api.mem"), d)
    assert_true(_has(d, "|service.env.API_URL=mem://api"), d)
    assert_true(_has(d, "|service.env.MODE=fast"), d)
    assert_equal(
        store.outputs_for(String("api/run")).get(String("URL")).value(), "mem://api"
    )

    var again = apply_resources(reg, mem, _list(_full("9090")), creds, store)
    for i in range(len(again)):
        if again[i].logical_id == "api/run":
            assert_equal(again[i].verb, VERB_UPDATE, "the port changed")
        else:
            assert_equal(again[i].verb, VERB_NOOP, again[i].logical_id + " is unaffected")
    print("  test_values_flow_through_mem: PASS")


def main() raises:
    print("test_mem_conformance")
    test_mem_passes_the_kit()
    test_mem_under_a_random_id_passes_the_kit()
    test_mem_lite_passes_the_kit_on_what_it_hosts()
    test_values_flow_through_mem()
    print("ALL kci_platform_mem CONFORMANCE TESTS PASSED")
