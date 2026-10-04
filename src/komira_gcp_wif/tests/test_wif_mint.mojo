# =============================================================================
# komira_gcp_wif/tests/test_wif_mint.mojo — both legs on the wire, over
#   komira_http_core's ScriptedConnector: no socket, no real credential.
# =============================================================================
#
# The real code runs end to end (SigV4 signing, the subject token, the form
# body, the token cache, the signJwt request) against scripted responses, and
# each test reads back the exact bytes the client wrote.
#
# ⛔ EXACT SETS, NEVER SUBSTRING PRESENCE. A `find("authorization") >= 0` check
# passes a change that plants a SECOND credential header; every header claim
# here is an equality against the full sorted name list, and every form claim
# an equality against the ordered field list.
#
# ⛔ EVERY ABSENCE CLAIM HAS A POSITIVE CONTROL. "signJwt was never dialed" is
# true of a minter that never reaches leg 2 at all, so the success-path test
# drives the same connector shape to a non-empty capture.
#
# The scripted responses are SYNTHETIC, written from the documented response
# schemas (STS: `access_token`, `issued_token_type`, `token_type`,
# `expires_in`; signJwt: `keyId`, `signedJwt`). They prove the code builds and
# reads the wire as specified, not that a live provider accepts it.
#
# No real credential: AWS's published documentation key pair.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_gcp_core import CachingTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock

from komira_gcp_wif import (
    AwsWifTokenFetcher,
    SIGNED_JWT_TTL_SECONDS,
    WifTokenMinter,
    aws1_subject_token,
)


comptime TIMEOUT_US: Int = 5_000_000
comptime REGION = "us-east-1"
comptime NOW_S: Int = 1_790_856_000  # 20261001T120000Z
comptime AMZ_DATE = "20261001T120000Z"
comptime AUDIENCE = (
    "//iam.googleapis.com/projects/1234567890/locations/global/"
    "workloadIdentityPools/example-pool/providers/example-aws"
)
comptime SA = "delivery@example-project.iam.gserviceaccount.com"
comptime JWT_AUD = "https://ingest.example.com"
comptime SESSION = "FwoGZXIvYXdzEXAMPLE+SESSION/TOKEN=="
comptime FEDERATED = "ya29.FEDERATED-FAKE"
comptime SIGNED = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJmYWtlIn0.SIGNATURE-FAKE"

comptime Fetcher = AwsWifTokenFetcher[ScriptedConnector, StaticCredsSource, FixedClock]
comptime Source = CachingTokenSource[Fetcher, ManualClock]
comptime Minter = WifTokenMinter[ScriptedConnector, Source, FixedClock]


# =============================================================================
# Fixtures. Every response SYNTHETIC; see the file header.
# =============================================================================


def _cred() -> AwsCredential:
    return AwsCredential(
        String("AKIAIOSFODNN7EXAMPLE"),
        String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        String(SESSION),
    )


def _http(status_line: String, body: String) -> List[UInt8]:
    var http = String("HTTP/1.1 ") + status_line + String("\r\nContent-Length: ")
    http += String(len(body.as_bytes()))
    http += String("\r\nConnection: close\r\n\r\n")
    http += body
    var out = List[UInt8]()
    out.extend(Span(http.as_bytes()))
    return out^


def _sts_ok() -> List[UInt8]:
    return _http(
        String("200 OK"),
        String('{"access_token":"') + FEDERATED + '","issued_token_type":'
        + '"urn:ietf:params:oauth:token-type:access_token","token_type":'
        + '"Bearer","expires_in":3600}',
    )


def _signjwt_ok() -> List[UInt8]:
    return _http(
        String("200 OK"), String('{"keyId":"fake-key-id","signedJwt":"') + SIGNED + '"}'
    )


def _capture() -> ArcPointer[List[UInt8]]:
    return ArcPointer[List[UInt8]](List[UInt8]())


def _text(cap: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(cap[]))


def _armed(var script: List[UInt8], shared: ArcPointer[List[UInt8]]) -> ScriptedConnector:
    """One response, and a write capture shared with the test. Reports TLS so
    the client's https scheme check passes; no handshake runs."""
    return ScriptedConnector.with_stream_tls(
        ScriptedStream.from_read_script_with_capture(script^, shared)
    )


def _fetcher(var sts: ScriptedConnector) raises -> Fetcher:
    return Fetcher(
        HttpClient[ScriptedConnector].with_request_timeout_us(sts^, TIMEOUT_US),
        StaticCredsSource(_cred()),
        FixedClock(NOW_S),
        String(REGION),
        String(AUDIENCE),
    )


def _minter(var sts: ScriptedConnector, var iam: ScriptedConnector) raises -> Minter:
    return Minter(
        HttpClient[ScriptedConnector].with_request_timeout_us(iam^, TIMEOUT_US),
        Source(_fetcher(sts^), ManualClock(0)),
        FixedClock(NOW_S),
    )


# =============================================================================
# Readers of what the client wrote. Strict on purpose.
# =============================================================================


def _head_lines(req: String) -> List[String]:
    """The request head's lines, request line first, up to the blank line."""
    var out = List[String]()
    var b = req.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(ord("\n")):
            var end = i
            if end > start and b[end - 1] == UInt8(ord("\r")):
                end -= 1
            if end == start:
                break
            out.append(String(unsafe_from_utf8=b[start:end]))
            start = i + 1
    return out^


def _header_names(req: String) raises -> String:
    """Every header name, lowercased and sorted, comma-joined."""
    var lines = _head_lines(req)
    var names = List[String]()
    for i in range(1, len(lines)):
        var colon = lines[i].find(":")
        if colon <= 0:
            raise Error("a head line with no name: " + lines[i])
        names.append(String(lines[i][byte=0:colon]).lower())
    sort(names)
    var out = String("")
    for i in range(len(names)):
        if i > 0:
            out += ","
        out += names[i]
    return out^


def _header_value(req: String, name: String) raises -> String:
    var lines = _head_lines(req)
    var found = List[String]()
    for i in range(1, len(lines)):
        var colon = lines[i].find(":")
        if colon > 0 and String(lines[i][byte=0:colon]).lower() == name:
            found.append(String(String(lines[i][byte=colon + 1 :]).strip()))
    if len(found) != 1:
        raise Error("header " + name + " appears " + String(len(found)) + " times")
    return found[0].copy()


def _body_of(req: String) -> String:
    var at = req.find("\r\n\r\n")
    if at < 0:
        return String("")
    return String(req[byte = at + 4 :])


def _form_fields(body: String) -> List[String]:
    var out = List[String]()
    for part in body.split("&"):
        var eq = part.find("=")
        out.append(String(part[byte=0:eq]) if eq >= 0 else String(part))
    return out^


def _form_value(body: String, key: String) raises -> String:
    for part in body.split("&"):
        var eq = part.find("=")
        if eq >= 0 and String(part[byte=0:eq]) == key:
            return String(part[byte = eq + 1 :])
    raise Error("no form field " + key)


def _hex(c: UInt8) raises -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c) - ord("A") + 10
    raise Error("not an uppercase hex digit: " + String(Int(c)))


def _percent_decode(s: String) raises -> String:
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        if b[i] == UInt8(ord("%")) and i + 2 < len(b):
            out.append(UInt8(_hex(b[i + 1]) * 16 + _hex(b[i + 2])))
            i += 3
        else:
            out.append(b[i])
            i += 1
    return String(unsafe_from_utf8=Span(out))


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def _joined(items: List[String]) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += ","
        out += items[i]
    return out^


# =============================================================================
# §1 — leg 1 on the wire.
# =============================================================================


def test_leg1_presents_no_credential_header_of_its_own() raises:
    """The STS POST's headers are exactly {content-length, content-type, host,
    user-agent}: the subject token in the body IS the credential."""
    var sts_cap = _capture()
    var m = _minter(_armed(_sts_ok(), sts_cap), _armed(_signjwt_ok(), _capture()))
    _ = m.mint_delivery_jwt(String(SA), String(JWT_AUD))
    var req = _text(sts_cap)
    assert_true(req.startswith("POST /v1/token HTTP/1.1\r\n"), req)
    assert_equal(_header_value(req, String("host")), "sts.googleapis.com")
    assert_equal(
        _header_value(req, String("content-type")),
        "application/x-www-form-urlencoded",
    )
    assert_equal(_header_names(req), "content-length,content-type,host,user-agent")


def test_leg1_body_is_the_references_form() raises:
    """The six fields in `google/oauth2/sts.py`'s order, each value
    form-encoded, and the subject token encoded a SECOND time: one decode of
    the field gives back exactly the token aws_subject.mojo built for the
    same credential, region, audience and signing time."""
    var sts_cap = _capture()
    var m = _minter(_armed(_sts_ok(), sts_cap), _armed(_signjwt_ok(), _capture()))
    _ = m.mint_delivery_jwt(String(SA), String(JWT_AUD))
    var body = _body_of(_text(sts_cap))
    assert_equal(
        _joined(_form_fields(body)),
        "grant_type,audience,scope,requested_token_type,subject_token,"
        "subject_token_type",
    )
    assert_equal(
        _form_value(body, String("grant_type")),
        "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange",
    )
    assert_equal(
        _form_value(body, String("audience")),
        "%2F%2Fiam.googleapis.com%2Fprojects%2F1234567890%2Flocations%2Fglobal"
        "%2FworkloadIdentityPools%2Fexample-pool%2Fproviders%2Fexample-aws",
    )
    assert_equal(
        _form_value(body, String("scope")),
        "https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform",
    )
    assert_equal(
        _form_value(body, String("requested_token_type")),
        "urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token",
    )
    assert_equal(
        _form_value(body, String("subject_token_type")),
        "urn%3Aietf%3Aparams%3Aaws%3Atoken-type%3Aaws4_request",
    )
    var raw = _form_value(body, String("subject_token"))
    # Twice-encoded: the JSON's `{"` is `%7B%22`, and its `%` became `%25`.
    assert_true(raw.startswith("%257B%2522headers%2522"), raw)
    assert_equal(
        _percent_decode(raw),
        aws1_subject_token(_cred(), String(REGION), String(AUDIENCE), String(AMZ_DATE)),
    )


# =============================================================================
# §2 — leg 2 on the wire.
# =============================================================================


def test_leg2_presents_exactly_one_credential_and_it_is_leg1s() raises:
    """`Authorization: Bearer <the federated token>`, once, and the account
    in the path: the bearer authorizes, the path names who signs."""
    var iam_cap = _capture()
    var m = _minter(_armed(_sts_ok(), _capture()), _armed(_signjwt_ok(), iam_cap))
    _ = m.mint_delivery_jwt(String(SA), String(JWT_AUD))
    var req = _text(iam_cap)
    assert_true(
        req.startswith(
            String("POST /v1/projects/-/serviceAccounts/") + SA + ":signJwt HTTP/1.1\r\n"
        ),
        req,
    )
    assert_equal(_header_value(req, String("host")), "iamcredentials.googleapis.com")
    assert_equal(
        _header_names(req), "authorization,content-length,content-type,host,user-agent"
    )
    assert_equal(_header_value(req, String("authorization")), String("Bearer ") + FEDERATED)
    assert_equal(
        _header_value(req, String("content-type")), "application/json; charset=utf-8"
    )


def test_the_signed_claims_are_iss_sub_aud_iat_exp() raises:
    """The whole body, against text written by hand: the claims are a JSON
    string inside `payload` (escaped a second time), `iss` and `sub` the
    account, `iat` the wall clock, `exp` 600 s later. A payload with no
    `exp` would be a token that never expires."""
    var iam_cap = _capture()
    var m = _minter(_armed(_sts_ok(), _capture()), _armed(_signjwt_ok(), iam_cap))
    _ = m.mint_delivery_jwt(String(SA), String(JWT_AUD))
    assert_equal(SIGNED_JWT_TTL_SECONDS, 600)
    var want = (
        String('{"payload":"{\\"iss\\":\\"') + SA
        + '\\",\\"sub\\":\\"' + SA
        + '\\",\\"aud\\":\\"' + JWT_AUD
        + '\\",\\"iat\\":' + String(NOW_S)
        + ',\\"exp\\":' + String(NOW_S + 600) + '}"}'
    )
    assert_equal(_body_of(_text(iam_cap)), want)


def test_the_positive_control_both_legs_dial_and_the_jwt_is_returned() raises:
    """THE POSITIVE CONTROL for every absence below: on success both
    captures are non-empty and the minted value is the scripted signedJwt."""
    var sts_cap = _capture()
    var iam_cap = _capture()
    var m = _minter(_armed(_sts_ok(), sts_cap), _armed(_signjwt_ok(), iam_cap))
    var jwt = m.mint_delivery_jwt(String(SA), String(JWT_AUD))
    assert_equal(jwt, SIGNED)
    assert_true(len(sts_cap[]) > 0)
    assert_true(len(iam_cap[]) > 0)


# =============================================================================
# §3 — absences: what must never be dialed.
# =============================================================================


def test_a_refused_leg1_never_dials_signjwt() raises:
    """⛔ THE FIXTURE IS ADVERSARIAL: the 403 body carries an `access_token`
    and an `expires_in`, so it would parse as a token response.
    The status decides, so the mint raises without reading a token out of an
    error body, and IAM Credentials sees no byte. The raised text names the
    status and never quotes the body."""
    var sts_cap = _capture()
    var iam_cap = _capture()
    var m = _minter(
        _armed(
            _http(
                String("403 Forbidden"),
                String(
                    '{"error":"unauthorized_client","error_description":'
                    '"rejected by the attribute condition",'
                    '"access_token":"NOT-A-REAL-TOKEN","expires_in":3600}'
                ),
            ),
            sts_cap,
        ),
        _armed(_signjwt_ok(), iam_cap),
    )
    var msg = String("")
    try:
        _ = m.mint_delivery_jwt(String(SA), String(JWT_AUD))
    except e:
        msg = String(e)
    assert_true("federation refused" in msg, msg)
    assert_true("HTTP 403" in msg, msg)
    assert_false("NOT-A-REAL-TOKEN" in msg, msg)
    assert_false("attribute condition" in msg, msg)
    assert_equal(len(iam_cap[]), 0)
    assert_true(len(sts_cap[]) > 0)


def test_a_2xx_leg1_with_no_token_never_dials_signjwt() raises:
    """A 200 with no `access_token` is a failure, not an empty bearer."""
    var iam_cap = _capture()
    var m = _minter(
        _armed(_http(String("200 OK"), String('{"token_type":"Bearer","expires_in":3600}')), _capture()),
        _armed(_signjwt_ok(), iam_cap),
    )
    with assert_raises(contains="no access_token"):
        _ = m.mint_delivery_jwt(String(SA), String(JWT_AUD))
    assert_equal(len(iam_cap[]), 0)


def test_a_missing_config_never_dials_at_all() raises:
    """No audience, no service account, or no JWT audience: refused before
    either connector sees a byte."""
    _ = _fetcher(_armed(_sts_ok(), _capture()))  # control: with an audience it builds
    with assert_raises(contains="audience is empty"):
        _ = Fetcher(
            HttpClient[ScriptedConnector].with_request_timeout_us(
                _armed(_sts_ok(), _capture()), TIMEOUT_US
            ),
            StaticCredsSource(_cred()),
            FixedClock(NOW_S),
            String(REGION),
            String(""),
        )

    var sts_cap = _capture()
    var iam_cap = _capture()
    var m = _minter(_armed(_sts_ok(), sts_cap), _armed(_signjwt_ok(), iam_cap))
    with assert_raises(contains="service account is empty"):
        _ = m.mint_delivery_jwt(String(""), String(JWT_AUD))
    with assert_raises(contains="outside"):
        _ = m.mint_delivery_jwt(String("sa/../x"), String(JWT_AUD))
    with assert_raises(contains="JWT audience is empty"):
        _ = m.mint_delivery_jwt(String(SA), String(""))
    assert_equal(len(sts_cap[]), 0)
    assert_equal(len(iam_cap[]), 0)


# =============================================================================
# §4 — failure messages carry no credential and no body.
# =============================================================================


def _leg2_failure_message(var leg2: List[UInt8]) raises -> String:
    var m = _minter(_armed(_sts_ok(), _capture()), _armed(leg2^, _capture()))
    try:
        _ = m.mint_delivery_jwt(String(SA), String(JWT_AUD))
    except e:
        return String(e)
    raise Error("leg 2 did not fail")


def test_a_leg2_failure_quotes_neither_the_bearer_nor_the_body() raises:
    """Both leg-2 failure paths (a non-2xx, and a 2xx with no `signedJwt`):
    the message is non-empty, names the failure, and holds neither the
    federated token it was carrying nor a byte of the body."""
    var refused = _leg2_failure_message(
        _http(
            String("403 Forbidden"),
            String(
                '{"error":{"code":403,"message":"permission denied on sa",'
                '"status":"PERMISSION_DENIED"}}'
            ),
        )
    )
    assert_true("signJwt refused" in refused, refused)
    assert_true("HTTP 403" in refused, refused)
    assert_true("PERMISSION_DENIED" in refused, refused)
    assert_false(FEDERATED in refused, refused)
    assert_false("permission denied on sa" in refused, refused)

    var empty = _leg2_failure_message(_http(String("200 OK"), String('{"keyId":"k-only"}')))
    assert_true("no signedJwt" in empty, empty)
    assert_false(FEDERATED in empty, empty)
    assert_false("k-only" in empty, empty)


# =============================================================================
# §5 — the federated token goes through the GcpTokenSource cache.
# =============================================================================


def test_the_federated_token_is_cached_then_refreshed() raises:
    """Two mints, one STS exchange: the second takes the cached token. Past
    the refresh margin, the next mint exchanges again."""
    var sts_cap = _capture()
    var iam_cap = _capture()
    var sts = _armed(_sts_ok(), sts_cap)
    sts.arm_next(ScriptedStream.from_read_script_with_capture(_sts_ok(), sts_cap))
    var iam = _armed(_signjwt_ok(), iam_cap)
    iam.arm_next(ScriptedStream.from_read_script_with_capture(_signjwt_ok(), iam_cap))
    iam.arm_next(ScriptedStream.from_read_script_with_capture(_signjwt_ok(), iam_cap))
    var m = _minter(sts^, iam^)

    assert_equal(m.mint_delivery_jwt(String(SA), String(JWT_AUD)), SIGNED)
    assert_equal(m.mint_delivery_jwt(String(SA), String(JWT_AUD)), SIGNED)
    assert_equal(_count(_text(sts_cap), "POST /v1/token "), 1)
    assert_equal(m.tokens().fetches(), 1)

    # 3600 s token, 225 s default refresh margin: at 3400 s it is stale.
    m.tokens().clock().advance(3_400_000)
    assert_equal(m.mint_delivery_jwt(String(SA), String(JWT_AUD)), SIGNED)
    assert_equal(_count(_text(sts_cap), "POST /v1/token "), 2)
    assert_equal(m.tokens().fetches(), 2)
    assert_equal(_count(_text(iam_cap), ":signJwt "), 3)


def main() raises:
    test_leg1_presents_no_credential_header_of_its_own()
    test_leg1_body_is_the_references_form()
    test_leg2_presents_exactly_one_credential_and_it_is_leg1s()
    test_the_signed_claims_are_iss_sub_aud_iat_exp()
    test_the_positive_control_both_legs_dial_and_the_jwt_is_returned()
    test_a_refused_leg1_never_dials_signjwt()
    test_a_2xx_leg1_with_no_token_never_dials_signjwt()
    test_a_missing_config_never_dials_at_all()
    test_a_leg2_failure_quotes_neither_the_bearer_nor_the_body()
    test_the_federated_token_is_cached_then_refreshed()
    print("test_wif_mint: OK")
