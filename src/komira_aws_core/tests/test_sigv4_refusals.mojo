# =============================================================================
# komira_aws_core/tests/test_sigv4_refusals.mojo
# =============================================================================
#
# What the signer refuses (and that a refusal never carries the secret), the
# path encoding modes the test suite does not exercise (S3's verbatim path,
# double encoding of an already-encoded path), that SigningKeyCache yields
# the uncached signature byte for byte as each key field changes on its own,
# and that `omit_session_token` attaches the token without signing it, in
# both header and query signing.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_aws_core import (
    EMPTY_PAYLOAD_SHA256,
    UNSIGNED_PAYLOAD,
    AwsCredential,
    Header,
    SigningKeyCache,
    SigV4SigningContext,
    canonical_query,
    canonical_uri,
    derive_signing_key,
    sigv4_presign,
    sigv4_sign_cached,
    sigv4_sign_payload_hash,
)

comptime _SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
comptime _TOKEN = "EXAMPLE-SESSION-TOKEN"


def _ctx(
    region: String = "us-east-1",
    amz_date: String = "20260901T000000Z",
    secret: String = _SECRET,
    service: String = "logs",
    token: String = _TOKEN,
    omit_session_token: Bool = False,
) -> SigV4SigningContext:
    return SigV4SigningContext(
        AwsCredential(String("AKIDEXAMPLE"), secret, token),
        region,
        service,
        amz_date,
        omit_session_token=omit_session_token,
    )


def _has_header(headers: List[Header], name: String, value: String) -> Bool:
    for i in range(len(headers)):
        if headers[i].name == name and headers[i].value == value:
            return True
    return False


def _derive_error(ctx: SigV4SigningContext) -> String:
    """The message derive_signing_key raises, or "" when it derives."""
    try:
        _ = derive_signing_key(ctx)
    except e:
        return String(e)
    return String("")


def _cut_errors(ctx: SigV4SigningContext) -> List[String]:
    """What short_date() and credential_scope() each raise when called
    directly, or "" when it returns. Every other public caller validates the
    context before it cuts, so only a direct call shows the cut checks
    amz_date itself."""
    var out = List[String]()
    try:
        _ = ctx.short_date()
        out.append(String(""))
    except e:
        out.append(String(e))
    try:
        _ = ctx.credential_scope()
        out.append(String(""))
    except e:
        out.append(String(e))
    return out^


def _host() -> List[Header]:
    var h = List[Header]()
    h.append(Header(String("Host"), String("logs.us-east-1.amazonaws.com")))
    return h^


def _sign_error(
    headers: List[Header], ctx: SigV4SigningContext, target: String = "/"
) -> String:
    """The message the header signer raises, or "" when it signs."""
    try:
        _ = sigv4_sign_payload_hash(
            String("POST"), target, headers, String(EMPTY_PAYLOAD_SHA256), ctx
        )
    except e:
        var msg = String(e)
        # No refusal carries the secret or the session token.
        if msg.find(_SECRET) >= 0 or msg.find(_TOKEN) >= 0:
            return String("LEAKED A SECRET: ") + msg
        return msg
    return String("")


def _presign_error(target: String, expires: Int) -> String:
    try:
        _ = sigv4_presign(
            String("GET"),
            target,
            _host(),
            String(UNSIGNED_PAYLOAD),
            _ctx(),
            expires,
        )
    except e:
        return String(e)
    return String("")


def _refused(msg: String, needle: String) raises:
    assert_true(msg.byte_length() > 0, "expected a refusal naming " + needle)
    assert_true(msg.find("LEAKED") < 0, msg)
    assert_true(msg.find(needle) >= 0, msg)


def test_refusals() raises:
    assert_equal(_sign_error(_host(), _ctx()), "")
    _refused(_sign_error(List[Header](), _ctx()), "no Host header")

    var owned = List[String]()
    owned.append("Authorization")
    owned.append("X-Amz-Date")
    owned.append("X-Amz-Security-Token")
    owned.append("x-amz-content-sha256")
    for i in range(len(owned)):
        var h = _host()
        h.append(Header(owned[i], String("x")))
        _refused(_sign_error(h, _ctx()), "the signer writes it")

    var crlf = _host()
    crlf.append(Header(String("X-Custom"), String("a\r\nInjected: b")))
    _refused(_sign_error(crlf, _ctx()), "CR or LF")
    var empty_name = _host()
    empty_name.append(Header(String(" "), String("v")))
    _refused(_sign_error(empty_name, _ctx()), "empty name")

    _refused(_sign_error(_host(), _ctx(amz_date="2026-09-01T00:00:00Z")), "amz_date")
    _refused(_sign_error(_host(), _ctx(amz_date="20260901000000Z")), "amz_date")
    _refused(_sign_error(_host(), _ctx(region="us-east-1/evil")), "region")
    _refused(_sign_error(_host(), _ctx(region="")), "region is empty")
    _refused(_sign_error(_host(), _ctx(secret="")), "empty secret")
    # A CR/LF in the session token would inject a header through
    # X-Amz-Security-Token. _sign_error also checks the message does not
    # echo the token (it starts with _TOKEN).
    var bad_token = String(_TOKEN) + "\r\nX-Injected: 1"
    _refused(_sign_error(_host(), _ctx(token=bad_token)), "session token")
    _refused(
        _sign_error(_host(), _ctx(token=String(_TOKEN) + "\n")), "CR or LF"
    )

    # The public key derivation checks the date itself, rather than cutting a
    # short or non-ASCII amz_date at byte 8 into a wrong key (or a String that
    # is not UTF-8: the e-acute below spans bytes 7 and 8).
    assert_equal(_derive_error(_ctx()), "")
    _refused(_derive_error(_ctx(amz_date="2026090é000000Z")), "amz_date")
    _refused(_derive_error(_ctx(amz_date="2026")), "amz_date")
    _refused(_derive_error(_ctx(amz_date="")), "amz_date")
    # short_date() and credential_scope() are public too, and are called here
    # directly: through derive_signing_key, validate() refuses first.
    var good = _cut_errors(_ctx())
    assert_equal(good[0], "")
    assert_equal(good[1], "")
    assert_equal(_ctx().short_date(), "20260901")
    assert_equal(
        _ctx().credential_scope(), "20260901/us-east-1/logs/aws4_request"
    )
    var bad_dates = List[String]()
    bad_dates.append("2026090é000000Z")
    bad_dates.append("2026")
    bad_dates.append("")
    for i in range(len(bad_dates)):
        var errs = _cut_errors(_ctx(amz_date=bad_dates[i]))
        _refused(errs[0], "amz_date")
        _refused(errs[1], "amz_date")

    _refused(_presign_error("/", 0), "presign expiry")
    _refused(_presign_error("/", 604801), "presign expiry")
    assert_equal(_presign_error("/", 604800), "")
    _refused(_presign_error("/?X-Amz-Signature=abc", 60), "X-Amz-Signature")
    _refused(_presign_error("/?X-Amz-Credential=abc", 60), "X-Amz-Credential")


def test_path_modes() raises:
    # S3: the wire path is the canonical path, not normalized or re-encoded.
    assert_equal(canonical_uri("/my%20key//a/../b", False, False), "/my%20key//a/../b")
    # Other services: an encoded wire path is encoded again.
    assert_equal(canonical_uri("/my%20key", True, True), "/my%2520key")
    assert_equal(canonical_uri("", True, True), "/")
    assert_equal(canonical_uri("/a/b/.", True, True), "/a/b/")
    assert_equal(canonical_uri("/a/b/..", True, True), "/a/")
    # Query: sorted by key, then value; a key that prefixes another sorts first.
    assert_equal(canonical_query("b=2&a=2&a=1&a-b=3"), "a=1&a=2&a-b=3&b=2")
    assert_equal(canonical_query("k=a+b&s=a%2Fb&e"), "e=&k=a%2Bb&s=a%2Fb")


def test_signing_key_cache() raises:
    # Each step differs from the one before it in EXACTLY one cache key field,
    # so each of the cache's compares is the only thing that can force the
    # recompute at its step: dropping any one of them reuses a stale key there.
    comptime _SECRET2 = "ANOTHER/SECRET+KEYEXAMPLE"
    var cache = SigningKeyCache()
    var ctxs = List[SigV4SigningContext]()
    ctxs.append(_ctx())
    ctxs.append(_ctx())  # a hit
    ctxs.append(_ctx(secret=_SECRET2))  # the secret only
    ctxs.append(_ctx(secret=_SECRET2, amz_date="20260902T000000Z"))  # the date
    ctxs.append(
        _ctx(secret=_SECRET2, amz_date="20260902T000000Z", region="us-west-2")
    )  # the region
    ctxs.append(
        _ctx(
            secret=_SECRET2,
            amz_date="20260902T000000Z",
            region="us-west-2",
            service="sqs",
        )
    )  # the service
    var prev = String()
    for i in range(len(ctxs)):
        var want = sigv4_sign_payload_hash(
            String("GET"), String("/"), _host(), String(EMPTY_PAYLOAD_SHA256), ctxs[i]
        )
        var got = sigv4_sign_cached(
            String("GET"),
            String("/"),
            _host(),
            String(EMPTY_PAYLOAD_SHA256),
            ctxs[i],
            cache,
        )
        assert_equal(got.authorization, want.authorization)
        # Every changed field changes the signature, so a stale key shows.
        if i == 1:
            assert_equal(want.signature, prev)
        elif i > 1:
            assert_true(want.signature != prev, "step " + String(i))
        prev = want.signature
    # The secret step changes only the key, never the string to sign: only
    # the signature can tell a stale key there.
    var a = sigv4_sign_payload_hash(
        String("GET"), String("/"), _host(), String(EMPTY_PAYLOAD_SHA256), ctxs[1]
    )
    var b = sigv4_sign_payload_hash(
        String("GET"), String("/"), _host(), String(EMPTY_PAYLOAD_SHA256), ctxs[2]
    )
    assert_equal(a.string_to_sign, b.string_to_sign)
    assert_true(a.signature != b.signature)


def test_omit_session_token() raises:
    # Header signing: the token is attached but not signed.
    var omit = _ctx(omit_session_token=True)
    var r = sigv4_sign_payload_hash(
        String("GET"), String("/"), _host(), String(EMPTY_PAYLOAD_SHA256), omit
    )
    assert_true(r.signed_headers.find("x-amz-security-token") < 0, r.signed_headers)
    assert_true(r.canonical_request.find("x-amz-security-token") < 0)
    assert_true(r.canonical_request.find(_TOKEN) < 0)
    assert_true(
        _has_header(r.headers_to_add, "X-Amz-Security-Token", String(_TOKEN))
    )
    # The control: without the flag the same token IS signed.
    var signed = sigv4_sign_payload_hash(
        String("GET"), String("/"), _host(), String(EMPTY_PAYLOAD_SHA256), _ctx()
    )
    assert_true(signed.signed_headers.find("x-amz-security-token") >= 0)
    assert_true(signed.canonical_request.find(_TOKEN) >= 0)

    # Query signing: the token is in the signed target, not the canonical query.
    var p = sigv4_presign(
        String("GET"), String("/"), _host(), String(UNSIGNED_PAYLOAD), omit, 60
    )
    assert_true(p.canonical_request.find("X-Amz-Security-Token") < 0)
    assert_true(p.canonical_request.find(_TOKEN) < 0)
    assert_true(
        p.signed_target.find(String("X-Amz-Security-Token=") + _TOKEN) >= 0,
        p.signed_target,
    )
    assert_true(
        _has_header(p.query_to_add, "X-Amz-Security-Token", String(_TOKEN))
    )
    var ps = sigv4_presign(
        String("GET"), String("/"), _host(), String(UNSIGNED_PAYLOAD), _ctx(), 60
    )
    assert_true(
        ps.canonical_request.find(String("X-Amz-Security-Token=") + _TOKEN) >= 0
    )


def main() raises:
    test_refusals()
    test_path_modes()
    test_signing_key_cache()
    test_omit_session_token()
    print("OK")
