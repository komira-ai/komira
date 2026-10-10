# An S3Fs dials plaintext only when its endpoint says http, and TLS
# otherwise (s3_endpoint.mojo).
#
# Rows:
#  * s3_endpoint_is_plaintext: "" (AWS's own endpoint) and https:// are TLS,
#    http:// is plaintext, and any other scheme is refused, named. The scheme
#    is case-insensitive (RFC 3986 section 3.1): HTTP:// is plaintext and
#    HTTPS:// is TLS.
#  * through the file system: komira_http_client's SchemeConnector over two
#    ScriptedConnectors, the plaintext one answering "plai" and the TLS one
#    (which reports TLS, no handshake) answering "tlsx". The factory s3_connector_factory picks for
#    an http:// endpoint reads "plai", and for an https:// endpoint "tlsx";
#    each read passes komira_http_client's scheme check, so a factory picked
#    the wrong way round is refused there (HttpError[URL_INVALID]). An
#    HTTP:// and an HTTPS:// endpoint read the same way.
#  * the production factory: its connector for an http:// endpoint is
#    plaintext and for https:// or AWS's own is TLS (nothing is dialed).
#  * the production file system: the S3Fs s3_prod_fs builds for an http://
#    endpoint makes plaintext connectors, for https://, HTTPS:// or AWS's own
#    TLS ones
#    (asked through S3Fs.new_connector, nothing dialed, no store built), and
#    an ftp:// endpoint is refused, named.
#  * the production type constructs and clones without dialing: an S3Fs over
#    KernelSchemeConnector with the shared default credential chain
#    (ProcessCredsSource) and a factory that raises if called keeps its
#    bucket through a clone, a clone of the clone and two moves, and builds
#    no store.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import (
    AwsCredential,
    AwsCredentialParams,
    ProcessCredsSource,
    StaticCredsSource,
    SystemAwsClock,
    process_creds_source,
)
from komira_http_client import (
    KernelSchemeConnector,
    SchemeConnector,
    kernel_plain_scheme_connector,
    kernel_tls_scheme_connector,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore_s3 import (
    S3Config,
    S3Fs,
    s3_connector_factory,
    s3_endpoint_is_plaintext,
    s3_prod_fs,
)


comptime _Split = SchemeConnector[ScriptedConnector, ScriptedConnector]
comptime _Fs = S3Fs[_Split, StaticCredsSource, SystemAwsClock]


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
    var fs = _Fs("lake", config^, mk, HttpClientConfig.defaults(), _creds(), SystemAwsClock())
    var file = fs.open("data/a.parquet")
    var buf = fs.read_at(file, 0, 4)
    var view = buf.view_range_ro(0, buf.len())
    return String(unsafe_from_utf8=view.into_span())


def test_the_endpoint_scheme_decides() raises:
    assert_false(s3_endpoint_is_plaintext(""))
    assert_false(s3_endpoint_is_plaintext("https://s3.example.test"))
    assert_true(s3_endpoint_is_plaintext("http://127.0.0.1:9000"))
    with assert_raises(
        contains="s3_endpoint: an S3 endpoint must start with http:// or https://, got 'ftp://x'"
    ):
        _ = s3_endpoint_is_plaintext("ftp://x")
    assert_true(s3_endpoint_is_plaintext("HTTP://x"))
    assert_true(s3_endpoint_is_plaintext("Http://x"))
    assert_false(s3_endpoint_is_plaintext("HTTPS://x"))
    with assert_raises(
        contains="s3_endpoint: an S3 endpoint must start with http:// or https://, got 'HTTPX://x'"
    ):
        _ = s3_endpoint_is_plaintext("HTTPX://x")


def test_an_http_endpoint_reads_over_plaintext() raises:
    assert_equal(_read("http://127.0.0.1:9000"), "plai")
    assert_equal(_read("HTTP://127.0.0.1:9000"), "plai")


def test_an_https_endpoint_reads_over_tls() raises:
    assert_equal(_read("https://127.0.0.1:9000"), "tlsx")
    assert_equal(_read("HTTPS://127.0.0.1:9000"), "tlsx")


def test_the_production_factory() raises:
    var plain = s3_connector_factory[KernelSchemeConnector](
        "http://127.0.0.1:9000", kernel_plain_scheme_connector, kernel_tls_scheme_connector
    )()
    assert_false(plain.is_tls())
    var tls = s3_connector_factory[KernelSchemeConnector](
        "https://s3.example.test", kernel_plain_scheme_connector, kernel_tls_scheme_connector
    )()
    assert_true(tls.is_tls())
    var aws = s3_connector_factory[KernelSchemeConnector](
        "", kernel_plain_scheme_connector, kernel_tls_scheme_connector
    )()
    assert_true(aws.is_tls())


def _prod_fs_is_tls(var config: S3Config) raises -> Bool:
    """Whether the connectors s3_prod_fs's file system dials with, for
    `config`'s endpoint, are TLS; nothing is dialed."""
    var fs = s3_prod_fs(
        "lake",
        config^,
        HttpClientConfig.defaults(),
        _creds(),
    )
    assert_equal(fs.bucket(), "lake")
    var is_tls = fs.new_connector().is_tls()
    assert_equal(fs.stores_built(), 0)
    return is_tls


def test_the_production_fs() raises:
    assert_false(
        _prod_fs_is_tls(S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000")),
        "s3_prod_fs dials TLS for an http:// endpoint",
    )
    assert_true(
        _prod_fs_is_tls(S3Config.custom_endpoint("us-east-1", "https://s3.example.test")),
        "s3_prod_fs dials plaintext for an https:// endpoint",
    )
    assert_true(
        _prod_fs_is_tls(S3Config.custom_endpoint("us-east-1", "HTTPS://minio.example.test:9000")),
        "s3_prod_fs dials plaintext for an HTTPS:// endpoint",
    )
    assert_true(
        _prod_fs_is_tls(S3Config.aws("us-east-1")),
        "s3_prod_fs dials plaintext for AWS's own endpoint",
    )
    with assert_raises(
        contains="s3_endpoint: an S3 endpoint must start with http:// or https://, got 'ftp://x'"
    ):
        _ = _prod_fs_is_tls(S3Config.custom_endpoint("us-east-1", "ftp://x"))


def _never_dial() raises -> KernelSchemeConnector:
    raise Error("test: the S3Fs made a connector")


def _shared_creds() raises -> ProcessCredsSource:
    """The production source: the default chain, shared by every clone, with
    the keys stated so that it needs no network."""
    var params = AwsCredentialParams()
    params.credential = Optional[AwsCredential](
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )
    return process_creds_source(params, HttpClientConfig.defaults())


def test_the_production_type_clones_without_dialing() raises:
    var fs = S3Fs[KernelSchemeConnector, ProcessCredsSource, SystemAwsClock](
        "lake",
        S3Config.aws("us-east-1"),
        _never_dial,
        HttpClientConfig.defaults(),
        _shared_creds(),
        SystemAwsClock(),
    )
    assert_equal(fs.bucket(), "lake")
    var c = fs.clone()
    assert_equal(c.bucket(), "lake")
    # A clone of a clone, and both move whole: still nothing dialed.
    var cc = c.clone()
    var fs_moved = fs^
    var cc_moved = cc^
    assert_equal(fs_moved.bucket(), "lake")
    assert_equal(cc_moved.bucket(), "lake")
    assert_equal(fs_moved.stores_built(), 0)
    assert_equal(cc_moved.stores_built(), 0)
    assert_equal(c.stores_built(), 0)


def main() raises:
    test_the_endpoint_scheme_decides()
    test_an_http_endpoint_reads_over_plaintext()
    test_an_https_endpoint_reads_over_tls()
    test_the_production_factory()
    test_the_production_fs()
    test_the_production_type_clones_without_dialing()
    print("OK")
