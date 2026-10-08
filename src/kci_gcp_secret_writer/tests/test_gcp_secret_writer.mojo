# =============================================================================
# tests/test_gcp_secret_writer.mojo: the writer's requests as written, its
# create-if-absent race, its probe and its refusals, over scripted answers.
# =============================================================================
#
# No socket: the generated client sends over komira_http_core's
# ScriptedConnector, one scripted stream per dial (each answer closes its
# connection, so the client dials again for the next request; further
# streams are queued with `arm_next`), every stream writing into one shared
# capture, so a test reads each request line in order, or sees that nothing
# was written. The service's behaviour (versions, `latest`, a disabled
# version, create-if-absent at a regional host, the checksum it verifies)
# is the subject of komira_secrets_e2e's test_gcp_store_registry, over a
# stateful fake behind TLS on a real socket.
#
# What each test catches:
#   * test_write_wire: the payload or its dataCrc32c not sent; the writer
#     conforms to `SecretWriter` (called through a generic).
#   * test_write_create_race: AddSecretVersion answered 404, CreateSecret
#     answered 409 ALREADY_EXISTS (another writer created the secret in
#     between), AddSecretVersion answered 200: the write succeeds, and the
#     three request lines are exactly add, create, add. Red under "raise on
#     any create error" (the write raises) and under "return after the
#     create" (two requests).
#   * test_write_create_other_error: the same, but CreateSecret answered 403
#     PERMISSION_DENIED: the write raises naming the handle and the code,
#     after two requests. Red under "swallow any create error".
#   * test_create_body_replication: the CreateSecret a write sends after a
#     404, for a global secret (its body asks for automatic replication)
#     and for a regional one (its parent names the location and its body
#     carries no replication policy, which a regional secret refuses). Red
#     under "always send automatic replication" and "never send it".
#   * test_has_version_reads_latest: the probe's request line (GET
#     `<secret>/versions/latest`, never `:access` and never a list); an
#     ENABLED `latest` answers True; a DISABLED `latest` (whatever older
#     version is enabled: the bare handle resolves `latest`) and a DESTROYED
#     one answer False; NOT_FOUND answers False; PERMISSION_DENIED raises.
#     Red under "any state counts" and under "every error answers False".
#   * test_writer_refusals_send_nothing: a deploy token ignored, a version
#     handle written, a handle outside the grammar sent: each refused with
#     nothing on the wire, without quoting a pasted value.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from kci_secret_writer import SecretWriter
from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.service import SecretManagerServiceClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretValue

from kci_gcp_secret_writer import GcpSecretManagerWriter

comptime _Client = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource]
comptime _S = "projects/demo-project/secrets/smtp"


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


def _status(code: Int, status: String) -> String:
    return (
        String('{"error":{"code":')
        + String(code)
        + ',"message":"leak-canary-31 says no.","status":"'
        + status
        + '"}}'
    )


def _client(capture: ArcPointer[List[UInt8]], answers: List[List[UInt8]]) raises -> _Client:
    var connector = ScriptedConnector.with_stream_tls(
        ScriptedStream.from_read_script_with_capture(answers[0].copy(), capture)
    )
    for i in range(1, len(answers)):
        connector.arm_next(
            ScriptedStream.from_read_script_with_capture(answers[i].copy(), capture)
        )
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(connector^),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _one(capture: ArcPointer[List[UInt8]], answer: List[UInt8]) raises -> _Client:
    var answers = List[List[UInt8]]()
    answers.append(answer.copy())
    return _client(capture, answers)


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _lines(capture: ArcPointer[List[UInt8]]) -> List[String]:
    """Each request line written, in order, without its ` HTTP/1.1`."""
    var out = List[String]()
    var wire = _wire(capture)
    for piece in wire.split("\r\n"):
        var line = String(piece)
        if line.endswith(" HTTP/1.1"):
            # A request with a body ends without a line break, so the next
            # request line follows the body on the same line.
            var at = max(line.rfind("POST /v1/"), line.rfind("GET /v1/"))
            if at >= 0:
                out.append(String(line[byte = at : line.byte_length() - 9]))
    return out^


def _write[W: SecretWriter](mut w: W, secret_ref: String, value: String, token: String) raises:
    w.write(secret_ref, SecretValue.from_string(value), token)


def test_write_wire() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var w = GcpSecretManagerWriter(
        _one(
            capture,
            _http(200, "OK", '{"name":"projects/000000000000/secrets/smtp/versions/4","state":"ENABLED"}'),
        )
    )
    _write(w, String(_S), String("hunter2"), String(""))
    var wire = _wire(capture)
    assert_true(wire.startswith("POST /v1/projects/demo-project/secrets/smtp:addVersion HTTP/1.1\r\n"), wire)
    assert_true(
        wire.endswith('\r\n\r\n{"payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}'),
        wire,
    )
    print("  test_write_wire PASS")


def test_write_create_race() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var answers = List[List[UInt8]]()
    answers.append(_http(404, "Not Found", _status(404, String("NOT_FOUND"))))
    answers.append(_http(409, "Conflict", _status(409, String("ALREADY_EXISTS"))))
    answers.append(
        _http(200, "OK", '{"name":"projects/000000000000/secrets/smtp/versions/1","state":"ENABLED"}')
    )
    var w = GcpSecretManagerWriter(_client(capture, answers))
    _write(w, String(_S), String("raced-value"), String(""))
    var got = _lines(capture)
    var want: List[String] = [
        "POST /v1/projects/demo-project/secrets/smtp:addVersion",
        "POST /v1/projects/demo-project/secrets?secretId=smtp",
        "POST /v1/projects/demo-project/secrets/smtp:addVersion",
    ]
    assert_equal(len(got), len(want), _wire(capture))
    for i in range(len(want)):
        assert_equal(got[i], want[i])
    print("  test_write_create_race PASS")


def test_write_create_other_error() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var answers = List[List[UInt8]]()
    answers.append(_http(404, "Not Found", _status(404, String("NOT_FOUND"))))
    answers.append(_http(403, "Forbidden", _status(403, String("PERMISSION_DENIED"))))
    answers.append(_http(200, "OK", '{"name":"projects/0/secrets/smtp/versions/1"}'))
    var w = GcpSecretManagerWriter(_client(capture, answers))
    var text = String("")
    try:
        _write(w, String(_S), String("denied-canary-value"), String(""))
    except e:
        text = String(e)
    assert_true(
        text.startswith(
            "GcpSecretManagerWriter: write of secret_ref " + _S
            + " failed: POST CreateSecret: HTTP 403, PERMISSION_DENIED (code 7)"
        ),
        text,
    )
    assert_false(text.find("denied-canary-value") >= 0, text)
    assert_false(text.find("leak-canary-31") >= 0, text)
    assert_equal(len(_lines(capture)), 2, "add, create, and no second add")
    print("  test_write_create_other_error PASS")


def _create_body(secret_ref: String, mut line: String) raises -> String:
    """Write to `secret_ref` over add 404, create 200, add 200; return the
    CreateSecret body and set `line` to its request line."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var answers = List[List[UInt8]]()
    answers.append(_http(404, "Not Found", _status(404, String("NOT_FOUND"))))
    answers.append(_http(200, "OK", '{"name":"projects/000000000000/secrets/smtp"}'))
    answers.append(
        _http(200, "OK", '{"name":"projects/000000000000/secrets/smtp/versions/1","state":"ENABLED"}')
    )
    var w = GcpSecretManagerWriter(_client(capture, answers))
    _write(w, secret_ref, String("first-value"), String(""))
    var lines = _lines(capture)
    assert_equal(len(lines), 3, _wire(capture))
    line = lines[1].copy()
    var wire = _wire(capture)
    var at = wire.find("?secretId=")
    assert_true(at >= 0, wire)
    var start = wire.find("\r\n\r\n", at)
    assert_true(start >= 0, wire)
    start += 4
    var end = wire.find("POST /v1/", start)
    assert_true(end > start, wire)
    return String(wire[byte=start:end])


def test_create_body_replication() raises:
    var line = String("")
    var global_body = _create_body(String(_S), line)
    assert_equal(line, "POST /v1/projects/demo-project/secrets?secretId=smtp")
    assert_true(global_body.find('"replication":{"automatic":{') >= 0, global_body)

    var regional_body = _create_body(
        String("projects/demo-project/locations/us-central1/secrets/smtp"), line
    )
    assert_equal(
        line, "POST /v1/projects/demo-project/locations/us-central1/secrets?secretId=smtp"
    )
    assert_false(regional_body.find("replication") >= 0, regional_body)
    assert_false(regional_body.find("automatic") >= 0, regional_body)
    print("  test_create_body_replication PASS")


def _probe(answer: List[UInt8], mut line: String) raises -> Bool:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var w = GcpSecretManagerWriter(_one(capture, answer))
    var got = w.has_version(String(_S), String(""))
    var lines = _lines(capture)
    line = lines[0].copy() if len(lines) == 1 else _wire(capture)
    return got


def test_has_version_reads_latest() raises:
    var line = String("")
    var latest = String("GET /v1/projects/demo-project/secrets/smtp/versions/latest")
    assert_true(
        _probe(
            _http(200, "OK", '{"name":"projects/0/secrets/smtp/versions/4","state":"ENABLED"}'),
            line,
        ),
        "an enabled latest",
    )
    assert_equal(line, latest)
    # `latest` disabled, version 3 enabled: the bare handle resolves
    # `latest`, which cannot be read, so the probe answers False and a write
    # makes a new, readable `latest`.
    assert_false(
        _probe(
            _http(200, "OK", '{"name":"projects/0/secrets/smtp/versions/4","state":"DISABLED"}'),
            line,
        ),
        "a disabled latest",
    )
    assert_equal(line, latest)
    assert_false(
        _probe(
            _http(200, "OK", '{"name":"projects/0/secrets/smtp/versions/4","state":"DESTROYED"}'),
            line,
        ),
        "a destroyed latest",
    )
    # No version, or no secret: NOT_FOUND.
    assert_false(
        _probe(_http(404, "Not Found", _status(404, String("NOT_FOUND"))), line),
        "no latest",
    )
    assert_equal(line, latest)

    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var denied = GcpSecretManagerWriter(
        _one(capture, _http(403, "Forbidden", _status(403, String("PERMISSION_DENIED"))))
    )
    var text = String("")
    try:
        _ = denied.has_version(String(_S), String(""))
    except e:
        text = String(e)
    assert_true(
        text.startswith(
            "GcpSecretManagerWriter: has_version of secret_ref " + _S
            + " failed: GET GetSecretVersion: HTTP 403, PERMISSION_DENIED (code 7)"
        ),
        text,
    )
    assert_false(text.find("leak-canary-31") >= 0, text)
    print("  test_has_version_reads_latest PASS")


def test_writer_refusals_send_nothing() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var w = GcpSecretManagerWriter(_one(capture, _http(200, "OK", "{}")))
    var texts = List[String]()
    try:
        _write(w, String(_S), String("v"), String("deploy-bearer-canary"))
    except e:
        texts.append(String(e))
    try:
        _ = w.has_version(String(_S), String("deploy-bearer-canary"))
    except e:
        texts.append(String(e))
    try:
        w.define_container(String(_S), String("deploy-bearer-canary"))
    except e:
        texts.append(String(e))
    assert_equal(len(texts), 3)
    for i in range(len(texts)):
        assert_true(texts[i].find("refused: a deploy token was given") >= 0, texts[i])
        assert_false(texts[i].find("deploy-bearer-canary") >= 0, texts[i])
    with assert_raises(contains="write refused: the handle names a version"):
        _write(w, String(_S) + "/versions/latest", String("v"), String(""))
    with assert_raises(contains="define_container refused: secret_ref is not a Secret Manager name"):
        w.define_container(String("p/s"), String(""))
    var pasted = String("")
    try:
        _ = w.has_version(String('projects/demo-project/secrets/{"password":"pasted-canary"}'), String(""))
    except e:
        pasted = String(e)
    assert_true(pasted.startswith("GcpSecretManagerWriter: has_version refused: secret_ref's secret id"), pasted)
    assert_false(pasted.find("pasted-canary") >= 0, pasted)
    assert_equal(len(capture[]), 0, "a refusal wrote to the wire")
    print("  test_writer_refusals_send_nothing PASS")


def main() raises:
    # Each leg runs; the failures are raised together at the end, so one
    # red run names every failing leg.
    var failed = List[String]()
    try:
        test_write_wire()
    except e:
        failed.append(String("test_write_wire: ") + String(e))
    try:
        test_write_create_race()
    except e:
        failed.append(String("test_write_create_race: ") + String(e))
    try:
        test_write_create_other_error()
    except e:
        failed.append(String("test_write_create_other_error: ") + String(e))
    try:
        test_create_body_replication()
    except e:
        failed.append(String("test_create_body_replication: ") + String(e))
    try:
        test_has_version_reads_latest()
    except e:
        failed.append(String("test_has_version_reads_latest: ") + String(e))
    try:
        test_writer_refusals_send_nothing()
    except e:
        failed.append(String("test_writer_refusals_send_nothing: ") + String(e))
    if len(failed) > 0:
        var text = String("FAILED:")
        for i in range(len(failed)):
            text += String("\n  ") + failed[i]
        raise Error(text)
    print("PASS kci_gcp_secret_writer")
