# fs_handle_from_typed_fs and fs_is_registry_arm: a concrete file system whose
# type is exactly an arm of the production FsHandle is wrapped with that arm's
# tag; any other file system gets None.
#
# Rows: LocalFs[NoopSink] wraps with the local tag and keeps its root; the
# production S3 arm (S3Fs over the TLS connector) wraps with the S3 tag and
# keeps its bucket, and nothing is dialed (its connector factory raises);
# an S3Fs over ScriptedConnector advertises the S3 scheme but is not the arm's
# type, so it is not an arm and wraps to None, as does an S3Fs over the plain
# kernel connector and one with a different clock type.
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_aws_core import (
    AwsCredential,
    FixedClock,
    StaticCredsSource,
    SystemAwsClock,
)
from komira_fs.local_fs import LocalFs
from komira_fs_registry import (
    LocalArm,
    S3Arm,
    S3ProdConnector,
    fs_handle_from_typed_fs,
    fs_is_registry_arm,
)
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_core.transport.scripted import ScriptedConnector
from komira_objectstore_s3 import S3Config, S3Fs
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_FILE, FS_SCHEME_S3


def _never_dial() raises -> S3ProdConnector:
    raise Error("test: the S3 arm made a connector")


def _never_script() raises -> ScriptedConnector:
    raise Error("test: the scripted S3Fs made a connector")


def _never_kernel() raises -> KernelTcpConnector:
    raise Error("test: the kernel S3Fs made a connector")


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(String("AKIDEXAMPLE"), String("secret"), String(""))
    )


def test_arm_types() raises:
    assert_true(fs_is_registry_arm[LocalArm]())
    assert_true(fs_is_registry_arm[S3Arm[S3ProdConnector]]())
    assert_false(fs_is_registry_arm[S3Arm[ScriptedConnector]]())
    assert_false(fs_is_registry_arm[S3Arm[KernelTcpConnector]]())
    assert_false(
        fs_is_registry_arm[S3Fs[S3ProdConnector, StaticCredsSource, FixedClock]]()
    )


def test_local_fs_wraps_with_the_local_tag() raises:
    var h = fs_handle_from_typed_fs(LocalFs[NoopSink].from_root("/data"))
    assert_true(Bool(h))
    assert_equal(h.value().tag(), FS_SCHEME_FILE)
    assert_true(h.value().is_local())
    assert_true(Bool(h.value().local_ref()))


def test_prod_s3_fs_wraps_with_the_s3_tag() raises:
    var fs = S3Arm[S3ProdConnector](
        "lake", S3Config.aws("eu-west-1"), _never_dial, _creds(), SystemAwsClock()
    )
    var h = fs_handle_from_typed_fs(fs^)
    assert_true(Bool(h))
    assert_equal(h.value().tag(), FS_SCHEME_S3)
    assert_true(h.value().is_s3())
    assert_equal(h.value().s3_ref().value().bucket(), "lake")


def test_scripted_s3_fs_is_not_an_arm() raises:
    var fs = S3Arm[ScriptedConnector](
        "lake",
        S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
        _never_script,
        _creds(),
        SystemAwsClock(),
    )
    # It advertises the S3 scheme, and is still not the arm's type.
    assert_equal(S3Arm[ScriptedConnector].SCHEME, FS_SCHEME_S3)
    var h = fs_handle_from_typed_fs(fs^)
    assert_false(Bool(h))


def test_other_s3_monomorphs_are_not_arms() raises:
    var kernel = S3Arm[KernelTcpConnector](
        "lake",
        S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
        _never_kernel,
        _creds(),
        SystemAwsClock(),
    )
    assert_false(Bool(fs_handle_from_typed_fs(kernel^)))
    var fixed = S3Fs[S3ProdConnector, StaticCredsSource, FixedClock](
        "lake", S3Config.aws("us-east-1"), _never_dial, _creds(), FixedClock(1790000000)
    )
    assert_false(Bool(fs_handle_from_typed_fs(fixed^)))


def main() raises:
    test_arm_types()
    test_local_fs_wraps_with_the_local_tag()
    test_prod_s3_fs_wraps_with_the_s3_tag()
    test_scripted_s3_fs_is_not_an_arm()
    test_other_s3_monomorphs_are_not_arms()
    print("OK")
