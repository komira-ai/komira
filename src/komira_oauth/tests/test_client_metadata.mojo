# =============================================================================
# test_client_metadata.mojo: the client registration record of
#   client_metadata.mojo against golden JSON in the RFC 7591 section 3.1
#   shape (tests/golden/client_metadata_*.json, one with the keys by value and
#   one with a jwks_uri), its round trip, the RFC's own two section 3.1
#   examples (tests/golden/rfc7591_3_1_*.json, the line breaks the RFC adds
#   inside a value for display taken out), and each refusal.
# =============================================================================
#
# The RFC examples have no client_id and use `client_secret_basic`, so they
# are read up to those refusals, then with exactly the members this profile
# requires put in; every other member they carry (redirect_uris, logo_uri,
# policy_uri, a language-tagged client_name, an extension parameter) is
# ignored, as RFC 7591 section 2 requires.
#
# main runs every test and reports every failure.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_jwks import JwkSet, Jwk, parse_jwk_set
from komira_oauth import (
    OAUTH_CLIENT_METADATA_MAX_BYTES,
    ClientMetadata,
    parse_client_metadata,
)


comptime GOLDEN = "src/komira_oauth/tests/golden/"


def _read(name: String) raises -> String:
    var text = Path(String(GOLDEN) + name).read_text()
    var b = text.as_bytes()
    if len(b) > 0 and b[len(b) - 1] == 0x0A:
        return String(text[byte = 0 : len(b) - 1])
    return text^


def _first(s: String, old: String, new: String) raises -> String:
    """`s` with the first `old` replaced by `new`."""
    var at = s.find(old)
    if at < 0:
        raise Error(String("fixture edit: not found: ") + old)
    return (
        String(s[byte=0:at]) + new + String(s[byte = at + old.byte_length() :])
    )


def _append(doc: String, member: String) -> String:
    """`doc` (an object) with `member` added as its last member."""
    var n = doc.byte_length()
    return String(doc[byte = 0 : n - 1]) + "," + member + "}"


def _refusal(doc: String) -> String:
    try:
        _ = parse_client_metadata(doc)
    except e:
        return String(e)
    return String("accepted")


def _list(*values: String) -> List[String]:
    var out = List[String]()
    for v in values:
        out.append(String(v))
    return out^


def _keys() raises -> JwkSet:
    return parse_jwk_set(
        '{"keys":[{"kty":"EC","crv":"P-256","alg":"ES256","use":"sig","kid":"k1",'
        + '"x":"f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU","y":"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"},'
        + '{"kty":"EC","crv":"P-256","kid":"k2","x":"MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",'
        + '"y":"4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM"}]}'
    )


def _with_jwks_refusal(
    client_id: String = "service-a",
    alg: String = "ES256",
    scope: String = "",
    resource_types: List[String] = List[String](),
) -> String:
    try:
        _ = ClientMetadata.with_jwks(
            client_id=client_id,
            client_name="",
            signing_alg=alg,
            scope=scope,
            jwks=_keys(),
            resource_types=resource_types,
        )
    except e:
        return String(e)
    return String("accepted")


def _with_uri_refusal(uri: String) -> String:
    try:
        _ = ClientMetadata.with_jwks_uri(
            client_id="c",
            client_name="",
            signing_alg="EdDSA",
            scope="",
            jwks_uri=uri,
            resource_types=List[String](),
        )
    except e:
        return String(e)
    return String("accepted")


def test_golden_jwks() raises:
    var m = ClientMetadata.with_jwks(
        client_id="service-a",
        client_name="Service A",
        signing_alg="ES256",
        scope="read write",
        jwks=_keys(),
        resource_types=_list("doc", "folder"),
    )
    var golden = _read("client_metadata_jwks.json")
    assert_equal(m.render(), golden)
    var back = parse_client_metadata(golden)
    assert_equal(back.client_id, "service-a")
    assert_equal(back.client_name, "Service A")
    assert_equal(back.token_endpoint_auth_signing_alg, "ES256")
    assert_equal(back.scope, "read write")
    assert_equal(len(back.jwks.value().keys), 2)
    assert_equal(back.jwks.value().keys[1].kid().value(), "k2")
    assert_equal(back.jwks_uri, "")
    assert_equal(len(back.resource_types), 2)
    assert_equal(back.resource_types[1], "folder")
    assert_equal(back.render(), golden)


def test_golden_jwks_uri() raises:
    var m = ClientMetadata.with_jwks_uri(
        client_id="service-b",
        client_name="",
        signing_alg="EdDSA",
        scope="",
        jwks_uri="https://service-b.example/keys.json",
        resource_types=List[String](),
    )
    var golden = _read("client_metadata_jwks_uri.json")
    assert_equal(m.render(), golden)
    var back = parse_client_metadata(golden)
    assert_false(Bool(back.jwks))
    assert_equal(back.jwks_uri, "https://service-b.example/keys.json")
    assert_equal(back.client_name, "")
    assert_equal(back.scope, "")
    assert_equal(len(back.resource_types), 0)
    assert_equal(back.render(), golden)


def test_rfc_examples() raises:
    var open_doc = _read("rfc7591_3_1_open.json")
    assert_equal(_refusal(open_doc), "OAuthError: member client_id is missing")
    var with_id = _first(open_doc, "{", '{"client_id":"c1",')
    assert_equal(
        _refusal(with_id),
        "OAuthError: token_endpoint_auth_method is not private_key_jwt",
    )
    var with_method = with_id.replace("client_secret_basic", "private_key_jwt")
    assert_equal(
        _refusal(with_method),
        "OAuthError: member token_endpoint_auth_signing_alg is missing",
    )
    var with_alg = with_method.replace(
        '"logo_uri"', '"token_endpoint_auth_signing_alg":"ES256","logo_uri"'
    )
    assert_equal(
        _refusal(with_alg), "OAuthError: grant_types is not exactly client_credentials"
    )
    var full = with_alg.replace(
        '"logo_uri"', '"grant_types":["client_credentials"],"logo_uri"'
    )
    var m = parse_client_metadata(full)
    assert_equal(m.client_id, "c1")
    assert_equal(m.client_name, "My Example Client")
    assert_equal(m.jwks_uri, "https://client.example.org/my_public_keys.jwks")
    assert_equal(
        m.render(),
        '{"client_id":"c1","client_name":"My Example Client","token_endpoint_auth_method":"private_key_jwt","token_endpoint_auth_signing_alg":"ES256","grant_types":["client_credentials"],"jwks_uri":"https://client.example.org/my_public_keys.jwks"}',
    )
    # The second example registers its JWK Set by value: an RSA key.
    var by_value = _read("rfc7591_3_1_by_value.json")
    var fixed = (
        _first(by_value, "{", '{"client_id":"c2","token_endpoint_auth_signing_alg":"EdDSA","grant_types":["client_credentials"],')
        .replace("client_secret_basic", "private_key_jwt")
    )
    var k = parse_client_metadata(fixed)
    assert_equal(len(k.jwks.value().keys), 1)
    assert_equal(k.jwks.value().keys[0].kty(), "RSA")
    assert_equal(len(k.jwks.value().keys[0].n()), 256)


def test_constructor_refusals() raises:
    assert_equal(_with_jwks_refusal(client_id=""), "OAuthError: the client_id is empty")
    var bad_alg = "OAuthError: the signing alg must be ES256 or EdDSA"
    var misses = String("")
    for a in ["ES25", "ES2566", "xES256", "S256", "es256", "Es256", "ES257", "FS256", "EdDS", "EdDSAx", "xEdDSA", "dDSA", "EDDSA", "eddsa", "EdDSB", "FdDSA", "RS256", "none", ""]:
        var got = _with_jwks_refusal(alg=a)
        if got != bad_alg:
            misses += String(a) + " -> " + got + "\n"
    assert_equal(misses, "")
    assert_equal(_with_jwks_refusal(alg="EdDSA"), "accepted")
    for s in ["a  b", " a", "a ", 'a"b', "a\\b"]:
        assert_equal(_with_jwks_refusal(scope=s), "OAuthError: the scope is not a scope", s)
    assert_equal(_with_jwks_refusal(scope="a b !#[]~"), "accepted")
    assert_equal(
        _with_jwks_refusal(resource_types=_list("a", "")),
        "OAuthError: resource_types holds an empty string",
    )
    assert_equal(
        _with_jwks_refusal(resource_types=_list("a", "b", "a")),
        "OAuthError: resource_types names a value twice",
    )
    try:
        _ = ClientMetadata.with_jwks(
            client_id="c", client_name="", signing_alg="ES256", scope="",
            jwks=JwkSet(List[Jwk](), List[String]()), resource_types=List[String](),
        )
        raise Error("an empty set was accepted")
    except e:
        assert_equal(String(e), "OAuthError: the jwks holds no key")
    var with_skip = parse_jwk_set(
        '{"keys":[{"kty":"EC","crv":"P-256","x":"f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU","y":"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"},{"kty":"oct-x"}]}'
    )
    assert_equal(len(with_skip.skipped), 1)
    try:
        _ = ClientMetadata.with_jwks(
            client_id="c", client_name="", signing_alg="ES256", scope="",
            jwks=with_skip, resource_types=List[String](),
        )
        raise Error("a skipped key was accepted")
    except e:
        assert_equal(String(e), "OAuthError: the jwks holds a key komira_jwks skips")
    assert_equal(_with_uri_refusal("http://k.example/j"), "OAuthError: the jwks_uri is not an https URL")
    assert_equal(_with_uri_refusal("https://k.example/j#f"), "OAuthError: the jwks_uri has a fragment")
    assert_equal(_with_uri_refusal("https:///j"), "OAuthError: the jwks_uri has no host")
    assert_equal(_with_uri_refusal("https://k.example/j?v=2"), "accepted")


def test_parse_refusals() raises:
    var g = _read("client_metadata_jwks_uri.json")
    assert_equal(_refusal("x"), "OAuthError: the client metadata is not JSON")
    assert_equal(_refusal("[]"), "OAuthError: the client metadata is not a JSON object")
    assert_equal(_refusal(_append(_first(g, "{", '{"scope":"a",'), '"scope":"b"')), "OAuthError: the client metadata names a member twice")
    assert_equal(_refusal(g.replace('"client_id":"service-b"', '"client_id":1')), "OAuthError: member client_id is not a string")
    assert_equal(_refusal(g.replace('"client_id":"service-b"', '"client_id":""')), "OAuthError: member client_id is empty")
    assert_equal(_refusal(_first(g, "{", '{"client_name":"",')), "OAuthError: member client_name is empty")
    assert_equal(_refusal(g.replace('"token_endpoint_auth_method":"private_key_jwt",', "")), "OAuthError: token_endpoint_auth_method is not private_key_jwt")
    var misses = String("")
    for m in ["private_key_jw", "private_key_jwtx", "xprivate_key_jwt", "rivate_key_jwt", "PRIVATE_KEY_JWT", "zrivate_key_jwt", "private_key_jwz", "client_secret_jwt", "none"]:
        var got = _refusal(g.replace('"private_key_jwt"', String('"') + m + '"'))
        if got != "OAuthError: token_endpoint_auth_method is not private_key_jwt":
            misses += String(m) + " -> " + got + "\n"
    assert_equal(misses, "")
    assert_equal(_refusal(g.replace('"token_endpoint_auth_signing_alg":"EdDSA",', "")), "OAuthError: member token_endpoint_auth_signing_alg is missing")
    assert_equal(_refusal(g.replace('"EdDSA"', '"RS256"')), "OAuthError: the signing alg must be ES256 or EdDSA")
    var not_cc = "OAuthError: grant_types is not exactly client_credentials"
    assert_equal(_refusal(g.replace(',"grant_types":["client_credentials"]', "")), not_cc)
    assert_equal(_refusal(g.replace('["client_credentials"]', '["client_credentials","authorization_code"]')), not_cc)
    assert_equal(_refusal(g.replace('["client_credentials"]', '["authorization_code","client_credentials"]')), not_cc)
    for gt in ["client_credential", "client_credentialsx", "xclient_credentials", "lient_credentials", "CLIENT_CREDENTIALS", "zlient_credentials", "client_credentialz"]:
        assert_equal(_refusal(g.replace('["client_credentials"]', String('["') + gt + '"]')), not_cc, gt)
    assert_equal(_refusal(g.replace('["client_credentials"]', '"client_credentials"')), "OAuthError: member grant_types is not a non-empty array of strings")
    assert_equal(_refusal(g.replace('["client_credentials"]', "[]")), "OAuthError: member grant_types is not a non-empty array of strings")
    assert_equal(_refusal(g.replace('["client_credentials"]', '["client_credentials","client_credentials"]')), "OAuthError: member grant_types names a value twice")
    assert_equal(_refusal(_first(g, "{", '{"scope":"",')), "OAuthError: member scope is empty")
    assert_equal(_refusal(_first(g, "{", '{"scope":"a  b",')), "OAuthError: the scope is not a scope")
    assert_equal(_refusal(_append(g, '"resource_types":[]')), "OAuthError: member resource_types is not a non-empty array of strings")
    assert_equal(_refusal(_append(g, '"resource_types":["a",""]')), "OAuthError: member resource_types holds an empty string")
    assert_equal(_refusal(_append(g, '"resource_types":["a","a"]')), "OAuthError: member resource_types names a value twice")
    assert_equal(_refusal(g.replace('"https://service-b.example/keys.json"', '""')), "OAuthError: member jwks_uri is empty")
    assert_equal(_refusal(g.replace('"https://service-b.example/keys.json"', '"http://service-b.example/keys.json"')), "OAuthError: the jwks_uri is not an https URL")
    assert_equal(_refusal(g.replace(',"jwks_uri":"https://service-b.example/keys.json"', "")), "OAuthError: the record holds neither jwks nor jwks_uri")
    var jg = _read("client_metadata_jwks.json")
    assert_equal(_refusal(_append(jg, '"jwks_uri":"https://k.example/j"')), "OAuthError: the record holds both jwks and jwks_uri")
    assert_equal(_refusal(_first(jg, "{", '{"jwks_uri":"https://k.example/j",')), "OAuthError: the record holds both jwks and jwks_uri")
    assert_equal(_refusal(g.replace('"jwks_uri":"https://service-b.example/keys.json"', '"jwks":[]')), "OAuthError: member jwks is not a JWK Set")
    assert_equal(_refusal(g.replace('"jwks_uri":"https://service-b.example/keys.json"', '"jwks":{"key":[]}')), "OAuthError: member jwks is not a JWK Set")
    assert_equal(
        _refusal(g.replace('"jwks_uri":"https://service-b.example/keys.json"', '"jwks":{"keys":[{"kty":"OKP","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo","d":"nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"}]}')),
        "OAuthError: member jwks is not a JWK Set",
    )
    assert_equal(_refusal(g.replace('"jwks_uri":"https://service-b.example/keys.json"', '"jwks":{"keys":[]}')), "OAuthError: the jwks holds no key")
    assert_equal(
        _refusal(g.replace('"jwks_uri":"https://service-b.example/keys.json"', '"jwks":{"keys":[{"kty":"OKP","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"},{"kty":"EC","crv":"P-384","x":"a","y":"b"}]}')),
        "OAuthError: the jwks holds a key komira_jwks skips",
    )
    # A JWK Set member alone parses.
    var one = parse_client_metadata(g.replace('"jwks_uri":"https://service-b.example/keys.json"', '"jwks":{"keys":[{"kty":"OKP","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}]}'))
    assert_equal(len(one.jwks.value().keys), 1)


def test_size_limit() raises:
    var g = _read("client_metadata_jwks_uri.json")
    var head = g.replace("}", ',"pad":"')
    var buf = List[UInt8]()
    buf.extend(Span(head.as_bytes()))
    while len(buf) < OAUTH_CLIENT_METADATA_MAX_BYTES - 2:
        buf.append(0x61)
    buf.append(0x22)
    buf.append(0x7D)
    var at_limit = String(unsafe_from_utf8=Span(buf))
    assert_equal(at_limit.byte_length(), OAUTH_CLIENT_METADATA_MAX_BYTES)
    assert_equal(parse_client_metadata(at_limit).client_id, "service-b")
    var over = head + "a" + String(at_limit[byte = head.byte_length() :])
    assert_equal(_refusal(over), "OAuthError: the client metadata is longer than 262144 bytes")


def main() raises:
    var failures = String("")
    try:
        test_golden_jwks()
    except e:
        failures += String("test_golden_jwks: ") + String(e) + "\n"
    try:
        test_golden_jwks_uri()
    except e:
        failures += String("test_golden_jwks_uri: ") + String(e) + "\n"
    try:
        test_rfc_examples()
    except e:
        failures += String("test_rfc_examples: ") + String(e) + "\n"
    try:
        test_constructor_refusals()
    except e:
        failures += String("test_constructor_refusals: ") + String(e) + "\n"
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
        raise Error("test_client_metadata failed")
    print("PASS komira_oauth test_client_metadata")
