# =============================================================================
# komira_job_supervisor/tests/test_heartbeat_delivery_edges.mojo
#   How a beat's reply is read, the refusals a reporter repeats per beat, a
#   process out of file descriptors, the auth conformers' edges, and the
#   transport the S3 credential chain dials through.
# =============================================================================
#
#   test_only_a_2xx_reply_is_read_for_its_directive
#       `send_heartbeat` over a scripted connection: a 200 whose body says
#       CANCEL is ok and cancels; a 200 with an empty body is ok and does not;
#       a 503 and a 300 whose bodies say CANCEL are not ok and cancel nothing
#       (an error envelope is never decoded as a reply).
#   test_the_plaintext_refusal_is_repeated_before_every_beat
#       A reporter built with an auth that attaches nothing over http://, whose
#       auth then starts attaching a credential: the next beat is refused
#       (AUTH_REFUSED) before the auth is asked. CONTROL: back to attaching
#       nothing, the auth is asked and the beat is dialled.
#   test_a_beat_with_no_file_descriptor_left_fails_softly
#       With the descriptor limit at the lowest free descriptor, a beat cannot
#       build its runtime: the outcome is a failed delivery (status 0), and
#       nothing raises.
#   test_the_auth_conformers_edges
#       NoHeartbeatAuth's name; a bearer file path that is empty; a bearer
#       credential from a variable names itself bearer-env; a bearer conformer
#       holding no credential refuses to produce headers.
#   test_the_credential_transport_dials_only_http_and_https
#       S3CredentialTransport refuses any scheme but http and https, naming
#       it; an http and an https request each go to their transport (a closed
#       loopback port: the error is the dial's, not the scheme refusal).
# =============================================================================

from std.ffi import external_call
from std.os import setenv
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_aws_core.credential_transport import CredentialHttpRequest
from komira_http_client.client import HttpClient
from komira_http_client.header_map import HeaderEntry
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_job_supervisor import (
    BearerHeartbeatAuth,
    HEARTBEAT_STATUS_AUTH_REFUSED,
    HeartbeatAuth,
    HeartbeatOutcome,
    HttpHeartbeatReporter,
    NoHeartbeatAuth,
    SupervisorHeartbeat,
)
from komira_job_supervisor.heartbeat_client import send_heartbeat
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase
from komira_job_supervisor.s3_store import S3CredentialTransport


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _cancel_reply() -> List[UInt8]:
    """A JobHeartbeatReply whose directive (field 1, varint) is CANCEL (1)."""
    var out = List[UInt8]()
    out.append(UInt8(0x08))
    out.append(UInt8(0x01))
    return out^


def _answer(status_line: String, var body: List[UInt8]) -> ScriptedConnector:
    var wire = _bytes(
        String("HTTP/1.1 ")
        + status_line
        + "\r\nContent-Length: "
        + String(len(body))
        + "\r\n\r\n"
    )
    for i in range(len(body)):
        wire.append(body[i])
    return ScriptedConnector.with_stream(ScriptedStream.from_read_script(wire^))


def _send(var conn: ScriptedConnector) raises -> HeartbeatOutcome:
    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var client = HttpClient[ScriptedConnector].with_defaults(conn^)
    return send_heartbeat[BlockingRuntime[NoopSink], ScriptedConnector](
        client,
        reactor,
        String("http://127.0.0.1:9/v1/beat"),
        _bytes(String("beat")),
        List[HeaderEntry](),
    )


def test_only_a_2xx_reply_is_read_for_its_directive() raises:
    var cancel = _send(_answer(String("200 OK"), _cancel_reply()))
    assert_true(cancel.ok, "200: delivered")
    assert_true(cancel.cancel, "200 + CANCEL: cancel")
    assert_equal(cancel.status, 200)

    var go_on = _send(_answer(String("200 OK"), List[UInt8]()))
    assert_true(go_on.ok, "200, empty body: delivered")
    assert_false(go_on.cancel, "an empty reply is CONTINUE")

    var busy = _send(_answer(String("503 Service Unavailable"), _cancel_reply()))
    assert_false(busy.ok, "503: not delivered")
    assert_false(busy.cancel, "a 503 body is not a reply")
    assert_equal(busy.status, 503)

    var moved = _send(_answer(String("300 Multiple Choices"), _cancel_reply()))
    assert_false(moved.ok, "300: not a 2xx")
    assert_false(moved.cancel, "a 300 body is not a reply")
    assert_equal(moved.status, 300)
    print("  test_only_a_2xx_reply_is_read_for_its_directive: PASS")


struct ToggleAuth(HeartbeatAuth):
    """Attaches a credential iff `attach`; counts its calls."""

    var attach: Bool
    var calls: Int

    def __init__(out self, attach: Bool):
        self.attach = attach
        self.calls = 0

    def name(self) -> String:
        return String("toggle")

    def attaches_credential(self) -> Bool:
        return self.attach

    def headers(
        mut self, method: String, url: String, body: List[UInt8]
    ) raises -> List[HeaderEntry]:
        self.calls += 1
        return List[HeaderEntry]()


def _beat() -> SupervisorHeartbeat:
    return SupervisorHeartbeat(
        String("job-1"), JobSupervisorPhase.running(), String("inst-1"), None, None, None
    )


def test_the_plaintext_refusal_is_repeated_before_every_beat() raises:
    var url = String("http://127.0.0.1:1/beat")
    var reporter = HttpHeartbeatReporter[ToggleAuth](url, ToggleAuth(False))
    assert_equal(reporter.url(), url)
    assert_false(reporter.uses_tls())
    reporter.auth().attach = True
    var refused = reporter.report(_beat())
    assert_false(refused.ok)
    assert_equal(refused.status, HEARTBEAT_STATUS_AUTH_REFUSED)
    assert_equal(reporter.auth().calls, 0, "the auth was never asked")
    # CONTROL: attaching nothing again, the auth is asked and the beat dialled
    # (the closed port answers nothing: status 0).
    reporter.auth().attach = False
    var dialled = reporter.report(_beat())
    assert_equal(reporter.auth().calls, 1)
    assert_equal(dialled.status, 0)
    print("  test_the_plaintext_refusal_is_repeated_before_every_beat: PASS")


comptime _RLIMIT_NOFILE_LINUX: Int32 = 7
comptime _RLIMIT_NOFILE_MACOS: Int32 = 8


def _nofile() -> Int32:
    comptime if CompilationTarget.is_macos():
        return _RLIMIT_NOFILE_MACOS
    else:
        return _RLIMIT_NOFILE_LINUX


def test_a_beat_with_no_file_descriptor_left_fails_softly() raises:
    var reporter = HttpHeartbeatReporter[NoHeartbeatAuth](
        String("http://127.0.0.1:1/beat"), NoHeartbeatAuth()
    )
    var saved = InlineArray[UInt64, 2](fill=UInt64(0))
    # SAFETY: `saved` is a local two-word rlimit the call fills synchronously.
    var rc = external_call["getrlimit", Int32](_nofile(), saved.unsafe_ptr())
    assert_equal(rc, Int32(0), "getrlimit")
    var lowest = external_call["dup", Int32](Int32(2))
    assert_true(lowest >= Int32(0), "dup")
    _ = external_call["close", Int32](lowest)
    var tight = InlineArray[UInt64, 2](fill=UInt64(0))
    tight[0] = UInt64(Int(lowest))
    tight[1] = saved[1]
    # SAFETY: `tight` is a local two-word rlimit the call reads synchronously.
    rc = external_call["setrlimit", Int32](_nofile(), tight.unsafe_ptr())
    assert_equal(rc, Int32(0), "setrlimit")
    var out = reporter.report(_beat())
    # SAFETY: as above; restores the limit before any assertion can raise.
    rc = external_call["setrlimit", Int32](_nofile(), saved.unsafe_ptr())
    assert_equal(rc, Int32(0), "the limit is restored")
    assert_false(out.ok, "no descriptor: not delivered")
    assert_false(out.cancel)
    assert_equal(out.status, 0, "a delivery failure, not an auth one")
    print("  test_a_beat_with_no_file_descriptor_left_fails_softly: PASS")


def test_the_auth_conformers_edges() raises:
    assert_equal(NoHeartbeatAuth().name(), String("none"))

    var r = String("")
    try:
        _ = BearerHeartbeatAuth.from_file(String(""))
    except e:
        r = String(e)
    assert_true(r.find(String("credential file path is empty")) >= 0, r)

    var name = String("KOMIRA_JOB_SUPERVISOR_EDGE_TOKEN")
    _ = setenv(name, String("tok-edge-0123456789"), True)
    var env_auth = BearerHeartbeatAuth.from_env(name)
    assert_equal(env_auth.name(), String("bearer-env"))
    assert_false(env_auth.reads_file_per_beat())

    var empty = BearerHeartbeatAuth(String(""), None)
    r = String("")
    try:
        _ = empty.headers(String("POST"), String("https://hb.example.com/"), List[UInt8]())
    except e:
        r = String(e)
    assert_true(r.find(String("no heartbeat credential is held")) >= 0, r)
    print("  test_the_auth_conformers_edges: PASS")


def _dial_error(scheme: String) -> String:
    var t = S3CredentialTransport()
    var req = CredentialHttpRequest(
        String("GET"), scheme, String("127.0.0.1"), 1, String("/credentials")
    )
    try:
        _ = t.send(req)
    except e:
        return String(e)
    return String("<answered>")


def test_the_credential_transport_dials_only_http_and_https() raises:
    var ftp = _dial_error(String("ftp"))
    assert_true(
        ftp.find(String("a provider asked for scheme ftp, not http or https")) >= 0,
        ftp,
    )
    var http = _dial_error(String("http"))
    assert_false(http.find(String("not http or https")) >= 0, "http is dialled: " + http)
    assert_false(http == String("<answered>"), "the closed port answers nothing")
    var https = _dial_error(String("https"))
    assert_false(
        https.find(String("not http or https")) >= 0, "https is dialled: " + https
    )
    assert_false(https == String("<answered>"))
    print("  test_the_credential_transport_dials_only_http_and_https: PASS")


def main() raises:
    print("test_heartbeat_delivery_edges:")
    test_only_a_2xx_reply_is_read_for_its_directive()
    test_the_plaintext_refusal_is_repeated_before_every_beat()
    test_a_beat_with_no_file_descriptor_left_fails_softly()
    test_the_auth_conformers_edges()
    test_the_credential_transport_dials_only_http_and_https()
    print("test_heartbeat_delivery_edges: ALL PASS")
