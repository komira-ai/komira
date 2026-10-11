# =============================================================================
# test_middleware.mojo: BearerJwtMiddleware's refusals and principal
#   replacement.
# =============================================================================
#
# RFC 6750 section 3: a missing Authorization header or another scheme is a
# 401 with a bare `Bearer` challenge (no error code); a malformed header
# (including non-ASCII bytes and a token over MAX_TOKEN_BYTES) is a 400
# invalid_request; two Authorization fields of any schemes (comma-folded by
# the HTTP/1 parser, which one test runs on a raw request), an empty field
# folded in, or a list holding a Bearer credential, are a 400 invalid_request
# with their own reason, while one credential whose auth-params hold commas
# (quoted or not) stays one credential of another scheme; every verification failure is a 401 invalid_token; no usable key
# set (past max-stale) is a 503 with Retry-After and no challenge, and the
# middleware recovers once a refresh succeeds. `cache-control: no-store` on
# every refusal, no token text in any response, and ctx.principal REPLACED on
# success and cleared on every refusal.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_http_auth import (
    BearerJwtConfig,
    FixedAuthClock,
    Rs256JwksVerifier,
    ScriptedJwksFetcher,
    TrustAnchor,
    VerifyOutcome,
)
from komira_http_auth.reasons import (
    REASON_ALG,
    REASON_AUD,
    REASON_CRIT,
    REASON_DUPLICATE_KEY,
    REASON_EXP,
    REASON_EXPIRED,
    REASON_HEADER_JSON,
    REASON_IAT,
    REASON_ISS,
    REASON_KEYS_UNAVAILABLE,
    REASON_KEY_IN_HEADER,
    REASON_KID,
    REASON_MALFORMED_HEADER,
    REASON_MALFORMED_TOKEN,
    REASON_MISSING_HEADER,
    REASON_NBF,
    REASON_OK,
    REASON_OTHER_SCHEME,
    REASON_PAYLOAD_JSON,
    REASON_REPEATED_HEADER,
    REASON_SIGNATURE,
    REASON_SUB,
    REASON_TTL,
    REASON_TYP,
    REASON_UNKNOWN_KID,
)
from komira_http_auth.testing import (
    rsa_jwk_json,
    rsa_jwks_json,
    sign_rs256_compact,
)


comptime ISSUER = "https://accounts.google.com"
comptime AUDIENCE = "https://api.example.com/"
comptime JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
comptime KID = "test-key-1"
comptime NOW: Int64 = 1800000000

comptime Verifier = Rs256JwksVerifier[ScriptedJwksFetcher, FixedAuthClock]


def _key() raises -> List[UInt8]:
    """The repository's RSA-2048 PKCS#8 test key (komira_http_core's TLS
    fixture), declared as this test's data in the BUCK file."""
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _config() -> BearerJwtConfig:
    return BearerJwtConfig(
        TrustAnchor.rs256(String("test"), ISSUER, AUDIENCE, JWKS_URL)
    )


def _header(kid: String) -> String:
    return String('{"alg":"RS256","typ":"JWT","kid":"') + kid + String('"}')


def _claims(iat: Int64, exp: Int64) -> String:
    return (
        String('{"iss":"')
        + ISSUER
        + String('","aud":"')
        + AUDIENCE
        + String('","sub":"svc-1","iat":')
        + String(iat)
        + String(',"exp":')
        + String(exp)
        + String("}")
    )


struct _Rig(Movable):
    """A verifier over a scripted JWKS fetcher and a fixed clock, with
    handles on both kept by the test."""

    var fetcher: ScriptedJwksFetcher
    var clock: FixedAuthClock
    var verifier: Verifier

    def __init__(out self, var cfg: BearerJwtConfig) raises:
        var f = ScriptedJwksFetcher()
        var c = FixedAuthClock(NOW)
        var v = Verifier(cfg, f.share(), c.share())
        self.fetcher = f^
        self.clock = c^
        self.verifier = v^


from komira_http_core.codec import ParseLimits, parse_request_head
from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.middleware import Principal, RequestContext
from komira_http_auth import (
    BearerJwtMiddleware,
    WWW_AUTHENTICATE_BEARER,
    WWW_AUTHENTICATE_INVALID_REQUEST,
    WWW_AUTHENTICATE_INVALID_TOKEN,
)


comptime Mw = BearerJwtMiddleware[Verifier]


struct _MwRig(Movable):
    var fetcher: ScriptedJwksFetcher
    var mw: Mw

    def __init__(out self, key: List[UInt8]) raises:
        var f = ScriptedJwksFetcher()
        f.add(200, String("max-age=3600"), rsa_jwks_json(key, KID))
        var v = Verifier(
            _config().with_copy_claim(String("email")),
            f.share(),
            FixedAuthClock(NOW),
        )
        self.fetcher = f^
        self.mw = Mw(v^)


def _req(authorization: Optional[String]) -> HttpRequest:
    var req = HttpRequest()
    req.method = HttpMethod.get()
    req.path = String("/v1/things")
    if authorization:
        req.headers[String("authorization")] = authorization.value()
    return req^


def _text(ref resp: HttpResponse) -> String:
    return String(unsafe_from_utf8=Span(resp.body))


def _preset_principal() raises -> Optional[Principal]:
    """What an earlier layer (or a forged path) may have left on the context."""
    return Optional[Principal](
        Principal(scheme=String("session"), subject=String("someone-else"))
        .with_claim(String("role"), String("admin"))
        .with_claim(String("email"), String("forged@example.com"))
    )


def _good_token(key: List[UInt8]) raises -> String:
    return sign_rs256_compact(
        _header(KID),
        String('{"iss":"')
        + ISSUER
        + String('","aud":"')
        + AUDIENCE
        + String('","sub":"svc-1","email":"svc@example.com","iat":')
        + String(NOW)
        + String(',"exp":')
        + String(NOW + 600)
        + String("}"),
        key,
    )


def _assert_refusal(
    ref resp: HttpResponse,
    status: Int,
    www_authenticate: Optional[String],
    body: String,
    what: String,
) raises:
    assert_equal(Int(resp.status), status, what)
    if www_authenticate:
        assert_equal(
            resp.headers[String("www-authenticate")],
            www_authenticate.value(),
            what,
        )
    else:
        assert_false(
            Bool(resp.headers.find(String("www-authenticate"))), what
        )
    assert_equal(_text(resp), body, what)
    assert_equal(
        resp.headers[String("content-length")], String(len(resp.body)), what
    )
    # A refusal must never be cached: a shared cache that kept it would
    # answer a later, valid request with it.
    assert_equal(resp.headers[String("cache-control")], String("no-store"), what)


def _assert_401(
    ref resp: HttpResponse, www_authenticate: String, what: String
) raises:
    _assert_refusal(
        resp,
        401,
        Optional[String](www_authenticate),
        String("unauthorized\n"),
        what,
    )


def _assert_400(ref resp: HttpResponse, what: String) raises:
    """RFC 6750 section 3.1: invalid_request is a 400."""
    _assert_refusal(
        resp,
        400,
        Optional[String](String(WWW_AUTHENTICATE_INVALID_REQUEST)),
        String("bad request\n"),
        what,
    )


def _assert_no_echo(ref resp: HttpResponse, secret: String) raises:
    """Neither the body nor any header value holds `secret` or any of its
    dot-separated parts."""
    var parts = secret.split(".")
    var hay = _text(resp)
    for e in resp.headers.items():
        hay += String("\n") + e.key + String(": ") + e.value
    assert_false(secret in hay, "token echoed")
    for i in range(len(parts)):
        var p = String(parts[i])
        if p.byte_length() >= 8:
            assert_false(p in hay, "token segment echoed")


# =============================================================================
# RFC 6750 header shapes.
# =============================================================================


def test_header_values_are_the_rfc6750_shapes() raises:
    assert_equal(String(WWW_AUTHENTICATE_BEARER), String("Bearer"))
    assert_equal(
        String(WWW_AUTHENTICATE_INVALID_REQUEST),
        String('Bearer error="invalid_request"'),
    )
    assert_equal(
        String(WWW_AUTHENTICATE_INVALID_TOKEN),
        String('Bearer error="invalid_token"'),
    )


def test_missing_authorization_is_a_bare_challenge() raises:
    # RFC 6750 section 3: a request that lacks any authentication
    # information gets 401 and a challenge with no error code.
    var rig = _MwRig(_key())
    var req = _req(Optional[String]())
    var ctx = RequestContext.new()
    ctx.principal = _preset_principal()
    var r = rig.mw.before(req, ctx)
    assert_true(Bool(r))
    _assert_401(r.value(), WWW_AUTHENTICATE_BEARER, "missing")
    assert_equal(rig.mw.last_reason(), String(REASON_MISSING_HEADER))
    assert_false(Bool(ctx.principal), "a refused request carries no principal")
    assert_equal(rig.fetcher.fetch_count(), 0)


def test_another_scheme_is_a_bare_challenge() raises:
    # RFC 6750 section 3: a client that "attempted using an unsupported
    # authentication method" lacks authentication information too: 401, no
    # error code. ONE credential of another scheme whose own auth-params
    # hold commas, in or out of quoted-strings, is one credential, not two
    # (RFC 9110 section 11.4: `auth-scheme [ 1*SP ( token68 / #auth-param )
    # ]`).
    var key = _key()
    var good = _good_token(key)
    var cases = List[String]()
    cases.append(String("Basic dXNlcjpwYXNz"))
    cases.append(String("Token ") + good)
    cases.append(String('Digest username="u", realm="r", nonce="n"'))
    cases.append(String("Digest a=b, c=d"))
    # BWS around `=` is still an auth-param.
    cases.append(String('Digest realm = "r" ,\tnonce\t="n"'))
    # BWS between `=` and `"` still opens the quoted-string, so the comma
    # inside it does not split off a `Basic b` credential.
    cases.append(String('Digest realm = "a, Basic b"'))
    # Commas inside quoted-strings do not split, even before something that
    # looks like a second credential.
    cases.append(String('Digest username="a, Bearer b", realm="r"'))
    cases.append(String('Digest uri="/x?a=1,2", qop=auth, nc=00000001'))
    # An escaped quote does not close the quoted-string.
    cases.append(String('Digest username="a \\", Bearer b", realm="r"'))
    # A second field that is only an auth-param reads as one of the first
    # credential's params (the documented limit of the list rule): one
    # credential of another scheme, still refused.
    cases.append(String("Basic dXNlcjpwYXNz, a=b"))
    cases.append(String("Bearerx ") + good)
    cases.append(String("Basic"))
    # Schemes holding RFC 9110 tchar specials ("-" and the rest of the set
    # beyond letters and digits) are tokens, so another scheme, not
    # malformed.
    cases.append(String("X-Api-Key abc"))
    cases.append(String("Hawk-1 abc"))
    cases.append(String("A!#$%&'*+.^_`|~ abc"))
    for i in range(len(cases)):
        var rig = _MwRig(key)
        var req = _req(Optional[String](cases[i]))
        var ctx = RequestContext.new()
        ctx.principal = _preset_principal()
        var r = rig.mw.before(req, ctx)
        assert_true(Bool(r), "case " + String(i))
        _assert_401(r.value(), WWW_AUTHENTICATE_BEARER, "case " + String(i))
        _assert_no_echo(r.value(), good)
        assert_equal(rig.mw.last_reason(), String(REASON_OTHER_SCHEME))
        assert_false(Bool(ctx.principal))
        assert_equal(rig.fetcher.fetch_count(), 0)


def test_two_authorization_fields_are_invalid_request() raises:
    # RFC 6750 section 3.1: a request that "uses more than one method" or
    # "repeats the same parameter" is invalid_request, 400. The HTTP/1
    # parser comma-folds a repeated Authorization field into `a, b`
    # (test_two_authorization_lines_through_the_http1_parser below runs the
    # real parser); these are the values it builds. Two credentials of ANY
    # schemes are refused, as are an empty field folded in and a list
    # holding a Bearer credential (middleware.mojo, the list rule).
    var key = _key()
    var good = _good_token(key)
    var cases = List[String]()
    # (a) two credentials.
    cases.append(String("Bearer ") + good + String(", Bearer ") + good)
    cases.append(String("Basic dXNlcjpwYXNz, Bearer ") + good)
    cases.append(String("Bearer ") + good + String(", Basic dXNlcjpwYXNz"))
    cases.append(String("Bearer ") + good + String(",") + good)
    cases.append(String("bearer ") + good + String(",\tBEARER ") + good)
    # The ONLY Bearer element follows a comma and a horizontal tab: the
    # whitespace before an element's scheme is spaces and tabs alike.
    cases.append(String("Basic dXNlcjpwYXNz,\tBearer ") + good)
    # No Bearer anywhere: two Basic fields, Basic and Digest, two Digest
    # fields with their own params, two bare schemes.
    cases.append(String("Basic dXNlcjpwYXNz, Basic dXNlcjpwYXNz"))
    cases.append(String('Basic dXNlcjpwYXNz, Digest username="a", realm="b"'))
    cases.append(
        String('Digest username="a", realm="b", Digest username="c", realm="d"')
    )
    cases.append(String("Basic, Basic"))
    # The first element always starts a credential, whatever its shape.
    cases.append(String("a=b, Basic dXNlcjpwYXNz"))
    # A later element that starts with `=` has no token before it, so it is
    # not an auth-param: it starts a second credential (failing closed).
    cases.append(String("Basic dXNlcjpwYXNz, =x"))
    # A quoted comma does not split, but the credential after it does.
    cases.append(String('Digest username="a, b", Bearer ') + good)
    # A `"` not after `=` opens no quoted-string, so it cannot swallow the
    # fold.
    cases.append(String('Basic ab"c, Basic d"'))
    # (b) an empty field folded in, first or last.
    cases.append(String(", Bearer ") + good)
    cases.append(String(", Basic dXNlcjpwYXNz"))
    cases.append(String("Basic dXNlcjpwYXNz, "))
    # (c) a Bearer credential with anything after a comma: a token68 never
    # holds one.
    cases.append(String("Bearer ") + good + String(', realm="x"'))
    for i in range(len(cases)):
        var rig = _MwRig(key)
        var req = _req(Optional[String](cases[i]))
        var ctx = RequestContext.new()
        ctx.principal = _preset_principal()
        var r = rig.mw.before(req, ctx)
        assert_true(Bool(r), "case " + String(i))
        _assert_400(r.value(), "case " + String(i))
        _assert_no_echo(r.value(), good)
        assert_equal(
            rig.mw.last_reason(), String(REASON_REPEATED_HEADER), "case " + String(i)
        )
        assert_false(Bool(ctx.principal))
        assert_equal(rig.fetcher.fetch_count(), 0)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _authorization_lines(first: String, second: String) -> String:
    """A raw HTTP/1.1 request head with two Authorization lines."""
    return (
        String("GET /v1/things HTTP/1.1\r\nHost: api.example.com\r\n")
        + String("Authorization: ")
        + first
        + String("\r\nAccept: */*\r\nAuthorization: ")
        + second
        + String("\r\n\r\n")
    )


def test_two_authorization_lines_through_the_http1_parser() raises:
    # The defence above holds only while komira_http_core's HTTP/1 parser
    # FOLDS a repeated field. Here the raw request goes through that parser
    # and the request it builds goes to the middleware. If the parser kept
    # only the last (or first) field, the two-Bearer case would carry one
    # valid token and be accepted, and this test would fail.
    var key = _key()
    var good = _good_token(key)
    var firsts = List[String]()
    var seconds = List[String]()
    firsts.append(String("Bearer ") + good)
    seconds.append(String("Bearer ") + good)
    firsts.append(String("Basic dXNlcjpwYXNz"))
    seconds.append(String("Bearer ") + good)
    firsts.append(String("Bearer ") + good)
    seconds.append(String("Basic dXNlcjpwYXNz"))
    firsts.append(String("Basic dXNlcjpwYXNz"))
    seconds.append(String("Basic dXNlcjpwYXNz"))
    firsts.append(String('Digest username="a", realm="b"'))
    seconds.append(String("Basic dXNlcjpwYXNz"))
    for i in range(len(firsts)):
        var raw = _bytes(_authorization_lines(firsts[i], seconds[i]))
        var parsed = parse_request_head(Span[UInt8](raw), ParseLimits.defaults())
        assert_true(parsed.err.is_ok(), "case " + String(i))
        var rig = _MwRig(key)
        var ctx = RequestContext.new()
        ctx.principal = _preset_principal()
        var r = rig.mw.before(parsed.request, ctx)
        assert_true(Bool(r), "case " + String(i))
        _assert_400(r.value(), "case " + String(i))
        _assert_no_echo(r.value(), good)
        assert_equal(
            rig.mw.last_reason(), String(REASON_REPEATED_HEADER), "case " + String(i)
        )
        assert_false(Bool(ctx.principal))
        assert_equal(rig.fetcher.fetch_count(), 0)
    # Control: ONE Authorization line through the same parser is accepted,
    # so the refusals above are the second line's doing.
    var one = _bytes(
        String("GET /v1/things HTTP/1.1\r\nHost: api.example.com\r\n")
        + String("Authorization: Bearer ")
        + good
        + String("\r\n\r\n")
    )
    var parsed = parse_request_head(Span[UInt8](one), ParseLimits.defaults())
    assert_true(parsed.err.is_ok())
    var rig = _MwRig(key)
    var ctx = RequestContext.new()
    assert_false(Bool(rig.mw.before(parsed.request, ctx)), "one line accepted")
    assert_equal(rig.mw.last_reason(), String(REASON_OK))
    assert_true(Bool(ctx.principal))


def test_malformed_authorization_is_invalid_request() raises:
    # RFC 6750 section 3.1: "otherwise malformed" is invalid_request, 400.
    var key = _key()
    var good = _good_token(key)
    var cases = List[String]()
    cases.append(String(""))
    cases.append(String("Bearer"))
    cases.append(String("Bearer "))
    cases.append(String("Bearer  ") + good)  # two spaces
    cases.append(String("Bearer ") + good + String(" "))
    cases.append(String("Bearer\t") + good)
    cases.append(String(" Bearer ") + good)
    cases.append(String("Bearer a=b"))
    # ':' is not a token68 byte (RFC 7235 2.1), so a Basic-style pair is
    # refused as a malformed header, not passed on to the verifier.
    cases.append(String("Bearer a:b"))
    # An unterminated quoted-string, also one whose last quote is escaped.
    cases.append(String('Digest username="a'))
    cases.append(String('Digest username="a\\"'))
    for i in range(len(cases)):
        var rig = _MwRig(key)
        var req = _req(Optional[String](cases[i]))
        var ctx = RequestContext.new()
        ctx.principal = _preset_principal()
        var r = rig.mw.before(req, ctx)
        assert_true(Bool(r), "case " + String(i))
        _assert_400(r.value(), "case " + String(i))
        _assert_no_echo(r.value(), good)
        assert_equal(rig.mw.last_reason(), String(REASON_MALFORMED_HEADER))
        assert_false(Bool(ctx.principal))
        assert_equal(rig.fetcher.fetch_count(), 0)


def test_non_ascii_authorization_is_invalid_request() raises:
    # The HTTP/1 parser turns an obs-text byte into a two-byte character, so
    # a byte-6 boundary of these values falls inside a character. The scheme
    # is compared byte by byte; each is a plain invalid_request (400), never
    # an abort. A scheme holding a non-token byte is malformed, not another
    # scheme.
    var key = _key()
    var cases = List[String]()
    cases.append(String("Beare") + chr(0xE9) + String(" abc.def.ghi"))
    cases.append(String("Bearer") + chr(0xE9) + String("abc.def.ghi"))
    cases.append(chr(0xE9) + String("earer abc.def.ghi"))
    cases.append(String("Bearer ") + chr(0xE9) + String("abc.def.ghi"))
    cases.append(String("Bearer abc.def") + chr(0xE9))
    for i in range(len(cases)):
        var rig = _MwRig(key)
        var req = _req(Optional[String](cases[i]))
        var ctx = RequestContext.new()
        var r = rig.mw.before(req, ctx)
        assert_true(Bool(r), "case " + String(i))
        _assert_400(r.value(), "case " + String(i))
        assert_equal(rig.mw.last_reason(), String(REASON_MALFORMED_HEADER))
        assert_false(Bool(ctx.principal))
        assert_equal(rig.fetcher.fetch_count(), 0)


def _run_of(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def test_token_over_max_token_bytes_is_invalid_request() raises:
    # MAX_TOKEN_BYTES is 8192: a token68 one byte over it is a malformed
    # header (invalid_request), refused before the verifier runs.
    var key = _key()
    var rig = _MwRig(key)
    var req = _req(Optional[String](String("Bearer ") + _run_of("a", 8193)))
    var ctx = RequestContext.new()
    ctx.principal = _preset_principal()
    var r = rig.mw.before(req, ctx)
    assert_true(Bool(r))
    _assert_400(r.value(), "8193")
    assert_equal(rig.mw.last_reason(), String(REASON_MALFORMED_HEADER))
    assert_false(Bool(ctx.principal))
    assert_equal(rig.fetcher.fetch_count(), 0)


def test_token_of_exactly_max_token_bytes_reaches_the_verifier() raises:
    # At exactly 8192 bytes the header is well formed and the token goes to
    # the verifier, which refuses the dotless run as a malformed token
    # (invalid_token), not as a malformed header.
    var key = _key()
    var rig = _MwRig(key)
    var req = _req(Optional[String](String("Bearer ") + _run_of("a", 8192)))
    var ctx = RequestContext.new()
    ctx.principal = _preset_principal()
    var r = rig.mw.before(req, ctx)
    assert_true(Bool(r))
    _assert_401(r.value(), WWW_AUTHENTICATE_INVALID_TOKEN, "8192")
    assert_equal(rig.mw.last_reason(), String(REASON_MALFORMED_TOKEN))
    assert_false(Bool(ctx.principal))
    assert_equal(rig.fetcher.fetch_count(), 0)


def test_bad_token_is_invalid_token_and_not_echoed() raises:
    var key = _key()
    var good = _good_token(key)
    # The same token with one character inside its signature changed (not
    # the last, whose low bits are padding).
    var at = good.byte_length() - 10
    var was = String(good[byte=at : at + 1])
    var flipped = (
        String(good[byte=0:at])
        + (String("A") if was != String("A") else String("B"))
        + String(good[byte = at + 1 : good.byte_length()])
    )
    var cases = List[String]()
    cases.append(flipped)
    cases.append(String("not-a-jwt-at-all"))
    cases.append(String("aaaa.bbbb.cccc"))
    for i in range(len(cases)):
        var rig = _MwRig(key)
        var req = _req(Optional[String](String("Bearer ") + cases[i]))
        var ctx = RequestContext.new()
        ctx.principal = _preset_principal()
        var r = rig.mw.before(req, ctx)
        assert_true(Bool(r), "case " + String(i))
        _assert_401(r.value(), WWW_AUTHENTICATE_INVALID_TOKEN, "case " + String(i))
        _assert_no_echo(r.value(), cases[i])
        assert_false(Bool(ctx.principal), "case " + String(i))
        assert_true(rig.mw.last_reason() != String(REASON_OK))
        assert_false(cases[i] in rig.mw.last_reason())


def test_valid_token_replaces_a_preset_principal() raises:
    var key = _key()
    var rig = _MwRig(key)
    var tok = _good_token(key)
    var req = _req(Optional[String](String("Bearer ") + tok))
    var ctx = RequestContext.new()
    ctx.principal = _preset_principal()
    var r = rig.mw.before(req, ctx)
    assert_false(Bool(r), "the request goes on")
    assert_equal(rig.mw.last_reason(), String(REASON_OK))
    assert_true(Bool(ctx.principal))
    ref p = ctx.principal.value()
    assert_equal(p.scheme, String("jwt"))
    assert_equal(p.subject, String("svc-1"))
    # REPLACED, not merged: nothing of the preset principal survives.
    assert_false(p.claims.has(String("role")), "preset claim leaked")
    assert_equal(p.claims.get(String("email")).value(), String("svc@example.com"))
    assert_equal(p.claims.len(), 3)  # iss, aud, email
    assert_equal(p.claims.get(String("iss")).value(), String(ISSUER))
    assert_equal(p.claims.get(String("aud")).value(), String(AUDIENCE))


def test_scheme_name_is_case_insensitive() raises:
    var key = _key()
    var rig = _MwRig(key)
    var req = _req(Optional[String](String("bearer ") + _good_token(key)))
    var ctx = RequestContext.new()
    var r = rig.mw.before(req, ctx)
    assert_false(Bool(r))
    assert_true(Bool(ctx.principal))


def test_a_refusal_after_a_success_clears_the_principal() raises:
    var key = _key()
    var rig = _MwRig(key)
    var ctx = RequestContext.new()
    var ok_req = _req(Optional[String](String("Bearer ") + _good_token(key)))
    _ = rig.mw.before(ok_req, ctx)
    assert_true(Bool(ctx.principal))
    var bad_req = _req(Optional[String](String("Bearer aaaa.bbbb.cccc")))
    var r = rig.mw.before(bad_req, ctx)
    assert_true(Bool(r))
    assert_false(Bool(ctx.principal))


def test_keys_past_max_stale_are_503_with_retry_after_then_recover() raises:
    # Fetch 1 publishes KID with max-age=0 (stale at once); max-stale is
    # 120 s. Fetch 2 fails. Fetch 3 publishes KID again.
    var key = _key()
    var f = ScriptedJwksFetcher()
    f.add(200, String("max-age=0"), rsa_jwks_json(key, KID))
    f.add_failure()
    f.add(200, String("max-age=0"), rsa_jwks_json(key, KID))
    var clock = FixedAuthClock(NOW)
    var v = Verifier(
        _config().with_jwks_max_stale_s(Int64(120)), f.share(), clock.share()
    )
    var mw = Mw(v^)
    var tok = String("Bearer ") + _good_token(key)

    var ctx = RequestContext.new()
    var ok_req = _req(Optional[String](tok))
    assert_false(Bool(mw.before(ok_req, ctx)), "fresh keys verify")

    # NOW+121: past expiry (NOW) + 120; the refresh fails. Fail closed: 503,
    # no challenge (the token was not judged), Retry-After the whole 60 s
    # window, a fixed body, nothing of the token, no principal.
    clock.set(NOW + 121)
    ctx.principal = _preset_principal()
    var req = _req(Optional[String](tok))
    var r = mw.before(req, ctx)
    assert_true(Bool(r))
    _assert_refusal(
        r.value(),
        503,
        Optional[String](),
        String("authentication unavailable\n"),
        "503",
    )
    assert_equal(r.value().headers[String("retry-after")], String("60"))
    _assert_no_echo(r.value(), tok)
    assert_equal(mw.last_reason(), String(REASON_KEYS_UNAVAILABLE))
    assert_false(Bool(ctx.principal))
    assert_equal(f.fetch_count(), 2)

    # NOW+150: inside the window, no fetch; Retry-After is what is left.
    clock.set(NOW + 150)
    var req2 = _req(Optional[String](tok))
    var r2 = mw.before(req2, ctx)
    assert_equal(Int(r2.value().status), 503)
    assert_equal(r2.value().headers[String("retry-after")], String("31"))
    assert_equal(f.fetch_count(), 2)

    # A malformed token is still judged without keys: 401 invalid_token.
    var bad = _req(Optional[String](String("Bearer aaaa.bbbb.cccc")))
    var rb = mw.before(bad, ctx)
    _assert_401(rb.value(), WWW_AUTHENTICATE_INVALID_TOKEN, "bad token")

    # NOW+181: the window has passed and the refresh succeeds: recovered.
    clock.set(NOW + 181)
    var req3 = _req(Optional[String](tok))
    assert_false(Bool(mw.before(req3, ctx)), "recovered")
    assert_equal(mw.last_reason(), String(REASON_OK))
    assert_true(Bool(ctx.principal))
    assert_equal(f.fetch_count(), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
