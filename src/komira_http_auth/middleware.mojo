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
#        * two or more credentials: the HTTP/1 parser folds a repeated
#          header into `a, b`, so two Authorization fields, of any schemes,
#          reach this layer as one comma list. The list is split at commas
#          outside quoted-strings; it is refused when two of its elements
#          start a credential (an element after the first starts one unless
#          it is empty or an auth-param, `token BWS "="`), when an element
#          is empty (an empty field folded in), or when it holds a Bearer
#          credential (a Bearer token68 never holds a comma). The request
#          "uses more than one method" or "repeats the same parameter": 400
#          with `WWW-Authenticate: Bearer error="invalid_request"`, reason
#          `repeated_authorization`. One credential whose own auth-params
#          hold commas (`Digest username="a", realm="b"`) is ONE credential
#          and is answered as another scheme, 401;
#        * an unterminated quoted-string, a scheme that is not an RFC 9110
#          token, or the `Bearer` scheme not followed by exactly one space
#          and a token68 (RFC 7235: the base64url and base64 alphabets,
#          `.`, `~`, `+`, `/`, trailing `=`) of at most 8 KiB: malformed,
#          so 400 invalid_request as above;
#   3. hands the token to the verifier. A refusal because the verifier has
#      no usable keys (`VerifyOutcome.keys_unavailable()`: never fetched, or
#      past freshness plus max-stale with every refresh failing) is answered
#      503 with `Retry-After: <seconds until the next refresh may start>` and
#      no challenge: the token was not judged. Any other refusal is answered
#      401 with `WWW-Authenticate: Bearer error="invalid_token"`;
#   4. on success sets `ctx.principal` and lets the request through.
#
# The scheme name is compared case-insensitively. `_classify_authorization`
# states the list rule exactly. Two fields are refused as repeated whenever
# the second is a well-formed credential and the first leaves no
# quoted-string open. A fold hides only when the second field is a bare
# auth-param (`a=b`) or the first leaves a quoted-string open (it swallows
# the comma); the value is then refused as one malformed or other-scheme
# credential. Nothing in the list rule can move a value toward acceptance,
# which needs exactly `Bearer <token68>`.
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


# Bytes the Authorization classifier compares against, as constants so no
# String is built per byte or per element.
comptime _SP: UInt8 = 0x20
comptime _HTAB: UInt8 = 0x09
comptime _COMMA: UInt8 = 0x2C
comptime _EQUALS: UInt8 = 0x3D
comptime _DQUOTE: UInt8 = 0x22
comptime _BACKSLASH: UInt8 = 0x5C


def _is_tchar(c: UInt8) -> Bool:
    """RFC 9110 section 5.6.2 tchar: ALPHA, DIGIT and
    `! # $ % & ' * + - . ^ _ ` | ~`."""
    return (
        (c >= 0x41 and c <= 0x5A)  # A-Z
        or (c >= 0x61 and c <= 0x7A)  # a-z
        or (c >= 0x30 and c <= 0x39)  # 0-9
        or c == 0x21  # !
        or c == 0x23  # #
        or c == 0x24  # $
        or c == 0x25  # %
        or c == 0x26  # &
        or c == 0x27  # '
        or c == 0x2A  # *
        or c == 0x2B  # +
        or c == 0x2D  # -
        or c == 0x2E  # .
        or c == 0x5E  # ^
        or c == 0x5F  # _
        or c == 0x60  # `
        or c == 0x7C  # |
        or c == 0x7E  # ~
    )


@always_inline
def _is_ows(c: UInt8) -> Bool:
    return c == _SP or c == _HTAB


@always_inline
def _lower(c: UInt8) -> UInt8:
    return c + 0x20 if (c >= 0x41 and c <= 0x5A) else c


def _is_bearer_word(b: Span[UInt8, _], start: Int, end: Int) -> Bool:
    """Whether bytes [start, end) of `b` are `bearer`, ASCII
    case-insensitively."""
    if end - start != 6:
        return False
    return (
        _lower(b[start]) == 0x62  # b
        and _lower(b[start + 1]) == 0x65  # e
        and _lower(b[start + 2]) == 0x61  # a
        and _lower(b[start + 3]) == 0x72  # r
        and _lower(b[start + 4]) == 0x65  # e
        and _lower(b[start + 5]) == 0x72  # r
    )


def _classify_authorization(value: String) -> Int:
    """Which case of the module header (step 2) `value` is: `_AUTH_BEARER`
    (scheme Bearer, which `bearer_token_from_header` then parses),
    `_AUTH_OTHER_SCHEME`, `_AUTH_MALFORMED` or `_AUTH_REPEATED`. Byte by
    byte: the HTTP/1 parser maps an obs-text byte to a two-byte UTF-8
    character, so a String slice could split one.

    THE LIST. `value` is split into elements at every comma that is not
    inside a quoted-string. A quoted-string opens only at a `"` whose
    previous non-blank byte in the element is `=` (the value of an
    auth-param, `token BWS "=" BWS quoted-string`), and inside it a
    backslash escapes the next byte. Linear in the value, no allocation (the
    list scan, then a scan of the scheme).

    THE ELEMENTS. After leading spaces and tabs, an element is
      * EMPTY when nothing is left;
      * an AUTH-PARAM when it is not the first element and it is a token
        (1*tchar), optional spaces or tabs, then `=`;
      * otherwise the START OF A CREDENTIAL. The first element always is
        (a value starts with its scheme); a later one is when it begins with
        a token followed by a space, a tab or its end (`Basic xyz`, `Basic`),
        and, failing closed, whenever it is neither empty nor an auth-param.
      A credential start is a BEARER credential when its token is `bearer`
      (any case) followed by a space, a tab or the element's end.

    THE RULE. A value of two or more elements is `_AUTH_REPEATED` when
      (a) two or more elements start a credential, or
      (b) an element is empty (an empty field folded in), or
      (c) a Bearer credential is in it (a Bearer credential is one token68
          and never holds a comma).
    Otherwise an unterminated quoted-string is `_AUTH_MALFORMED`, and the
    value is one credential: its scheme runs to the first space.

    A well-formed credential (RFC 9110 section 11.4: `auth-scheme [ 1*SP (
    token68 / #auth-param ) ]`) never starts an element after its first,
    so the HTTP/1 fold of two fields, `A, B`, is caught by (a) whenever B is
    a well-formed credential and A leaves no quoted-string open; by (b) when
    either is empty. A quoted-string left open by A swallows the fold, and a
    B that is only an auth-param (`a=b`) is read as one of A's; the value is
    then read as one credential, malformed or of another scheme, and refused
    either way: no rule here moves a value toward acceptance, which needs
    exactly `Bearer <token68>`."""
    var b = value.as_bytes()
    var n = len(b)
    var elements = 0
    var credentials = 0
    var empty_elements = 0
    var bearer_credentials = 0
    var unterminated = False
    var i = 0
    while i <= n:
        # One element: [i, j) up to the next comma outside a quoted-string,
        # or the end.
        var j = i
        var in_quote = False
        var prev = UInt8(0)  # the last non-blank byte outside a quote
        while j < n:
            var c = b[j]
            if in_quote:
                if c == _BACKSLASH:
                    j += 2
                    continue
                if c == _DQUOTE:
                    in_quote = False
                    prev = c
                j += 1
                continue
            if c == _COMMA:
                break
            if c == _DQUOTE and prev == _EQUALS:
                in_quote = True
            elif not _is_ows(c):
                prev = c
            j += 1
        if in_quote:
            unterminated = True
        if j > n:
            j = n  # a trailing backslash inside a quote
        elements += 1
        var s = i
        while s < j and _is_ows(b[s]):
            s += 1
        if s == j:
            empty_elements += 1
        else:
            var e = s
            while e < j and _is_tchar(b[e]):
                e += 1
            var t = e
            while t < j and _is_ows(b[t]):
                t += 1
            var is_param = elements > 1 and e > s and t < j and b[t] == _EQUALS
            if not is_param:
                credentials += 1
                if (e == j or _is_ows(b[e])) and _is_bearer_word(b, s, e):
                    bearer_credentials += 1
        i = j + 1
    if elements > 1 and (
        credentials > 1 or empty_elements > 0 or bearer_credentials > 0
    ):
        return _AUTH_REPEATED
    if unterminated:
        return _AUTH_MALFORMED
    # One credential: the scheme runs to the first space.
    var k = 0
    while k < n and b[k] != _SP:
        if not _is_tchar(b[k]):
            return _AUTH_MALFORMED
        k += 1
    if k == 0:
        return _AUTH_MALFORMED
    if _is_bearer_word(b, 0, k):
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
    if not _is_bearer_word(b, 0, 6):
        return Optional[String]()
    if b[6] != _SP:
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
