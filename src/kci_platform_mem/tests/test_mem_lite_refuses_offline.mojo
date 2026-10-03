# =============================================================================
# test_mem_lite_refuses_offline.mojo: THE OFFLINE REFUSAL PROOF.
# =============================================================================
#
# One author file: a `service` with a public URL that may CALL a scheduled
# `job`. "mem" hosts it. "mem-lite" cannot, twice over: it has no adapter for
# `job` (NOT_YET) and no public ingress (a shape of `service` it cannot
# host). With no cloud and no credentials:
#
#   1. validate reports BOTH reasons, in one pass, in the exact text below;
#   2. plan, apply and destroy on mem-lite are each refused, and afterwards
#      mem-lite's call log is EMPTY and nothing exists: not one create, not
#      even for the `service` mem-lite could otherwise host;
#   3. the same file applies on mem (3 nodes), so the refusal is about the
#      graph and the platform, not a broken file;
#   4. a file mem-lite CAN host (an internal service, no job) applies on it,
#      so mem-lite is a working platform, not one that refuses everything;
#   5. a value above a platform limit is refused the same way on mem.
#
# v1 of the catalog declares no PLATFORM_BOUND type, so there is no
# ABSENT_BY_DESIGN refusal to show here yet; its declaration rule is pinned in
# kci_platform's own tests, on a synthetic bound row.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_iac import Creds, InMemoryStateStore
from kci_platform import (
    Catalog,
    Registry,
    apply_resources,
    describe,
    destroy_resources,
    plan_resources,
    refusal_text,
    validate_for,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_platform_mem import MemLitePlatform, MemPlatform


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _file() -> String:
    return String(
        '{"resource":['
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":8080,"public":{}},'
        '"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]},'
        '{"id":"nightly","job":{"image":{"digest":"sha256:b2"},'
        '"schedule":{"cron":"0 3 * * *","timezone":"UTC"}}}'
        "]}"
    )


def _registry() raises -> Registry:
    var reg = Registry(Catalog.v1())
    reg.add(describe(MemPlatform()))
    reg.add(describe(MemLitePlatform()))
    return reg^


comptime EXPECTED = (
    'kci: cannot apply this graph to platform "mem-lite". Nothing was created.\n'
    '  resource "api" field service.public: mem-lite has no public ingress; it hosts'
    " internal services only (citation: kci_platform_mem: reference limits)\n"
    '  resource "nightly": job (PORTABLE): no adapter in platform "mem-lite"'
    " (NOT_YET: mem-lite has no run-to-completion runner)\n"
    "      platforms linked into this kci that implement it: mem"
)


def test_mem_lite_refuses_before_anything_is_created() raises:
    var reg = _registry()
    var lite = MemLitePlatform()
    var resources = _list(_file())

    var findings = validate_for(reg, lite, resources)
    assert_equal(refusal_text(lite.platform_id(), findings), String(EXPECTED))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    for verb in range(3):
        var raised = False
        try:
            if verb == 0:
                _ = plan_resources(reg, lite, resources, creds)
            elif verb == 1:
                _ = apply_resources(reg, lite, resources, creds, store)
            else:
                _ = destroy_resources(reg, lite, resources, creds, store)
        except e:
            raised = True
            assert_equal(String(e), String(EXPECTED))
        assert_true(raised, String("verb ") + String(verb) + " was refused")
    assert_equal(len(lite.cloud[].calls), 0, "mem-lite served no call at all")
    assert_equal(lite.live_count(), 0, "and nothing exists on it")
    assert_equal(store.physical_id_for(String("api/run")), "", "no intent was written")
    print("  test_mem_lite_refuses_before_anything_is_created: PASS")


def test_the_same_file_applies_on_mem() raises:
    var reg = _registry()
    var mem = MemPlatform()
    var store = InMemoryStateStore()
    var applied = apply_resources(reg, mem, _list(_file()), Creds.none(), store)
    assert_equal(len(applied), 3)
    assert_equal(mem.live_count(), 3)
    assert_true(mem.cloud[].find(String("api/uses/nightly")) >= 0, "the grant exists")
    var i = mem.cloud[].find(String("nightly/run"))
    assert_true(_has(mem.cloud[].digests[i], "|cron=0 3 * * *|tz=UTC"), mem.cloud[].digests[i])
    print("  test_the_same_file_applies_on_mem: PASS")


def test_mem_lite_hosts_what_it_can() raises:
    var reg = _registry()
    var lite = MemLitePlatform()
    var store = InMemoryStateStore()
    var ok = String(
        '{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},'
        '"port":8080,"internal":{}}}]}'
    )
    var applied = apply_resources(reg, lite, _list(ok), Creds.none(), store)
    assert_equal(len(applied), 1)
    assert_equal(lite.live_count(), 1)
    print("  test_mem_lite_hosts_what_it_can: PASS")


def test_a_limit_is_refused_the_same_way() raises:
    var reg = _registry()
    var mem = MemPlatform()
    var long = _file().replace('"timezone":"UTC"}', '"timezone":"UTC"},"timeout":"90000s"')
    var store = InMemoryStateStore()
    var raised = False
    try:
        _ = apply_resources(reg, mem, _list(long), Creds.none(), store)
    except e:
        raised = True
        assert_true(
            _has(
                String(e),
                'resource "nightly" field job.timeout: above this platform\'s job limit'
                " of 86400s",
            ),
            String(e),
        )
    assert_true(raised, "a job above the limit is refused")
    assert_equal(len(mem.cloud[].calls), 0, "before anything is created")
    print("  test_a_limit_is_refused_the_same_way: PASS")


def main() raises:
    print("test_mem_lite_refuses_offline")
    test_mem_lite_refuses_before_anything_is_created()
    test_the_same_file_applies_on_mem()
    test_mem_lite_hosts_what_it_can()
    test_a_limit_is_refused_the_same_way()
    print("ALL kci_platform_mem OFFLINE REFUSAL TESTS PASSED")
