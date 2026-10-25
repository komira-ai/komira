# =============================================================================
# tests/test_gcp_secret_store.mojo: the handle grammar, CRC32C, and the
# store over scripted answers, with the bytes each request put on the wire.
# =============================================================================
#
# No socket: the generated client sends over komira_http_core's
# ScriptedConnector with a shared write capture, so a test reads the request
# as written, or sees that nothing was written. No test talks to the service.
#
# What each test catches:
#   * test_handle_grammar: a version dropped or `latest` not defaulted, a
#     regional parent spelled as a global one, a malformed name accepted, a
#     refusal that quotes the handle.
#   * test_handle_shapes: a secret id outside `[A-Za-z0-9_-]{1,255}`, a
#     project that is neither a number nor a project id, a location that is
#     not a location id accepted (a pasted value among them), a refusal that
#     quotes the handle; and the edges that must pass (255 bytes, a
#     domain-scoped project, a project number).
#   * test_version_aliases: a version alias refused (Google reads a version
#     by alias as by number), or one outside the alias rule accepted: a
#     digit or `_` first, a dot, over 63 bytes, and `new` or `latest` in a
#     case other than the special name's.
#   * test_crc32c_published_values: a checksum that is not CRC-32C (the
#     store's check rests on it).
#   * test_resolve_reads_and_checks: the wrong version name on the wire, the
#     payload not decoded, a checksum mismatch accepted, an answer with no
#     dataCrc32c read unchecked, an answer with no payload returned as an
#     empty value; the store conforms to `SecretStore`.
#   * test_resolve_error_names_the_handle: an error answer swallowed, or its
#     body (a canary in error.message) put into the raised text.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.service import SecretManagerServiceClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretStore, SecretValue

from komira_gcp_secret_store import GcpSecretManagerStore, crc32c, parse_gcp_secret_ref

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
        String("projects/demo-project/locations/us-central1/secrets/smtp/versions/latest")
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
        "projects/canary-zz9/secrets/s/versions/first.second",
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
            _http(200, "OK", '{"name":"projects/000000000000/secrets/smtp/versions/2","payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}'),
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

    var unsummed = ArcPointer[List[UInt8]](List[UInt8]())
    var no_checksum = GcpSecretManagerStore(
        _client(
            unsummed,
            _http(200, "OK", '{"name":"projects/0/secrets/smtp/versions/3","payload":{"data":"aHVudGVyMg=="}}'),
        )
    )
    with assert_raises(contains="resolve of secret_ref projects/demo-project/secrets/smtp failed: the answer carries no dataCrc32c"):
        _ = no_checksum.resolve(String("projects/demo-project/secrets/smtp"))

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


def _refusal(secret_ref: String) -> String:
    try:
        _ = parse_gcp_secret_ref(secret_ref)
    except e:
        return String(e)
    return String("accepted")


def test_handle_shapes() raises:
    var long_id = String("")
    for _ in range(255):
        long_id += "A"
    var accepted: List[String] = [
        "projects/demo-project/secrets/" + long_id,
        "projects/demo-project/secrets/Smtp_pass-2",
        "projects/000000000000/secrets/s",
        "projects/example.com:demo-project/secrets/s",
        "projects/a23456/locations/europe-west4/secrets/s/versions/7",
    ]
    for i in range(len(accepted)):
        assert_equal(String(parse_gcp_secret_ref(accepted[i])), accepted[i])

    var refused: List[String] = [
        # Secret ids: a pasted value, a dot, a space, over-long.
        'projects/demo-project/secrets/{"password":"canary-zz9"}',
        "projects/demo-project/secrets/canary.zz9",
        "projects/demo-project/secrets/canary zz9",
        "projects/demo-project/secrets/" + long_id + "canary",
        # Projects: too short, upper case, a digit first, a hyphen last,
        # a bad domain, `.` and `..`.
        "projects/canar/secrets/s",
        "projects/Canary-zz9/secrets/s",
        "projects/9canary-zz9/secrets/s",
        "projects/canary-zz9-/secrets/s",
        "projects/.canary:demo-project/secrets/s",
        "projects/./secrets/canary",
        "projects/../secrets/canary",
        # A project id with a character outside [a-z0-9-], an empty domain,
        # a domain with a character outside [a-z0-9.-].
        "projects/canary_zz9/secrets/s",
        "projects/:demo-project/secrets/s",
        "projects/canary_zz9.example:demo-project/secrets/s",
        # Locations: upper case, a digit first, a dot.
        "projects/demo-project/locations/US-canary/secrets/s",
        "projects/demo-project/locations/1canary/secrets/s",
        "projects/demo-project/locations/canary.zz9/secrets/s",
    ]
    var why: List[String] = [
        "secret id is not 1 to 255",
        "secret id is not 1 to 255",
        "secret id is not 1 to 255",
        "secret id is not 1 to 255",
        "project is neither",
        "project is neither",
        "project is neither",
        "project is neither",
        "project is neither",
        "project is neither",
        "project is neither",
        "project is neither",
        "project is neither",
        "project is neither",
        "location is not a location id",
        "location is not a location id",
        "location is not a location id",
    ]
    assert_equal(len(refused), len(why))
    for i in range(len(refused)):
        var text = _refusal(refused[i])
        assert_true(text.find(why[i]) >= 0, String(i) + ": " + text)
        assert_false(text.find("canary") >= 0, text)
    print("  test_handle_shapes PASS")


def test_version_aliases() raises:
    var a63 = String("p")
    for _ in range(62):
        a63 += "9"
    var accepted: List[String] = [
        "projects/demo-project/secrets/smtp/versions/prod",
        "projects/demo-project/secrets/smtp/versions/Prod_2-b",
        "projects/demo-project/secrets/smtp/versions/" + a63,
        "projects/demo-project/locations/us-central1/secrets/smtp/versions/newer",
        "projects/demo-project/secrets/smtp/versions/latest2",
    ]
    for i in range(len(accepted)):
        var parsed = parse_gcp_secret_ref(accepted[i])
        assert_true(parsed.names_version())
        assert_equal(parsed.version_name(), accepted[i])
    assert_equal(
        parse_gcp_secret_ref(String("projects/demo-project/secrets/smtp/versions/prod")).version,
        "prod",
    )

    var refused: List[String] = [
        # Malformed aliases: a digit then a letter, `_` or `-` first, a dot,
        # 64 bytes.
        "projects/canary-zz9/secrets/s/versions/2prod",
        "projects/canary-zz9/secrets/s/versions/_prod",
        "projects/canary-zz9/secrets/s/versions/-prod",
        "projects/canary-zz9/secrets/s/versions/pr.od",
        "projects/canary-zz9/secrets/s/versions/" + a63 + "9",
        # Reserved in any case; only `latest`, spelled so, is the service's.
        "projects/canary-zz9/secrets/s/versions/new",
        "projects/canary-zz9/secrets/s/versions/NEW",
        "projects/canary-zz9/secrets/s/versions/New",
        "projects/canary-zz9/secrets/s/versions/LATEST",
        "projects/canary-zz9/secrets/s/versions/Latest",
        # No version at all.
        "projects/canary-zz9/secrets/s/versions/",
    ]
    for i in range(len(refused)):
        var text = _refusal(refused[i])
        assert_true(text.find("version is neither") >= 0, String(i) + ": " + text)
        assert_false(text.find("canary") >= 0, text)
    print("  test_version_aliases PASS")


def test_resolve_bad_handle_and_long_payload() raises:
    """A handle outside the grammar raises from `resolve` with the store's
    name, and sends nothing; a payload over `MAX_SECRET_LEN` (whose checksum
    is right) raises naming the handle, holding no part of the value."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var store = GcpSecretManagerStore(_client(capture, _http(200, "OK", "{}")))
    var text = String("")
    try:
        _ = store.resolve(String("projects/demo-project/secrets/{canary-zz9}"))
    except e:
        text = String(e)
    assert_true(text.startswith("GcpSecretManagerStore: secret_ref"), text)
    assert_false(text.find("canary") >= 0, text)
    assert_equal(len(capture[]), 0)

    # 1366 x base64("AAA") = 4098 decoded bytes, over MAX_SECRET_LEN (4096).
    var b64 = String("")
    var raw = List[UInt8]()
    for _ in range(1366):
        b64 += "QUFB"
        raw.append(UInt8(ord("A")))
        raw.append(UInt8(ord("A")))
        raw.append(UInt8(ord("A")))
    var answer = (
        String('{"name":"projects/0/secrets/big/versions/1","payload":{"data":"')
        + b64
        + '","dataCrc32c":"'
        + String(Int(crc32c(Span(raw))))
        + '"}}'
    )
    var big = GcpSecretManagerStore(
        _client(ArcPointer[List[UInt8]](List[UInt8]()), _http(200, "OK", answer))
    )
    text = String("")
    try:
        _ = big.resolve(String("projects/demo-project/secrets/big"))
    except e:
        text = String(e)
    assert_true(
        text.startswith(
            "GcpSecretManagerStore: resolve of secret_ref projects/demo-project/secrets/big failed:"
        ),
        text,
    )
    assert_false(text.find("AAAAAAAA") >= 0, text)
    print("  test_resolve_bad_handle_and_long_payload PASS")


def test_crc_mismatch_error_holds_no_payload() raises:
    """A checksum refusal names the handle and the fact, never a byte of the
    payload (plain or base64) or the checksums: the payload is the secret."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var damaged = GcpSecretManagerStore(
        _client(
            capture,
            _http(
                200,
                "OK",
                '{"name":"projects/0/secrets/smtp/versions/3","payload":'
                + '{"data":"aHVudGVyMw==","dataCrc32c":"1736498283"}}',
            ),
        )
    )
    var text = String("")
    try:
        _ = damaged.resolve(String("projects/demo-project/secrets/smtp"))
    except e:
        text = String(e)
    assert_true(text.find("CRC32C") >= 0, text)
    assert_true(text.startswith("GcpSecretManagerStore: resolve of secret_ref projects/demo-project/secrets/smtp failed:"), text)
    assert_false(text.find("hunter") >= 0, text)
    assert_false(text.find("aHVudGVy") >= 0, text)
    assert_false(text.find("1736498283") >= 0, text)
    # The same for an answer with no checksum.
    var no_sum = GcpSecretManagerStore(
        _client(
            ArcPointer[List[UInt8]](List[UInt8]()),
            _http(200, "OK", '{"name":"projects/0/secrets/smtp/versions/3","payload":{"data":"aHVudGVyMg=="}}'),
        )
    )
    text = String("")
    try:
        _ = no_sum.resolve(String("projects/demo-project/secrets/smtp"))
    except e:
        text = String(e)
    assert_true(text.find("dataCrc32c") >= 0, text)
    assert_false(text.find("hunter") >= 0, text)
    assert_false(text.find("aHVudGVy") >= 0, text)
    print("  test_crc_mismatch_error_holds_no_payload PASS")


def main() raises:
    test_handle_grammar()
    test_version_aliases()
    test_crc32c_published_values()
    test_resolve_reads_and_checks()
    test_resolve_error_names_the_handle()
    test_handle_shapes()
    test_resolve_bad_handle_and_long_payload()
    test_crc_mismatch_error_holds_no_payload()
    print("PASS komira_gcp_secret_store")
