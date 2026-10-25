# =============================================================================
# conjur_auth_source.mojo: the access-token seam under `ConjurSecretStore`.
# =============================================================================
#
#   * `ConjurAuthSource`        the trait: `access_token()` returns the base64
#                               token for `Authorization: Token token="..."`. A
#                               mint failure raises; a resolve never falls back to
#                               anonymous.
#   * `LiveConjurAuthSource[C]` POSTs the API key to
#                               `{appliance}/authn/{account}/{login}/authenticate`
#                               over a fresh connector, one POST per token, and
#                               returns the 200 body (trimmed of surrounding
#                               ASCII whitespace). The API key is the request
#                               body, never a header; it is held in a field so a
#                               later call can mint again, never returned and
#                               never in an error.
#   * `StaticConjurAuthSource`  a canned token with a mint counter (the double).
#
# Tokens are not cached: every `access_token()` is one authn POST. A caching
# wrapper (read the token's expiry, mint again near it) would be a new
# `ConjurAuthSource` over this trait.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_POST, HttpMethod
from komira_http_core.transport.io_stream import Connector


# =============================================================================
# §0 — ConjurAuthSource — the pluggable access-token seam.
# =============================================================================
trait ConjurAuthSource(Movable, Deinitable):
    """Produce a fresh Conjur access token (the base64 value stamped into the
    `Authorization: Token token="<base64>"` header) for the Conjur secret-read
    REST call. A mint failure RAISES (fail fast and loud: a resolve path that
    cannot authenticate must not fall back to anonymous and then 401 on the
    read). No UnsafePointer crosses the boundary; the long-lived API key is the
    mint INPUT and is never returned, never logged. The output is the
    base64-encoded Conjur access token string."""

    def access_token(mut self) raises -> String:
        ...


# =============================================================================
# §0.5 — pure authn request-construction helpers (testable without a wire
#   round-trip).
# =============================================================================
def authn_path_for(account: String, login: String) -> String:
    """The Conjur authn REST path: `/authn/{account}/{login}/authenticate`.
    `account` is the Conjur organization account; `login` is the URL-encoded
    host/user identity (e.g. `host%2Fmy-app`). Pure — no network."""
    return (
        String("/authn/")
        + account
        + String("/")
        + login
        + String("/authenticate")
    )


def build_authn_request_headers() raises -> HeaderMap:
    """Build the request headers for the Conjur authn POST: `Content-Type:
    text/plain` (the body is the raw API key) + `Accept: text/plain` (the
    response is the base64 access token as a bare text body). Factored out so
    the authn request shape is unit-testable WITHOUT a live wire round-trip.
    Pure — no network. NOTE: the API key is the request BODY, not a header, so
    no secret material lands on the returned HeaderMap."""
    var headers = HeaderMap()
    headers.append(String("Content-Type"), String("text/plain"))
    headers.append(String("Accept"), String("text/plain"))
    return headers^


# =============================================================================
# §1 — StaticConjurAuthSource — a canned base64 access token (the test double).
#
# Returns a fixed base64 token string with NO network. Lets the store test
# assert the `Authorization: Token token="<token>"` header was stamped on the
# outbound read request (the canned value flows through the store's pure header
# builder) — and lets every resolve test run offline. The live source below
# never holds a fixed token like this; it mints per-use via the authn POST.
# =============================================================================
struct StaticConjurAuthSource(ConjurAuthSource, Movable):
    """An in-memory, canned `ConjurAuthSource` (the TEST DOUBLE). Returns a fixed
    base64 access token on every `access_token()` and records a `mint_count`
    (the auth-call proof). No network, no reactor."""

    var _token: String
    var _mint_count: Int

    def __init__(out self, var token: String):
        self._token = token^
        self._mint_count = 0

    def mint_count(self) -> Int:
        """How many times a token was requested (the auth-call proof)."""
        return self._mint_count

    def access_token(mut self) raises -> String:
        """Return the canned token + bump the mint count. NEVER raises (the
        double always has a token); a live source raises on a mint failure."""
        self._mint_count += 1
        return self._token.copy()


# =============================================================================
# §2 — LiveConjurAuthSource[C] — the live source over the Conjur authn
#   endpoint (the API-key → base64-access-token authn POST).
#
# Owns the appliance host/port + account + login + the long-lived API key, plus
# its OWN connector factory (a `def () thin -> C` fn-ptr). On `access_token()`
# it drives a SINGLE
# synchronous authn POST over a fresh `HttpClient[C]` + `BlockingRuntime` and
# returns the base64 access-token body. This is the ONLY auth path that touches
# the network. A non-200 (401 bad key / 404 wrong account-or-login) RAISES
# (fail-LOUD — never anonymous). The API key is the mint INPUT (held as a field
# so re-auth after token expiry can re-mint), never returned, never logged.
#
# NOTE (no token cache): this source mints a fresh token on EVERY
# `access_token()` (so a job resolving N secrets does N authn POSTs + N reads).
# A caching wrapper (parse the token's `exp`, re-mint at the TTL margin) is a
# clean additive follow-up over THIS trait.
# =============================================================================
struct LiveConjurAuthSource[C: Connector](ConjurAuthSource, Movable):
    """The live `ConjurAuthSource`: mints a Conjur access token by POSTing
    the API key to `{appliance}/authn/{account}/{login}/authenticate` over a
    fresh `HttpClient[C]`, returning the base64 access-token body. A non-200
    status RAISES (fail-LOUD — never anonymous). The long-lived API key is the
    mint input (a field, re-used on each re-mint), never returned, never logged.

    Fields are a `def () thin -> C` connector-factory fn-ptr (a code pointer,
    no heap), flat-String config and the API key String. No wildcard-origin
    field, no UnsafePointer field; the API key and the minted token are values,
    never logged."""

    # The connector factory — a `thin` (non-raising, non-capturing) fn-ptr, the
    # same idiom the store uses. Production binds a TLS-connector factory.
    var _mk_connector: def () thin -> Self.C
    # The Conjur appliance host (e.g. `conjur.example.com`) + port (443 by default).
    var _appliance_host: String
    var _appliance_port: UInt16
    # The Conjur organization account.
    var _account: String
    # The URL-encoded login identity (e.g. `host%2Fmy-app`).
    var _login: String
    # The long-lived host/user API key — the mint INPUT. Held so a re-auth after
    # token expiry can re-mint. NEVER returned, NEVER logged.
    var _api_key: String

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        var appliance_host: String,
        appliance_port: UInt16,
        var account: String,
        var login: String,
        var api_key: String,
    ):
        """Construct with the connector factory + the Conjur appliance/account/
        login config + the long-lived API key (the mint input)."""
        self._mk_connector = mk_connector
        self._appliance_host = appliance_host^
        self._appliance_port = appliance_port
        self._account = account^
        self._login = login^
        self._api_key = api_key^

    def access_token(mut self) raises -> String:
        """Mint a fresh Conjur access token by POSTing the API key to the authn
        endpoint. The 200 body IS the base64 access token (returned verbatim for
        the `Authorization: Token token="<base64>"` header). A non-200 RAISES —
        the error NEVER carries the API key or the token body."""
        # --- 1. Build the authn POST to /authn/{account}/{login}/authenticate. -
        var path = authn_path_for(self._account, self._login)
        var url = Url.https(
            self._appliance_host.copy(), self._appliance_port, path^
        )
        var headers = build_authn_request_headers()
        # The API key is the request BODY (text/plain). Copy it into the body
        # conformer; the field copy stays for a later re-mint.
        var body = BytesBody.from_str(self._api_key)
        var req = build_request_with_body[BytesBody](
            HttpMethod(code=HTTP_METHOD_POST),
            url^,
            headers^,
            body^,
        )

        # --- 2. Dial a fresh connector + drive one synchronous POST. ---
        var connector = self._mk_connector()
        var client = HttpClient[Self.C].with_defaults(connector^)
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
            req^, reactor
        )
        var status = Int(cr.status)
        var resp_bytes = cr.body.take_bytes()

        # --- 3. Map a non-200 to a clear RAISE (fail fast and loud). ---
        # The error NEVER includes the response body or the API key.
        if status != 200:
            _wipe_list(resp_bytes)
            raise Error(
                String("LiveConjurAuthSource: authn POST to /authn/")
                + self._account
                + String("/")
                + self._login
                + String("/authenticate failed: HTTP ")
                + String(status)
                + _authn_status_hint(status)
            )

        # --- 4. The 200 body IS the base64 access token. Return it verbatim. ---
        # The body is a bare text response (the base64 access token). Conjur may
        # frame it without a trailing newline; trim surrounding ASCII whitespace
        # defensively so the stamped header value is clean.
        var token = _ascii_trim(String(unsafe_from_utf8=Span(resp_bytes)))
        _wipe_list(resp_bytes)
        if token.byte_length() > 0 and not is_header_safe_token(token):
            raise Error(
                String("LiveConjurAuthSource: authn POST returned a body that")
                + String(" is not a valid access token (it holds a space, a")
                + String(" control byte or a non-ASCII byte)")
            )
        if token.byte_length() == 0:
            raise Error(
                String("LiveConjurAuthSource: authn POST returned 200 with an")
                + String(" empty access-token body")
            )
        return token^


# =============================================================================
# §3 — tiny helpers (no external string-util dep needed for these).
# =============================================================================
def is_header_safe_token(token: String) -> Bool:
    """Whether `token` can sit inside `Authorization: Token token="..."`: every
    byte printable ASCII (0x21 to 0x7E) and no `"` or `\\`. A Conjur access
    token is base64, so a real one always passes; CR, LF, a space, a control
    byte or a non-ASCII byte means the appliance (or a test double) is sending
    something that would break out of the header."""
    var b = token.as_bytes()
    for i in range(len(b)):
        if b[i] < UInt8(0x21) or b[i] > UInt8(0x7E):
            return False
        if b[i] == UInt8(0x22) or b[i] == UInt8(0x5C):
            return False
    return True


def _authn_status_hint(status: Int) -> StaticString:
    """A short, NON-secret hint for the common Conjur authn error statuses —
    aids the operator without echoing the response body or the API key."""
    if status == 401:
        return (
            " (UNAUTHENTICATED — the API key was rejected for this login)"
        )
    if status == 404:
        return (
            " (NOT_FOUND — the account or login identity does not exist)"
        )
    return ""


def _ascii_trim(var s: String) -> String:
    """Trim leading/trailing ASCII whitespace (space/tab/CR/LF) from `s`. The
    Conjur authn body is the base64 token; some appliances frame it with a
    trailing newline. Base64 contains no whitespace, so trimming cannot corrupt
    a well-formed token. Pure — no network."""
    var sb = s.as_bytes()
    var n = len(sb)
    var lo = 0
    while lo < n and (
        sb[lo] == UInt8(ord(" "))
        or sb[lo] == UInt8(ord("\t"))
        or sb[lo] == UInt8(ord("\n"))
        or sb[lo] == UInt8(ord("\r"))
    ):
        lo += 1
    var hi = n
    while hi > lo and (
        sb[hi - 1] == UInt8(ord(" "))
        or sb[hi - 1] == UInt8(ord("\t"))
        or sb[hi - 1] == UInt8(ord("\n"))
        or sb[hi - 1] == UInt8(ord("\r"))
    ):
        hi -= 1
    if lo == 0 and hi == n:
        return s^
    var out = String("")
    for k in range(lo, hi):
        out += chr(Int(sb[k]))
    return out^


def _wipe_list(mut buf: List[UInt8]):
    """Best-effort overwrite-then-clear of a transient `List[UInt8]` that held
    token (or api-key-derived) bytes. Defense-in-depth: the authoritative wipe of
    the SECRET value is the `SecretValue` (InlineArray + the -O3-surviving FFI
    `zeroize_inline_array`); the authn token is a short-lived runtime credential,
    not the secret, but we scrub the transient anyway. (A plain loop may be
    DCE-eligible at -O3, which is why the load-bearing secure wipe lives on the
    InlineArray-backed value, not here.)"""
    for i in range(len(buf)):
        buf[i] = UInt8(0)
    buf.clear()
