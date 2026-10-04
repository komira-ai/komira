# =============================================================================
# komira_job_supervisor/tests/test_heartbeat_auth_seam.mojo
#   The heartbeat request an operator's auth conformer produces is the one
#   that is serialized; the shipped no-auth default adds nothing.
# =============================================================================
#
# `build_heartbeat_request` is the one place the heartbeat POST is assembled,
# and `HttpHeartbeatReporter.report` sends exactly what it builds. These arms
# read the SERIALIZED request (`ClientRequest.request_bytes`), so "the header
# reaches the wire" is asserted, not inferred, without a network.
#
# Also: a heartbeat URL carrying userinfo is refused (a URL is a command-line
# value, and argv is readable by every user on the host), and the wire
# projection puts --job-name / --instance-name into the message's job_id /
# pod_name fields and reads the reply's cancel bit.
#
# EVERY ARM HAS A CONTROL.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_client.header_map import HeaderEntry
from komira_proto_codec import decode_proto, encode_proto
from komira_supervisor_proto.supervisor import (
    HeartbeatResponse as PbHeartbeatResponse,
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    JobPhase as PbJobPhase,
)

from komira_job_supervisor.heartbeat_auth import HeartbeatAuth, NoHeartbeatAuth
from komira_job_supervisor.heartbeat_client import (
    SupervisorHeartbeat,
    build_heartbeat_request,
    decode_cancel,
    encode_heartbeat,
    parse_heartbeat_url,
)
from komira_job_supervisor.job_supervisor_state import (
    FailureReport,
    JobSupervisorPhase,
)


comptime _TOKEN: String = "tok-0123456789abcdef"


struct SigningAuth(HeartbeatAuth):
    """An operator-style conformer that emits TWO headers derived from the
    request (a signing scheme's shape), to prove the seam carries more than
    one header and sees the method, URL and body."""

    var seen_method: String
    var seen_url: String
    var seen_body_len: Int

    def __init__(out self):
        self.seen_method = String("")
        self.seen_url = String("")
        self.seen_body_len = -1

    def name(self) -> String:
        return String("test-signing")

    def attaches_credential(self) -> Bool:
        return True

    def headers(
        mut self, method: String, url: String, body: List[UInt8]
    ) raises -> List[HeaderEntry]:
        self.seen_method = method
        self.seen_url = url
        self.seen_body_len = len(body)
        var out = List[HeaderEntry]()
        out.append(
            HeaderEntry(
                name=String("Authorization"), value=String("Bearer ") + _TOKEN
            )
        )
        out.append(
            HeaderEntry(
                name=String("X-Body-Length"), value=String(len(body))
            )
        )
        return out^


def _head_lower(var req_bytes: List[UInt8]) -> String:
    """The serialized request, lowercased (header names are
    case-insensitive), with non-ASCII bytes as '?' (the body is binary)."""
    var out = String("")
    for i in range(len(req_bytes)):
        var b = req_bytes[i]
        out += chr(Int(b)) if b < UInt8(0x80) else String("?")
    return out.lower()


def _beat() -> SupervisorHeartbeat:
    return SupervisorHeartbeat(
        String("nightly-report"),
        JobSupervisorPhase.running(),
        String("worker-7"),
        Optional[Int32](Int32(40)),
        Optional[String](String("halfway")),
        Optional[FailureReport](),
    )


def test_the_auth_headers_reach_the_serialized_request() raises:
    var url = String("https://hb.example.com:8443/v1/beat")
    var body = encode_heartbeat(_beat())
    var auth = SigningAuth()
    var hs = auth.headers(String("POST"), url, body)
    assert_equal(auth.seen_method, String("POST"), "the conformer sees the method")
    assert_equal(auth.seen_url, url, "the conformer sees the full URL")
    assert_equal(auth.seen_body_len, len(body), "the conformer sees the body")

    var req = build_heartbeat_request(url, body.copy(), hs)
    var head = _head_lower(req.request_bytes.copy())
    assert_true(
        head.startswith(String("post /v1/beat http/1.1")),
        "the POST goes to the URL's path: " + head,
    )
    assert_true(
        head.find(String("authorization: bearer ") + _TOKEN) >= 0,
        "the conformer's credential header is on the serialized wire",
    )
    assert_true(
        head.find(String("x-body-length: ") + String(len(body))) >= 0,
        "a second conformer header is on the wire too",
    )
    assert_true(
        head.find(String("content-type: application/protobuf")) >= 0,
        "the content type is protobuf",
    )
    _ = req^

    # CONTROL: the shipped no-auth default adds NO header at all.
    var none = NoHeartbeatAuth()
    assert_false(none.attaches_credential(), "CONTROL: none attaches nothing")
    var none_hs = none.headers(String("POST"), url, body)
    assert_equal(len(none_hs), 0, "CONTROL: none produces no header")
    var none_req = build_heartbeat_request(url, body.copy(), none_hs)
    var none_head = _head_lower(none_req.request_bytes.copy())
    assert_false(
        none_head.find(String("authorization")) >= 0,
        "CONTROL: no authorization header is serialized under none",
    )
    _ = none_req^
    print("  test_the_auth_headers_reach_the_serialized_request: PASS")


def test_a_url_with_userinfo_is_refused() raises:
    var refused = False
    var msg = String("")
    try:
        _ = parse_heartbeat_url(String("https://user:s3cret@hb.example.com/beat"))
    except e:
        refused = True
        msg = String(e)
    assert_true(refused, "userinfo in the heartbeat URL must be refused")
    assert_false(msg.find(String("s3cret")) >= 0, "the refusal does not echo it")

    var bad_scheme = False
    try:
        _ = parse_heartbeat_url(String("ftp://hb.example.com/beat"))
    except:
        bad_scheme = True
    assert_true(bad_scheme, "only http and https are accepted")

    # CONTROL: a plain https URL parses.
    var ok = parse_heartbeat_url(String("https://hb.example.com/beat"))
    assert_true(ok.is_https(), "CONTROL: https parses")
    print("  test_a_url_with_userinfo_is_refused: PASS")


def test_the_wire_projection() raises:
    var back = decode_proto[PbSupervisorHeartbeat](encode_heartbeat(_beat()))
    assert_equal(back.job_id, String("nightly-report"), "--job-name -> job_id")
    assert_equal(back.pod_name, String("worker-7"), "--instance-name -> pod_name")
    assert_equal(back.phase.value, PbJobPhase.JOB_PHASE_RUNNING, "phase")
    assert_equal(back.progress.value(), UInt32(40), "progress")
    assert_equal(back.message.value(), String("halfway"), "message")
    assert_false(Bool(back.node_id), "no partition-ownership fields")
    assert_equal(len(back.owned_partitions), 0, "no owned partitions")

    var yes = PbHeartbeatResponse(True, List[UInt32](), None, None, List[Int64]())
    assert_true(decode_cancel(encode_proto[PbHeartbeatResponse](yes)), "cancel")
    # CONTROL: an empty reply is all-defaults, cancel=false.
    assert_false(decode_cancel(List[UInt8]()), "CONTROL: empty reply, no cancel")
    print("  test_the_wire_projection: PASS")


def main() raises:
    print("test_heartbeat_auth_seam:")
    test_the_auth_headers_reach_the_serialized_request()
    test_a_url_with_userinfo_is_refused()
    test_the_wire_projection()
    print("test_heartbeat_auth_seam: ALL PASS")
