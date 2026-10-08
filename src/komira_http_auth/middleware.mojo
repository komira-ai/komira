# =============================================================================
# komira_http_auth/middleware.mojo: `BearerJwtMiddleware`, the auth slot of
#   komira_http_server's middleware chain.
# =============================================================================
#
# `before`:
#   1. clears `ctx.principal`. Whatever an earlier layer put there is gone
#      before this layer decides, so a refused request never carries a
#      principal, and an accepted one carries exactly the one built here
#      (REPLACED, never merged with an earlier principal or its claims);
#   2. reads `Authorization` and answers as RFC 6750 section 3 says:
#        * no Authorization header, or a credential of another scheme
#          (`Basic ...`, `Digest ...`; the scheme name an RFC 9110 token, the
#          rest not examined): the request "lacks any
#          authentication information", so 401 with a bare
#          `WWW-Authenticate: Bearer` and no error code;
#        * more than one credential naming Bearer: a comma list one of whose
#          elements has the scheme `Bearer`. The HTTP/1 parser folds a
#          repeated header into `a, b`, and a Bearer credential (token68)
#          never holds a comma, so this is a second Authorization field or a
#          list; it "uses more than one method" or "repeats the same
#          parameter": 400 with `WWW-Authenticate: Bearer
#          error="invalid_request"`;
#        * a scheme that is not an RFC 9110 token, or the `Bearer` scheme not
#          followed by exactly one space and a token68 (RFC 7235: the
#          base64url and base64 alphabets, `.`, `~`, `+`, `/`, trailing `=`)
#          of at most 8 KiB: malformed, so 400 invalid_request as above;
#   3. hands the token to the verifier. A refusal because the verifier has
#      no usable keys (`VerifyOutcome.keys_unavailable()`: never fetched, or
#      past freshness plus max-stale with every refresh failing) is answered
#      503 with `Retry-After: <seconds until the next refresh may start>` and
#      no challenge: the token was not judged. Any other refusal is answered
#      401 with `WWW-Authenticate: Bearer error="invalid_token"`;
#   4. on success sets `ctx.principal` and lets the request through.
#
# The scheme name is compared case-insensitively. A comma list with no Bearer
# element (`Digest a=b, c=d`, or two Basic fields folded) is another scheme.
#
# HTTP/2: komira_http_server's chained (middleware) serving path closes h2
# connections and its h2 path runs no middleware, so no h2 request reaches
# this layer today. When one does, the server must fold a repeated field the
# way the HTTP/1 parser does, or the second Authorization field is invisible
# here.
#
# Every response body is a fixed text and every header a fixed value or a
# number: nothing in a response, and nothing this file logs (it logs
# nothing), comes from the token. `last_reason()` holds the reason code of
# the last decision for the embedder to log or count.
#
# `before` never raises (a raise would become a 500 in ErrorMappingMiddleware):
# anything unexpected is an invalid_token refusal.
#
# The verifier runs on the serving worker's event-loop thread, so a JWKS
# fetch stalls that whole worker while it runs, at most once per refetch
# window. The fetch timeout bounds its TLS handshake and its request; the TCP
# connect adds up to 5 s and DNS resolution is not bounded at all, so a fetch
# takes the DNS time plus at most 5 s + 2 x the fetch timeout, and has no
# bound with a hanging resolver (jwks_fetch.mojo header).
# =============================================================================

from komira_http_core.codec.types import HttpRequest, HttpResponse
from komira_http_server.middleware import (
    Middleware,
    Principal,
    RequestContext,
)

from komira_http_auth.reasons import (
    REASON_MALFORMED_HEADER,
    REASON_MISSING_HEADER,
    REASON_OTHER_SCHEME,
    REASON_REPEATED_HEADER,
)
from komira_http_auth.token import MAX_TOKEN_BYTES
from komira_http_auth.verifier import BearerVerifier


comptime WWW_AUTHENTICATE_BEARER: String = "Bearer"
comptime WWW_AUTHENTICATE_INVALID_REQUEST: String = 'Bearer error="invalid_request"'
comptime WWW_AUTHENTICATE_INVALID_TOKEN: String = 'Bearer error="invalid_token"'
comptime UNAUTHORIZED_BODY: String = "unauthorized\n"
comptime BAD_REQUEST_BODY: String = "bad request\n"
comptime KEYS_UNAVAILABLE_BODY: String = "authentication unavailable\n"

# How `_classify_authorization` sees a header value (module header, step 2).
comptime _AUTH_BEARER = 0
comptime _AUTH_OTHER_SCHEME = 1
comptime _AUTH_MALFORMED = 2
comptime _AUTH_REPEATED = 3


def _is_token68_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("-"))
        or c == UInt8(ord("."))
        or c == UInt8(ord("_"))
        or c == UInt8(ord("~"))
        or c == UInt8(ord("+"))
        or c == UInt8(ord("/"))
    )


def _is_tchar(c: UInt8) -> Bool:
    """RFC 9110 section 5.6.2 tchar."""
    if (
        (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
    ):
        return True
    var extra = String("!#$%&'*+-.^_`|~")
    var e = extra.as_bytes()
    for k in range(len(e)):
        if c == e[k]:
            return True
    return False


def _is_bearer_word(value: String, start: Int, end: Int) -> Bool:
    """Whether bytes [start, end) of `value` are `bearer`, ASCII
    case-insensitively."""
    if end - start != 6:
        return False
    var b = value.as_bytes()
    var bearer = String("bearer")
    var want = bearer.as_bytes()
    for k in range(6):
        var c = b[start + k]
        if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            c = c + UInt8(0x20)
        if c != want[k]:
            return False
    return True


def _classify_authorization(value: String) -> Int:
    """Which case of the module header (step 2) `value` is: `_AUTH_BEARER`
    (scheme Bearer, which `bearer_token_from_header` then parses),
    `_AUTH_OTHER_SCHEME`, `_AUTH_MALFORMED` (scheme not a token) or
    `_AUTH_REPEATED`. Byte by byte: the HTTP/1 parser maps an obs-text byte
    to a two-byte UTF-8 character, so a String slice could split one."""
    var b = value.as_bytes()
    var n = len(b)
    # A comma list with an element whose scheme is Bearer.
    var has_comma = False
    var bearer_elements = 0
    var i = 0
    while i <= n:
        # One element: [i, j) up to the next comma or the end.
        var j = i
        while j < n and b[j] != UInt8(ord(",")):
            j += 1
        if j < n:
            has_comma = True
        var s = i
        while s < j and (b[s] == UInt8(ord(" ")) or b[s] == UInt8(0x09)):
            s += 1
        var e = s
        while e < j and b[e] != UInt8(ord(" ")) and b[e] != UInt8(0x09):
            e += 1
        if _is_bearer_word(value, s, e):
            bearer_elements += 1
        i = j + 1
    if has_comma and bearer_elements > 0:
        return _AUTH_REPEATED
    # One credential: the scheme runs to the first space.
    var k = 0
    while k < n and b[k] != UInt8(ord(" ")):
        if not _is_tchar(b[k]):
            return _AUTH_MALFORMED
        k += 1
    if k == 0:
        return _AUTH_MALFORMED
    if _is_bearer_word(value, 0, k):
        return _AUTH_BEARER
    return _AUTH_OTHER_SCHEME


def bearer_token_from_header(value: String) -> Optional[String]:
    """The token of an `Authorization: Bearer <token68>` value, or None when
    the value is not exactly that (scheme name case-insensitive)."""
    var b = value.as_bytes()
    if len(b) < 8 or len(b) > 7 + MAX_TOKEN_BYTES:
        return Optional[String]()
    # The scheme is compared byte by byte, never by slicing the String: the
    # HTTP/1 parser maps an obs-text byte to a two-byte UTF-8 character, so
    # byte 6 of a hostile value can fall inside a character.
    var bearer = String("bearer")
    var want = bearer.as_bytes()
    for k in range(6):
        var c = b[k]
        if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            c = c + UInt8(0x20)
        if c != want[k]:
            return Optional[String]()
    if b[6] != UInt8(ord(" ")):
        return Optional[String]()
    var i = 7
    while i < len(b) and _is_token68_byte(b[i]):
        i += 1
    if i == 7:
        return Optional[String]()
    while i < len(b) and b[i] == UInt8(ord("=")):
        i += 1
    if i != len(b):
        return Optional[String]()
    return Optional[String](String(value[byte=7 : len(b)]))


def _refusal(status: Int, text: String) -> HttpResponse:
    """`status` with a fixed text body, never cached."""
    var r = HttpResponse(status=Int32(status))
    r.headers[String("content-type")] = String("text/plain; charset=utf-8")
    r.headers[String("cache-control")] = String("no-store")
    var body = List[UInt8]()
    body.extend(Span(text.as_bytes()))
    r.headers[String("content-length")] = String(len(body))
    r.body = body^
    return r^


def unauthorized_response(www_authenticate: String) -> HttpResponse:
    """A 401 with the given `WWW-Authenticate` value and a fixed body."""
    var r = _refusal(401, UNAUTHORIZED_BODY)
    r.headers[String("www-authenticate")] = www_authenticate
    return r^


def bad_request_response() -> HttpResponse:
    """A 400 with `WWW-Authenticate: Bearer error="invalid_request"` and a
    fixed body (RFC 6750 section 3.1)."""
    var r = _refusal(400, BAD_REQUEST_BODY)
    r.headers[String("www-authenticate")] = WWW_AUTHENTICATE_INVALID_REQUEST
    return r^


def keys_unavailable_response(retry_after_s: Int) -> HttpResponse:
    """A 503 with `Retry-After: <retry_after_s>` (at least 1) and a fixed
    body; no challenge, since the token was not judged."""
    var r = _refusal(503, KEYS_UNAVAILABLE_BODY)
    r.headers[String("retry-after")] = String(
        retry_after_s if retry_after_s >= 1 else 1
    )
    return r^


struct BearerJwtMiddleware[V: BearerVerifier](Middleware, Movable, Deinitable):
    """Authenticates every request by its bearer JWT through `V` (module
    header)."""

    var _verifier: Self.V
    var _last_reason: String

    def __init__(out self, var verifier: Self.V):
        self._verifier = verifier^
        self._last_reason = String("")

    def last_reason(self) -> String:
        """The reason code of the last `before` (reasons.mojo)."""
        return self._last_reason.copy()

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        ctx.principal = Optional[Principal]()
        var header = req.headers.get(String("authorization"))
        if not header:
            self._last_reason = String(REASON_MISSING_HEADER)
            return Optional[HttpResponse](
                unauthorized_response(WWW_AUTHENTICATE_BEARER)
            )
        var kind = _classify_authorization(header.value())
        if kind == _AUTH_REPEATED:
            self._last_reason = String(REASON_REPEATED_HEADER)
            return Optional[HttpResponse](bad_request_response())
        if kind == _AUTH_OTHER_SCHEME:
            self._last_reason = String(REASON_OTHER_SCHEME)
            return Optional[HttpResponse](
                unauthorized_response(WWW_AUTHENTICATE_BEARER)
            )
        var token = Optional[String]()
        if kind == _AUTH_BEARER:
            token = bearer_token_from_header(header.value())
        if not token:
            self._last_reason = String(REASON_MALFORMED_HEADER)
            return Optional[HttpResponse](bad_request_response())
        var outcome = self._verifier.verify(token.value())
        self._last_reason = outcome.reason.copy()
        if outcome.keys_unavailable():
            return Optional[HttpResponse](
                keys_unavailable_response(outcome.retry_after_s)
            )
        if not outcome.principal:
            return Optional[HttpResponse](
                unauthorized_response(WWW_AUTHENTICATE_INVALID_TOKEN)
            )
        ctx.principal = Optional[Principal](outcome.principal.take())
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        pass
