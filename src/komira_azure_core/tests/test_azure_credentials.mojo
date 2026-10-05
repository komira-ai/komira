# The credential types and static providers, and the JSON reader of a token
# endpoint's answer both token providers share: `expires_in` as a JSON number
# (Entra) and as a string of digits (IMDS), escapes decoded as JSON decodes
# them, only top-level members read, and a named refusal for each malformed
# body that repeats none of it.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_azure_core import (
    AzureBearerToken,
    AzureSas,
    AzureSharedKey,
    OAuthTokenResponse,
    SasProvider,
    SharedKeyProvider,
    parse_oauth_token_response,
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


def _bytes(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    b.extend(Span(s.as_bytes()))
    return b^


def _read(s: String) raises -> OAuthTokenResponse:
    return parse_oauth_token_response(_bytes(s))


def test_token_response_fields() raises:
    # Entra: expires_in a number, extra members ignored.
    var r = _read(
        '{"token_type":"Bearer","expires_in":3599,"ext_expires_in":3599,'
        '"access_token":"eyJ0.x.y"}'
    )
    assert_equal(r.access_token, "eyJ0.x.y")
    assert_equal(r.expires_in, 3599)
    assert_equal(r.token_type, "Bearer")
    # IMDS: expires_in a numeric string, more extra members, whitespace.
    r = _read(
        '{ "access_token" :\t"t", "refresh_token": "", "expires_in": "86399",\n'
        '  "expires_on": "1700000000", "not_before": "0",'
        ' "resource": "https://storage.azure.com/", "token_type": "Bearer" }'
    )
    assert_equal(r.access_token, "t")
    assert_equal(r.expires_in, 86399)
    # token_type is optional, and compared without case.
    assert_equal(_read('{"access_token":"t","expires_in":1}').token_type, "Bearer")
    assert_equal(
        _read('{"access_token":"t","expires_in":1,"token_type":"bearer"}').token_type,
        "bearer",
    )


def test_token_response_escapes_and_nesting() raises:
    # Escaped quotes, backslashes, solidus and a \u escape: a byte scan
    # stopping at the first `"` would cut this token short.
    var r = _read(
        '{"access_token":"a\\"b\\\\\\"c\\/d\\u00e9\\u0041",'
        '"expires_in":60}'
    )
    assert_equal(r.access_token, 'a"b\\"c/déA')
    # A member name inside a string value, and a decoy member in a nested
    # object, are not the token.
    r = _read(
        '{"note":"\\"access_token\\":\\"no\\"",'
        '"inner":{"access_token":"decoy","expires_in":1},'
        '"list":[{"access_token":"decoy"}],'
        '"access_token":"real","expires_in":"3599"}'
    )
    assert_equal(r.access_token, "real")
    assert_equal(r.expires_in, 3599)


def _refused(body: String, contains: String) raises:
    var raised = False
    try:
        _ = _read(body)
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find(contains) >= 0, msg)
        assert_equal(msg.find("SECRET"), -1, msg)
    assert_true(raised, body)


def test_token_response_refusals() raises:
    _refused('{"access_token":"SECRET","expires_in":1', "is not JSON")
    _refused('access_token=SECRET&expires_in=1', "is not JSON")
    _refused('{"access_token":"SECRET","expires_in":1} x', "is not JSON")
    _refused("", "is not JSON")
    _refused('["access_token","SECRET"]', "is not a JSON object")
    _refused('"SECRET"', "is not a JSON object")
    _refused(
        '{"expires_in":1,"inner":{"access_token":"SECRET"}}',
        "has no access_token string",
    )
    _refused('{"access_token":null,"expires_in":1}', "has no access_token string")
    _refused('{"access_token":"","expires_in":1}', "access_token is empty")
    _refused('{"access_token":"SECRET"}', "has no expires_in")
    comptime bad_exp = "expires_in is not a positive whole number"
    _refused('{"access_token":"SECRET","expires_in":"SECRET"}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":"-5"}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":"+5"}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":"3599 "}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":""}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":-5}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":0}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":3599.0}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":1e3}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":true}', bad_exp)
    _refused('{"access_token":"SECRET","expires_in":99999999999999999999}', bad_exp)
    _refused(
        '{"access_token":"SECRET","expires_in":1,"token_type":"pop"}',
        "token_type is not Bearer",
    )
    _refused(
        '{"access_token":"SECRET","expires_in":1,"token_type":1}',
        "token_type is not Bearer",
    )


def main() raises:
    test_shared_key_provider_round_trip()
    test_sas_provider_round_trip()
    test_credential_pods()
    test_bearer_token_empty_sentinel()
    test_token_response_fields()
    test_token_response_escapes_and_nesting()
    test_token_response_refusals()
    print("OK")
