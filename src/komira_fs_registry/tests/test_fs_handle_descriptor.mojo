# fs_arm_tag_for_descriptor: a komira_plan_expr descriptor maps to the tag of
# the arm that serves it, and a descriptor for an arm this build lacks is
# refused by name.
#
# Rows: the local descriptor and a file descriptor map to FsHandle.FS_LOCAL;
# an S3 descriptor maps to FsHandle.FS_S3; a GCS descriptor raises "no GCS arm
# in this build" and an Azure one "no Azure arm in this build", each naming
# the bucket; any other scheme code raises "unknown file system scheme";
# fs_arm_tag_for_scheme resolves a komira_core descriptor (the wire codec's
# type) the same way.
from std.testing import assert_equal, assert_raises

from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod as CoreFsDescriptorPod
from komira_fs_registry import (
    FsHandle,
    fs_arm_tag_for_descriptor,
    fs_arm_tag_for_scheme,
)
from komira_plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_FILE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
    FsDescriptorPod,
)


def test_local_and_s3_descriptors() raises:
    assert_equal(fs_arm_tag_for_descriptor(FsDescriptorPod.local()), FsHandle.FS_LOCAL)
    assert_equal(
        fs_arm_tag_for_descriptor(FsDescriptorPod(FS_SCHEME_FILE, String(""), 3)),
        FsHandle.FS_LOCAL,
    )
    assert_equal(
        fs_arm_tag_for_descriptor(FsDescriptorPod.cloud(FS_SCHEME_S3, "lake", 7)),
        FsHandle.FS_S3,
    )


def test_gcs_descriptor_names_the_missing_arm() raises:
    with assert_raises(contains="no GCS arm in this build"):
        _ = fs_arm_tag_for_descriptor(FsDescriptorPod.cloud(FS_SCHEME_GCS, "gbucket", 2))
    with assert_raises(contains="bucket 'gbucket', node 2"):
        _ = fs_arm_tag_for_descriptor(FsDescriptorPod.cloud(FS_SCHEME_GCS, "gbucket", 2))


def test_azure_descriptor_names_the_missing_arm() raises:
    with assert_raises(contains="no Azure arm in this build"):
        _ = fs_arm_tag_for_descriptor(FsDescriptorPod.cloud(FS_SCHEME_AZURE, "box", 4))
    with assert_raises(contains="bucket 'box', node 4"):
        _ = fs_arm_tag_for_descriptor(FsDescriptorPod.cloud(FS_SCHEME_AZURE, "box", 4))


def test_unknown_scheme() raises:
    with assert_raises(contains="unknown file system scheme 9"):
        _ = fs_arm_tag_for_descriptor(FsDescriptorPod(UInt8(9), String("x"), 1))


def test_a_core_descriptor_resolves_by_its_scheme_code() raises:
    var s3 = CoreFsDescriptorPod.cloud(UInt8(1), "lake", 7)
    assert_equal(fs_arm_tag_for_scheme(s3.scheme, s3.bucket, s3.node_id), FsHandle.FS_S3)
    var local = CoreFsDescriptorPod.local()
    assert_equal(
        fs_arm_tag_for_scheme(local.scheme, local.bucket, local.node_id), FsHandle.FS_LOCAL
    )
    var gcs = CoreFsDescriptorPod.cloud(UInt8(2), "gbucket", 5)
    with assert_raises(contains="no GCS arm in this build (descriptor scheme 2, bucket 'gbucket', node 5)"):
        _ = fs_arm_tag_for_scheme(gcs.scheme, gcs.bucket, gcs.node_id)


def main() raises:
    test_local_and_s3_descriptors()
    test_gcs_descriptor_names_the_missing_arm()
    test_azure_descriptor_names_the_missing_arm()
    test_unknown_scheme()
    test_a_core_descriptor_resolves_by_its_scheme_code()
    print("OK")
