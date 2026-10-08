# =============================================================================
# tests/test_gcp_secret_store.mojo: the handle grammar, CRC32C, and the
# store and writer over scripted answers, with the bytes each request put on
# the wire.
# =============================================================================
#
# No socket: the generated client sends over komira_http_core's
# ScriptedConnector with a shared write capture, so a test reads the request
# as written, or sees that nothing was written. The service itself (versions,
# `latest`, create-if-absent, a regional secret at its own host, the
# checksum the fake verifies) is the subject of komira_secrets_e2e's
# test_gcp_store_registry, over a stateful fake behind TLS on a real socket.
#
# What each test catches:
#   * test_handle_grammar: a version dropped or `latest` not defaulted, a
#     regional parent spelled as a global one, a malformed name accepted, a
#     refusal that quotes the handle.
#   * test_crc32c_published_values: a checksum that is not CRC-32C (the
#     writer's dataCrc32c and the store's check both rest on it).
#   * test_resolve_reads_and_checks: the wrong version name on the wire, the
#     payload not decoded, a checksum mismatch accepted, an answer with no
#     payload returned as an empty value; the store conforms to `SecretStore`.
#   * test_resolve_error_names_the_handle: an error answer swallowed, or its
#     body (a canary in error.message) put into the raised text.
#   * test_writer_wire: the payload or its dataCrc32c not sent, a filter or
#     page size dropped from the probe, an empty list answered True; the
#     writer conforms to `SecretWriter`.
#   * test_writer_refusals_send_nothing: a deploy token ignored, a version
#     handle written: each refused with nothing on the wire.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from kci_secret_writer import SecretWriter
from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.service import SecretManagerServiceClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretStore, SecretValue

from komira_gcp_secret_store import (
    GcpSecretManagerStore,
    GcpSecretManagerWriter,
    crc32c,
    parse_gcp_secret_ref,
)

comptime _Client = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _http(status: Int, reason: String, body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 ")
        + String(status)
        + " "
        + reason
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(capture: ArcPointer[List[UInt8]], answer: List[UInt8]) raises -> _Client:
    var stream = ScriptedStream.from_read_script_with_capture(answer.copy(), capture)
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(ScriptedConnector.with_stream_tls(stream^)),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _line(capture: ArcPointer[List[UInt8]]) -> String:
    var w = _wire(capture)
    var end = w.find(" HTTP/1.1\r\n")
    return String(w[byte=0:end]) if end >= 0 else w


def _text(v: SecretValue) -> String:
    var out = List[UInt8]()
    out.extend(v.revealed_bytes())
    return String(unsafe_from_utf8=Span(out))


def _resolve[S: SecretStore](mut store: S, secret_ref: String) raises -> SecretValue:
    return store.resolve(secret_ref)


def test_handle_grammar() raises:
    var g = parse_gcp_secret_ref(String("projects/demo-project/secrets/smtp"))
    assert_false(g.is_regional())
    assert_false(g.names_version())
    assert_equal(g.parent(), "projects/demo-project")
    assert_equal(g.secret_name(), "projects/demo-project/secrets/smtp")
    assert_equal(g.version_name(), "projects/demo-project/secrets/smtp/versions/latest")

    var gv = parse_gcp_secret_ref(String("projects/demo-project/secrets/smtp/versions/12"))
    assert_true(gv.names_version())
    assert_equal(gv.version_name(), "projects/demo-project/secrets/smtp/versions/12")
    assert_equal(String(gv), "projects/demo-project/secrets/smtp/versions/12")

    var r = parse_gcp_secret_ref(String("projects/000000000000/locations/us-central1/secrets/smtp"))
    assert_true(r.is_regional())
    assert_equal(r.parent(), "projects/000000000000/locations/us-central1")
    assert_equal(
        r.version_name(),
        "projects/000000000000/locations/us-central1/secrets/smtp/versions/latest",
    )
    var rv = parse_gcp_secret_ref(
        String("projects/p/locations/us-central1/secrets/smtp/versions/latest")
    )
    assert_equal(rv.version, "latest")
    assert_equal(rv.secret_id, "smtp")

    var refused: List[String] = [
        "",
        "canary-zz9",
        "projects/canary-zz9",
        "projects/canary-zz9/secrets",
        "projects/canary-zz9/secrets/",
        "projects//secrets/canary-zz9",
        "projects/canary-zz9/secrets/..",
        "projects/canary-zz9/secrets/s/versions",
        "projects/canary-zz9/secrets/s/versions/0",
        "projects/canary-zz9/secrets/s/versions/01",
        "projects/canary-zz9/secrets/s/versions/first",
        "projects/canary-zz9/secrets/s/versions/1/extra",
        "projects/canary-zz9/locations//secrets/s",
        "projects/canary-zz9/zones/z/secrets/s",
        "folders/canary-zz9/secrets/s",
    ]
    for i in range(len(refused)):
        var text = String("")
        try:
            _ = parse_gcp_secret_ref(refused[i])
        except e:
            text = String(e)
        assert_true(text.startswith("secret_ref"), refused[i] + " -> " + text)
        assert_false(text.find("canary-zz9") >= 0, text)
    print("  test_handle_grammar PASS")


def test_crc32c_published_values() raises:
    # RFC 3720 appendix B.4 (32 zero bytes), the CRC-32C check value of
    # "123456789", and the Secret Manager reference's "hunter2".
    var zeros = List[UInt8]()
    zeros.resize(32, UInt8(0))
    assert_equal(Int(crc32c(Span(zeros))), 0x8A9136AA)
    assert_equal(Int(crc32c(Span(_bytes("123456789")))), 0xE3069283)
    assert_equal(Int(crc32c(Span(_bytes("hunter2")))), 1736498283)
    print("  test_crc32c_published_values PASS")


def test_resolve_reads_and_checks() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var store = GcpSecretManagerStore(
        _client(
            capture,
            _http(
                200,
                "OK",
                '{"name":"projects/000000000000/secrets/smtp/versions/3",'
                + '"payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}',
            ),
        )
    )
    var v = _resolve(store, String("projects/demo-project/secrets/smtp"))
    assert_equal(_text(v), "hunter2")
    assert_equal(
        _line(capture), "GET /v1/projects/demo-project/secrets/smtp/versions/latest:access"
    )

    var pinned = ArcPointer[List[UInt8]](List[UInt8]())
    var by_number = GcpSecretManagerStore(
        _client(
            pinned,
            _http(200, "OK", '{"name":"projects/000000000000/secrets/smtp/versions/2","payload":{"data":"aHVudGVyMg=="}}'),
        )
    )
    assert_equal(_text(by_number.resolve(String("projects/demo-project/secrets/smtp/versions/2"))), "hunter2")
    assert_equal(_line(pinned), "GET /v1/projects/demo-project/secrets/smtp/versions/2:access")

    var bad = ArcPointer[List[UInt8]](List[UInt8]())
    var damaged = GcpSecretManagerStore(
        _client(
            bad,
            _http(200, "OK", '{"name":"projects/0/secrets/smtp/versions/3","payload":{"data":"aHVudGVyMw==","dataCrc32c":"1736498283"}}'),
        )
    )
    with assert_raises(contains="resolve of secret_ref projects/demo-project/secrets/smtp failed: the payload's CRC32C is not the dataCrc32c"):
        _ = damaged.resolve(String("projects/demo-project/secrets/smtp"))

    var none = ArcPointer[List[UInt8]](List[UInt8]())
    var empty = GcpSecretManagerStore(
        _client(none, _http(200, "OK", '{"name":"projects/0/secrets/smtp/versions/3"}'))
    )
    with assert_raises(contains="failed: the answer has no payload"):
        _ = empty.resolve(String("projects/demo-project/secrets/smtp"))
    print("  test_resolve_reads_and_checks PASS")


def test_resolve_error_names_the_handle() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var store = GcpSecretManagerStore(
        _client(
            capture,
            _http(
                404,
                "Not Found",
                '{"error":{"code":404,"message":"leak-canary-52 not found.","status":"NOT_FOUND"}}',
            ),
        )
    )
    var text = String("")
    try:
        _ = store.resolve(String("projects/demo-project/secrets/gone"))
    except e:
        text = String(e)
    assert_true(
        text.startswith(
            "GcpSecretManagerStore: resolve of secret_ref projects/demo-project/secrets/gone"
            " failed: GET AccessSecretVersion: HTTP 404, NOT_FOUND (code 5)"
        ),
        text,
    )
    assert_false(text.find("leak-canary-52") >= 0, text)
    print("  test_resolve_error_names_the_handle PASS")


def _write[W: SecretWriter](mut w: W, secret_ref: String, value: String, token: String) raises:
    w.write(secret_ref, SecretValue.from_string(value), token)


def test_writer_wire() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var w = GcpSecretManagerWriter(
        _client(
            capture,
            _http(200, "OK", '{"name":"projects/000000000000/secrets/smtp/versions/4","state":"ENABLED"}'),
        )
    )
    _write(w, String("projects/demo-project/secrets/smtp"), String("hunter2"), String(""))
    var wire = _wire(capture)
    assert_true(wire.startswith("POST /v1/projects/demo-project/secrets/smtp:addVersion HTTP/1.1\r\n"), wire)
    assert_true(
        wire.endswith('\r\n\r\n{"payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}'),
        wire,
    )

    var listed = ArcPointer[List[UInt8]](List[UInt8]())
    var probe = GcpSecretManagerWriter(
        _client(
            listed,
            _http(200, "OK", '{"versions":[{"name":"projects/0/secrets/smtp/versions/4","state":"ENABLED"}],"nextPageToken":"t","totalSize":4}'),
        )
    )
    assert_true(probe.has_version(String("projects/demo-project/secrets/smtp"), String("")))
    assert_equal(
        _line(listed),
        "GET /v1/projects/demo-project/secrets/smtp/versions?pageSize=1&filter=state%3AENABLED",
    )
    var nothing = ArcPointer[List[UInt8]](List[UInt8]())
    var empty = GcpSecretManagerWriter(_client(nothing, _http(200, "OK", "{}")))
    assert_false(empty.has_version(String("projects/demo-project/secrets/smtp"), String("")))
    print("  test_writer_wire PASS")


def test_writer_refusals_send_nothing() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var w = GcpSecretManagerWriter(_client(capture, _http(200, "OK", "{}")))
    var texts = List[String]()
    try:
        _write(w, String("projects/p/secrets/s"), String("v"), String("deploy-bearer-canary"))
    except e:
        texts.append(String(e))
    try:
        _ = w.has_version(String("projects/p/secrets/s"), String("deploy-bearer-canary"))
    except e:
        texts.append(String(e))
    try:
        w.define_container(String("projects/p/secrets/s"), String("deploy-bearer-canary"))
    except e:
        texts.append(String(e))
    assert_equal(len(texts), 3)
    for i in range(len(texts)):
        assert_true(texts[i].find("refused: a deploy token was given") >= 0, texts[i])
        assert_false(texts[i].find("deploy-bearer-canary") >= 0, texts[i])
    with assert_raises(contains="write refused: the handle names a version"):
        _write(w, String("projects/p/secrets/s/versions/latest"), String("v"), String(""))
    with assert_raises(contains="define_container refused: secret_ref is not a Secret Manager name"):
        w.define_container(String("p/s"), String(""))
    assert_equal(len(capture[]), 0, "a refusal wrote to the wire")
    print("  test_writer_refusals_send_nothing PASS")


def main() raises:
    test_handle_grammar()
    test_crc32c_published_values()
    test_resolve_reads_and_checks()
    test_resolve_error_names_the_handle()
    test_writer_wire()
    test_writer_refusals_send_nothing()
    print("PASS komira_gcp_secret_store")
