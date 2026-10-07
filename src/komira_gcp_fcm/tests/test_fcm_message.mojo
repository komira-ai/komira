# =============================================================================
# komira_gcp_fcm/tests/test_fcm_message.mojo -- the request: body, path,
#   refusals, and the scope Application Default Credentials asks for.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * test_golden_body: the body for a fixed wake, byte for byte, against a
#     literal spelled from FCM's v1 REST reference (`message.token`,
#     `message.data`, `message.android.priority` = HIGH). Catches a field
#     added to the data map (a `title` makes the wake carry content), a
#     `notification` block (no longer data-only), a priority spelled any
#     other way.
#   * test_data_key_set: the body parsed back: `message` holds exactly
#     token, data and android, and `data` exactly id, kind and source. The
#     same defects as the golden, stated as the content-blind rule rather
#     than as bytes.
#   * test_escaping: a `"` and `\` in every value round-trip through a JSON
#     parse; a builder that concatenated raw strings would break the body.
#   * test_refusals: an empty token or wake field, and a project id that
#     could leave its path segment (a `/`, `?`, upper case, or a `.`/`..`
#     dot segment a normalising server would remove), each refused with its
#     exact message.
#   * test_adc_scope_on_the_wire: `fcm_adc_options()` given to
#     komira_gcp_core's ADC over a scripted metadata server asks for exactly
#     the firebase.messaging scope (the token request target, whole); a
#     scope list with cloud-platform, or none, fails it. That the production
#     entry passes these options is test_fcm_loopback's step 5.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_gcp_core import (
    FixedWallClock,
    GcpHttpTransport,
    MapEnv,
    MapFiles,
    TokenHttpRequest,
    TokenHttpResponse,
    application_default_token_source_with,
)
from komira_json import parse_json_bytes
from komira_retry import ManualClock

from komira_gcp_fcm import (
    FCM_SCOPE,
    FcmWake,
    fcm_adc_options,
    fcm_message_json,
    fcm_send_path,
)


comptime _TOKEN = "dXJnOkFQQTkxYi1mYWtl:APA91b-fake_registration-token"


def _wake() -> FcmWake:
    return FcmWake(
        String("evt-0001"), String("job.failed"), String("jobs.example.com")
    )


def test_golden_body() raises:
    assert_equal(
        fcm_message_json(String(_TOKEN), _wake()),
        String('{"message":{"token":"')
        + _TOKEN
        + '","data":{"id":"evt-0001","kind":"job.failed",'
        + '"source":"jobs.example.com"},"android":{"priority":"HIGH"}}}',
    )
    print("  test_golden_body PASS")


def _keys(doc_text: String, path: String) raises -> List[String]:
    var bytes = List[UInt8]()
    bytes.extend(Span(doc_text.as_bytes()))
    var v = parse_json_bytes(bytes, 16)
    var at = v.get(String("message"))
    if path == "data":
        at = at.get(String("data"))
    var out = List[String]()
    for i in range(at.num_members()):
        out.append(at.key_at(i))
    return out^


def _expect(got: List[String], want: List[String], what: String) raises:
    assert_equal(len(got), len(want), what + ": key count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + " key #" + String(i))


def test_data_key_set() raises:
    var body = fcm_message_json(String(_TOKEN), _wake())
    _expect(
        _keys(body, String("message")),
        [String("token"), String("data"), String("android")],
        String("message"),
    )
    _expect(
        _keys(body, String("data")),
        [String("id"), String("kind"), String("source")],
        String("data"),
    )
    print("  test_data_key_set PASS")


def test_escaping() raises:
    var odd = String('a"b\\c')
    var body = fcm_message_json(odd, FcmWake(odd, odd, odd))
    var bytes = List[UInt8]()
    bytes.extend(Span(body.as_bytes()))
    var m = parse_json_bytes(bytes, 16).get(String("message"))
    assert_equal(m.get(String("token")).as_string(), odd)
    var d = m.get(String("data"))
    assert_equal(d.get(String("id")).as_string(), odd)
    assert_equal(d.get(String("kind")).as_string(), odd)
    assert_equal(d.get(String("source")).as_string(), odd)
    print("  test_escaping PASS")


def _refusal_of_body(token: String, wake: FcmWake) -> String:
    try:
        _ = fcm_message_json(token, wake)
    except e:
        return String(e)
    return String("<not refused>")


def _refusal_of_path(project: String) -> String:
    try:
        _ = fcm_send_path(project)
    except e:
        return String(e)
    return String("<not refused>")


def test_refusals() raises:
    var t = String(_TOKEN)
    var e = String()
    assert_equal(
        _refusal_of_body(e, _wake()),
        "komira_gcp_fcm: the device token is empty",
    )
    assert_equal(
        _refusal_of_body(t, FcmWake(e, String("k"), String("s"))),
        "komira_gcp_fcm: the wake id is empty",
    )
    assert_equal(
        _refusal_of_body(t, FcmWake(String("i"), e, String("s"))),
        "komira_gcp_fcm: the wake kind is empty",
    )
    assert_equal(
        _refusal_of_body(t, FcmWake(String("i"), String("k"), e)),
        "komira_gcp_fcm: the wake source is empty",
    )
    assert_equal(
        fcm_send_path(String("example-project-123")),
        "/v1/projects/example-project-123/messages:send",
    )
    assert_equal(
        fcm_send_path(String("example.com:legacy-project")),
        "/v1/projects/example.com:legacy-project/messages:send",
    )
    assert_equal(_refusal_of_path(e), "komira_gcp_fcm: the project id is empty")
    var outside = String(
        "komira_gcp_fcm: the project id holds a byte outside [a-z0-9.:-]"
    )
    assert_equal(_refusal_of_path(String("p/../other")), outside)
    assert_equal(_refusal_of_path(String("p?x=1")), outside)
    assert_equal(_refusal_of_path(String("Project")), outside)
    # A dot segment: every byte is allowed, so only the first-byte rule
    # refuses it.
    var start = String(
        "komira_gcp_fcm: the project id does not start with [a-z0-9]"
    )
    assert_equal(_refusal_of_path(String("..")), start)
    assert_equal(_refusal_of_path(String(".")), start)
    assert_equal(_refusal_of_path(String("-p")), start)
    print("  test_refusals PASS")


# -----------------------------------------------------------------------------
# A scripted metadata server: answers each token request with `body` and
# keeps each request target in `targets` (shared with the test).
# -----------------------------------------------------------------------------


struct _Metadata(GcpHttpTransport, Movable, Deinitable):
    var targets: ArcPointer[List[String]]

    def __init__(out self, targets: ArcPointer[List[String]]):
        self.targets = targets

    def send(mut self, req: TokenHttpRequest) raises -> TokenHttpResponse:
        self.targets[].append(req.target.copy())
        var body = List[UInt8]()
        body.extend(
            Span(String('{"access_token":"ya29.FCM","expires_in":3599}').as_bytes())
        )
        return TokenHttpResponse(200, body^)


def test_adc_scope_on_the_wire() raises:
    var targets = ArcPointer(List[String]())
    var env = MapEnv()
    env.set(String("GCE_METADATA_HOST"), String("127.0.0.1:8080"))
    var files = MapFiles()
    var src = application_default_token_source_with(
        env,
        files,
        _Metadata(targets),
        _Metadata(targets),
        _Metadata(targets),
        FixedWallClock(1_790_000_000),
        ManualClock(0),
        fcm_adc_options(),
    )
    assert_equal(src.access_token(), "ya29.FCM")
    assert_equal(len(targets[]), 1, "one token request")
    assert_equal(
        targets[][0],
        "/computeMetadata/v1/instance/service-accounts/default/token"
        "?scopes=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Ffirebase.messaging",
    )
    assert_equal(len(fcm_adc_options().scopes), 1)
    assert_equal(fcm_adc_options().scopes[0], String(FCM_SCOPE))
    print("  test_adc_scope_on_the_wire PASS")


def main() raises:
    test_golden_body()
    test_data_key_set()
    test_escaping()
    test_refusals()
    test_adc_scope_on_the_wire()
    print("PASS komira_gcp_fcm message")
