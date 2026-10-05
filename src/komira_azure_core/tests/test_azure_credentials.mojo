# The credential types and static providers, and the OAuth2 token-response
# readers both token providers share: the string field (with its escapes),
# `expires_in` as a JSON number (Entra) and as a JSON string (IMDS), and the
# named error for each malformed body.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_azure_core import (
    AzureBearerToken,
    AzureSas,
    AzureSharedKey,
    SasProvider,
    SharedKeyProvider,
    extract_oauth_token_field,
    parse_oauth_expires_in,
    parse_oauth_expires_in_str,
)


def test_shared_key_provider_round_trip() raises:
    var p = SharedKeyProvider.make(String("acct"), String("a2V5Cg=="))
    var c = p.credential()
    assert_equal(c.account, String("acct"))
    assert_equal(c.key_b64, String("a2V5Cg=="))
    # Static: the same credential every call.
    assert_equal(p.credential().account, c.account)


def test_sas_provider_round_trip() raises:
    var p = SasProvider.make(String("sv=2026-10-01&sp=r&sig=abc"))
    assert_equal(p.credential().query_string, String("sv=2026-10-01&sp=r&sig=abc"))


def test_credential_pods() raises:
    var k = AzureSharedKey(String("acct"), String("a2V5Cg=="))
    var k2 = k
    assert_equal(k2.account, String("acct"))
    assert_equal(k2.key_b64, String("a2V5Cg=="))
    var s = AzureSas(String("sv=2026-10-01&sig=Zm9v"))
    assert_equal(s.query_string, String("sv=2026-10-01&sig=Zm9v"))


def test_bearer_token_empty_sentinel() raises:
    assert_true(AzureBearerToken(String(""), Int64(-1)).is_empty())
    assert_false(AzureBearerToken(String("t"), Int64(5)).is_empty())


def test_token_field_with_escapes_and_whitespace() raises:
    var body = String(
        '{"token_type": "Bearer",\n  "access_token" :\t"a\\"b\\\\c\\/d"}'
    )
    assert_equal(extract_oauth_token_field(body, String("token_type")), "Bearer")
    assert_equal(
        extract_oauth_token_field(body, String("access_token")), 'a"b\\c/d'
    )


def test_token_field_errors() raises:
    with assert_raises(contains="field not found: access_token"):
        _ = extract_oauth_token_field(String('{"x":"y"}'), String("access_token"))
    with assert_raises(contains="value not a string for key expires_in"):
        _ = extract_oauth_token_field(
            String('{"expires_in":3599}'), String("expires_in")
        )
    with assert_raises(contains="unterminated string for key access_token"):
        _ = extract_oauth_token_field(
            String('{"access_token":"abc'), String("access_token")
        )


def test_expires_in_number_and_string_forms() raises:
    # Entra: a JSON number.
    assert_equal(parse_oauth_expires_in(String('{"expires_in": 3599}')), 3599)
    # IMDS: a JSON string; the string reader takes both forms.
    assert_equal(
        parse_oauth_expires_in_str(String('{"expires_in":"86399"}')), 86399
    )
    assert_equal(parse_oauth_expires_in_str(String('{"expires_in":42}')), 42)
    # The number reader does not take the string form.
    with assert_raises(contains="value not numeric"):
        _ = parse_oauth_expires_in(String('{"expires_in":"3599"}'))
    with assert_raises(contains="field not found: expires_in"):
        _ = parse_oauth_expires_in(String('{"access_token":"t"}'))


def main() raises:
    test_shared_key_provider_round_trip()
    test_sas_provider_round_trip()
    test_credential_pods()
    test_bearer_token_empty_sentinel()
    test_token_field_with_escapes_and_whitespace()
    test_token_field_errors()
    test_expires_in_number_and_string_forms()
    print("OK")
