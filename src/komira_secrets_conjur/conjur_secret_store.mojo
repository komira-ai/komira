# =============================================================================
# conjur_secret_store.mojo: `ConjurSecretStore`, a `SecretStore` over CyberArk
#   Conjur's REST API.
# =============================================================================
#
# `resolve(secret_ref)` parses the handle, takes an access token from the
# `ConjurAuthSource`, and sends one
#
#     GET https://{appliance}/secrets/{account}/variable/{variable_id}
#     Authorization: Token token="<base64 access token>"
#
# over a fresh connector. The 200 body IS the secret (no JSON envelope, no
# base64); it goes straight into a zeroizing `SecretValue` and the transient
# buffer is wiped. Any other status raises with the status and a hint, never the
# response body or the token. A 200 with an empty body raises too, rather than
# returning an empty value.
#
# The handle is `{account}/{variable_id}` (the variable id is a slash-delimited
# policy path, so the split is on the FIRST '/'), or
# `{appliance_host}|{account}/{variable_id}` to name the appliance in the handle.
# A handle that names a host makes the store send the access token to that host:
# accept such handles only from a source you trust.
#
# The connector factory is a non-capturing `def () thin -> C`; production binds
# a TLS connector factory and a test binds a `ScriptedConnector` factory.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_GET, HttpMethod
from komira_http_core.transport.io_stream import Connector

from komira_secret_store.secret_store import SecretStore
from komira_secret_store.secret_value import SecretValue

from komira_secrets_conjur.conjur_auth_source import ConjurAuthSource


# =============================================================================
# §0 — the Conjur REST endpoint facts.
# =============================================================================
# The default Conjur appliance port. TLS: the connector `C` must be a TLS connector
# against a real appliance. Port 443.
comptime CONJUR_DEFAULT_PORT: UInt16 = 443
# The secret-read path prefix + the resource-kind segment. The full path is
# `/secrets/{account}/variable/{variable_id}` where {account} + {variable_id}
# come from the opaque secret_ref (see `parse_conjur_ref`). `variable` is the
# Conjur resource KIND for a stored secret.
comptime CONJUR_SECRETS_PREFIX: String = "/secrets/"
comptime CONJUR_VARIABLE_KIND: String = "/variable/"


# =============================================================================
# §0.5 — secret_ref parsing + pure request-construction helpers (testable
#   without a wire round-trip).
# =============================================================================
@fieldwise_init
struct ConjurSecretRef(Copyable, Movable, Deinitable):
    """The parsed parts of a Conjur `secret_ref`. The foundation stores an opaque
    handle; for Conjur that handle is `{account}/{variable_id}` (the variable_id
    itself may contain `/`, e.g. `app/db/password`, so the parse splits on the
    FIRST `/` only). Carries ONLY names (no secret)."""

    var account: String
    var variable_id: String

    # Host is OPTIONAL in the ref — when absent the store uses the
    # appliance host configured at construction. An empty host means "use the
    # configured appliance host".
    var appliance_host: String


def parse_conjur_ref(secret_ref: String) raises -> ConjurSecretRef:
    """Parse an opaque Conjur `secret_ref` into its parts (two accepted forms).

    Forms:

      * `{account}/{variable_id}` — the common case; the appliance host comes
        from the store's construction-time config. e.g.
        `myorg/app/db/password` → account=`myorg`,
        variable_id=`app/db/password`.
      * `{appliance_host}|{account}/{variable_id}` — a fully-qualified ref that
        also names the appliance host (the `|` separates the host from the
        account/id), for multi-appliance deployments.

    The variable_id may contain `/` (Conjur policy paths are slash-delimited),
    so the account split is on the FIRST `/` AFTER any host prefix. A malformed
    ref (no `/`, or an empty account/variable) RAISES — fail fast and loud, never
    a silent mis-read of the wrong variable. Pure — no network."""
    var rest = secret_ref
    var host = String("")
    # Optional `{host}|` prefix.
    var bar = _index_of(rest, ord("|"))
    if bar >= 0:
        host = _slice(rest, 0, bar)
        rest = _slice(rest, bar + 1, len(rest.as_bytes()))
    # Split account from variable_id on the FIRST `/`.
    var slash = _index_of(rest, ord("/"))
    if slash <= 0:
        raise Error(
            String("ConjurSecretStore: malformed secret_ref '")
            + secret_ref
            + String(
                "' — expected '{account}/{variable_id}' (or"
                " '{host}|{account}/{variable_id}')"
            )
        )
    var account = _slice(rest, 0, slash)
    var variable_id = _slice(rest, slash + 1, len(rest.as_bytes()))
    if len(account.as_bytes()) == 0 or len(variable_id.as_bytes()) == 0:
        raise Error(
            String("ConjurSecretStore: malformed secret_ref '")
            + secret_ref
            + String("' — empty account or variable id")
        )
    return ConjurSecretRef(
        account=account^, variable_id=variable_id^, appliance_host=host^
    )


def read_path_for(account: String, variable_id: String) -> String:
    """The Conjur secret-read REST path:
    `/secrets/{account}/variable/{variable_id}`. Pure — no network."""
    return (
        CONJUR_SECRETS_PREFIX + account + CONJUR_VARIABLE_KIND + variable_id
    )


def build_read_request_headers(var token: String) raises -> HeaderMap:
    """Build the request headers for the Conjur secret-read GET: the
    `Authorization: Token token="<base64>"` Conjur-scheme auth + `Accept:
    text/plain`. Takes `token` BY VALUE (moved in) so the caller keeps no
    lingering copy — the only copy ends up on the returned `HeaderMap`'s bytes.
    Factored out so the auth-header stamping is unit-testable WITHOUT a live wire
    round-trip — a test asserts the `Token token="…"` header off the returned
    `HeaderMap` (the 'the auth path sends a Conjur Token header' gate). Pure — no
    network."""
    var headers = HeaderMap()
    # Build the Conjur `Token token="<base64>"` header value. The token is moved
    # in BY VALUE; concatenate via a single owned local so the move binds before
    # the chained `+` (a moved operand mid-chain is mis-parsed as a unary `+`).
    var auth_value = String('Token token="')
    auth_value += token^
    auth_value += String('"')
    headers.append(String("Authorization"), auth_value^)
    headers.append(String("Accept"), String("text/plain"))
    return headers^


# =============================================================================
# §1 — ConjurSecretStore[C, T] — the SecretStore conformer.
# =============================================================================
struct ConjurSecretStore[C: Connector, T: ConjurAuthSource](
    SecretStore, Movable, Deinitable
):
    """The CyberArk Conjur `SecretStore` conformer.
    `resolve(secret_ref)` GETs `https://{appliance}/secrets/{account}/variable/
    {variable_id}` with the Conjur `Token token="<base64>"` access token, and
    lands the RAW response body (the secret — NO JSON envelope, NO base64) in a
    zeroizing `SecretValue`. A non-200 status RAISES (fail fast and loud).
    Parametric over the HTTP connector `C` (TLS against a real appliance, scripted in test) for
    the secret READ + the auth source `T` (live authn POST, or static in
    test).

    Fields are a `def () thin -> C` fn-ptr (a code pointer, no heap), the
    moved-in auth source `T`, and the flat-String appliance config. No
    wildcard-origin field, no UnsafePointer field; no secret is ever a struct
    field (the resolved value is built in the frame and returned)."""

    # The connector factory for the secret READ — a `thin` (non-raising,
    # non-capturing) fn-ptr. Production binds a TLS-connector factory; a test
    # binds a `ScriptedConnector`-producing factory.
    var _mk_connector: def () thin -> Self.C
    # The Conjur access-token source (moved in). Owns the live authn POST
    # or the canned token (test).
    var _auth: Self.T
    # The default Conjur appliance host + port (used when the secret_ref does not
    # carry its own host).
    var _appliance_host: String
    var _appliance_port: UInt16

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        var auth: Self.T,
        var appliance_host: String,
        appliance_port: UInt16 = CONJUR_DEFAULT_PORT,
    ):
        """Construct with the read-connector factory + the (moved-in) auth
        source + the default appliance host/port."""
        self._mk_connector = mk_connector
        self._auth = auth^
        self._appliance_host = appliance_host^
        self._appliance_port = appliance_port

    # -------------------------------------------------------------------------
    # The SecretStore trait method — handle in, zeroizing value out.
    # -------------------------------------------------------------------------
    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        """Resolve `secret_ref` (a Conjur `{account}/{variable_id}` handle) to
        its value by GETting the Conjur secret-read endpoint with the
        `Token token="<base64>"` access token. A non-200 status (404 missing /
        401 token rejected / 403 not permitted / any other) RAISES (fail fast and
        loud — never a silent stale / empty value). The RAW response body IS the
        secret — it lands DIRECTLY in a zeroizing `SecretValue` (no JSON
        envelope, no base64-decode), and the transient response bytes are WIPED
        before return. The error NEVER carries the secret body or the access
        token."""
        # --- 1. Parse the ref + mint / fetch the access token (the auth seam). -
        var parsed = parse_conjur_ref(secret_ref)
        var token = self._auth.access_token()

        # --- 2. Build the GET to /secrets/{account}/variable/{variable_id}. ---
        # The path + header construction are factored into pure helpers
        # (`read_path_for` / `build_read_request_headers`) so the auth-header
        # stamping is unit-testable WITHOUT a wire round-trip.
        var path = read_path_for(parsed.account, parsed.variable_id)
        var host = parsed.appliance_host.copy()
        if len(host.as_bytes()) == 0:
            host = self._appliance_host.copy()
        var url = Url.https(host^, self._appliance_port, path^)
        # MOVE the token into the header builder (no lingering local copy on this
        # frame): after this, `token` is consumed and the only copy lives on the
        # request's header bytes.
        var headers = build_read_request_headers(token^)
        var req = build_request_with_body[EmptyBody](
            HttpMethod(code=HTTP_METHOD_GET),
            url^,
            headers^,
            EmptyBody.new(),
        )

        # --- 3. Dial a fresh connector + drive one synchronous GET. ---
        var connector = self._mk_connector()
        var client = HttpClient[Self.C].with_defaults(connector^)
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            req^, reactor
        )
        var status = Int(cr.status)
        var resp_bytes = cr.body.take_bytes()

        # --- 4. Map a non-200 to a clear RAISE (fail fast and loud). ---
        # The error NEVER includes the response body (it might carry sensitive
        # detail) or the token; only the status + the (non-secret) ref name.
        if status != 200:
            _wipe_list(resp_bytes)
            raise Error(
                String("ConjurSecretStore: resolve of secret_ref '")
                + secret_ref
                + String("' failed: HTTP ")
                + String(status)
                + _status_hint(status)
            )

        # --- 5. The 200 body IS the secret. Land it DIRECTLY in SecretValue. ---
        # Conjur returns the raw stored value as the response body — no JSON
        # envelope, no base64. A zero-length body on a 200 is a protocol surprise
        # we never paper over with an empty SecretValue.
        if len(resp_bytes) == 0:
            _wipe_list(resp_bytes)
            raise Error(
                String("ConjurSecretStore: resolve of secret_ref '")
                + secret_ref
                + String("' returned 200 with an empty body")
            )
        var value = SecretValue(Span[UInt8, origin_of(resp_bytes)](resp_bytes))

        # --- 6. Wipe the transient that held the plaintext, then return. ---
        # The raw response bytes held the secret. The SecretValue has its own
        # zeroizing copy; wipe the transient so no plaintext outlives the value.
        _wipe_list(resp_bytes)
        return value^


# =============================================================================
# §2 — tiny String helpers (no external string-util dep needed for these).
# =============================================================================
def _index_of(haystack: String, byte: Int) -> Int:
    """Index of the first occurrence of `byte` in `haystack`, or -1."""
    var hb = haystack.as_bytes()
    for i in range(len(hb)):
        if Int(hb[i]) == byte:
            return i
    return -1


def _slice(s: String, start: Int, end: Int) -> String:
    """A byte-range substring `s[start:end]` (ASCII-safe — Conjur refs are
    ASCII). Bounds are assumed valid by the caller (the parse computes them)."""
    var sb = s.as_bytes()
    var out = String("")
    var lo = start
    if lo < 0:
        lo = 0
    var hi = end
    if hi > len(sb):
        hi = len(sb)
    for k in range(lo, hi):
        out += chr(Int(sb[k]))
    return out^


def _status_hint(status: Int) -> StaticString:
    """A short, NON-secret hint for the common Conjur error statuses — aids the
    operator without echoing the response body."""
    if status == 404:
        return " (NOT_FOUND — the variable does not exist)"
    if status == 403:
        return (
            " (FORBIDDEN — the authenticated role lacks 'execute' on the"
            " variable)"
        )
    if status == 401:
        return " (UNAUTHENTICATED — the access token was rejected)"
    return ""


def _wipe_list(mut buf: List[UInt8]):
    """Best-effort overwrite-then-clear of a transient `List[UInt8]` that held
    secret bytes. Defense-in-depth: the AUTHORITATIVE wipe is the `SecretValue`
    (InlineArray + the -O3-surviving FFI `zeroize_inline_array`); these transients
    hold the bytes for only the few instructions between the wire read and the
    `SecretValue` copy. We overwrite each byte then clear (drop the heap buffer).
    (A plain loop may be DCE-eligible at -O3, which is why the load-bearing secure
    wipe lives on the InlineArray-backed value, not here.)"""
    for i in range(len(buf)):
        buf[i] = UInt8(0)
    buf.clear()
