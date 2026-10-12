# =============================================================================
# komira_gcp_fcm/tests/test_fcm_reading.mojo -- the edges of outcome.mojo's
#   readers: outcome names, the FcmError `errorCode` reader, the accepted
#   answer's `name`, and the status and Retry-After boundaries.
# =============================================================================
#
# test_fcm_outcome.mojo proves the answer table on well-formed envelopes;
# this file proves each reader's boundary and each shape it must turn down.
# Every body is synthetic, in the shape FCM's v1 reference documents.
#
# Each test is run by `main` on its own and every failure is printed before
# the run fails, and each case of a test is checked even after another case
# of it fails, so one broken reader does not hide another.
#
# What each test proves, and the defect it catches:
#   * test_outcome_names: the four kinds by name, and any other number as
#     `UNKNOWN(<n>)`. Catches a lost arm (REFUSED printed as UNKNOWN(3)) and
#     an unknown kind printed as a real one.
#   * test_error_code_token: the errorCode kept only as a bare `[A-Z_]` token
#     of 1 to 64 bytes: `A`, `Z`, `_` and 64 bytes kept; empty, 65 bytes, `@`
#     (just below `A`) and `[` (just above `Z`) turned down. Catches an
#     off-by-one on the length cap or either end of the letter range, and a
#     lost `_`.
#   * test_error_code_envelope_shapes: no code from a document that is not
#     an object, has no `error`, whose `error` is not an object, has no
#     `details`, or whose `details` is not an array; the walk passes over
#     entries that are not objects, have no `@type`, or whose `@type` is not
#     a string; the first FcmError decides (one with no `errorCode`, or a
#     non-string one, yields "" even when a later FcmError names
#     UNREGISTERED; of two codes the first is kept). Catches a walk that
#     stops at the first odd entry, and one that reads past the first
#     FcmError (a later entry would make a live token DEAD).
#   * test_parse_size_bound: a body of exactly 65536 bytes is read (errorCode
#     and accepted `name`), one of 65537 is not. Catches an off-by-one on
#     either reader's cap, and a cap that was dropped.
#   * test_message_name_shapes: a 2xx answer whose body is not JSON, is not
#     an object, has no `name`, or a non-string `name` has message_name "".
#   * test_status_bounds: 199 and 300 REFUSED, 200 and 299 ACCEPTED, 428 and
#     430 REFUSED, 429 TRANSIENT, 499 and 600 REFUSED, 500 and 599
#     TRANSIENT, 403 and 405 REFUSED, 404 DEAD. Catches an off-by-one on
#     each range end, and an equality widened to an ordering.
#   * test_retry_after_bounds: Retry-After 0 is 0 ms (not "none"), 10^9 s
#     and 10^9 + 1 s are both 10^12 ms, a negative header falls through to
#     RetryInfo, a RetryInfo of "0s" is 0 ms. Catches `>= 0` read as `> 0`
#     on either source, and a clamp that is skipped.
# =============================================================================


from komira_gcp_fcm import (
    FCM_ACCEPTED,
    FCM_DEAD,
    FCM_ERROR_TYPE,
    FCM_REFUSED,
    FCM_TRANSIENT,
    classify_fcm_response,
    fcm_error_code,
    fcm_outcome_name,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _rep(c: String, n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += c
    return out^


def _fcm(error_code_json: String) -> String:
    """An FcmError detail entry; `error_code_json` is the JSON value."""
    return (
        String('{"@type":"') + String(FCM_ERROR_TYPE) + '","errorCode":'
        + error_code_json + "}"
    )


def _with_details(details: String) -> List[UInt8]:
    return _bytes(
        String('{"error":{"code":400,"status":"INVALID_ARGUMENT","details":[')
        + details + "]}}"
    )


def _code_of(error_code: String) -> String:
    return fcm_error_code(_with_details(_fcm(String('"') + error_code + '"')))


def _kind(status: Int) -> String:
    return fcm_outcome_name(classify_fcm_response(status, -1, List[UInt8]()).kind)



def _eq[T: Equatable & Writable](
    mut bad: List[String], got: T, want: T, what: String = ""
):
    """Records a mismatch instead of stopping, so every case of a table runs
    and a failure names each case that went wrong."""
    if not (got == want):
        bad.append(what + " (got " + String(got) + ", want " + String(want) + ")")


def _done(bad: List[String]) raises:
    if len(bad) > 0:
        var all = String()
        for i in range(len(bad)):
            all += "\n    MISMATCH " + bad[i]
        raise Error(String(len(bad)) + " mismatch(es):" + all)

# -----------------------------------------------------------------------------


def test_outcome_names() raises:
    var bad = List[String]()
    _eq(bad, fcm_outcome_name(FCM_ACCEPTED), "ACCEPTED")
    _eq(bad, fcm_outcome_name(FCM_DEAD), "DEAD")
    _eq(bad, fcm_outcome_name(FCM_TRANSIENT), "TRANSIENT")
    _eq(bad, fcm_outcome_name(FCM_REFUSED), "REFUSED")
    _eq(bad, fcm_outcome_name(4), "UNKNOWN(4)", "one past the last kind")
    _eq(bad, fcm_outcome_name(-1), "UNKNOWN(-1)", "a negative kind")
    _done(bad)


def test_error_code_token() raises:
    var bad = List[String]()
    _eq(bad, _code_of(String("A")), "A", "the low end of [A-Z]")
    _eq(bad, _code_of(String("Z")), "Z", "the high end of [A-Z]")
    _eq(bad, _code_of(String("_")), "_", "an underscore")
    var at_cap = _rep(String("Q"), 64)
    _eq(bad, _code_of(at_cap), at_cap, "64 bytes is kept")
    _eq(bad, _code_of(_rep(String("Q"), 65)), "", "65 bytes is not")
    _eq(bad, _code_of(String()), "", "an empty errorCode")
    _eq(bad, _code_of(String("A@")), "", "@ sits just below A")
    _eq(bad, _code_of(String("Z[")), "", "[ sits just above Z")
    _done(bad)


def test_error_code_envelope_shapes() raises:
    var bad = List[String]()
    var unreg = _fcm(String('"UNREGISTERED"'))
    _eq(bad,
        fcm_error_code(_bytes(String('[{"error":{"details":[') + unreg + "]}}]")),
        "",
        "a document that is not an object",
    )
    _eq(bad,
        fcm_error_code(_bytes(String('{"err":{"details":[') + unreg + "]}}")),
        "",
        "no error member",
    )
    _eq(bad,
        fcm_error_code(_bytes(String('{"error":"UNREGISTERED"}'))),
        "",
        "an error that is not an object",
    )
    _eq(bad,
        fcm_error_code(_bytes(String('{"error":{"code":404,"errorCode":"UNREGISTERED"}}'))),
        "",
        "an error with no details",
    )
    _eq(bad,
        fcm_error_code(_bytes(String('{"error":{"details":') + unreg + "}}")),
        "",
        "details that are not an array",
    )
    # The walk passes over every entry that cannot be an FcmError.
    _eq(bad,
        fcm_error_code(
            _with_details(
                String('1,"UNREGISTERED",{"errorCode":"QUOTA_EXCEEDED"},')
                + '{"@type":7,"errorCode":"INTERNAL"},' + unreg
            )
        ),
        "UNREGISTERED",
        "entries that are not FcmError are passed over",
    )
    # The first FcmError decides.
    _eq(bad,
        fcm_error_code(_with_details(String('{"@type":"') + String(FCM_ERROR_TYPE) + '"},' + unreg)),
        "",
        "a first FcmError with no errorCode",
    )
    _eq(bad,
        fcm_error_code(_with_details(_fcm(String("7")) + "," + unreg)),
        "",
        "a first FcmError whose errorCode is not a string",
    )
    _eq(bad,
        fcm_error_code(_with_details(_fcm(String('"QUOTA_EXCEEDED"')) + "," + unreg)),
        "QUOTA_EXCEEDED",
        "of two FcmErrors the first is kept",
    )
    _eq(bad,
        _kind_of_body(503, _with_details(_fcm(String('"QUOTA_EXCEEDED"')) + "," + unreg)),
        "TRANSIENT",
        "a later UNREGISTERED does not make the token DEAD",
    )
    _done(bad)


def _kind_of_body(status: Int, body: List[UInt8]) -> String:
    return fcm_outcome_name(classify_fcm_response(status, -1, body).kind)


def _padded(core: String, total: Int) -> List[UInt8]:
    """`core` (a JSON object) with spaces after its opening brace, `total`
    bytes in all."""
    var pad = total - core.byte_length()
    var b = core.as_bytes()
    var out = List[UInt8]()
    out.append(b[0])
    for _ in range(pad):
        out.append(UInt8(ord(" ")))
    for i in range(1, len(b)):
        out.append(b[i])
    return out^


def test_parse_size_bound() raises:
    var bad = List[String]()
    var env = String('{"error":{"code":404,"status":"NOT_FOUND","details":[') + _fcm(
        String('"UNREGISTERED"')
    ) + "]}}"
    var at_cap = _padded(env, 65536)
    _eq(bad, len(at_cap), 65536)
    _eq(bad, fcm_error_code(at_cap), "UNREGISTERED", "a 65536-byte envelope is read")
    var over = _padded(env, 65537)
    _eq(bad, len(over), 65537)
    _eq(bad, fcm_error_code(over), "", "a 65537-byte envelope is not")
    var ok = String('{"name":"projects/example-project-123/messages/1"}')
    _eq(bad,
        classify_fcm_response(200, -1, _padded(ok, 65536)).message_name,
        "projects/example-project-123/messages/1",
        "a 65536-byte answer's name is read",
    )
    _eq(bad,
        classify_fcm_response(200, -1, _padded(ok, 65537)).message_name,
        "",
        "a 65537-byte answer's name is not",
    )
    _done(bad)


def test_message_name_shapes() raises:
    var bad = List[String]()
    _eq(bad, classify_fcm_response(200, -1, _bytes(String("not json"))).message_name, "", "not JSON")
    _eq(bad, classify_fcm_response(200, -1, _bytes(String('["name"]'))).message_name, "", "an array")
    _eq(bad, classify_fcm_response(200, -1, _bytes(String('{"nam":"x"}'))).message_name, "", "no name")
    _eq(bad, classify_fcm_response(200, -1, _bytes(String('{"name":5}'))).message_name, "", "a number")
    _eq(bad, classify_fcm_response(201, -1, _bytes(String('{"name":"n"}'))).message_name, "n", "201")
    _done(bad)


def test_status_bounds() raises:
    var bad = List[String]()
    _eq(bad, _kind(199), "REFUSED", "199")
    _eq(bad, _kind(200), "ACCEPTED", "200")
    _eq(bad, _kind(299), "ACCEPTED", "299")
    _eq(bad, _kind(300), "REFUSED", "300")
    _eq(bad, _kind(403), "REFUSED", "403")
    _eq(bad, _kind(404), "DEAD", "404")
    _eq(bad, _kind(405), "REFUSED", "405")
    _eq(bad, _kind(428), "REFUSED", "428")
    _eq(bad, _kind(429), "TRANSIENT", "429")
    _eq(bad, _kind(430), "REFUSED", "430")
    _eq(bad, _kind(499), "REFUSED", "499")
    _eq(bad, _kind(500), "TRANSIENT", "500")
    _eq(bad, _kind(599), "TRANSIENT", "599")
    _eq(bad, _kind(600), "REFUSED", "600")
    _eq(bad, classify_fcm_response(299, -1, List[UInt8]()).http_status, 299)
    _eq(bad, classify_fcm_response(600, -1, List[UInt8]()).http_status, 600)
    _done(bad)


def test_retry_after_bounds() raises:
    var bad = List[String]()
    var none = List[UInt8]()
    _eq(bad, classify_fcm_response(503, 0, none.copy()).retry_after_ms, 0, "Retry-After 0")
    _eq(bad,
        classify_fcm_response(503, 1_000_000_000, none.copy()).retry_after_ms,
        1_000_000_000_000,
        "Retry-After at the cap",
    )
    _eq(bad,
        classify_fcm_response(503, 1_000_000_001, none.copy()).retry_after_ms,
        1_000_000_000_000,
        "Retry-After one past the cap",
    )
    var zero_info = _bytes(
        String('{"error":{"code":503,"status":"UNAVAILABLE","details":[')
        + '{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"0s"}]}}'
    )
    _eq(bad, classify_fcm_response(503, -1, zero_info.copy()).retry_after_ms, 0, "RetryInfo 0s")
    var info = _bytes(
        String('{"error":{"code":503,"status":"UNAVAILABLE","details":[')
        + '{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"4s"}]}}'
    )
    _eq(bad,
        classify_fcm_response(503, -2, info.copy()).retry_after_ms,
        4000,
        "a negative Retry-After falls through to RetryInfo",
    )
    _eq(bad,
        classify_fcm_response(400, 5, info.copy()).retry_after_ms,
        -1,
        "no delay on REFUSED, from either source",
    )
    _done(bad)


def main() raises:
    var failed = List[String]()
    try:
        test_outcome_names()
    except e:
        failed.append(String("test_outcome_names: ") + String(e))
    try:
        test_error_code_token()
    except e:
        failed.append(String("test_error_code_token: ") + String(e))
    try:
        test_error_code_envelope_shapes()
    except e:
        failed.append(String("test_error_code_envelope_shapes: ") + String(e))
    try:
        test_parse_size_bound()
    except e:
        failed.append(String("test_parse_size_bound: ") + String(e))
    try:
        test_message_name_shapes()
    except e:
        failed.append(String("test_message_name_shapes: ") + String(e))
    try:
        test_status_bounds()
    except e:
        failed.append(String("test_status_bounds: ") + String(e))
    try:
        test_retry_after_bounds()
    except e:
        failed.append(String("test_retry_after_bounds: ") + String(e))
    for i in range(len(failed)):
        print("FAIL", failed[i])
    if len(failed) > 0:
        raise Error(String(len(failed)) + " test(s) of test_fcm_reading failed")
    print("PASS komira_gcp_fcm reading")
