# The S3 arm dials plaintext only when its endpoint says http, and TLS
# otherwise.
#
# Rows:
#  * s3_endpoint_is_plaintext: "" (AWS's own endpoint) and https:// are TLS,
#    http:// is plaintext, and any other scheme is refused, named.
#  * through the arm: a SchemeConnector over two ScriptedConnectors, the
#    plaintext one answering "plai" and the TLS one (which reports TLS, no
#    handshake) answering "tlsx". The factory s3_connector_factory picks for
#    an http:// endpoint reads "plai", and for an https:// endpoint "tlsx";
#    each read passes komira_http_client's scheme check, so a factory picked
#    the wrong way round is refused there (HttpError[URL_INVALID]).
#  * the production factory: its connector for an http:// endpoint is
#    plaintext and for https:// or AWS's own is TLS (nothing is dialed), and
#    s3_prod_arm builds an arm without dialing.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import AwsCredential, StaticCredsSource, SystemAwsClock
from komira_fs_registry import (
    FsHandleOver,
    S3Arm,
    S3ProdConnector,
    SchemeConnector,
    s3_connector_factory,
    s3_endpoint_is_plaintext,
    s3_prod_arm,
    s3_prod_plain_connector,
    s3_prod_tls_connector,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore_s3 import S3Config


comptime _Split = SchemeConnector[ScriptedConnector, ScriptedConnector]
comptime _Arm = S3Arm[_Split, StaticCredsSource]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(body: String) -> ScriptedStream:
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: close\r\n")
            + 'ETag: "e1"\r\nContent-Range: bytes 0-3/10\r\n\r\n'
            + body
        )
    )


def _mk_plain() raises -> _Split:
    return _Split(plain=ScriptedConnector.with_stream(_answer("plai")))


def _mk_tls() raises -> _Split:
    return _Split(tls=ScriptedConnector.with_stream_tls(_answer("tlsx")))


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _read(endpoint: String) raises -> String:
    var config = S3Config.custom_endpoint("us-east-1", endpoint)
    var mk = s3_connector_factory[_Split](config.endpoint, _mk_plain, _mk_tls)
    var h = FsHandleOver[_Split, StaticCredsSource].from_s3(
        _Arm("lake", config^, mk, HttpClientConfig.defaults(), _creds(), SystemAwsClock())
    )
    ref fs = h.s3_ref().value()
    var file = fs.open("data/a.parquet")
    var buf = fs.read_at(file, 0, 4)
    var view = buf.view_range_ro(0, buf.len())
    return String(unsafe_from_utf8=view.into_span())


def test_the_endpoint_scheme_decides() raises:
    assert_false(s3_endpoint_is_plaintext(""))
    assert_false(s3_endpoint_is_plaintext("https://s3.example.test"))
    assert_true(s3_endpoint_is_plaintext("http://127.0.0.1:9000"))
    with assert_raises(
        contains="fs_registry: an S3 endpoint must start with http:// or https://, got 'ftp://x'"
    ):
        _ = s3_endpoint_is_plaintext("ftp://x")
    with assert_raises(
        contains="fs_registry: an S3 endpoint must start with http:// or https://, got 'HTTP://x'"
    ):
        _ = s3_endpoint_is_plaintext("HTTP://x")


def test_an_http_endpoint_reads_over_plaintext() raises:
    assert_equal(_read("http://127.0.0.1:9000"), "plai")


def test_an_https_endpoint_reads_over_tls() raises:
    assert_equal(_read("https://127.0.0.1:9000"), "tlsx")


def test_the_production_factory() raises:
    var plain = s3_connector_factory[S3ProdConnector](
        "http://127.0.0.1:9000", s3_prod_plain_connector, s3_prod_tls_connector
    )()
    assert_false(plain.is_tls())
    var tls = s3_connector_factory[S3ProdConnector](
        "https://s3.example.test", s3_prod_plain_connector, s3_prod_tls_connector
    )()
    assert_true(tls.is_tls())
    var aws = s3_connector_factory[S3ProdConnector](
        "", s3_prod_plain_connector, s3_prod_tls_connector
    )()
    assert_true(aws.is_tls())
    var arm = s3_prod_arm(
        "lake",
        S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
        HttpClientConfig.defaults(),
        _creds(),
    )
    assert_equal(arm.bucket(), "lake")
    assert_equal(arm.stores_built(), 0)


def main() raises:
    test_the_endpoint_scheme_decides()
    test_an_http_endpoint_reads_over_plaintext()
    test_an_https_endpoint_reads_over_tls()
    test_the_production_factory()
    print("OK")
