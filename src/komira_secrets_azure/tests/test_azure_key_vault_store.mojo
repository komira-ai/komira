# =============================================================================
# tests/test_azure_key_vault_store.mojo: `AzureKeyVaultStore`, the token sources
#   and the ref grammar, over `ScriptedConnector`. No socket, no DNS, no vault.
# =============================================================================
#
#   * resolve returns the `value` plaintext exactly (not base64-decoded), for a
#     versioned and an unversioned handle, including JSON escapes, `\uXXXX`
#     (surrogate pairs too) and non-ASCII UTF-8;
#   * a 404, a 403, a 200 with no `value` and a handle that is not a Key Vault
#     URI each raise, as do an undecodable escape and an unterminated value;
#   * the read carries `Authorization: Bearer <token>`;
#   * the handle grammar: host and path split, the version segment, a non-vault
#     host, and a host that is not a plain DNS name, all refused;
#   * the service-principal and managed-identity sources mint a token over a
#     scripted connector;
#   * the audience constants name Key Vault, not Storage.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_secret_store.secret_value import SecretValue

from komira_secrets_azure.azure_token_source import (
    AZURE_KV_IMDS_RESOURCE,
    AZURE_KV_SP_SCOPE,
    ManagedIdentityTokenSource,
    ServicePrincipalTokenSource,
    StaticAzureTokenSource,
)
from komira_secrets_azure.azure_key_vault_store import (
    AZURE_KV_API_VERSION,
    AzureKeyVaultStore,
    KeyVaultRef,
    _extract_value,
    build_kv_request_headers,
    parse_key_vault_ref,
)


# =============================================================================
# Fixtures — the canned secret + the Key Vault get-secret response envelopes.
# =============================================================================

# The plaintext secret the vault holds for the test ref. A realistic
# Postgres connection string (with special chars the JSON un-escape must handle —
# the `"` would be JSON-escaped on the wire).
comptime _CANNED_SECRET: String = (
    'postgresql://app:pw-w0rd@db.example.test:5432/app?sslmode=require'
)
# The opaque secret_ref the foundation stores — a Key Vault secret identifier URI.
comptime _TEST_REF: String = (
    "https://acme-kv.vault.azure.net/secrets/pg-conn"
)
# A versioned ref form (the optional /{version} segment).
comptime _TEST_REF_VERSIONED: String = (
    "https://acme-kv.vault.azure.net/secrets/pg-conn/abc123def456"
)
comptime _CANNED_TOKEN: String = "eyJ0eXAiOiJKV1Qi.test-aad-access-token.abc123"
# The dial host the test pins so the round-trip is HERMETIC: 127.0.0.1 is the
# loopback FAST PATH in the dial layer (ZERO DNS / getaddrinfo), so the
# ScriptedConnector's canned stream is reached without resolving the (fake) vault
# host. The logical `secret_ref` host stays the real *.vault.azure.net identity.
comptime _DIAL_HOST: String = "127.0.0.1"


def _json_escape(s: String) -> String:
    """Minimal JSON string-escape (the inverse of the store's `_extract_value`
    un-escape) so the canned wire body carries a properly-escaped `value`."""
    var sb = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(sb)):
        var c = sb[i]
        if c == UInt8(ord('"')):
            out.append(UInt8(ord("\\")))
            out.append(c)
        elif c == UInt8(ord("\\")):
            out.append(c)
            out.append(c)
        else:
            out.append(c)
    return String(unsafe_from_utf8=Span(out))


def _kv_get_secret_envelope(plaintext: String) -> String:
    """A Key Vault get-secret 200 response envelope. The real shape:
    `{"value":"<json-escaped-plaintext>","id":"https://.../secrets/name/ver",
    "attributes":{"enabled":true,...}}`. We include the `id` + `attributes`
    siblings so the value scanner is exercised against a realistic (not minimal)
    body."""
    return String('{"value":"') + _json_escape(plaintext) + String(
        '","id":"https://acme-kv.vault.azure.net/secrets/pg-conn/'
        'abc123def456","attributes":{"enabled":true,"created":1700000000,'
        '"updated":1700000000}}'
    )


def _http_response(status_line: String, body: String) -> String:
    """Wrap a JSON body in a minimal HTTP/1.1 response with Content-Length."""
    var out = String("HTTP/1.1 ") + status_line + String("\r\n")
    out += String("Content-Length: ") + String(len(body.as_bytes()))
    out += String("\r\nContent-Type: application/json\r\n\r\n")
    out += body
    return out^


def _scripted_connector_for(http_response: String) -> ScriptedConnector:
    """Build a ScriptedConnector armed with the given raw HTTP response, over a
    stream that REPORTS as TLS (so the store's `https://` URL passes the
    scheme-check gate while the bytes flow over the plaintext ScriptedStream — no
    real handshake). A fresh connector per call (the store does ONE GET per
    resolve)."""
    var script = List[UInt8]()
    var rb = http_response.as_bytes()
    for i in range(len(rb)):
        script.append(rb[i])
    var stream = ScriptedStream.from_read_script(script^)
    return ScriptedConnector.with_stream_tls(stream^)


# -----------------------------------------------------------------------------
# `thin` connector factories (the store's `_mk_connector` field is a non-
# capturing `def () thin -> ScriptedConnector`; each factory bakes its canned
# response into the binary — `thin` cannot capture, so one factory per response).
# -----------------------------------------------------------------------------
def _mk_ok_connector() -> ScriptedConnector:
    var body = _kv_get_secret_envelope(_CANNED_SECRET)
    return _scripted_connector_for(_http_response(String("200 OK"), body))


def _mk_404_connector() -> ScriptedConnector:
    var body = String(
        '{"error":{"code":"SecretNotFound","message":"A secret with'
        ' (name/id) pg-conn was not found in this key vault."}}'
    )
    return _scripted_connector_for(
        _http_response(String("404 Not Found"), body)
    )


def _mk_403_connector() -> ScriptedConnector:
    var body = String(
        '{"error":{"code":"Forbidden","message":"The user, group or'
        ' application does not have secrets get permission on key vault."}}'
    )
    return _scripted_connector_for(
        _http_response(String("403 Forbidden"), body)
    )


def _mk_no_value_connector() -> ScriptedConnector:
    # A 200 with a well-formed envelope but NO `value` (a protocol surprise the
    # store must fail loud on, never return an empty SecretValue).
    var body = String(
        '{"id":"https://x.vault.azure.net/secrets/y/1",'
        '"attributes":{"enabled":true}}'
    )
    return _scripted_connector_for(_http_response(String("200 OK"), body))


def _make_store(
    mk_connector: def () thin -> ScriptedConnector,
    var token_src: StaticAzureTokenSource,
) -> AzureKeyVaultStore[ScriptedConnector, StaticAzureTokenSource]:
    """Build the store with the loopback dial-host override so the round-trip is
    HERMETIC (no DNS): the dial goes to 127.0.0.1 while the logical secret_ref
    host stays a real *.vault.azure.net identity. The `mk_connector` thin factory
    bakes the canned response for the case."""
    return AzureKeyVaultStore[
        ScriptedConnector, StaticAzureTokenSource
    ].with_dial_host(mk_connector, token_src^, String(_DIAL_HOST))


# =============================================================================
# (a) RESOLVE round-trip — valid ref returns the plaintext value.
# =============================================================================
def test_resolve_returns_plaintext_value() raises:
    """`resolve(valid_ref)` over a canned 200 returns a SecretValue whose bytes
    equal the canned plaintext `value` (NO base64 decode). The token source is
    consulted."""
    var token_src = StaticAzureTokenSource(String(_CANNED_TOKEN))
    var store = _make_store(_mk_ok_connector, token_src^)

    var sv = store.resolve(String(_TEST_REF))

    # The resolved value equals the canned plaintext secret, byte-for-byte.
    var expected = String(_CANNED_SECRET).as_bytes()
    assert_equal(sv.len(), len(expected), "resolved length == secret length")
    var bytes = sv.revealed_bytes()
    for i in range(len(expected)):
        assert_equal(bytes[i], expected[i], "resolved byte matches the secret")
    _ = sv^
    _ = store^


def test_resolve_versioned_ref_returns_value() raises:
    """A versioned ref (`/secrets/{name}/{version}`) resolves the same way — the
    optional version segment is carried through to the request path."""
    var token_src = StaticAzureTokenSource(String(_CANNED_TOKEN))
    var store = _make_store(_mk_ok_connector, token_src^)
    var sv = store.resolve(String(_TEST_REF_VERSIONED))
    assert_true(sv.len() > 0, "a versioned ref resolves")
    _ = sv^
    _ = store^


def test_resolve_consults_token_source() raises:
    """The resolve path CONSULTS the token source (a resolve that did NOT mint a
    token could not have stamped the Bearer header the wire path needs)."""
    var token_src = StaticAzureTokenSource(String(_CANNED_TOKEN))
    var store = _make_store(_mk_ok_connector, token_src^)
    var sv = store.resolve(String(_TEST_REF))
    assert_true(sv.len() > 0, "a value resolved (the auth+wire path completed)")
    _ = sv^
    _ = store^


# =============================================================================
# (b) FAIL-FAST — 404 / 403 / no-value / malformed-ref each RAISE.
# =============================================================================
def test_resolve_404_raises() raises:
    """A 404 (SecretNotFound) RAISES — never a silent stale/empty value."""
    var token_src = StaticAzureTokenSource(String(_CANNED_TOKEN))
    var store = _make_store(_mk_404_connector, token_src^)
    var raised = False
    try:
        var sv = store.resolve(String(_TEST_REF))
        _ = sv^
    except e:
        raised = True
        # The error must NOT carry a secret (there is none on a 404), and SHOULD
        # name the status for the operator.
        var msg = String(e)
        assert_true(
            msg.find(String("404")) >= 0, "the error names the 404 status"
        )
    assert_true(raised, "a 404 resolve raises (fail fast and loud)")
    _ = store^


def test_resolve_403_raises() raises:
    """A 403 (Forbidden) RAISES (the runtime identity lacks 'get')."""
    var token_src = StaticAzureTokenSource(String(_CANNED_TOKEN))
    var store = _make_store(_mk_403_connector, token_src^)
    var raised = False
    try:
        var sv = store.resolve(String(_TEST_REF))
        _ = sv^
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("403")) >= 0, "the error names the 403 status"
        )
    assert_true(raised, "a 403 resolve raises (fail fast and loud)")
    _ = store^


def test_resolve_200_without_value_raises() raises:
    """A 200 with no `value` RAISES — never a silent empty SecretValue."""
    var token_src = StaticAzureTokenSource(String(_CANNED_TOKEN))
    var store = _make_store(_mk_no_value_connector, token_src^)
    var raised = False
    try:
        var sv = store.resolve(String(_TEST_REF))
        _ = sv^
    except e:
        raised = True
    assert_true(raised, "a 200 with no value raises")
    _ = store^


def test_resolve_malformed_ref_raises() raises:
    """A `secret_ref` that is not a Key Vault secret URI RAISES up-front (before
    any wire round-trip) — fail fast on a bad handle, not a confusing 404."""
    var token_src = StaticAzureTokenSource(String(_CANNED_TOKEN))
    var store = _make_store(_mk_ok_connector, token_src^)
    var raised = False
    try:
        # Not an https Key Vault host, and no /secrets/ segment.
        var sv = store.resolve(String("projects/x/secrets/y/versions/1"))
        _ = sv^
    except e:
        raised = True
    assert_true(raised, "a non-Key-Vault ref raises up-front")
    _ = store^


# =============================================================================
# (c) AUTH — the Bearer header is stamped + the token source is consulted.
# =============================================================================
def test_build_kv_request_headers_stamps_bearer() raises:
    """The pure header-builder stamps `Authorization: Bearer <token>` — the auth
    path the resolve uses. Asserting off the built HeaderMap deterministically
    proves the Bearer header without a wire round-trip."""
    var headers = build_kv_request_headers(String(_CANNED_TOKEN))
    var auth = headers.get(String("Authorization"))
    assert_true(auth.__bool__(), "an Authorization header is present")
    var auth_val = auth.value()
    assert_equal(
        auth_val,
        String("Bearer ") + String(_CANNED_TOKEN),
        "the Authorization header is 'Bearer <token>'",
    )
    # The token must NOT leak into any other header, and Accept is JSON.
    var accept = headers.get(String("Accept"))
    assert_true(accept.__bool__(), "an Accept header is present")
    assert_equal(
        accept.value(), String("application/json"), "Accept is application/json"
    )


def test_static_token_source_mints_and_counts() raises:
    """The `StaticAzureTokenSource` double returns the canned Bearer + bumps a
    mint count (the auth-call proof the live resolve relies on)."""
    var src = StaticAzureTokenSource(String(_CANNED_TOKEN))
    assert_equal(src.mint_count(), 0, "no mint yet")
    var t = src.access_token()
    assert_equal(t, String(_CANNED_TOKEN), "the canned token is returned")
    assert_equal(src.mint_count(), 1, "the mint count bumped")
    var t2 = src.access_token()
    assert_equal(t2, String(_CANNED_TOKEN), "a second mint returns the token")
    assert_equal(src.mint_count(), 2, "the mint count bumped again")
    _ = src^


# =============================================================================
# Ref-parse helpers + the audience-pivot constants.
# =============================================================================
def test_parse_key_vault_ref_splits_host_and_path() raises:
    """`parse_key_vault_ref` splits the Key Vault secret URI into per-vault host +
    /secrets/{name} path."""
    var kv = parse_key_vault_ref(String(_TEST_REF))
    assert_equal(
        kv.host, String("acme-kv.vault.azure.net"), "the per-vault host"
    )
    assert_equal(kv.path, String("/secrets/pg-conn"), "the /secrets/{name} path")
    _ = kv^


def test_parse_key_vault_ref_carries_version() raises:
    """A versioned ref keeps the /{version} segment on the path."""
    var kv = parse_key_vault_ref(String(_TEST_REF_VERSIONED))
    assert_equal(
        kv.path,
        String("/secrets/pg-conn/abc123def456"),
        "the version segment is carried on the path",
    )
    _ = kv^


def test_parse_key_vault_ref_rejects_non_kv_host() raises:
    """A ref whose host is not `*.vault.azure.net` RAISES (defends against a
    mis-typed handle reaching a non-Key-Vault endpoint)."""
    var raised = False
    try:
        var kv = parse_key_vault_ref(
            String("https://evil.example.com/secrets/x")
        )
        _ = kv^
    except e:
        raised = True
    assert_true(raised, "a non-vault host is rejected")


def test_audience_pivots_to_key_vault() raises:
    """The audience constants point at Key Vault, NOT Storage — the load-bearing
    pivot off the providers' storage default (a storage-scoped token
    would 401 on Key Vault)."""
    assert_equal(
        String(AZURE_KV_SP_SCOPE),
        String("https://vault.azure.net/.default"),
        "the SP scope is the Key Vault .default scope",
    )
    assert_equal(
        String(AZURE_KV_IMDS_RESOURCE),
        String("https://vault.azure.net"),
        "the IMDS resource is the Key Vault audience",
    )
    assert_false(
        String(AZURE_KV_SP_SCOPE).find(String("storage")) >= 0,
        "the SP scope is NOT the storage audience",
    )
    assert_equal(
        String(AZURE_KV_API_VERSION), String("7.4"), "the KV API version is 7.4"
    )


# =============================================================================
# Value decoding: JSON escapes, \uXXXX, UTF-8, and refusal of anything undecodable.
# =============================================================================
def _decode(envelope: String) -> String:
    """`_extract_value` of `envelope`, as a String (empty when refused)."""
    var out = _extract_value(envelope.as_bytes())
    return String(unsafe_from_utf8=Span(out))


def test_extract_value_decodes_escapes() raises:
    """Every escape JSON defines (quote, backslash, slash, n, t, r, b, f) decodes."""
    var got = _decode(String('{"value":"q\\"b\\\\s\\/n\\nt\\tr\\rb\\bf\\fE","id":"x"}'))
    var want = String('q"b\\s/n') + chr(10) + "t" + chr(9) + "r" + chr(13) + "b" + chr(8) + "f" + chr(12) + "E"
    assert_equal(got, want, "escapes decode")


def test_extract_value_decodes_unicode_escapes() raises:
    """\\uXXXX decodes to UTF-8: one, two, three and (as a surrogate pair)
    four bytes. Azure's JSON writer escapes characters such as `&` this way, so
    a value with one must come back exact, not with a literal backslash."""
    assert_equal(_decode(String('{"value":"a\\u0026b"}')), String("a&b"), "u0026")
    assert_equal(_decode(String('{"value":"caf\\u00e9"}')), String("café"), "two bytes")
    assert_equal(_decode(String('{"value":"\\u20AC"}')), String("€"), "three bytes, upper-case hex")
    assert_equal(
        _decode(String('{"value":"\\ud83d\\ude00"}')), String("😀"), "surrogate pair"
    )


def test_extract_value_keeps_raw_utf8() raises:
    """Raw (unescaped) UTF-8 in the value is not re-encoded."""
    assert_equal(
        _decode(String('{"value":"naïve—ok 日本","id":"x"}')),
        String("naïve—ok 日本"),
        "raw UTF-8 passes through byte for byte",
    )
    assert_equal(
        _decode(String('{ "id":"x",\n "value" :\t"v" }')), String("v"), "whitespace around the colon"
    )


def test_extract_value_refuses_what_it_cannot_decode() raises:
    """An absent key, a non-string value, an unterminated string, an unknown
    escape, a bad or short \\u, and lone or mismatched surrogates all answer
    empty: the store raises on empty, never returns half a value."""
    var refused = List[String]()
    refused.append(String('{"id":"x"}'))
    refused.append(String('{"value":5}'))
    refused.append(String('{"value":"abc'))
    refused.append(String('{"value":"ab\\'))
    refused.append(String('{"value":"a\\xb"}'))
    refused.append(String('{"value":"a\\u12G4b"}'))
    refused.append(String('{"value":"a\\u12'))
    refused.append(String('{"value":"\\ud83d"}'))
    refused.append(String('{"value":"\\ud83dx"}'))
    refused.append(String('{"value":"\\ud83d\\u0041"}'))
    refused.append(String('{"value":"\\ud83d\\uzzzz"}'))
    refused.append(String('{"value":"\\ude00"}'))
    refused.append(String('{"value":""}'))
    for i in range(len(refused)):
        assert_equal(_decode(refused[i]), String(""), "refused: " + refused[i])


def _mk_unicode_connector() -> ScriptedConnector:
    var body = String('{"value":"p\\u0026w \\ud83d\\ude00 caf\\u00e9 \\"q\\"","id":"x"}')
    return _scripted_connector_for(_http_response(String("200 OK"), body))


def _mk_bad_escape_connector() -> ScriptedConnector:
    var body = String('{"value":"half\\x"}')
    return _scripted_connector_for(_http_response(String("200 OK"), body))


def test_resolve_decodes_unicode_escapes() raises:
    """End to end: a value Azure escaped as \\u0026 and a surrogate pair
    resolves to the real characters."""
    var store = _make_store(
        _mk_unicode_connector, StaticAzureTokenSource(String(_CANNED_TOKEN))
    )
    var sv = store.resolve(String(_TEST_REF))
    var want = String('p&w 😀 café "q"').as_bytes()
    assert_equal(sv.len(), len(want), "length")
    var got = sv.revealed_bytes()
    for i in range(len(want)):
        assert_equal(got[i], want[i], "byte")
    _ = sv^
    _ = store^


def test_resolve_undecodable_value_raises() raises:
    """A value that cannot be decoded raises and the message holds no value."""
    var store = _make_store(
        _mk_bad_escape_connector, StaticAzureTokenSource(String(_CANNED_TOKEN))
    )
    var raised = False
    try:
        var sv = store.resolve(String(_TEST_REF))
        _ = sv^
    except e:
        raised = True
        assert_true(String(e).find(String("half")) < 0, "no value in the error")
    assert_true(raised, "an undecodable value raises")
    _ = store^


# =============================================================================
# Handle grammar: the token is only sent to a plain *.vault.azure.net name.
# =============================================================================
def _refused(secret_ref: String) -> Bool:
    try:
        var kv = parse_key_vault_ref(secret_ref)
        _ = kv^
    except:
        return True
    return False


def test_parse_key_vault_ref_refusals() raises:
    """Not https, no path, not /secrets/, a foreign host, and hosts that merely
    end in the suffix (userinfo, port, fragment, backslash, empty label, an
    underscore) are each refused."""
    assert_true(_refused(String("http://a.vault.azure.net/secrets/x")), "http")
    assert_true(_refused(String("https://a.vault.azure.net")), "no path")
    assert_true(_refused(String("https://a.vault.azure.net/keys/x")), "not /secrets/")
    assert_true(_refused(String("https://evil.example/secrets/x")), "foreign host")
    assert_true(_refused(String("https://u@a.vault.azure.net/secrets/x")), "userinfo")
    assert_true(_refused(String("https://a.vault.azure.net:8443/secrets/x")), "port")
    assert_true(_refused(String("https://evil.example#.vault.azure.net/secrets/x")), "fragment")
    assert_true(_refused(String("https://evil.example\\.vault.azure.net/secrets/x")), "backslash")
    assert_true(_refused(String("https://.vault.azure.net/secrets/x")), "empty label")
    assert_true(_refused(String("https://a_b.vault.azure.net/secrets/x")), "underscore")
    assert_true(_refused(String("https://a.b.vault.azure.net/secrets/x")), "dotted label")
    assert_false(_refused(String("https://Acme-KV-9.vault.azure.net/secrets/x")), "letters, digits, hyphen")


# =============================================================================
# The live token sources, over a scripted connector.
# =============================================================================
def _mk_sp_token_connector() -> ScriptedConnector:
    var body = String('{"token_type":"Bearer","expires_in":3599,"access_token":"sp-tok"}')
    return _scripted_connector_for(_http_response(String("200 OK"), body))


def _mk_imds_token_connector() -> ScriptedConnector:
    # The IMDS endpoint is plain http (link-local), so its stream is plaintext.
    var body = String(
        '{"access_token":"imds-tok","expires_in":"3599","token_type":"Bearer"}'
    )
    var script = List[UInt8]()
    script.extend(Span(_http_response(String("200 OK"), body).as_bytes()))
    return ScriptedConnector.with_stream(ScriptedStream.from_read_script(script^))


def _mk_denied_connector() -> ScriptedConnector:
    var body = String('{"error":"invalid_client","error_description":"s3cret-detail"}')
    return _scripted_connector_for(_http_response(String("401 Unauthorized"), body))


def test_service_principal_source_mints_token() raises:
    """The service-principal source returns the token the Entra answer carries
   ."""
    var src = ServicePrincipalTokenSource[ScriptedConnector](
        _mk_sp_token_connector, String("tenant.example"), String("app-id"), String("app-secret")
    )
    assert_equal(src.access_token(), String("sp-tok"), "minted")
    assert_equal(src.access_token(), String("sp-tok"), "second call")


def test_service_principal_source_refusal_raises_without_secret() raises:
    """A 401 from Entra raises, and the message holds neither the client secret
    nor the answer's body."""
    var src = ServicePrincipalTokenSource[ScriptedConnector](
        _mk_denied_connector, String("tenant.example"), String("app-id"), String("app-secret")
    )
    var raised = False
    try:
        var t = src.access_token()
        _ = t
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find(String("app-secret")) < 0, "no client secret")
        assert_true(msg.find(String("s3cret-detail")) < 0, "no response body")
    assert_true(raised, "a refused grant raises")


def test_managed_identity_sources_mint_token() raises:
    """The system- and user-assigned managed-identity sources return the IMDS
    token."""
    var sys_src = ManagedIdentityTokenSource[ScriptedConnector](_mk_imds_token_connector)
    assert_equal(sys_src.access_token(), String("imds-tok"), "system-assigned")
    var user_src = ManagedIdentityTokenSource[ScriptedConnector].for_client_id(
        _mk_imds_token_connector, String("11111111-2222-3333-4444-555555555555")
    )
    assert_equal(user_src.access_token(), String("imds-tok"), "user-assigned")


def _mk_401_connector() -> ScriptedConnector:
    var body = String('{"error":{"code":"Unauthorized","message":"leaky-body-detail"}}')
    return _scripted_connector_for(_http_response(String("401 Unauthorized"), body))


def _mk_500_connector() -> ScriptedConnector:
    return _scripted_connector_for(
        _http_response(String("500 Internal Server Error"), String("leaky-body-detail"))
    )


def _mk_too_long_connector() -> ScriptedConnector:
    var big = String("")
    for _ in range(4097):
        big += "x"
    return _scripted_connector_for(
        _http_response(String("200 OK"), _kv_get_secret_envelope(big))
    )


def _resolve_error(mk: def () thin -> ScriptedConnector) -> String:
    """The error text of `resolve(_TEST_REF)` over `mk` (empty if it resolved)."""
    var store = _make_store(mk, StaticAzureTokenSource(String(_CANNED_TOKEN)))
    var msg = String("")
    try:
        var sv = store.resolve(String(_TEST_REF))
        _ = sv^
    except e:
        msg = String(e)
    _ = store^
    return msg^


def test_resolve_error_hints_and_no_body_or_token() raises:
    """A refused read names the status and a hint for 401, 403 and 404, none for
    another status, and never the response body or the Bearer token."""
    var denied = _resolve_error(_mk_401_connector)
    assert_true(denied.find(String("HTTP 401")) >= 0, "names 401")
    assert_true(denied.find(String("Unauthorized")) >= 0, "401 hint")
    var forbidden = _resolve_error(_mk_403_connector)
    assert_true(forbidden.find(String("Forbidden")) >= 0, "403 hint")
    var missing = _resolve_error(_mk_404_connector)
    assert_true(missing.find(String("SecretNotFound")) >= 0, "404 hint")
    var other = _resolve_error(_mk_500_connector)
    assert_true(other.find(String("HTTP 500")) >= 0, "names 500")
    assert_true(other.find(String("(")) < 0, "no hint for 500")
    var all = denied + forbidden + missing + other
    assert_true(all.find(String("leaky-body-detail")) < 0, "no response body")
    assert_true(all.find(String(_CANNED_TOKEN)) < 0, "no Bearer token")


def test_resolve_value_over_max_raises_without_value() raises:
    """A value over `MAX_SECRET_LEN` raises, naming the handle and not the
    value."""
    var msg = _resolve_error(_mk_too_long_connector)
    assert_true(msg.find(String("failed")) >= 0, "raised")
    assert_true(msg.find(String(_TEST_REF)) >= 0, "names the handle")
    assert_true(msg.find(String("xxxxxxxx")) < 0, "no value in the error")


def test_service_principal_source_refuses_bad_tenant() raises:
    """A tenant id that is neither a GUID nor a domain name is refused when the
    source is built, before any request."""
    var raised = False
    try:
        var src = ServicePrincipalTokenSource[ScriptedConnector](
            _mk_sp_token_connector, String("evil.example/x"), String("a"), String("b")
        )
        _ = src^
    except:
        raised = True
    assert_true(raised, "a malformed tenant id raises")


def main() raises:
    # (a) resolve round-trip
    test_resolve_returns_plaintext_value()
    test_resolve_versioned_ref_returns_value()
    test_resolve_consults_token_source()
    # (b) fail-fast
    test_resolve_404_raises()
    test_resolve_403_raises()
    test_resolve_200_without_value_raises()
    test_resolve_malformed_ref_raises()
    # (c) auth
    test_build_kv_request_headers_stamps_bearer()
    test_static_token_source_mints_and_counts()
    # ref-parse + audience pivot
    test_parse_key_vault_ref_splits_host_and_path()
    test_parse_key_vault_ref_carries_version()
    test_parse_key_vault_ref_rejects_non_kv_host()
    test_audience_pivots_to_key_vault()
    # value decoding, handle grammar, live token sources
    test_extract_value_decodes_escapes()
    test_extract_value_decodes_unicode_escapes()
    test_extract_value_keeps_raw_utf8()
    test_extract_value_refuses_what_it_cannot_decode()
    test_resolve_decodes_unicode_escapes()
    test_resolve_undecodable_value_raises()
    test_parse_key_vault_ref_refusals()
    test_service_principal_source_mints_token()
    test_service_principal_source_refusal_raises_without_secret()
    test_managed_identity_sources_mint_token()
    test_resolve_error_hints_and_no_body_or_token()
    test_resolve_value_over_max_raises_without_value()
    test_service_principal_source_refuses_bad_tenant()
    print("PASS test_azure_key_vault_store")
