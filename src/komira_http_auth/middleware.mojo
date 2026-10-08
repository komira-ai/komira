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
#   2. reads `Authorization`. It must be `Bearer`, one space, and a token68
#      (RFC 7235: the base64url and base64 alphabets, `.`, `~`, `+`, `/`,
#      trailing `=`) of at most 8 KiB. Missing, another scheme, extra spaces,
#      or a comma (the HTTP/1 parser folds a repeated header into
#      `a, b`) is answered 401 with
#      `WWW-Authenticate: Bearer error="invalid_request"`;
#   3. hands the token to the verifier. Any refusal is answered 401 with
#      `WWW-Authenticate: Bearer error="invalid_token"`;
#   4. on success sets `ctx.principal` and lets the request through.
#
# Two deliberate departures from RFC 6750 section 3.1, both from the package
# spec: (a) it pairs invalid_request with 400; here every authentication
# failure is a 401 so a client has one status to handle; (b) it says a request
# with no credentials, or with another scheme such as `Basic`, SHOULD get a
# bare `WWW-Authenticate: Bearer` with no error code; here it gets
# invalid_request like any other unusable Authorization header. A bare
# challenge for those two cases is a candidate change for the spec owner.
#
# The HTTP request's headers are one map entry per name; the HTTP/1 parser
# comma-folds a repeated `Authorization` into one value, and the comma makes
# it malformed, so two Authorization headers are invalid_request.
#
# The 401 body is a fixed text and its headers are fixed values: nothing in a
# response, and nothing this file logs (it logs nothing), comes from the
# token. `last_reason()` holds the reason code of the last decision for the
# embedder to log or count.
#
# `before` never raises (a raise would become a 500 in ErrorMappingMiddleware):
# anything unexpected is an invalid_token refusal.
#
# The verifier runs on the serving thread, so a JWKS fetch blocks it for at
# most the fetch timeout, at most once per refetch window.
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
)
from komira_http_auth.token import MAX_TOKEN_BYTES
from komira_http_auth.verifier import BearerVerifier


comptime WWW_AUTHENTICATE_INVALID_REQUEST: String = 'Bearer error="invalid_request"'
comptime WWW_AUTHENTICATE_INVALID_TOKEN: String = 'Bearer error="invalid_token"'
comptime UNAUTHORIZED_BODY: String = "unauthorized\n"


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


def unauthorized_response(www_authenticate: String) -> HttpResponse:
    """A 401 with the given `WWW-Authenticate` value and a fixed body."""
    var r = HttpResponse(status=Int32(401))
    r.headers[String("www-authenticate")] = www_authenticate
    r.headers[String("content-type")] = String("text/plain; charset=utf-8")
    r.headers[String("cache-control")] = String("no-store")
    var body = List[UInt8]()
    body.extend(Span(UNAUTHORIZED_BODY.as_bytes()))
    r.headers[String("content-length")] = String(len(body))
    r.body = body^
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
                unauthorized_response(WWW_AUTHENTICATE_INVALID_REQUEST)
            )
        var token = bearer_token_from_header(header.value())
        if not token:
            self._last_reason = String(REASON_MALFORMED_HEADER)
            return Optional[HttpResponse](
                unauthorized_response(WWW_AUTHENTICATE_INVALID_REQUEST)
            )
        var outcome = self._verifier.verify(token.value())
        self._last_reason = outcome.reason.copy()
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
