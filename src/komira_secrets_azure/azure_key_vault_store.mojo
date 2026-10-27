# =============================================================================
# azure_key_vault_store.mojo: `AzureKeyVaultStore`, a `SecretStore` over the
#   Azure Key Vault data plane.
# =============================================================================
#
# `resolve(secret_ref)` takes a secret identifier URI,
#
#     https://{vault}.vault.azure.net/secrets/{name}[/{version}]
#
# gets a token from the `AzureTokenSource`, and sends one
#
#     GET /secrets/{name}[/{version}]?api-version=7.4
#     Authorization: Bearer <token>
#
# over a fresh connector. The `value` field of the JSON answer (the plaintext,
# JSON-unescaped, not base64) goes into a zeroizing `SecretValue` and every
# transient that held it is dropped or wiped. Any other status raises with the
# status and a hint, never the body or the token; a 200 with no `value`
# raises. A handle that is not an https URI, whose host is not a plain
# `*.vault.azure.net` DNS name, or whose path is not `/secrets/...` raises
# before anything is sent: the token is only ever sent to a Key Vault host.
#
# `with_dial_host` points the TCP dial at another host (a private endpoint, or
# `127.0.0.1` in a test) while the handle's vault stays the logical identity.
#
# The connector factory is a non-capturing `def () thin -> C`.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.service import ClientRequest
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_GET, HttpMethod
from komira_http_core.transport.io_stream import Connector

from komira_secret_store.secret_store import SecretStore
from komira_secret_store.secret_value import SecretValue

from komira_secrets_azure.azure_token_source import AzureTokenSource


# =============================================================================
# §0 — the Azure Key Vault REST endpoint facts.
# =============================================================================
# The Key Vault DNS suffix every vault shares: `{vault}.vault.azure.net`. The
# host is per-vault (parsed out of the secret_ref), but it MUST end in this
# suffix for the request to reach the public Key Vault data plane.
comptime AZURE_KV_DNS_SUFFIX: String = ".vault.azure.net"
# Public Key Vault is HTTPS only — the connector `C` must be a TLS connector in
# production. Port 443 (0 = scheme default works too; we pin 443 for clarity).
comptime AZURE_KV_PORT: UInt16 = 443
# The data-plane API version. 7.4 is the current GA version. Sent as the
# mandatory `api-version` query parameter (a bare GET with no api-version 400s).
comptime AZURE_KV_API_VERSION: String = "7.4"
# The path segment that marks a SECRET resource (vs key / certificate).
comptime AZURE_KV_SECRETS_SEGMENT: String = "/secrets/"


# =============================================================================
# §0.5 — pure request-construction helpers (testable without a wire round-trip).
# =============================================================================
@fieldwise_init
struct KeyVaultRef(Movable, Deinitable):
    """The parsed pieces of a Key Vault secret identifier: the per-vault HOST
    (`{vault}.vault.azure.net`) and the resource PATH (`/secrets/{name}` or
    `/secrets/{name}/{version}`). A value POD — no secret, no pointer."""

    var host: String
    var path: String


def parse_key_vault_ref(secret_ref: String) raises -> KeyVaultRef:
    """Parse an Azure Key Vault secret identifier URI into (host, path). The
    only accepted form is
        https://{vault}.vault.azure.net/secrets/{name}[/{version}]
    where {vault} is one DNS label (letters, digits, `-`), {name} is 1 to 127 of
    letters, digits and `-` (Key Vault's grammar) and {version} is 1 to 64 of
    letters, digits and `-`. Everything else RAISES up-front: another scheme,
    host, port, userinfo, query, fragment, dot segment, empty or extra segment,
    space or control byte. The handle is untrusted text that becomes the request
    line, so nothing outside that grammar can reach it. No refusal quotes the
    handle (it may be a value pasted into the wrong field). Pure: no network."""
    var s = secret_ref
    # --- 1. The scheme: https:// only (the Key Vault data plane is HTTPS only).
    var scheme = String("https://")
    if not _starts_with(s, scheme):
        raise Error(
            String("AzureKeyVaultStore: secret_ref must be an https:// Key Vault")
            + String(" secret URI")
        )
    var after_scheme = _substr_from(s, len(scheme.as_bytes()))
    # --- 2. Split host from path at the first '/'. ---
    var slash = _find(after_scheme, String("/"))
    if slash < 0:
        raise Error(
            String("AzureKeyVaultStore: secret_ref has no path (expected")
            + String(" /secrets/{name}[/{version}])")
        )
    var host = _substr_range(after_scheme, 0, slash)
    var path = _substr_from(after_scheme, slash)
    # --- 3. The host: the token goes there, so the label before the suffix must
    #        be a plain DNS label (letters, digits, '-'), which keeps `user@`,
    #        ports, '#', '?' and '\\' out. ---
    var plain = _ends_with(host, AZURE_KV_DNS_SUFFIX)
    if plain:
        var label = String(
            host[byte=0 : host.byte_length() - AZURE_KV_DNS_SUFFIX.byte_length()]
        )
        plain = _is_dns_label(label)
    if not plain:
        raise Error(
            String("AzureKeyVaultStore: secret_ref host is not a plain ")
            + String("*")
            + AZURE_KV_DNS_SUFFIX
            + String(" name")
        )
    # --- 4. The path: /secrets/{name}[/{version}], each segment in Key Vault's
    #        grammar. ---
    var parts = List[String]()
    for piece in path.split("/"):
        parts.append(String(piece))
    var ok = (
        (len(parts) == 3 or len(parts) == 4)
        and parts[0] == ""
        and parts[1] == "secrets"
        and _segment_ok(parts[2], 127)
    )
    if ok and len(parts) == 4:
        ok = _segment_ok(parts[3], 64)
    if not ok:
        raise Error(
            String("AzureKeyVaultStore: secret_ref path is not")
            + String(" /secrets/{name}[/{version}], with each segment 1 to the")
            + String(" Key Vault limit of letters, digits and '-'")
        )
    return KeyVaultRef(host^, path^)


def _segment_ok(s: String, max_len: Int) -> Bool:
    """1 to `max_len` bytes of letters, digits and '-'."""
    var n = s.byte_length()
    if n < 1 or n > max_len:
        return False
    return _is_dns_label(s)


def build_kv_request(
    var dial_host: String, var path: String, var token: String
) raises -> ClientRequest[EmptyBody]:
    """The exact request `resolve` sends: `GET {path}?api-version=7.4` to
    `dial_host` with `Authorization: Bearer <token>` and `Accept:
    application/json`. Factored out so a test reads the bytes `resolve` puts on
    the wire (`request_bytes`) without a socket. `path` must come from
    `parse_key_vault_ref`."""
    var url = Url.https(dial_host^, AZURE_KV_PORT, path^)
    # The mandatory api-version query parameter (a bare GET 400s).
    url.query = String("api-version=") + AZURE_KV_API_VERSION
    var headers = build_kv_request_headers(token^)
    return build_request_with_body[EmptyBody](
        HttpMethod(code=HTTP_METHOD_GET),
        url^,
        headers^,
        EmptyBody.new(),
    )


def build_kv_request_headers(var token: String) raises -> HeaderMap:
    """Build the request headers for the Key Vault GET: the `Authorization:
    Bearer <token>` runtime-identity auth + `Accept: application/json`. Takes
    `token` BY VALUE (moved in) so the caller keeps no lingering copy — the only
    copy ends up on the returned `HeaderMap`'s bytes. Factored out so the
    auth-header stamping is unit-testable WITHOUT a live wire round-trip — a test
    asserts the Bearer header off the returned `HeaderMap` (the 'the auth path
    sends a Bearer header' gate). Pure — no network."""
    var headers = HeaderMap()
    headers.append(String("Authorization"), String("Bearer ") + token^)
    headers.append(String("Accept"), String("application/json"))
    return headers^


# =============================================================================
# §1 — AzureKeyVaultStore[C, T] — the SecretStore conformer.
# =============================================================================
struct AzureKeyVaultStore[C: Connector, T: AzureTokenSource](
    SecretStore, Movable, Deinitable
):
    """The Azure Key Vault `SecretStore` conformer.
    `resolve(secret_ref)` GETs
    `https://{vault}.vault.azure.net/secrets/{name}[/{version}]?api-version=7.4`
    with the runtime-identity AAD `Bearer` token, extracts the `value` field
    (the plaintext directly — NOT base64), and lands the bytes in a zeroizing
    `SecretValue`. A non-200 status RAISES (fail fast and loud). Parametric over
    the HTTP connector `C` (TLS against a real vault, scripted in test) + the token
    source `T` (live service principal or managed identity, static in test).

    Fields are a `def () thin -> C` fn-ptr (a code pointer, no heap), the
    moved-in token source `T` and an optional dial host. No wildcard-origin
    field, no UnsafePointer field; no secret is ever a struct field (the
    resolved value is built in the frame and returned)."""

    # The connector factory — a `thin` (non-raising, non-capturing) fn-ptr.
    # Production binds a TLS-connector factory; a test binds a
    # `ScriptedConnector`-producing factory.
    var _mk_connector: def () thin -> Self.C
    # The AAD token source (moved in). Owns the live SP/IMDS provider or
    # the canned token (test).
    var _token_source: Self.T
    # An OPTIONAL dial-host override (empty in production). The `secret_ref` host
    # is the LOGICAL vault identity (it drives the URL path + the request the
    # service authorizes); the DIAL endpoint is normally that same host. A test
    # (or a private-endpoint / proxy deployment) can point the dial at a different
    # host — e.g. `127.0.0.1` (the loopback FAST PATH, ZERO DNS) for a hermetic
    # ScriptedConnector round-trip — WITHOUT changing the logical ref. This is the
    # same test-injection seam komira_azure_core's providers expose
    # (`with_login_endpoint` / `with_endpoint`). When empty, the dial host is the
    # ref's vault host (the production path). A non-secret config String.
    var _dial_host_override: String

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        var token_source: Self.T,
    ):
        """Construct with the connector factory + the (moved-in) token source. The
        dial host is the ref's vault host (the production path)."""
        self._mk_connector = mk_connector
        self._token_source = token_source^
        self._dial_host_override = String("")

    @staticmethod
    def with_dial_host(
        mk_connector: def () thin -> Self.C,
        var token_source: Self.T,
        dial_host: String,
    ) -> AzureKeyVaultStore[Self.C, Self.T]:
        """Construct with an explicit dial-host override (test injection /
        private-endpoint deployments). The `secret_ref` host stays the logical
        vault identity; only the TCP dial target changes — e.g. `127.0.0.1` for a
        hermetic ScriptedConnector round-trip with ZERO DNS."""
        var store = AzureKeyVaultStore[Self.C, Self.T](
            mk_connector, token_source^
        )
        store._dial_host_override = dial_host
        return store^

    def build_request(mut self, secret_ref: String) raises -> ClientRequest[EmptyBody]:
        """The request `resolve(secret_ref)` sends, without sending it: parse
        and validate the handle up-front (a refusal builds nothing and mints no
        token), mint the runtime-identity token (the auth seam), and build the
        GET with `build_kv_request`. The DIAL host is the handle's vault host in
        production; a test or private endpoint overrides it (`with_dial_host`)
        while the logical handle and path stay the real vault identity. `resolve`
        calls this, so a test that reads the bytes sees what `resolve` sends."""
        var kv = parse_key_vault_ref(secret_ref)
        var token = self._token_source.access_token()
        var dial_host = kv.host.copy()
        if self._dial_host_override.byte_length() > 0:
            dial_host = self._dial_host_override.copy()
        # MOVE the token into the request builder (no lingering local copy on
        # this frame): the only copy lives on the request's header bytes.
        return build_kv_request(dial_host^, kv.path.copy(), token^)

    # -------------------------------------------------------------------------
    # The SecretStore trait method — handle in, zeroizing value out.
    # -------------------------------------------------------------------------
    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        """Resolve `secret_ref` (a Key Vault secret URI
        `https://{vault}.vault.azure.net/secrets/{name}[/{version}]`) to its
        value by GETting the Key Vault data plane with the runtime-identity AAD
        Bearer token. A non-200 status (404 missing / 403 denied / any other)
        RAISES (fail fast and loud — never a silent stale / empty value). A
        malformed ref RAISES up-front. The `value` field is the plaintext; it
        lands directly in a zeroizing `SecretValue`, and every transient that
        held it is WIPED before return. The error NEVER carries the secret body
        or the Bearer token."""
        # --- 1-3. Parse the handle, mint the token, build the request. ---
        var req = self.build_request(secret_ref)

        # --- 4. Dial a fresh connector + drive one synchronous GET. ---
        var connector = self._mk_connector()
        var client = HttpClient[Self.C].with_defaults(connector^)
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            req^, reactor
        )
        var status = Int(cr.status)
        var resp_bytes = cr.body.take_bytes()

        # --- 5. Map a non-200 to a clear RAISE (fail fast and loud). ---
        # The error NEVER includes the response body (it might echo the secret
        # ref but must never carry a value); only the status + ref name.
        if status != 200:
            # Wipe the body buffer before raising — a 200-with-secret never
            # reaches here, but a body may carry sensitive detail; keep nothing.
            _wipe_list(resp_bytes)
            raise Error(
                String("AzureKeyVaultStore: resolve of secret_ref '")
                + secret_ref
                + String("' failed: HTTP ")
                + String(status)
                + _status_hint(status)
            )

        # --- 6. Extract the `value` field (plaintext) from the JSON envelope,
        #        as bytes: a UTF-8 value stays UTF-8 and nothing is re-encoded. -
        var value_bytes = _extract_value(Span(resp_bytes))
        if len(value_bytes) == 0:
            # A 200 with no (or empty, or malformed) value is a protocol
            # surprise we never paper over with an empty SecretValue.
            _wipe_list(value_bytes)
            _wipe_list(resp_bytes)
            raise Error(
                String("AzureKeyVaultStore: resolve of secret_ref '")
                + secret_ref
                + String("' returned 200 with no usable 'value' field")
            )

        # --- 7. Land the plaintext bytes in SecretValue (NO base64 decode:
        # Key Vault returns the plaintext in `value`). ---
        var value: SecretValue
        try:
            value = SecretValue(Span(value_bytes))
        except e:
            _wipe_list(value_bytes)
            _wipe_list(resp_bytes)
            raise Error(
                String("AzureKeyVaultStore: resolve of secret_ref '")
                + secret_ref
                + String("' failed: ")
                + String(e)
            )

        # --- 8. Wipe every transient that held plaintext, then return. The
        # SecretValue has its own zeroizing copy. ---
        _wipe_list(value_bytes)
        _wipe_list(resp_bytes)
        return value^


# =============================================================================
# §2 — JSON envelope extraction: the top-level `value` out of the KV response.
#
# The Key Vault GET-secret response is a small, fixed-shape JSON envelope:
#   {"value":"<plaintext>","id":"https://.../secrets/name/ver",
#    "attributes":{...},"tags":{...}}
# One field is needed (`value`, the plaintext string), so this is a targeted
# scanner over the bytes: find the `"value"` key, read the quoted string, and
# decode the JSON string escapes (the plaintext can contain `"`, `\\`, control
# characters and, as `\uXXXX`, any character the service chose to escape,
# surrogate pairs included). Bytes outside escapes are copied as they are, so a
# UTF-8 value stays UTF-8. An absent key, an unterminated string, an escape this
# scanner does not know and a bad `\u` all yield an empty list, which the caller
# turns into a raise: a value is never returned half-decoded.
# =============================================================================
def _hex_val(b: UInt8) -> Int:
    """The value of hex digit `b`, or -1."""
    if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
        return Int(b) - ord("0")
    if b >= UInt8(ord("a")) and b <= UInt8(ord("f")):
        return Int(b) - ord("a") + 10
    if b >= UInt8(ord("A")) and b <= UInt8(ord("F")):
        return Int(b) - ord("A") + 10
    return -1


def _read_hex4(body: Span[UInt8, _], at: Int) -> Int:
    """The code unit `XXXX` at `body[at:at+4]`, or -1 if it is short or not hex."""
    if at + 4 > len(body):
        return -1
    var v = 0
    for k in range(4):
        var h = _hex_val(body[at + k])
        if h < 0:
            return -1
        v = v * 16 + h
    return v


def _append_utf8(mut out: List[UInt8], cp: Int):
    """Append the UTF-8 encoding of code point `cp` (<= 0x10FFFF, not a
    surrogate)."""
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _skip_ws(body: Span[UInt8, _], at: Int) -> Int:
    var i = at
    while i < len(body) and (
        body[i] == UInt8(ord(" "))
        or body[i] == UInt8(ord("\t"))
        or body[i] == UInt8(ord("\n"))
        or body[i] == UInt8(ord("\r"))
    ):
        i += 1
    return i


def _skip_string(body: Span[UInt8, _], at: Int) -> Int:
    """The index just past the closing quote of the string whose body starts at
    `at` (just after its opening quote), or -1 if it is unterminated. A
    backslash skips the byte after it."""
    var i = at
    var n = len(body)
    while i < n:
        if body[i] == UInt8(ord("\\")):
            i += 2
            continue
        if body[i] == UInt8(ord('"')):
            return i + 1
        i += 1
    return -1


def _skip_value(body: Span[UInt8, _], at: Int) -> Int:
    """The index just past the JSON value starting at `at` (a string, an object
    or array with nesting, or a bare number / literal), or -1 when it is
    malformed or unterminated. Only the extent is found; the content is not
    validated."""
    var n = len(body)
    if at >= n:
        return -1
    var c = body[at]
    if c == UInt8(ord('"')):
        return _skip_string(body, at + 1)
    if c == UInt8(ord("{")) or c == UInt8(ord("[")):
        var depth = 0
        var i = at
        while i < n:
            var b = body[i]
            if b == UInt8(ord('"')):
                i = _skip_string(body, i + 1)
                if i < 0:
                    return -1
                continue
            if b == UInt8(ord("{")) or b == UInt8(ord("[")):
                depth += 1
            elif b == UInt8(ord("}")) or b == UInt8(ord("]")):
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        return -1
    var i = at
    while i < n and not (
        body[i] == UInt8(ord(","))
        or body[i] == UInt8(ord("}"))
        or body[i] == UInt8(ord("]"))
        or body[i] == UInt8(ord(" "))
        or body[i] == UInt8(ord("\t"))
        or body[i] == UInt8(ord("\n"))
        or body[i] == UInt8(ord("\r"))
    ):
        i += 1
    if i == at:
        return -1
    return i


def _extract_value(body: Span[UInt8, _]) -> List[UInt8]:
    """The decoded `value` string of the Key Vault GET-secret envelope as
    bytes, or an empty list when it is absent, empty, not a string or the
    document is malformed (the caller raises). `value` is read as a key of the
    TOP-LEVEL object only: nested objects, arrays and other strings are skipped
    as a whole, so a `"value"` inside `tags` or inside another string can never
    be taken for it. The first top-level `value` wins."""
    var empty = List[UInt8]()
    var n = len(body)
    var i = _skip_ws(body, 0)
    if i >= n or body[i] != UInt8(ord("{")):
        return empty^
    i += 1
    while True:
        i = _skip_ws(body, i)
        if i >= n or body[i] != UInt8(ord('"')):
            return empty^  # no key: `}` (no value), or malformed
        var key_start = i + 1
        var after_key = _skip_string(body, key_start)
        if after_key < 0:
            return empty^
        var key_end = after_key - 1
        i = _skip_ws(body, after_key)
        if i >= n or body[i] != UInt8(ord(":")):
            return empty^
        i = _skip_ws(body, i + 1)
        var is_value = (
            key_end - key_start == 5
            and body[key_start] == UInt8(ord("v"))
            and body[key_start + 1] == UInt8(ord("a"))
            and body[key_start + 2] == UInt8(ord("l"))
            and body[key_start + 3] == UInt8(ord("u"))
            and body[key_start + 4] == UInt8(ord("e"))
        )
        if is_value:
            if i >= n or body[i] != UInt8(ord('"')):
                return empty^
            return _decode_string(body, i + 1)
        i = _skip_value(body, i)
        if i < 0:
            return empty^
        i = _skip_ws(body, i)
        if i < n and body[i] == UInt8(ord(",")):
            i += 1
            continue
        return empty^  # `}` with no `value`, or malformed


def _decode_string(body: Span[UInt8, _], at: Int) -> List[UInt8]:
    """Decode the JSON string whose body starts at `at` (just past its opening
    quote) to bytes, or an empty list when it is unterminated or holds an escape
    that cannot be decoded."""
    var out = List[UInt8]()
    var n = len(body)
    var i = at
    while i < n:
        var b = body[i]
        if b == UInt8(ord('"')):
            return out^  # the closing quote
        if b != UInt8(ord("\\")):
            out.append(b)
            i += 1
            continue
        # An escape: needs at least one more byte.
        if i + 1 >= n:
            break
        var esc = body[i + 1]
        i += 2
        if esc == UInt8(ord('"')) or esc == UInt8(ord("\\")) or esc == UInt8(ord("/")):
            out.append(esc)
        elif esc == UInt8(ord("n")):
            out.append(UInt8(0x0A))
        elif esc == UInt8(ord("t")):
            out.append(UInt8(0x09))
        elif esc == UInt8(ord("r")):
            out.append(UInt8(0x0D))
        elif esc == UInt8(ord("b")):
            out.append(UInt8(0x08))
        elif esc == UInt8(ord("f")):
            out.append(UInt8(0x0C))
        elif esc == UInt8(ord("u")):
            var cu = _read_hex4(body, i)
            if cu < 0:
                break
            i += 4
            if cu >= 0xD800 and cu <= 0xDBFF:
                # A high surrogate must be followed by `\uDC00..\uDFFF`.
                if (
                    i + 6 > n
                    or body[i] != UInt8(ord("\\"))
                    or body[i + 1] != UInt8(ord("u"))
                ):
                    break
                var lo = _read_hex4(body, i + 2)
                if lo < 0xDC00 or lo > 0xDFFF:
                    break
                i += 6
                _append_utf8(out, 0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00))
            elif cu >= 0xDC00 and cu <= 0xDFFF:
                break  # a lone low surrogate
            else:
                _append_utf8(out, cu)
        else:
            break  # an escape JSON does not define
    # Unterminated string, or an escape that could not be decoded.
    _wipe_list(out)
    return List[UInt8]()


# =============================================================================
# §3 — tiny String helpers (no external string-util dep needed for these).
# =============================================================================
def _find(haystack: String, needle: String) -> Int:
    """Index of the first occurrence of `needle` (not empty, not longer than
    `haystack`) in `haystack`, or -1."""
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    var last = len(hb) - len(nb)
    for s in range(0, last + 1):
        var ok = True
        for j in range(len(nb)):
            if hb[s + j] != nb[j]:
                ok = False
                break
        if ok:
            return s
    return -1


def _is_dns_label(s: String) -> Bool:
    """True iff `s` is one or more of letters, digits and '-'."""
    var sb = s.as_bytes()
    if len(sb) == 0:
        return False
    for i in range(len(sb)):
        var c = sb[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("-"))
        )
        if not ok:
            return False
    return True


def _starts_with(s: String, prefix: String) -> Bool:
    """True iff `s` begins with `prefix`."""
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def _ends_with(s: String, suffix: String) -> Bool:
    """True iff `s` ends with `suffix`."""
    var sb = s.as_bytes()
    var fb = suffix.as_bytes()
    if len(fb) > len(sb):
        return False
    var off = len(sb) - len(fb)
    for i in range(len(fb)):
        if sb[off + i] != fb[i]:
            return False
    return True


def _substr_from(s: String, start: Int) -> String:
    """The substring of `s` from byte index `start` to the end. `start` is
    always just after an ASCII delimiter, so it is a UTF-8 boundary."""
    return String(s[byte=start : s.byte_length()])


def _substr_range(s: String, start: Int, end: Int) -> String:
    """The substring of `s` over [start, end) (byte indices at ASCII
    delimiters, so UTF-8 boundaries)."""
    return String(s[byte=start : end])


def _status_hint(status: Int) -> StaticString:
    """A short, NON-secret hint for the common Key Vault error statuses — aids
    the operator without echoing the response body."""
    if status == 404:
        return " (SecretNotFound — the secret does not exist in the vault)"
    if status == 403:
        return (
            " (Forbidden — the runtime identity lacks 'get' on this secret, or"
            " the vault firewall blocked the request)"
        )
    if status == 401:
        return (
            " (Unauthorized — the AAD token was rejected; check the audience is"
            " https://vault.azure.net)"
        )
    return ""


def _wipe_list(mut buf: List[UInt8]):
    """Best-effort overwrite-then-clear of a transient `List[UInt8]` that held
    secret bytes. This is defense-in-depth: the
    AUTHORITATIVE wipe is the `SecretValue` (InlineArray + the -O3-surviving FFI
    `zeroize_inline_array`); these transients hold the bytes for only the few
    instructions between extract and the `SecretValue` copy. We overwrite each
    byte then clear (drop the heap buffer). (A plain loop may be DCE-eligible at
    -O3, which is why the load-bearing secure wipe lives on the InlineArray-backed
    value, not here.)"""
    for i in range(len(buf)):
        buf[i] = UInt8(0)
    buf.clear()
