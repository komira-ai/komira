# =============================================================================
# test_fake_limited_refuses_offline.mojo: THE OFFLINE REFUSAL PROOF.
# =============================================================================
#
# One author file: a `service` with a public URL that may CALL a
# `container_job`. "fake" hosts it. "fake-limited" cannot, twice over: it has
# no adapter for `container_job` (NOT_YET) and no public ingress (a shape of
# `service` it cannot host). With no cloud and no credentials:
#
#   1. validate reports BOTH reasons, in one pass, in the exact text below;
#   2. plan, apply and destroy on fake-limited are each refused, and afterwards
#      fake-limited's call log is EMPTY and nothing exists: not one create, not
#      even for the `service` fake-limited could otherwise host;
#   3. the same file applies on fake (8 nodes: the identity, run, public and
#      two grant roles of the service, the identity, run and grant roles of
#      the job, whose command is in its run's digest), so the refusal is
#      about the graph and the cloud, not a broken file;
#   4. a file fake-limited CAN host (an internal service, no job) applies on it,
#      so fake-limited is a working cloud, not one that refuses everything;
#   5. a value above a cloud limit is refused the same way on fake.
#
#   6. A CLOUD-BOUND SHAPE FAILS EARLY: v1 of the catalog declares no
#      CLOUD_BOUND type, so this case builds a catalog that marks
#      `container_job` CLOUD_BOUND and a fake-limited that declares it
#      ABSENT_BY_DESIGN; the same
#      file is refused, naming the bound type and the cloud that hosts it,
#      with zero calls served.
#   7. A BUCKET IS NOT YET ON fake-limited: a file with a bucket is refused
#      as a NOT_YET coverage gap, naming the cloud that hosts it, with zero
#      calls served.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import CellScope, Creds, InMemoryStateStore, Provenance, ResourceKey
from kci_cloud import (
    ABSENT_BY_DESIGN,
    ACCESS_CALL,
    CLOUD_BOUND,
    Catalog,
    CatalogType,
    CellContext,
    FIELD_BUCKET,
    FIELD_CONTAINER_JOB,
    FIELD_SERVICE,
    ACCESS_READ,
    OUTPUT_HOST,
    OUTPUT_NAME,
    OUTPUT_URL,
    RETENTION_KEEP,
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

from kci_cloud_fake import FakeLimitedCloud, FakeCloud


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _file() -> String:
    return String(
        '{"resource":['
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":8080,"public":{}},'
        '"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]},'
        '{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"},'
        '"command":["/bin/report","--full"]}}'
        "]}"
    )


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _clouds() raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    reg.add(describe(FakeLimitedCloud()))
    return reg^


comptime EXPECTED = (
    'kci: cannot apply this graph to cloud "fake-limited". Nothing was created.\n'
    '  resource "api" field service.public: fake-limited has no public ingress; it hosts'
    " internal services only (citation: kci_cloud_fake: reference limits)\n"
    '  resource "nightly": container_job (PORTABLE): no adapter in cloud "fake-limited"'
    " (NOT_YET: fake-limited has no run-to-completion runner)\n"
    "      clouds built into this kci that implement it: fake"
)


def test_fake_limited_refuses_before_anything_is_created() raises:
    var reg = _clouds()
    var limited = FakeLimitedCloud()
    var resources = _list(_file())

    var findings = validate_for(reg, limited, resources)
    assert_equal(refusal_text(limited.cloud_id(), findings), String(EXPECTED))

    var creds = Creds.none()
    var store = InMemoryStateStore()
    for verb in range(3):
        var raised = False
        try:
            if verb == 0:
                _ = plan_resources(reg, limited, _ctx(), resources, creds, store)
            elif verb == 1:
                _ = apply_resources(reg, limited, _ctx(), resources, creds, store)
            else:
                _ = destroy_resources(reg, limited, _ctx(), resources, creds, store)
        except e:
            raised = True
            assert_equal(String(e), String(EXPECTED))
        assert_true(raised, String("verb ") + String(verb) + " was refused")
    assert_equal(len(limited.store[].calls), 0, "fake-limited served no call at all")
    assert_equal(limited.live_count(), 0, "and nothing exists on it")
    var key = ResourceKey(String("shop"), String("blue"), String("api/run"))
    assert_equal(store.total_intents(key), 0, "no intent was written")
    print("  test_fake_limited_refuses_before_anything_is_created: PASS")


def test_the_same_file_applies_on_fake() raises:
    var reg = _clouds()
    var fake = FakeCloud()
    var store = InMemoryStateStore()
    var outcome = apply_resources(reg, fake, _ctx(), _list(_file()), Creds.none(), store)
    assert_true(outcome.ok())
    # api: identity, run, public, u-tvhrhu (CALL nightly), u-gktqg5 (cell LOGS);
    # nightly: identity, run, u-g2ewtg (cell LOGS)
    assert_equal(len(outcome.applied), 8)
    assert_equal(fake.live_count(), 8)
    assert_true(fake.store[].find(String("api/u-tvhrhu")) >= 0, "the grant exists")
    assert_true(fake.store[].find(String("api/u-gktqg5")) >= 0, "the implicit LOGS grant exists")
    assert_true(fake.store[].find(String("api/public")) >= 0, "the public role exists")
    var i = fake.store[].find(String("nightly/run"))
    assert_true(_has(fake.store[].digests[i], "|cmd=/bin/report|cmd=--full"), fake.store[].digests[i])
    print("  test_the_same_file_applies_on_fake: PASS")


def test_fake_limited_hosts_what_it_can() raises:
    var reg = _clouds()
    var limited = FakeLimitedCloud()
    var store = InMemoryStateStore()
    var ok = String(
        '{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},'
        '"port":8080,"internal":{}}}]}'
    )
    var outcome = apply_resources(reg, limited, _ctx(), _list(ok), Creds.none(), store)
    assert_true(outcome.ok())
    # api/identity, api/run, api/u-gktqg5 (cell LOGS), and api/public turned
    # off (internal): nothing to remove
    assert_equal(len(outcome.applied), 4)
    assert_equal(limited.live_count(), 3)
    print("  test_fake_limited_hosts_what_it_can: PASS")


def test_a_limit_is_refused_the_same_way() raises:
    var reg = _clouds()
    var fake = FakeCloud()
    var long = _file().replace('"--full"]', '"--full"],"timeout":"90000s"')
    assert_true(long != _file(), "the timeout was written")
    var store = InMemoryStateStore()
    var raised = False
    try:
        _ = apply_resources(reg, fake, _ctx(), _list(long), Creds.none(), store)
    except e:
        raised = True
        assert_true(
            _has(
                String(e),
                'resource "nightly" field container_job.timeout: above this cloud\'s job limit'
                " of 86400s",
            ),
            String(e),
        )
    assert_true(raised, "a job above the limit is refused")
    assert_equal(len(fake.store[].calls), 0, "before anything is created")
    print("  test_a_limit_is_refused_the_same_way: PASS")


def _bound_job_catalog() raises -> Catalog:
    """v1's types, with `container_job` marked CLOUD_BOUND."""
    var c = Catalog.v1()
    c.types[c.index_of(FIELD_CONTAINER_JOB)].portability = CLOUD_BOUND
    return c^


def test_a_cloud_bound_shape_fails_early() raises:
    var clouds = Clouds(_bound_job_catalog())
    clouds.add(describe(FakeCloud()))
    clouds.add(describe(FakeLimitedCloud(job_absence=ABSENT_BY_DESIGN)))
    var limited = FakeLimitedCloud(job_absence=ABSENT_BY_DESIGN)
    var internal_only = _file().replace('"public":{}', '"internal":{}')
    var resources = _list(internal_only)
    var text = refusal_text(limited.cloud_id(), validate_for(clouds, limited, resources))
    assert_equal(
        text,
        String(
            'kci: cannot apply this graph to cloud "fake-limited". Nothing was created.\n'
            '  resource "nightly": container_job (CLOUD_BOUND): no adapter in cloud "fake-limited"'
            " (ABSENT_BY_DESIGN: fake-limited will never run jobs)\n"
            "      clouds built into this kci that implement it: fake"
        ),
    )
    var store = InMemoryStateStore()
    var raised = False
    try:
        _ = apply_resources(clouds, limited, _ctx(), resources, Creds.none(), store)
    except e:
        raised = True
        assert_equal(String(e), text)
    assert_true(raised, "apply of a cloud-bound shape on a cloud without it is refused")
    assert_equal(len(limited.store[].calls), 0, "before any call is served")
    assert_equal(limited.live_count(), 0)

    # ABSENT_BY_DESIGN is not legal against the v1 catalog, where container_job is
    # PORTABLE: the declaration rule still holds.
    var v1 = Clouds(Catalog.v1())
    var refused = False
    try:
        v1.add(describe(FakeLimitedCloud(job_absence=ABSENT_BY_DESIGN)))
    except e:
        refused = True
        assert_true(_has(String(e), "ABSENT_BY_DESIGN is legal only for a CLOUD_BOUND type"), String(e))
    assert_true(refused)
    print("  test_a_cloud_bound_shape_fails_early: PASS")


def test_a_bucket_is_not_yet_on_fake_limited() raises:
    var reg = _clouds()
    var limited = FakeLimitedCloud()
    var resources = _list(String('{"resource":[{"id":"store","bucket":{}}]}'))
    var text = refusal_text(limited.cloud_id(), validate_for(reg, limited, resources))
    assert_equal(
        text,
        String(
            'kci: cannot apply this graph to cloud "fake-limited". Nothing was created.\n'
            '  resource "store": bucket (PORTABLE): no adapter in cloud "fake-limited"'
            " (NOT_YET: fake-limited has no object store)\n"
            "      clouds built into this kci that implement it: fake"
        ),
    )
    var store = InMemoryStateStore()
    var raised = False
    try:
        _ = apply_resources(reg, limited, _ctx(), resources, Creds.none(), store)
    except e:
        raised = True
        assert_equal(String(e), text)
    assert_true(raised, "a bucket on fake-limited is refused")
    assert_equal(len(limited.store[].calls), 0, "before any call is served")
    print("  test_a_bucket_is_not_yet_on_fake_limited: PASS")


def main() raises:
    print("test_fake_limited_refuses_offline")
    test_fake_limited_refuses_before_anything_is_created()
    test_the_same_file_applies_on_fake()
    test_fake_limited_hosts_what_it_can()
    test_a_limit_is_refused_the_same_way()
    test_a_cloud_bound_shape_fails_early()
    test_a_bucket_is_not_yet_on_fake_limited()
    print("ALL kci_cloud_fake OFFLINE REFUSAL TESTS PASSED")
