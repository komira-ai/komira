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
#      graph and the cloud, not a broken file;
#   4. a file mem-lite CAN host (an internal service, no job) applies on it,
#      so mem-lite is a working cloud, not one that refuses everything;
#   5. a value above a cloud limit is refused the same way on mem.
#
#   6. A CLOUD-BOUND SHAPE FAILS EARLY: v1 of the catalog declares no
#      CLOUD_BOUND type, so this case builds a catalog that marks `job`
#      CLOUD_BOUND and a mem-lite that declares it ABSENT_BY_DESIGN; the same
#      file is refused, naming the bound type and the cloud that hosts it,
#      with zero calls served.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import Creds, InMemoryStateStore
from kci_cloud import (
    ABSENT_BY_DESIGN,
    ACCESS_CALL,
    CLOUD_BOUND,
    Catalog,
    CatalogType,
    FIELD_JOB,
    FIELD_SERVICE,
    OUTPUT_HOST,
    OUTPUT_URL,
    PORTABLE,
    Clouds,
    apply_resources,
    describe,
    destroy_resources,
    plan_resources,
    refusal_text,
    validate_for,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_mem import MemLiteCloud, MemCloud


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


def _clouds() raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(MemCloud()))
    reg.add(describe(MemLiteCloud()))
    return reg^


comptime EXPECTED = (
    'kci: cannot apply this graph to cloud "mem-lite". Nothing was created.\n'
    '  resource "api" field service.public: mem-lite has no public ingress; it hosts'
    " internal services only (citation: kci_cloud_mem: reference limits)\n"
    '  resource "nightly": job (PORTABLE): no adapter in cloud "mem-lite"'
    " (NOT_YET: mem-lite has no run-to-completion runner)\n"
    "      clouds built into this kci that implement it: mem"
)


def test_mem_lite_refuses_before_anything_is_created() raises:
    var reg = _clouds()
    var lite = MemLiteCloud()
    var resources = _list(_file())

    var findings = validate_for(reg, lite, resources)
    assert_equal(refusal_text(lite.cloud_id(), findings), String(EXPECTED))

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
    assert_equal(len(lite.store[].calls), 0, "mem-lite served no call at all")
    assert_equal(lite.live_count(), 0, "and nothing exists on it")
    assert_equal(store.physical_id_for(String("api/run")), "", "no intent was written")
    print("  test_mem_lite_refuses_before_anything_is_created: PASS")


def test_the_same_file_applies_on_mem() raises:
    var reg = _clouds()
    var mem = MemCloud()
    var store = InMemoryStateStore()
    var outcome = apply_resources(reg, mem, _list(_file()), Creds.none(), store)
    assert_true(outcome.ok())
    assert_equal(len(outcome.applied), 3)
    assert_equal(mem.live_count(), 3)
    assert_true(mem.store[].find(String("api/uses/nightly")) >= 0, "the grant exists")
    var i = mem.store[].find(String("nightly/run"))
    assert_true(_has(mem.store[].digests[i], "|cron=0 3 * * *|tz=UTC"), mem.store[].digests[i])
    print("  test_the_same_file_applies_on_mem: PASS")


def test_mem_lite_hosts_what_it_can() raises:
    var reg = _clouds()
    var lite = MemLiteCloud()
    var store = InMemoryStateStore()
    var ok = String(
        '{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},'
        '"port":8080,"internal":{}}}]}'
    )
    var outcome = apply_resources(reg, lite, _list(ok), Creds.none(), store)
    assert_true(outcome.ok())
    assert_equal(len(outcome.applied), 1)
    assert_equal(lite.live_count(), 1)
    print("  test_mem_lite_hosts_what_it_can: PASS")


def test_a_limit_is_refused_the_same_way() raises:
    var reg = _clouds()
    var mem = MemCloud()
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
                'resource "nightly" field job.timeout: above this cloud\'s job limit'
                " of 86400s",
            ),
            String(e),
        )
    assert_true(raised, "a job above the limit is refused")
    assert_equal(len(mem.store[].calls), 0, "before anything is created")
    print("  test_a_limit_is_refused_the_same_way: PASS")


def _bound_job_catalog() raises -> Catalog:
    """v1's two types, with `job` marked CLOUD_BOUND."""
    var c = Catalog()
    var svc_out = List[String]()
    svc_out.append(String(OUTPUT_URL))
    svc_out.append(String(OUTPUT_HOST))
    var call = List[String]()
    call.append(String(ACCESS_CALL))
    c.add(CatalogType(FIELD_SERVICE, String("service"), PORTABLE, svc_out^, call.copy()))
    c.add(CatalogType(FIELD_JOB, String("job"), CLOUD_BOUND, List[String](), call^))
    return c^


def test_a_cloud_bound_shape_fails_early() raises:
    var clouds = Clouds(_bound_job_catalog())
    clouds.add(describe(MemCloud()))
    clouds.add(describe(MemLiteCloud(job_absence=ABSENT_BY_DESIGN)))
    var lite = MemLiteCloud(job_absence=ABSENT_BY_DESIGN)
    var internal_only = _file().replace('"public":{}', '"internal":{}')
    var resources = _list(internal_only)
    var text = refusal_text(lite.cloud_id(), validate_for(clouds, lite, resources))
    assert_equal(
        text,
        String(
            'kci: cannot apply this graph to cloud "mem-lite". Nothing was created.\n'
            '  resource "nightly": job (CLOUD_BOUND): no adapter in cloud "mem-lite"'
            " (ABSENT_BY_DESIGN: mem-lite will never run jobs)\n"
            "      clouds built into this kci that implement it: mem"
        ),
    )
    var store = InMemoryStateStore()
    var raised = False
    try:
        _ = apply_resources(clouds, lite, resources, Creds.none(), store)
    except e:
        raised = True
        assert_equal(String(e), text)
    assert_true(raised, "apply of a cloud-bound shape on a cloud without it is refused")
    assert_equal(len(lite.store[].calls), 0, "before any call is served")
    assert_equal(lite.live_count(), 0)

    # ABSENT_BY_DESIGN is not legal against the v1 catalog, where job is
    # PORTABLE: the declaration rule still holds.
    var v1 = Clouds(Catalog.v1())
    var refused = False
    try:
        v1.add(describe(MemLiteCloud(job_absence=ABSENT_BY_DESIGN)))
    except e:
        refused = True
        assert_true(_has(String(e), "ABSENT_BY_DESIGN is legal only for a CLOUD_BOUND type"), String(e))
    assert_true(refused)
    print("  test_a_cloud_bound_shape_fails_early: PASS")


def main() raises:
    print("test_mem_lite_refuses_offline")
    test_mem_lite_refuses_before_anything_is_created()
    test_the_same_file_applies_on_mem()
    test_mem_lite_hosts_what_it_can()
    test_a_limit_is_refused_the_same_way()
    test_a_cloud_bound_shape_fails_early()
    print("ALL kci_cloud_mem OFFLINE REFUSAL TESTS PASSED")
