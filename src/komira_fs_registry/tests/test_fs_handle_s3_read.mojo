# The S3 arm reads through the handle, over komira_http_core's
# ScriptedConnector: no socket. Each factory call arms ONE answer (the 206 for
# `bytes=0-3` of a 10-byte object), so a store reads once and its second read
# finds its script spent.
#
# Rows: the handle and its clone each read once, and each one's second read
# finds its own script spent (the clone's arm built a store of its own); a
# file system wrapped by `from_typed_fs` is MOVED into the arm, so a store it
# has already built is kept (its script, spent before the wrap, stays spent;
# a rebuilt store would answer again); the production arm over a plaintext
# http:// endpoint is refused on its first read (TLS only).
from std.testing import assert_equal, assert_raises, assert_true

from komira_aws_core import AwsCredential, StaticCredsSource, SystemAwsClock
from komira_fs_registry import FsHandle, FsHandleOver, S3Arm, S3ProdConnector
from komira_http_core.tls import TlsConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore_s3 import S3Config
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_S3


comptime _Handle = FsHandleOver[ScriptedConnector]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _mk_one_range() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(
            _bytes(
                "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: close\r\n"
                'ETag: "e1"\r\nContent-Range: bytes 0-3/10\r\n\r\nabcd'
            )
        )
    )


def _mk_tls() raises -> S3ProdConnector:
    """A real production connector; the refusal comes before any dial."""
    return S3ProdConnector.over(TlsConfig(), KernelTcpConnector.new())


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _text_of[C: Connector](fs: S3Arm[C], key: String) raises -> String:
    var file = fs.open(key)
    var buf = fs.read_at(file, 0, 4)
    var view = buf.view_range_ro(0, buf.len())
    return String(unsafe_from_utf8=view.into_span())


def _text(h: _Handle, key: String) raises -> String:
    return _text_of(h.s3_ref().value(), key)


def _scripted_arm() raises -> S3Arm[ScriptedConnector]:
    return S3Arm[ScriptedConnector](
        "lake",
        S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
        _mk_one_range,
        _creds(),
        SystemAwsClock(),
    )


def test_s3_arm_reads_through_a_scripted_connector() raises:
    var h = _Handle.from_s3(_scripted_arm())
    assert_equal(h.tag(), FS_SCHEME_S3)
    assert_true(h.is_s3())
    var c = h.clone()
    assert_equal(c.tag(), FS_SCHEME_S3)
    assert_equal(c.s3_ref().value().bucket(), "lake")
    assert_equal(_text(h, "data/a.parquet"), "abcd")
    assert_equal(_text(c, "data/b.parquet"), "abcd")
    with assert_raises(contains="ScriptedConnector.connect: no stream armed for dial #2"):
        _ = _text(h, "data/a.parquet")
    with assert_raises(contains="ScriptedConnector.connect: no stream armed for dial #2"):
        _ = _text(c, "data/b.parquet")


def test_wrapping_keeps_a_built_store() raises:
    var fs = S3Arm[ScriptedConnector].built(
        "lake",
        S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
        _mk_one_range,
        _creds(),
        SystemAwsClock(),
    )
    # Spend the built store's one answer before the wrap.
    assert_equal(_text_of(fs, "data/a.parquet"), "abcd")
    assert_true(_Handle.is_arm_type[S3Arm[ScriptedConnector]]())
    var maybe = _Handle.from_typed_fs(fs^)
    assert_true(Bool(maybe))
    var h = maybe.take()
    assert_true(h.is_s3())
    assert_equal(h.s3_ref().value().bucket(), "lake")
    # The same store: its script is still spent. A store rebuilt by the wrap
    # would have answered "abcd" again.
    with assert_raises(contains="ScriptedConnector.connect: no stream armed for dial #2"):
        _ = _text(h, "data/a.parquet")


def test_prod_arm_refuses_a_plaintext_endpoint() raises:
    var h = FsHandle.from_s3(
        S3Arm[S3ProdConnector](
            "lake",
            S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
            _mk_tls,
            _creds(),
            SystemAwsClock(),
        )
    )
    ref fs = h.s3_ref().value()
    var file = fs.open("data/a.parquet")
    with assert_raises(contains="HttpError[URL_INVALID]: http:// URL requires a plaintext connector"):
        _ = fs.read_at(file, 0, 4)


def main() raises:
    test_s3_arm_reads_through_a_scripted_connector()
    test_wrapping_keeps_a_built_store()
    test_prod_arm_refuses_a_plaintext_endpoint()
    print("OK")
