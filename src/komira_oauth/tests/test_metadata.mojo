# =============================================================================
# test_metadata.mojo: RFC 8414 authorization server metadata (metadata.mojo):
#   the well-known URL (the RFC's own section 3.1 example), the exact
#   document bytes and their round trip, the issuer compared byte for byte
#   (section 3.3) with a near-miss table, and each member's refusals.
# =============================================================================
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_oauth import (
    OAUTH_METADATA_MAX_BYTES,
    AuthorizationServerMetadata,
    authorization_server_metadata_url,
    parse_authorization_server_metadata,
)


comptime ISS = "https://issuer.example/a"


def _list(*values: String) -> List[String]:
    var out = List[String]()
    for v in values:
        out.append(String(v))
    return out^


def _meta(
    issuer: String = ISS,
    token_endpoint: String = "https://issuer.example/a/token",
    jwks_uri: String = "https://issuer.example/a/jwks",
    grants: List[String] = _list("client_credentials"),
    methods: List[String] = _list("private_key_jwt"),
    algs: List[String] = _list("ES256", "EdDSA"),
) raises -> AuthorizationServerMetadata:
    return AuthorizationServerMetadata(
        issuer=issuer,
        token_endpoint=token_endpoint,
        jwks_uri=jwks_uri,
        grant_types_supported=grants,
        token_endpoint_auth_methods_supported=methods,
        token_endpoint_auth_signing_alg_values_supported=algs,
    )


def _url_refusal(issuer: String) -> String:
    try:
        _ = authorization_server_metadata_url(issuer)
    except e:
        return String(e)
    return String("accepted")


def _meta_refusal(
    issuer: String = ISS,
    token_endpoint: String = "https://issuer.example/a/token",
    jwks_uri: String = "https://issuer.example/a/jwks",
    grants: List[String] = _list("client_credentials"),
    methods: List[String] = _list("private_key_jwt"),
    algs: List[String] = _list("ES256"),
) -> String:
    try:
        _ = _meta(issuer, token_endpoint, jwks_uri, grants, methods, algs)
    except e:
        return String(e)
    return String("accepted")


def _parse_refusal(doc: String, issuer: String = ISS) -> String:
    try:
        _ = parse_authorization_server_metadata(doc, issuer)
    except e:
        return String(e)
    return String("accepted")


comptime DOC: String = (
    '{"issuer":"https://issuer.example/a",'
    '"token_endpoint":"https://issuer.example/a/token",'
    '"jwks_uri":"https://issuer.example/a/jwks",'
    '"grant_types_supported":["client_credentials"],'
    '"token_endpoint_auth_methods_supported":["private_key_jwt"],'
    '"token_endpoint_auth_signing_alg_values_supported":["ES256","EdDSA"]}'
)


def test_well_known_url() raises:
    # RFC 8414 section 3.1's example.
    assert_equal(
        authorization_server_metadata_url("https://example.com/issuer1"),
        "https://example.com/.well-known/oauth-authorization-server/issuer1",
    )
    assert_equal(
        authorization_server_metadata_url("https://issuer.example"),
        "https://issuer.example/.well-known/oauth-authorization-server",
    )
    assert_equal(
        authorization_server_metadata_url("https://issuer.example/"),
        "https://issuer.example/.well-known/oauth-authorization-server",
    )
    assert_equal(
        authorization_server_metadata_url("https://issuer.example/a/b//"),
        "https://issuer.example/.well-known/oauth-authorization-server/a/b",
    )
    assert_equal(
        authorization_server_metadata_url("https://issuer.example:8443/a"),
        "https://issuer.example:8443/.well-known/oauth-authorization-server/a",
    )


def test_url_refusals() raises:
    assert_equal(_url_refusal("http://issuer.example/a"), "OAuthError: the issuer is not an https URL")
    assert_equal(_url_refusal("https:/issuer.example/a"), "OAuthError: the issuer is not an https URL")
    assert_equal(_url_refusal("HTTPS://issuer.example/a"), "OAuthError: the issuer is not an https URL")
    assert_equal(_url_refusal("https:/"), "OAuthError: the issuer is not an https URL")
    assert_equal(_url_refusal(""), "OAuthError: the issuer is not an https URL")
    assert_equal(_url_refusal("xhttps://issuer.example/a"), "OAuthError: the issuer is not an https URL")
    assert_equal(_url_refusal("https://"), "OAuthError: the issuer has no host")
    assert_equal(_url_refusal("https:///a"), "OAuthError: the issuer has no host")
    assert_equal(_url_refusal("https://issuer.example/a?b"), "OAuthError: the issuer has a query")
    assert_equal(_url_refusal("https://issuer.example/a#b"), "OAuthError: the issuer has a fragment")
    var bad_byte = "OAuthError: the issuer holds a byte that is not printable ASCII"
    assert_equal(_url_refusal("https://issuer.example/a b"), bad_byte)
    assert_equal(_url_refusal("https://issuer.example/a\x7f"), bad_byte)
    assert_equal(_url_refusal("https://issuer.example/é"), bad_byte)
    # The printable ends are URL bytes here.
    assert_equal(
        authorization_server_metadata_url("https://issuer.example/!~"),
        "https://issuer.example/.well-known/oauth-authorization-server/!~",
    )


def test_render() raises:
    assert_equal(_meta().render(), DOC)
    var bare = _meta(grants=List[String](), methods=List[String](), algs=List[String]())
    assert_equal(
        bare.render(),
        '{"issuer":"https://issuer.example/a","token_endpoint":"https://issuer.example/a/token","jwks_uri":"https://issuer.example/a/jwks"}',
    )
    var only_grants = _meta(methods=List[String](), algs=List[String]())
    assert_equal(
        only_grants.render(),
        '{"issuer":"https://issuer.example/a","token_endpoint":"https://issuer.example/a/token","jwks_uri":"https://issuer.example/a/jwks","grant_types_supported":["client_credentials"]}',
    )
    var only_algs = _meta(grants=List[String](), methods=List[String]())
    assert_equal(
        only_algs.render(),
        '{"issuer":"https://issuer.example/a","token_endpoint":"https://issuer.example/a/token","jwks_uri":"https://issuer.example/a/jwks","token_endpoint_auth_signing_alg_values_supported":["ES256","EdDSA"]}',
    )


def test_for_client_credentials() raises:
    var m = AuthorizationServerMetadata.for_client_credentials(
        issuer=ISS,
        token_endpoint="https://issuer.example/a/token",
        jwks_uri="https://issuer.example/a/jwks",
        signing_algs=_list("ES256", "EdDSA"),
    )
    assert_equal(m.render(), DOC)
    var msg = String("")
    try:
        _ = AuthorizationServerMetadata.for_client_credentials(
            issuer=ISS,
            token_endpoint="https://issuer.example/a/token",
            jwks_uri="https://issuer.example/a/jwks",
            signing_algs=List[String](),
        )
    except e:
        msg = String(e)
    assert_equal(msg, "OAuthError: private_key_jwt is listed without its signing algorithms")


def test_parse_round_trip() raises:
    var m = parse_authorization_server_metadata(DOC, ISS)
    assert_equal(m.issuer, ISS)
    assert_equal(m.token_endpoint, "https://issuer.example/a/token")
    assert_equal(m.jwks_uri, "https://issuer.example/a/jwks")
    assert_equal(len(m.grant_types_supported), 1)
    assert_equal(m.grant_types_supported[0], "client_credentials")
    assert_equal(len(m.token_endpoint_auth_methods_supported), 1)
    assert_equal(len(m.token_endpoint_auth_signing_alg_values_supported), 2)
    assert_equal(m.token_endpoint_auth_signing_alg_values_supported[1], "EdDSA")
    assert_equal(m.render(), DOC)
    # Unknown members, and an empty response type list, are ignored.
    var other = parse_authorization_server_metadata(
        '{"jwks_uri":"https://k.example/j","response_types_supported":[],"issuer":"https://issuer.example/a","token_endpoint":"https://t.example/t?x=1","x":{"y":[1]}}',
        ISS,
    )
    assert_equal(other.token_endpoint, "https://t.example/t?x=1")
    assert_equal(len(other.grant_types_supported), 0)
    assert_equal(len(other.token_endpoint_auth_methods_supported), 0)
    assert_equal(len(other.token_endpoint_auth_signing_alg_values_supported), 0)


def test_issuer_is_exact() raises:
    var near = List[String]()
    near.append("https://issuer.example/")
    near.append("https://issuer.example/ab")
    near.append("xhttps://issuer.example/a")
    near.append("ttps://issuer.example/a")
    near.append("HTTPS://ISSUER.EXAMPLE/A")
    near.append("https://issuer.example/A")
    near.append("zttps://issuer.example/a")
    near.append("https://issuer.example/z")
    near.append("")
    var misses = String("")
    for i in range(len(near)):
        # The document claims a near miss of the issuer it was fetched for.
        var doc = DOC.replace('"issuer":"https://issuer.example/a"', String('"issuer":"') + near[i] + '"')
        var got = _parse_refusal(doc)
        var want = String("OAuthError: member issuer is not the issuer")
        if near[i] == "":
            want = "OAuthError: member issuer is empty"
        if got != want:
            misses += near[i] + " -> " + got + "\n"
        # And the other way round: fetched for a near miss.
        if near[i] != "":
            var got2 = _parse_refusal(DOC, near[i])
            if got2 != "OAuthError: member issuer is not the issuer":
                misses += String("expected ") + near[i] + " -> " + got2 + "\n"
    assert_equal(misses, "")


def test_member_refusals() raises:
    assert_equal(_meta_refusal(issuer="https://issuer.example/a?q"), "OAuthError: the issuer has a query")
    assert_equal(_meta_refusal(token_endpoint="http://issuer.example/t"), "OAuthError: the token endpoint is not an https URL")
    assert_equal(_meta_refusal(token_endpoint="https://?t"), "OAuthError: the token endpoint has no host")
    assert_equal(_meta_refusal(token_endpoint="https://issuer.example/t#f"), "OAuthError: the token endpoint has a fragment")
    assert_equal(_meta_refusal(token_endpoint="https://issuer.example/t?q=1"), "accepted")
    assert_equal(_meta_refusal(jwks_uri="https://issuer.example/j#f"), "OAuthError: the jwks_uri has a fragment")
    assert_equal(_meta_refusal(jwks_uri="ftp://issuer.example/j"), "OAuthError: the jwks_uri is not an https URL")
    assert_equal(_meta_refusal(jwks_uri="https://issuer.example/j?q=1"), "accepted")
    assert_equal(_meta_refusal(grants=_list("client_credentials", "")), "OAuthError: grant_types_supported holds an empty string")
    assert_equal(_meta_refusal(grants=_list("a", "b", "a")), "OAuthError: grant_types_supported names a value twice")
    assert_equal(_meta_refusal(methods=_list("private_key_jwt", "")), "OAuthError: token_endpoint_auth_methods_supported holds an empty string")
    assert_equal(_meta_refusal(methods=_list("x", "x")), "OAuthError: token_endpoint_auth_methods_supported names a value twice")
    assert_equal(_meta_refusal(algs=_list("ES256", "")), "OAuthError: token_endpoint_auth_signing_alg_values_supported holds an empty string")
    assert_equal(_meta_refusal(algs=_list("ES256", "ES256")), "OAuthError: token_endpoint_auth_signing_alg_values_supported names a value twice")
    var no_algs = "OAuthError: private_key_jwt is listed without its signing algorithms"
    assert_equal(_meta_refusal(algs=List[String]()), no_algs)
    assert_equal(_meta_refusal(methods=_list("client_secret_basic", "private_key_jwt"), algs=List[String]()), no_algs)
    assert_equal(_meta_refusal(methods=_list("private_key_jwt", "client_secret_basic"), algs=List[String]()), no_algs)
    assert_equal(_meta_refusal(methods=_list("private_key_jw", "rivate_key_jwt", "private_key_jwtx"), algs=List[String]()), "accepted")
    assert_equal(_meta_refusal(methods=List[String](), algs=List[String]()), "accepted")


def test_parse_refusals() raises:
    assert_equal(_parse_refusal("x"), "OAuthError: the metadata is not JSON")
    assert_equal(_parse_refusal("[]"), "OAuthError: the metadata is not a JSON object")
    assert_equal(
        _parse_refusal(DOC.replace('"jwks_uri"', '"issuer":"https://issuer.example/a","jwks_uri"')),
        "OAuthError: the metadata names a member twice",
    )
    assert_equal(_parse_refusal('{"token_endpoint":"https://t.example/t","jwks_uri":"https://t.example/j"}'), "OAuthError: member issuer is missing")
    assert_equal(_parse_refusal('{"issuer":1}'), "OAuthError: member issuer is not a string")
    assert_equal(_parse_refusal('{"issuer":"https://issuer.example/a","jwks_uri":"https://t.example/j"}'), "OAuthError: member token_endpoint is missing")
    assert_equal(_parse_refusal('{"issuer":"https://issuer.example/a","token_endpoint":"https://t.example/t"}'), "OAuthError: member jwks_uri is missing")
    var arr = "OAuthError: member grant_types_supported is not a non-empty array of strings"
    assert_equal(_parse_refusal(DOC.replace('["client_credentials"]', '"client_credentials"')), arr)
    assert_equal(_parse_refusal(DOC.replace('["client_credentials"]', "[]")), arr)
    assert_equal(_parse_refusal(DOC.replace('["client_credentials"]', '["client_credentials",1]')), arr)
    assert_equal(_parse_refusal(DOC.replace('["client_credentials"]', '[1,"client_credentials"]')), arr)
    assert_equal(
        _parse_refusal(DOC.replace('["client_credentials"]', '["client_credentials",""]')),
        "OAuthError: member grant_types_supported holds an empty string",
    )
    assert_equal(
        _parse_refusal(DOC.replace('["client_credentials"]', '["a","b","a"]')),
        "OAuthError: member grant_types_supported names a value twice",
    )
    assert_equal(
        _parse_refusal(DOC.replace('["ES256","EdDSA"]', "[]")),
        "OAuthError: member token_endpoint_auth_signing_alg_values_supported is not a non-empty array of strings",
    )
    assert_equal(
        _parse_refusal(DOC.replace(',"token_endpoint_auth_signing_alg_values_supported":["ES256","EdDSA"]', "")),
        "OAuthError: private_key_jwt is listed without its signing algorithms",
    )
    assert_equal(
        _parse_refusal(DOC.replace('"https://issuer.example/a/token"', '"http://issuer.example/a/token"')),
        "OAuthError: the token endpoint is not an https URL",
    )


def test_size_limit() raises:
    var head = String('{"issuer":"https://issuer.example/a","token_endpoint":"https://issuer.example/a/token","jwks_uri":"https://issuer.example/a/jwks","pad":"')
    var buf = List[UInt8]()
    buf.extend(Span(head.as_bytes()))
    while len(buf) < OAUTH_METADATA_MAX_BYTES - 2:
        buf.append(0x61)
    buf.append(0x22)  # '"'
    buf.append(0x7D)  # '}'
    var at_limit = String(unsafe_from_utf8=Span(buf))
    assert_equal(at_limit.byte_length(), OAUTH_METADATA_MAX_BYTES)
    assert_equal(parse_authorization_server_metadata(at_limit, ISS).issuer, ISS)
    var over = head + "a" + String(at_limit[byte = head.byte_length() :])
    assert_equal(_parse_refusal(over), "OAuthError: the metadata is longer than 65536 bytes")


def main() raises:
    var failures = String("")
    try:
        test_well_known_url()
    except e:
        failures += String("test_well_known_url: ") + String(e) + "\n"
    try:
        test_url_refusals()
    except e:
        failures += String("test_url_refusals: ") + String(e) + "\n"
    try:
        test_render()
    except e:
        failures += String("test_render: ") + String(e) + "\n"
    try:
        test_for_client_credentials()
    except e:
        failures += String("test_for_client_credentials: ") + String(e) + "\n"
    try:
        test_parse_round_trip()
    except e:
        failures += String("test_parse_round_trip: ") + String(e) + "\n"
    try:
        test_issuer_is_exact()
    except e:
        failures += String("test_issuer_is_exact: ") + String(e) + "\n"
    try:
        test_member_refusals()
    except e:
        failures += String("test_member_refusals: ") + String(e) + "\n"
    try:
        test_parse_refusals()
    except e:
        failures += String("test_parse_refusals: ") + String(e) + "\n"
    try:
        test_size_limit()
    except e:
        failures += String("test_size_limit: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_metadata failed")
    print("PASS komira_oauth test_metadata")
