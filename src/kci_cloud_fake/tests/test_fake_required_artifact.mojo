# =============================================================================
# test_fake_required_artifact.mojo
# =============================================================================
#
# One artifact type word for an image. Every `ArtifactNeed` a fake cloud
# returns has kind `OCI` (the value of kci_release_channel's
# `ARTIFACT_TYPE_OCI`, the word a channel and the artifact manifest use) and
# platform `linux/amd64`. The comparison is with the literal, never with
# kci_cloud's own constant, so a constant changed to another word goes red
# here.
#
# Every fake is asked: the generic `FakeCloud`, `FakeCloud` on each built-in
# provider shape, and `FakeLimitedCloud`; and each is asked for every
# workload type (a service, a container job, a worker), so a fake that
# answers the right word for one resource and another word for the rest is
# caught on the resource it gets wrong.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_cloud import ArtifactNeed
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, FakeLimitedCloud, builtin_shapes


def _workloads() raises -> List[Resource]:
    """A service, a container job and a worker, in that order."""
    return decode_json[ResourceList](
        String('{"resource":[')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{}}},')
        + String('{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"}}},')
        + String('{"id":"relay","worker":{"image":{"digest":"sha256:c3"}}}')
        + String("]}")
    ).resource.copy()


def _check(cloud: String, r: Resource, need: ArtifactNeed) raises:
    var at = cloud + String(" / ") + r.id
    assert_equal(need.kind, "OCI", at)
    assert_equal(need.platform, "linux/amd64", at)


def test_every_fake_needs_oci_for_every_workload() raises:
    var rs = _workloads()
    assert_equal(len(rs), 3)
    var asked = 0

    var generic = FakeCloud()
    for i in range(len(rs)):
        _check(String("fake"), rs[i], generic.required_artifact(rs[i]))
        asked += 1

    var shapes = builtin_shapes()
    assert_true(len(shapes) >= 4, "aws, gcp, azure and onprem")
    for s in range(len(shapes)):
        var shaped = FakeCloud(shapes[s].name.copy(), shape=shapes[s].copy())
        for i in range(len(rs)):
            _check(shapes[s].name, rs[i], shaped.required_artifact(rs[i]))
            asked += 1

    var limited = FakeLimitedCloud()
    for i in range(len(rs)):
        _check(String("fake-limited"), rs[i], limited.required_artifact(rs[i]))
        asked += 1

    # Every (cloud, resource) pair was asked: no loop stopped early.
    assert_equal(asked, (2 + len(shapes)) * len(rs))


def main() raises:
    print("test_fake_required_artifact")
    test_every_fake_needs_oci_for_every_workload()
    print("ALL kci_cloud_fake REQUIRED ARTIFACT TESTS PASSED")
