# =============================================================================
# tests/test_conjur_secret_store.mojo: `ConjurSecretStore` and the auth sources
#   over `ScriptedConnector`. No socket, no DNS, no real appliance.
# =============================================================================
#
#   * resolve returns the raw 200 body byte for byte (static and live auth);
#   * the live source POSTs the API key and returns the token verbatim;
#   * a 404, a 401, an empty 200 body and a malformed ref each raise; so does a
#     401 on the authn POST;
#   * the read carries `Authorization: Token token="<token>"` (not Bearer);
#   * the path builders and the ref parser.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_secret_store.secret_value import SecretValue

from komira_secrets_conjur.conjur_auth_source import (
    LiveConjurAuthSource,
    StaticConjurAuthSource,
    authn_path_for,
    build_authn_request_headers,
)
from komira_secrets_conjur.conjur_secret_store import (
    ConjurSecretStore,
    ConjurSecretRef,
    build_read_request_headers,
    parse_conjur_ref,
    read_path_for,
)


# =============================================================================
# Fixtures — the canned secret + the canned Conjur responses.
# =============================================================================

# The plaintext secret Conjur holds for the test ref. A realistic Postgres
# connection string (with special chars the RAW body must round-trip verbatim —
# Conjur returns the secret as the raw response body, so there is NO base64/JSON
# layer to normalize these away).
comptime _CANNED_SECRET: String = (
    "postgresql://app:pw-w0rd@db.example.test:5432/app?sslmode=require"
)
# The opaque secret_ref the foundation stores: `{account}/{variable_id}`. The
# variable_id is a slash-delimited Conjur policy path.
comptime _TEST_REF: String = "myorg/app/db/password"
# A canned Conjur access token (base64 — what the auth seam returns; the live
# source gets this from the authn POST body).
comptime _CANNED_TOKEN: String = (
    "eyJwcm90ZWN0ZWQiOiJld...base64-conjur-access-token...=="
)
# A canned API key (the live-authn mint input).
comptime _CANNED_API_KEY: String = "1bb7zp3w0a8m2r4t6y8u0i2o4p6a8s0d"
# The appliance host the dial sites use. We use the loopback LITERAL `127.0.0.1`
# (NOT a DNS name): the client's dial path takes the IP-literal fast path with
# ZERO getaddrinfo, so the test is fully hermetic — no DNS lookup, no NXDOMAIN
# dependency on a documentation domain. The `ScriptedConnector` ignores the IP
# entirely (its armed stream encodes the canned response), so the literal is a
# pure no-DNS placeholder; production passes the real appliance DNS name.
comptime _APPLIANCE_HOST: String = "127.0.0.1"


def _http_response(status_line: String, body: String) -> String:
    """Wrap a body in a minimal HTTP/1.1 response with Content-Length."""
    var out = String("HTTP/1.1 ") + status_line + String("\r\n")
    out += String("Content-Length: ") + String(len(body.as_bytes()))
    out += String("\r\nContent-Type: text/plain\r\n\r\n")
    out += body
    return out^


def _scripted_connector_for(http_response: String) -> ScriptedConnector:
    """Build a ScriptedConnector armed with the given raw HTTP response, over a
    stream that REPORTS as TLS (so the store's `https://` URL passes the
    scheme-check gate while the bytes flow over the plaintext ScriptedStream —
    no real handshake). A fresh connector per call (the store does ONE GET per
    resolve; the live auth source does ONE POST per mint)."""
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
def _mk_ok_read_connector() -> ScriptedConnector:
    # The RAW body IS the secret — no base64, no JSON envelope (the Conjur shape).
    return _scripted_connector_for(
        _http_response(String("200 OK"), String(_CANNED_SECRET))
    )


def _mk_404_read_connector() -> ScriptedConnector:
    var body = String('{"error":"CONJ00076E Variable not found"}')
    return _scripted_connector_for(
        _http_response(String("404 Not Found"), body)
    )


def _mk_401_read_connector() -> ScriptedConnector:
    var body = String("Unauthorized")
    return _scripted_connector_for(
        _http_response(String("401 Unauthorized"), body)
    )


def _mk_empty_body_connector() -> ScriptedConnector:
    # A 200 with a zero-length body (a protocol surprise the store must fail loud
    # on, never return an empty SecretValue).
    return _scripted_connector_for(
        _http_response(String("200 OK"), String(""))
    )


def _mk_ok_authn_connector() -> ScriptedConnector:
    # The Conjur authn POST returns the base64 access token as the RAW body.
    return _scripted_connector_for(
        _http_response(String("200 OK"), String(_CANNED_TOKEN))
    )


def _mk_401_authn_connector() -> ScriptedConnector:
    var body = String("CONJ00002E Invalid API key")
    return _scripted_connector_for(
        _http_response(String("401 Unauthorized"), body)
    )


# =============================================================================
# (a) AUTHN -> READ HAPPY PATH — valid ref returns the raw body verbatim.
# =============================================================================
def test_resolve_returns_raw_body() raises:
    """`resolve(valid_ref)` over a canned 200 returns a SecretValue whose bytes
    equal the canned secret (the RAW response body), byte-for-byte. The Conjur
    body is the secret directly — no base64-decode, no JSON unwrap."""
    var auth = StaticConjurAuthSource(String(_CANNED_TOKEN))
    var store = ConjurSecretStore[ScriptedConnector, StaticConjurAuthSource](
        _mk_ok_read_connector, auth^, String(_APPLIANCE_HOST)
    )

    var sv = store.resolve(String(_TEST_REF))

    var expected = String(_CANNED_SECRET).as_bytes()
    assert_equal(sv.len(), len(expected), "resolved length == secret length")
    var bytes = sv.revealed_bytes()
    for i in range(len(expected)):
        assert_equal(bytes[i], expected[i], "resolved byte matches the secret")
    _ = sv^
    _ = store^


def test_live_authn_then_read_pairing() raises:
    """The LIVE auth source mints a token via a canned 200 authn POST, and that
    token is used for a canned 200 read — proving the authn->read pairing
    end-to-end over two scripted round-trips (each a fresh single-use
    connector)."""
    # The live auth source drives the authn POST over its OWN connector factory.
    var auth = LiveConjurAuthSource[ScriptedConnector](
        _mk_ok_authn_connector,
        String(_APPLIANCE_HOST),
        UInt16(443),
        String("myorg"),
        String("host%2Fmy-app"),
        String(_CANNED_API_KEY),
    )
    # The store drives the secret READ over a SEPARATE connector factory.
    var store = ConjurSecretStore[
        ScriptedConnector, LiveConjurAuthSource[ScriptedConnector]
    ](_mk_ok_read_connector, auth^, String(_APPLIANCE_HOST))

    var sv = store.resolve(String(_TEST_REF))
    var expected = String(_CANNED_SECRET).as_bytes()
    assert_equal(sv.len(), len(expected), "resolved length == secret length")
    var bytes = sv.revealed_bytes()
    for i in range(len(expected)):
        assert_equal(bytes[i], expected[i], "live-authn resolve byte matches")
    _ = sv^
    _ = store^


def test_live_authn_returns_token_verbatim() raises:
    """The LIVE auth source returns the canned 200 authn-POST body verbatim (the
    base64 access token) — the value the read path stamps into the Conjur
    `Token token="…"` header."""
    var auth = LiveConjurAuthSource[ScriptedConnector](
        _mk_ok_authn_connector,
        String(_APPLIANCE_HOST),
        UInt16(443),
        String("myorg"),
        String("host%2Fmy-app"),
        String(_CANNED_API_KEY),
    )
    var token = auth.access_token()
    assert_equal(
        token, String(_CANNED_TOKEN), "the authn body IS the access token"
    )
    _ = auth^


# =============================================================================
# (b) FAIL-FAST — 404 / 401 / empty-body / malformed-ref each RAISE.
# =============================================================================
def test_resolve_404_raises() raises:
    """A 404 (missing variable) RAISES — never a silent stale/empty value."""
    var auth = StaticConjurAuthSource(String(_CANNED_TOKEN))
    var store = ConjurSecretStore[ScriptedConnector, StaticConjurAuthSource](
        _mk_404_read_connector, auth^, String(_APPLIANCE_HOST)
    )
    var raised = False
    try:
        var sv = store.resolve(String(_TEST_REF))
        _ = sv^
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("404")) >= 0, "the error names the 404 status"
        )
    assert_true(raised, "a 404 resolve raises (fail fast and loud)")
    _ = store^


def test_resolve_401_raises() raises:
    """A 401 (token rejected) RAISES (the access token was not accepted)."""
    var auth = StaticConjurAuthSource(String(_CANNED_TOKEN))
    var store = ConjurSecretStore[ScriptedConnector, StaticConjurAuthSource](
        _mk_401_read_connector, auth^, String(_APPLIANCE_HOST)
    )
    var raised = False
    try:
        var sv = store.resolve(String(_TEST_REF))
        _ = sv^
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("401")) >= 0, "the error names the 401 status"
        )
    assert_true(raised, "a 401 resolve raises (fail fast and loud)")
    _ = store^


def test_resolve_200_empty_body_raises() raises:
    """A 200 with an empty body RAISES — never a silent empty SecretValue."""
    var auth = StaticConjurAuthSource(String(_CANNED_TOKEN))
    var store = ConjurSecretStore[ScriptedConnector, StaticConjurAuthSource](
        _mk_empty_body_connector, auth^, String(_APPLIANCE_HOST)
    )
    var raised = False
    try:
        var sv = store.resolve(String(_TEST_REF))
        _ = sv^
    except e:
        raised = True
    assert_true(raised, "a 200 with an empty body raises")
    _ = store^


def test_resolve_malformed_ref_raises() raises:
    """A secret_ref with no `/` (no variable id) RAISES at parse time — fail fast
    and loud, never a mis-read of the wrong variable."""
    var auth = StaticConjurAuthSource(String(_CANNED_TOKEN))
    var store = ConjurSecretStore[ScriptedConnector, StaticConjurAuthSource](
        _mk_ok_read_connector, auth^, String(_APPLIANCE_HOST)
    )
    var raised = False
    try:
        var sv = store.resolve(String("no-slash-here"))
        _ = sv^
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("malformed")) >= 0,
            "the error names the malformed ref",
        )
    assert_true(raised, "a malformed secret_ref raises")
    _ = store^


def test_live_authn_401_raises() raises:
    """A 401 on the LIVE authn POST (bad API key) RAISES — the resolve path
    cannot fall back to anonymous."""
    var auth = LiveConjurAuthSource[ScriptedConnector](
        _mk_401_authn_connector,
        String(_APPLIANCE_HOST),
        UInt16(443),
        String("myorg"),
        String("host%2Fmy-app"),
        String(_CANNED_API_KEY),
    )
    var raised = False
    try:
        var t = auth.access_token()
        _ = t
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("401")) >= 0, "the authn error names the 401 status"
        )
    assert_true(raised, "a 401 authn POST raises (fail fast and loud)")
    _ = auth^


# =============================================================================
# (c) AUTH — the Conjur `Token token="…"` header is stamped with the minted
#     token + the auth source is consulted.
# =============================================================================
def test_build_read_request_headers_stamps_conjur_token() raises:
    """The pure header-builder stamps `Authorization: Token token="<token>"` —
    the Conjur auth scheme (NOT OAuth2 Bearer). Asserting off the built HeaderMap
    deterministically proves the token is stamped — and carries EXACTLY the value
    the auth source minted — without a wire round-trip."""
    var headers = build_read_request_headers(String(_CANNED_TOKEN))
    var auth = headers.get(String("Authorization"))
    assert_true(auth.__bool__(), "an Authorization header is present")
    var auth_val = auth.value()
    assert_equal(
        auth_val,
        String('Token token="') + String(_CANNED_TOKEN) + String('"'),
        'the Authorization header is the Conjur Token token="..." scheme',
    )
    # It must be the Conjur scheme, NOT OAuth2 Bearer.
    assert_true(
        auth_val.find(String("Bearer")) < 0,
        "the Conjur header is NOT the Bearer scheme",
    )
    # Accept is text/plain (the raw-body read).
    var accept = headers.get(String("Accept"))
    assert_true(accept.__bool__(), "an Accept header is present")
    assert_equal(
        accept.value(), String("text/plain"), "Accept is text/plain"
    )


def test_static_auth_source_mints_and_counts() raises:
    """The `StaticConjurAuthSource` double returns the canned token + bumps a
    mint count (the auth-call proof the live resolve relies on)."""
    var src = StaticConjurAuthSource(String(_CANNED_TOKEN))
    assert_equal(src.mint_count(), 0, "no mint yet")
    var t = src.access_token()
    assert_equal(t, String(_CANNED_TOKEN), "the canned token is returned")
    assert_equal(src.mint_count(), 1, "the mint count bumped")
    var t2 = src.access_token()
    assert_equal(t2, String(_CANNED_TOKEN), "a second mint returns the token")
    assert_equal(src.mint_count(), 2, "the mint count bumped again")
    _ = src^


# =============================================================================
# Pure path/parse helpers — the request shape + the ref decode.
# =============================================================================
def test_read_path_for_builds_variable_path() raises:
    """The read path is `/secrets/{account}/variable/{variable_id}`."""
    var path = read_path_for(String("myorg"), String("app/db/password"))
    assert_equal(
        path,
        String("/secrets/myorg/variable/app/db/password"),
        "the read path is /secrets/{account}/variable/{variable_id}",
    )


def test_authn_path_for_builds_authenticate_path() raises:
    """The authn path is `/authn/{account}/{login}/authenticate`."""
    var path = authn_path_for(String("myorg"), String("host%2Fmy-app"))
    assert_equal(
        path,
        String("/authn/myorg/host%2Fmy-app/authenticate"),
        "the authn path is /authn/{account}/{login}/authenticate",
    )


def test_parse_conjur_ref_splits_account_from_variable() raises:
    """`{account}/{variable_id}` splits on the FIRST `/` only — the variable_id
    keeps its slash-delimited policy path."""
    var r = parse_conjur_ref(String("myorg/app/db/password"))
    assert_equal(r.account, String("myorg"), "account is the first segment")
    assert_equal(
        r.variable_id,
        String("app/db/password"),
        "variable_id keeps its remaining slash path",
    )
    assert_equal(r.appliance_host, String(""), "no host in the bare form")


def test_parse_conjur_ref_extracts_optional_host() raises:
    """The `{host}|{account}/{variable_id}` form extracts the appliance host."""
    var r = parse_conjur_ref(
        String("conjur.eu.example.com|euorg/app/key")
    )
    assert_equal(
        r.appliance_host,
        String("conjur.eu.example.com"),
        "the host prefix is extracted",
    )
    assert_equal(r.account, String("euorg"), "account follows the host bar")
    assert_equal(
        r.variable_id, String("app/key"), "variable_id is the remainder"
    )


def test_parse_conjur_ref_rejects_no_slash() raises:
    """A ref with no `/` (no variable id) RAISES."""
    var raised = False
    try:
        var r = parse_conjur_ref(String("just-an-account"))
        _ = r
    except e:
        raised = True
    assert_true(raised, "a ref with no '/' raises")


# =============================================================================
# More refusals, the status hints, the host-named handle and the token trim.
# =============================================================================
def _mk_403_read_connector() -> ScriptedConnector:
    return _scripted_connector_for(
        _http_response(String("403 Forbidden"), String("leaky-body-detail"))
    )


def _mk_500_read_connector() -> ScriptedConnector:
    return _scripted_connector_for(
        _http_response(String("500 Internal Server Error"), String("leaky-body-detail"))
    )


def _mk_padded_authn_connector() -> ScriptedConnector:
    # Some appliances frame the token with whitespace: "  <token>\r\n".
    return _scripted_connector_for(
        _http_response(String("200 OK"), String("  ") + String(_CANNED_TOKEN) + String("\r\n"))
    )


def _mk_blank_authn_connector() -> ScriptedConnector:
    return _scripted_connector_for(_http_response(String("200 OK"), String(" \t\r\n")))


def _mk_404_authn_connector() -> ScriptedConnector:
    return _scripted_connector_for(
        _http_response(String("404 Not Found"), String("leaky-body-detail"))
    )


def _mk_500_authn_connector() -> ScriptedConnector:
    return _scripted_connector_for(
        _http_response(String("500 Internal Server Error"), String("leaky-body-detail"))
    )


def _store_error(mk: def () thin -> ScriptedConnector) -> String:
    """The error text of `resolve(_TEST_REF)` over `mk` (empty if it resolved)."""
    var auth = StaticConjurAuthSource(String(_CANNED_TOKEN))
    var store = ConjurSecretStore[ScriptedConnector, StaticConjurAuthSource](
        mk, auth^, String(_APPLIANCE_HOST)
    )
    var msg = String("")
    try:
        var sv = store.resolve(String(_TEST_REF))
        _ = sv^
    except e:
        msg = String(e)
    _ = store^
    return msg^


def _live_error(mk: def () thin -> ScriptedConnector) -> String:
    var auth = LiveConjurAuthSource[ScriptedConnector](
        mk,
        String(_APPLIANCE_HOST),
        UInt16(443),
        String("myorg"),
        String("host%2Fmy-app"),
        String(_CANNED_API_KEY),
    )
    var msg = String("")
    try:
        var t = auth.access_token()
        _ = t
    except e:
        msg = String(e)
    _ = auth^
    return msg^


def test_read_error_has_status_hint_and_no_body_or_token() raises:
    """A refused read names the status and a hint for 401, 403 and 404, none for
    another status, and never the response body or the access token."""
    var forbidden = _store_error(_mk_403_read_connector)
    assert_true(forbidden.find(String("HTTP 403")) >= 0, "names 403")
    assert_true(forbidden.find(String("FORBIDDEN")) >= 0, "403 hint")
    var other = _store_error(_mk_500_read_connector)
    assert_true(other.find(String("HTTP 500")) >= 0, "names 500")
    assert_true(other.find(String("(")) < 0, "no hint for 500")
    var missing = _store_error(_mk_404_read_connector)
    assert_true(missing.find(String("NOT_FOUND")) >= 0, "404 hint")
    var denied = _store_error(_mk_401_read_connector)
    assert_true(denied.find(String("UNAUTHENTICATED")) >= 0, "401 hint")
    var all = forbidden + other + missing + denied
    assert_true(all.find(String("leaky-body-detail")) < 0, "no response body")
    assert_true(all.find(String(_CANNED_TOKEN)) < 0, "no access token")
    assert_true(all.find(String("CONJ00076E")) < 0, "no response body (404)")


def test_authn_error_has_status_hint_and_no_body_or_key() raises:
    """A refused authn POST names the status and a hint for 401 and 404, none
    for another status, and never the response body or the API key."""
    var bad_key = _live_error(_mk_401_authn_connector)
    assert_true(bad_key.find(String("HTTP 401")) >= 0, "names 401")
    assert_true(bad_key.find(String("API key was rejected")) >= 0, "401 hint")
    var missing = _live_error(_mk_404_authn_connector)
    assert_true(missing.find(String("HTTP 404")) >= 0, "names 404")
    assert_true(missing.find(String("does not exist")) >= 0, "404 hint")
    var other = _live_error(_mk_500_authn_connector)
    assert_true(other.find(String("HTTP 500")) >= 0, "names 500")
    assert_true(other.find(String("(")) < 0, "no hint for 500")
    var all = bad_key + missing + other
    assert_true(all.find(String(_CANNED_API_KEY)) < 0, "no API key")
    assert_true(all.find(String("leaky-body-detail")) < 0, "no response body")
    assert_true(all.find(String("CONJ00002E")) < 0, "no response body (401)")


def test_live_authn_trims_whitespace_around_token() raises:
    """Whitespace the appliance frames the token with is trimmed; the token
    itself is untouched."""
    var auth = LiveConjurAuthSource[ScriptedConnector](
        _mk_padded_authn_connector,
        String(_APPLIANCE_HOST),
        UInt16(443),
        String("myorg"),
        String("host%2Fmy-app"),
        String(_CANNED_API_KEY),
    )
    assert_equal(auth.access_token(), String(_CANNED_TOKEN), "trimmed")
    _ = auth^


def test_live_authn_blank_token_raises() raises:
    """A 200 whose body is only whitespace raises rather than yielding an empty
    token."""
    var msg = _live_error(_mk_blank_authn_connector)
    assert_true(msg.find(String("empty access-token body")) >= 0, "refused as empty")


def test_build_authn_request_headers_holds_no_key() raises:
    """The authn headers are text/plain both ways and carry no secret (the API
    key is the body)."""
    var headers = build_authn_request_headers()
    assert_equal(headers.get(String("Content-Type")).value(), String("text/plain"), "Content-Type")
    assert_equal(headers.get(String("Accept")).value(), String("text/plain"), "Accept")
    assert_false(headers.get(String("Authorization")).__bool__(), "no Authorization header")


def test_resolve_through_host_named_handle() raises:
    """A `host|account/variable` handle resolves too: the host prefix is parsed
    off and the read still returns the body."""
    var auth = StaticConjurAuthSource(String(_CANNED_TOKEN))
    var store = ConjurSecretStore[ScriptedConnector, StaticConjurAuthSource](
        _mk_ok_read_connector, auth^, String("unused.example")
    )
    var sv = store.resolve(String("127.0.0.1|myorg/app/db/password"))
    assert_equal(sv.len(), len(String(_CANNED_SECRET).as_bytes()), "resolved")
    _ = sv^
    _ = store^


def test_parse_conjur_ref_refuses_empty_parts() raises:
    """An empty variable id, an empty account, and a host with no account each
    raise."""
    var refs = List[String]()
    refs.append(String("myorg/"))
    refs.append(String("/app/db"))
    refs.append(String("host.example|"))
    refs.append(String("host.example|myorg"))
    refs.append(String(""))
    for i in range(len(refs)):
        var raised = False
        try:
            var r = parse_conjur_ref(refs[i])
            _ = r
        except:
            raised = True
        assert_true(raised, "refused: " + refs[i])


def main() raises:
    # (a) authn -> read happy path
    test_resolve_returns_raw_body()
    test_live_authn_then_read_pairing()
    test_live_authn_returns_token_verbatim()
    # (b) fail-fast
    test_resolve_404_raises()
    test_resolve_401_raises()
    test_resolve_200_empty_body_raises()
    test_resolve_malformed_ref_raises()
    test_live_authn_401_raises()
    # (c) auth header stamped + source consulted
    test_build_read_request_headers_stamps_conjur_token()
    test_static_auth_source_mints_and_counts()
    # pure helpers
    test_read_path_for_builds_variable_path()
    test_authn_path_for_builds_authenticate_path()
    test_parse_conjur_ref_splits_account_from_variable()
    test_parse_conjur_ref_extracts_optional_host()
    test_parse_conjur_ref_rejects_no_slash()
    # refusals, hints, host-named handle, token trim
    test_read_error_has_status_hint_and_no_body_or_token()
    test_authn_error_has_status_hint_and_no_body_or_key()
    test_live_authn_trims_whitespace_around_token()
    test_live_authn_blank_token_raises()
    test_build_authn_request_headers_holds_no_key()
    test_resolve_through_host_named_handle()
    test_parse_conjur_ref_refuses_empty_parts()
    print("PASS test_conjur_secret_store")
