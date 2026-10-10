# =============================================================================
# test_fake_body_arm.mojo: a resource's type, on the fake clouds, is its SET ARM.
# =============================================================================
#
# The generated `Resource` keeps one `Optional` per `body` arm and a case
# that says which arm is set. Decoding a message merged from two bodies
# (protobuf's rule: the last arm on the wire wins) sets the case to the last
# arm and leaves the earlier arm's `Optional` populated. kci's type test is
# the case, read through the catalog table (`body_field`, `body_is`); a test
# of an arm's `Optional` reads a type the resource does not have.
#
# 1. A MERGED RESOURCE IS ITS LAST ARM, on every fake cloud (generic, aws,
#    gcp, azure, onprem, and fake-limited for `check`): its limits and its
#    lowering are exactly those of the resource its last arm alone makes.
#    Each case names the site whose `Optional` test would read the earlier
#    arm, and the shape where that shows. All the cases run before the test
#    fails, so a red run names every site that reads a stale arm. The fake
#    is handed the edges, feeds and firings the graph has for the last arm,
#    so only the fake is under test. Four more type tests of the fake read
#    the set arm too, and no case here can tell them apart: `folds` and
#    `folded_fields` run only after the lowering has dispatched on the type,
#    and `messaging_limits` (a subscription) and metadata's folded schedule
#    match feeds and firings by the resource's id, which the graph's own
#    feeds and firings never name for another type.
# 2. THE COMMON LIMITS BY TYPE: a service's request timeout above 3600 s and
#    a scale whose max is below its min, and a container job's timeout above
#    86400 s, are refused on every fake cloud; a value at the limit is not.
#    These pin `common_limits` picking the service and the container job by
#    their catalog fields, not by an arm's position.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_proto
from kci_cloud import (
    FIELD_CONTAINER_JOB,
    FIELD_SERVICE,
    Finding,
    body_field,
    edges_for,
    feeds_of,
    firings_of,
    lowering_json,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, FakeLimitedCloud, ProviderShape, builtin_shapes


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _one(json: String) raises -> Resource:
    return decode_json[Resource](json)


def _merged(earlier: String, last: String) raises -> Resource:
    """The resource decoded from `earlier`'s bytes followed by `last`'s:
    protobuf's merge, so `last`'s arm is the set one."""
    var b = encode_proto(_one(earlier))
    b.extend(encode_proto(_one(last)))
    return decode_proto[Resource](b^)


def _shapes() -> List[ProviderShape]:
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.extend(builtin_shapes())
    return l^


def _text(findings: List[Finding]) -> String:
    var s = String("")
    for i in range(len(findings)):
        s += String("\n    ") + findings[i].field_path + String(": ") + findings[i].reason
    return s^


def _lowered(cloud: FakeCloud, r: Resource, graph: List[Resource], real: Resource) -> String:
    """The lowering of `r` as JSON, handed the edges, feeds and firings the
    graph has for `real` (so the fake alone is under test), or the error."""
    try:
        return lowering_json(cloud.lower(r, edges_for(graph, real), feeds_of(graph), firings_of(graph)))
    except e:
        return String("raised: ") + String(e)


def _same_as_last(
    what: String, earlier: String, last: String, graph_json: String, stale: Bool, mut bad: List[String]
) raises:
    """`_merged(earlier, last)` checks and lowers as `last` does on every
    fake cloud; `stale` says the earlier arm's `Optional` is populated (else
    the case proves nothing, and says so)."""
    var m = _merged(earlier, last)
    var real = _one(last)
    var graph = _list(graph_json)
    if body_field(m) != body_field(real):
        bad.append(what + String(": the merged resource's set arm is not the last one"))
        return
    if not stale:
        bad.append(what + String(": the earlier arm's Optional is not populated; the case tests nothing"))
        return
    var feeds = feeds_of(graph)
    var firings = firings_of(graph)
    var shapes = _shapes()
    for s in range(len(shapes)):
        var cloud = FakeCloud(shape=shapes[s])
        var got = _text(cloud.check(m, feeds, firings))
        var want = _text(cloud.check(real, feeds, firings))
        if got != want:
            bad.append(what + String(": check on ") + shapes[s].name + String(" got") + got + String("\n  want") + want)
        var lg = _lowered(cloud, m, graph, real)
        var lw = _lowered(cloud, real, graph, real)
        if lg != lw:
            bad.append(what + String(": lower on ") + shapes[s].name + String(" got\n") + lg + String("\n  want\n") + lw)
    var limited = FakeLimitedCloud()
    var got = _text(limited.check(m, feeds, firings))
    var want = _text(limited.check(real, feeds, firings))
    if got != want:
        bad.append(what + String(": check on fake-limited got") + got + String("\n  want") + want)


# ---- 1. a merged resource is its last arm ------------------------------------------


comptime _BUCKET = '{"id":"x","bucket":{}}'


def test_a_merged_resource_is_its_last_arm() raises:
    var bad = List[String]()
    var graph = String('{"resource":[') + String(_BUCKET) + String("]}")

    # common_limits: a container job's timeout above the limit, read off a
    # bucket (every fake cloud).
    var job = String('{"id":"x","containerJob":{"image":{"digest":"sha256:99"},"timeout":"100000s"}}')
    _same_as_last("container_job, then bucket", job, _BUCKET, graph, Bool(_merged(job, _BUCKET).container_job), bad)

    # workload_limits: a service scaling to zero, read off a worker (onprem).
    var svc = String('{"id":"x","service":{"image":{"digest":"sha256:a1"},"internal":{}}}')
    var worker = String('{"id":"x","worker":{"image":{"digest":"sha256:77"}}}')
    var wgraph = String('{"resource":[') + worker + String("]}")
    _same_as_last("service, then worker", svc, worker, wgraph, Bool(_merged(svc, worker).service), bad)

    # dns_limits: two names and a wildcard, read off a bucket (azure: one
    # name per certificate; gcp: one DNS authorization).
    var cert = String('{"id":"x","certificate":{"domains":["*.example.com","other.org"],"zone":{"resource":"z"}}}')
    _same_as_last("certificate, then bucket", cert, _BUCKET, graph, Bool(_merged(cert, _BUCKET).certificate), bad)

    # network_limits: a subnet with no zone, read off a bucket (aws).
    var subnet = String('{"id":"x","subnet":{"network":{"resource":"n"},"ipv4Cidr":"192.0.2.0/24"}}')
    _same_as_last("subnet, then bucket", subnet, _BUCKET, graph, Bool(_merged(subnet, _BUCKET).subnet), bad)

    # trigger_limits: a day of the month and a day of the week, read off a
    # bucket (aws).
    var sched = String('{"id":"x","schedule":{"cron":"0 2 1 * 1","target":{"resource":"j"}}}')
    _same_as_last("schedule, then bucket", sched, _BUCKET, graph, Bool(_merged(sched, _BUCKET).schedule), bad)

    var all = String("")
    for i in range(len(bad)):
        all += String("\n  ") + bad[i]
    assert_equal(len(bad), 0, String("a merged resource read as its earlier arm:") + all)
    print("  test_a_merged_resource_is_its_last_arm: PASS")


# ---- 2. the common limits, by type -------------------------------------------------


def _paths(findings: List[Finding]) -> String:
    var s = String("")
    for i in range(len(findings)):
        if i > 0:
            s += String(",")
        s += findings[i].field_path
    return s^


def test_the_common_limits_by_type() raises:
    var over = _one(
        String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},')
        + String('"requestTimeout":"3601s","scale":{"min":3,"max":1}}}')
    )
    var at = _one(
        String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},')
        + String('"requestTimeout":"3600s","scale":{"min":1,"max":1}}}')
    )
    var job_over = _one('{"id":"nightly","containerJob":{"image":{"digest":"sha256:99"},"timeout":"86401s"}}')
    var job_at = _one('{"id":"nightly","containerJob":{"image":{"digest":"sha256:99"},"timeout":"86400s"}}')
    var none = List[Resource]()
    var feeds = feeds_of(none)
    var firings = firings_of(none)
    var shapes = _shapes()
    for s in range(len(shapes)):
        var cloud = FakeCloud(shape=shapes[s])
        var name = shapes[s].name
        assert_equal(_paths(cloud.check(over, feeds, firings)), "service.request_timeout,service.scale", name)
        assert_equal(_paths(cloud.check(at, feeds, firings)), "", name + ": at the limit")
        assert_equal(_paths(cloud.check(job_over, feeds, firings)), "container_job.timeout", name)
        assert_equal(_paths(cloud.check(job_at, feeds, firings)), "", name + ": at the limit")
    var limited = FakeLimitedCloud()
    assert_equal(_paths(limited.check(over, feeds, firings)), "service.request_timeout,service.scale", "fake-limited")
    assert_equal(_paths(limited.check(job_over, feeds, firings)), "container_job.timeout", "fake-limited")
    print("  test_the_common_limits_by_type: PASS")


def main() raises:
    print("test_fake_body_arm")
    test_a_merged_resource_is_its_last_arm()
    test_the_common_limits_by_type()
    print("ALL kci_cloud_fake BODY ARM TESTS PASSED")
