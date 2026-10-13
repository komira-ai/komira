# check_source_scheme and check_source_descriptor: a scheme code a plan
# carries is one of the four codes source_scheme_for_url returns, and any
# other code is refused naming the descriptor.
#
# Rows: the local descriptor and a file descriptor with a node id give
# FS_SCHEME_FILE; S3, GCS and Azure descriptors give their own codes; the
# bare-code form agrees with the descriptor form; an unknown code (9, and 4,
# the first code past the four) raises "unknown file system scheme", naming
# the bucket and node. Every code 0..255, over buckets of length 0..2 and
# node ids 0, 1 and -1, in both forms: 0..3 come back unchanged and every
# other code is refused by its whole message, naming that bucket and node.
from std.testing import assert_equal, assert_raises

from komira_plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_FILE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
    FsDescriptorPod,
)
from komira_source_url import check_source_descriptor, check_source_scheme


def test_the_four_codes() raises:
    assert_equal(check_source_descriptor(FsDescriptorPod.local()), FS_SCHEME_FILE)
    assert_equal(
        check_source_descriptor(FsDescriptorPod(FS_SCHEME_FILE, String(""), 3)),
        FS_SCHEME_FILE,
    )
    assert_equal(
        check_source_descriptor(FsDescriptorPod.cloud(FS_SCHEME_S3, "lake", 7)),
        FS_SCHEME_S3,
    )
    assert_equal(
        check_source_descriptor(FsDescriptorPod.cloud(FS_SCHEME_GCS, "gbucket", 2)),
        FS_SCHEME_GCS,
    )
    assert_equal(
        check_source_descriptor(FsDescriptorPod.cloud(FS_SCHEME_AZURE, "box", 4)),
        FS_SCHEME_AZURE,
    )


def test_the_bare_code_form() raises:
    var s3 = FsDescriptorPod.cloud(UInt8(1), "lake", 7)
    assert_equal(check_source_scheme(s3.scheme, s3.bucket, s3.node_id), FS_SCHEME_S3)
    var local = FsDescriptorPod.local()
    assert_equal(
        check_source_scheme(local.scheme, local.bucket, local.node_id), FS_SCHEME_FILE
    )
    var azure = FsDescriptorPod.cloud(UInt8(3), "box", 6)
    assert_equal(
        check_source_scheme(azure.scheme, azure.bucket, azure.node_id), FS_SCHEME_AZURE
    )
    var gcs = FsDescriptorPod.cloud(UInt8(2), "gbucket", 5)
    assert_equal(check_source_scheme(gcs.scheme, gcs.bucket, gcs.node_id), FS_SCHEME_GCS)


def test_unknown_scheme() raises:
    with assert_raises(
        contains="source_url: unknown file system scheme 9 (bucket 'x', node 1)"
    ):
        _ = check_source_descriptor(FsDescriptorPod(UInt8(9), String("x"), 1))
    with assert_raises(
        contains="source_url: unknown file system scheme 4 (bucket 'gbucket', node 5)"
    ):
        _ = check_source_scheme(UInt8(4), "gbucket", 5)


def _refusal(desc: FsDescriptorPod) raises -> String:
    try:
        var code = check_source_descriptor(desc)
        return "accepted as code " + String(Int(code))
    except e:
        return String(e)


def _bare_refusal(scheme: UInt8, bucket: String, node_id: Int) raises -> String:
    try:
        var code = check_source_scheme(scheme, bucket, node_id)
        return "accepted as code " + String(Int(code))
    except e:
        return String(e)


def test_every_code_bucket_and_node() raises:
    var buckets: List[String] = ["", "b", "bk"]
    var nodes: List[Int] = [0, 1, -1]
    var accepted = 0
    for code in range(256):
        for b in range(len(buckets)):
            for n in range(len(nodes)):
                var desc = FsDescriptorPod(UInt8(code), buckets[b], nodes[n])
                var want: String
                if code <= 3:
                    want = "accepted as code " + String(code)
                    accepted += 1
                else:
                    want = (
                        "source_url: unknown file system scheme "
                        + String(code)
                        + " (bucket '"
                        + buckets[b]
                        + "', node "
                        + String(nodes[n])
                        + ")"
                    )
                assert_equal(_refusal(desc), want)
                assert_equal(_bare_refusal(UInt8(code), buckets[b], nodes[n]), want)
    assert_equal(accepted, 4 * 3 * 3)


def main() raises:
    test_the_four_codes()
    test_the_bare_code_form()
    test_unknown_scheme()
    test_every_code_bucket_and_node()
    print("OK")
