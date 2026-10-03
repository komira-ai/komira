# The S3 arm reads through the handle, over komira_http_core's
# ScriptedConnector: no socket. Each factory call arms ONE answer (the 206 for
# `bytes=0-3` of a 10-byte object), so the handle and its clone each read
# once, and each one's second read finds its own script spent: the clone's
# arm built a store of its own.
from std.testing import assert_equal, assert_raises, assert_true

from komira_aws_core import AwsCredential, StaticCredsSource, SystemAwsClock
from komira_fs_registry import FsHandleOver, S3Arm
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


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _text(h: _Handle, key: String) raises -> String:
    ref fs = h.s3_ref().value()
    var file = fs.open(key)
    var buf = fs.read_at(file, 0, 4)
    var view = buf.view_range_ro(0, buf.len())
    return String(unsafe_from_utf8=view.into_span())


def test_s3_arm_reads_through_a_scripted_connector() raises:
    var h = _Handle.from_s3(
        S3Arm[ScriptedConnector](
            "lake",
            S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
            _mk_one_range,
            _creds(),
            SystemAwsClock(),
        )
    )
    assert_equal(h.tag, FS_SCHEME_S3)
    assert_true(h.is_s3())
    var c = h.clone()
    assert_equal(c.tag, FS_SCHEME_S3)
    assert_equal(_text(h, "data/a.parquet"), "abcd")
    assert_equal(_text(c, "data/b.parquet"), "abcd")
    with assert_raises(contains="ScriptedConnector.connect: no stream armed for dial #2"):
        _ = _text(h, "data/a.parquet")
    with assert_raises(contains="ScriptedConnector.connect: no stream armed for dial #2"):
        _ = _text(c, "data/b.parquet")


def main() raises:
    test_s3_arm_reads_through_a_scripted_connector()
    print("OK")
