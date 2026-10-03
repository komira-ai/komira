# Each arm of the production FsHandle constructs and clones with its tag, and
# nothing is dialed: the S3 arm's connector factory raises if it is ever
# called, so a handle that built a store (or dialed) would fail here.
#
# Rows: the local arm's tag is FS_SCHEME_FILE and FsHandle.FS_LOCAL, only the
# local Optional is set, and a clone keeps both; the S3 arm's tag is
# FS_SCHEME_S3 and FsHandle.FS_S3, only the S3 Optional is set, the bucket
# survives a clone, and handle and clone move whole; the reserved GCS and
# Azure codes are not either arm's tag.
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_aws_core import AwsCredential, StaticCredsSource, SystemAwsClock
from komira_fs.local_fs import LocalFs
from komira_fs_registry import FsHandle, S3Arm, S3ProdConnector
from komira_objectstore_s3 import S3Config
from komira_plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_FILE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
)


def _never_dial() raises -> S3ProdConnector:
    raise Error("test: the S3 arm made a connector")


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _s3_arm() raises -> S3Arm[S3ProdConnector]:
    return S3Arm[S3ProdConnector](
        "lake", S3Config.aws("us-east-1"), _never_dial, _creds(), SystemAwsClock()
    )


def test_tags_are_the_scheme_codes() raises:
    assert_equal(FsHandle.FS_LOCAL, FS_SCHEME_FILE)
    assert_equal(FsHandle.FS_S3, FS_SCHEME_S3)
    assert_equal(Int(FS_SCHEME_FILE), 0)
    assert_equal(Int(FS_SCHEME_S3), 1)
    assert_true(FsHandle.FS_LOCAL != FS_SCHEME_GCS)
    assert_true(FsHandle.FS_S3 != FS_SCHEME_GCS)
    assert_true(FsHandle.FS_LOCAL != FS_SCHEME_AZURE)
    assert_true(FsHandle.FS_S3 != FS_SCHEME_AZURE)


def test_local_arm_constructs_and_clones() raises:
    var h = FsHandle.from_local(LocalFs[NoopSink].from_root("/data"))
    assert_equal(h.tag, FS_SCHEME_FILE)
    assert_true(h.is_local())
    assert_false(h.is_s3())
    assert_true(Bool(h.local_ref()))
    assert_false(Bool(h.s3_ref()))
    var c = h.clone()
    assert_equal(c.tag, FS_SCHEME_FILE)
    assert_true(c.is_local())
    assert_true(Bool(c.local_ref()))
    assert_false(Bool(c.s3_ref()))
    var moved = c^
    assert_true(moved.is_local())


def test_s3_arm_constructs_and_clones_without_dialing() raises:
    var h = FsHandle.from_s3(_s3_arm())
    assert_equal(h.tag, FS_SCHEME_S3)
    assert_true(h.is_s3())
    assert_false(h.is_local())
    assert_true(Bool(h.s3_ref()))
    assert_false(Bool(h.local_ref()))
    assert_equal(h.s3_ref().value().bucket(), "lake")
    var c = h.clone()
    assert_equal(c.tag, FS_SCHEME_S3)
    assert_true(c.is_s3())
    assert_false(Bool(c.local_ref()))
    assert_equal(c.s3_ref().value().bucket(), "lake")
    # A clone of a clone, and both move whole: still nothing dialed.
    var cc = c.clone()
    var h_moved = h^
    var cc_moved = cc^
    assert_equal(h_moved.s3_ref().value().bucket(), "lake")
    assert_equal(cc_moved.s3_ref().value().bucket(), "lake")


def main() raises:
    test_tags_are_the_scheme_codes()
    test_local_arm_constructs_and_clones()
    test_s3_arm_constructs_and_clones_without_dialing()
    print("OK")
