# =============================================================================
# komira_github_fake/tests/test_client_auth.mojo -- the real GitHubAppClient
#   against the fake: the App JWT, the token cache, the one-repository token.
# =============================================================================
#
# The client and the fake keep separate clocks; `_at` moves both, so they
# agree unless a test says otherwise.
#
# What each test proves, and the defect it catches:
#   * test_app_jwt_checked_by_fake: a JWT the client mints verifies under the
#     App's public key (signature, iss, alg, window). Refused with 401: the
#     same JWT at its `exp` (EXPIRED; one second earlier it is accepted),
#     under another public key, for another issuer, with its claims
#     re-encoded to another valid `exp` (the signature no longer matches), with
#     `alg` changed, and with no credential. Catches the fake (or GitHub's
#     rule in komira_github) accepting an expired or forged JWT.
#   * test_client_remints_before_expiry: the client sends the same JWT until
#     61 s of it remain, a new one from 60 s (at +480 s), and never one
#     the fake refuses as expired. Catches re-minting only at expiry.
#   * test_token_refresh_margin: one installation token serves every call
#     until 301 s remain; at 300 s remaining the client mints a new one
#     (fake's mint count 1 -> 2). Catches REFRESH AT EXPIRY.
#   * test_one_repo_token: `repo_contents_read_token` sends exactly the
#     one-repository body, and the token it gets reads the file of that
#     repository but sees neither the installation's OTHER repository (the
#     last one; 404 on the repository and its contents) nor any route
#     needing another permission (403 on a check run). Catches a token
#     request WITHOUT repository_ids (it would cover both repositories).
#   * test_token_expiry_edges: the fake accepts an installation token 1 s
#     before `expires_at` and refuses it at `expires_at`; the client sends a
#     caller-held token with 301 s left and refuses (AUTH, nothing sent)
#     with 300 s left.
#   * test_401_drops_tokens: when GitHub stops accepting a cached token the
#     call raises AUTH, and the next call mints a fresh token and succeeds.
#   * test_suspended_installation: a suspended installation's token mint is
#     403 and raised as HTTP_STATUS, not retried.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_encoding import base64_url_encode_nopad
from komira_github import (
    AppCredentials,
    GitHubAppClient,
    GitHubHttpRequest,
    ManualUnixClock,
    create_check_run,
    CheckRunFields,
    get_authenticated_app,
    get_contents,
    get_repository,
    github_error_kind,
    list_installation_repositories,
    mint_app_jwt,
)

from komira_github_fake import FakeAppPublicKey, FakeGitHub, app_public_key_from_pkcs8


comptime NOW: Int64 = 1_790_856_000
comptime ISSUER = "Iv23liFAKEAPP"
comptime Client = GitHubAppClient[FakeGitHub, ManualUnixClock]


def _key() raises -> List[UInt8]:
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _one(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _ids(a: Int64, b: Int64) -> List[Int64]:
    var out = List[Int64]()
    out.append(a)
    out.append(b)
    return out^


def _perms() -> List[String]:
    var p = List[String]()
    p.append(String("metadata:read"))
    p.append(String("contents:read"))
    p.append(String("checks:write"))
    return p^


def _bytes(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    b.extend(Span(s.as_bytes()))
    return b^


struct Setup(Movable):
    var client: Client
    var inst: Int64
    var app1: Int64
    var app2: Int64

    def __init__(out self, var client: Client, inst: Int64, app1: Int64, app2: Int64):
        self.client = client^
        self.inst = inst
        self.app1 = app1
        self.app2 = app2


def _setup() raises -> Setup:
    var fake = FakeGitHub(String(ISSUER), app_public_key_from_pkcs8(_key()), NOW)
    var a = fake.state.add_repo("alice", "app1", _one("alice"))
    var b = fake.state.add_repo("alice", "app2", _one("alice"))
    fake.state.put_file(a, "main", "README.md", _bytes("app one"))
    fake.state.put_file(b, "main", "README.md", _bytes("app two"))
    var inst = fake.state.install("alice", "alice", _ids(a, b), _perms())
    var client = Client(fake^, AppCredentials(String(ISSUER), _key()), ManualUnixClock(NOW))
    return Setup(client^, inst, a, b)


def _at(mut c: Client, t: Int64):
    c.clock().set(t)
    c.transport().set_now(t)


def _raw_app_get(mut fake: FakeGitHub, bearer: String) raises -> Int:
    var req = GitHubHttpRequest(String("GET"), String("/app"))
    if bearer.byte_length() > 0:
        req.add_header(String("Authorization"), String("Bearer ") + bearer)
    return fake.send(req).status


def _b64(s: String) -> String:
    return base64_url_encode_nopad(s.as_bytes())


def _segments(token: String) -> List[String]:
    var out = List[String]()
    var b = token.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == UInt8(ord(".")):
            out.append(String(token[byte=start:i]))
            start = i + 1
    return out^


def test_app_jwt_checked_by_fake() raises:
    var key = _key()
    var pub = app_public_key_from_pkcs8(key)
    var fake = FakeGitHub(String(ISSUER), pub.copy(), NOW)
    var creds = AppCredentials(String(ISSUER), key.copy())
    var jwt = mint_app_jwt(creds, NOW)
    assert_equal(_raw_app_get(fake, jwt.token), 200, "a fresh JWT")
    fake.set_now(NOW + 539)
    assert_equal(_raw_app_get(fake, jwt.token), 200, "one second before exp")
    fake.set_now(NOW + 540)
    assert_equal(_raw_app_get(fake, jwt.token), 401, "at exp: expired")
    fake.set_now(NOW + 3600)
    assert_equal(_raw_app_get(fake, jwt.token), 401, "long expired")
    fake.set_now(NOW)
    var refused = String("")
    var other_n = pub.n.copy()
    other_n[len(other_n) - 1] = other_n[len(other_n) - 1] ^ 0x02
    var other = FakeGitHub(String(ISSUER), FakeAppPublicKey(other_n^, pub.e), NOW)
    if _raw_app_get(other, jwt.token) != 401:
        refused += "other-key "
    var other_iss = FakeGitHub(String("Iv23liFAKEAPq"), pub.copy(), NOW)
    if _raw_app_get(other_iss, jwt.token) != 401:
        refused += "other-issuer "
    var segs = _segments(jwt.token)
    # Valid times (exp 530 s ahead), so only the signature can refuse it.
    var later = _b64(String('{"iat":1790855940,"exp":1790856530,"iss":"') + ISSUER + String('"}'))
    if _raw_app_get(fake, segs[0] + String(".") + later + String(".") + segs[2]) != 401:
        refused += "re-encoded-claims "
    var hs = _b64(String('{"alg":"HS256","typ":"JWT"}'))
    if _raw_app_get(fake, hs + String(".") + segs[1] + String(".") + segs[2]) != 401:
        refused += "alg "
    if _raw_app_get(fake, String("")) != 401:
        refused += "no-credential "
    if _raw_app_get(fake, segs[0] + String(".") + segs[1]) != 401:
        refused += "two-segments "
    assert_equal(refused, String(""), "forged App JWTs are refused")
    assert_equal(_raw_app_get(fake, jwt.token), 200, "the real one still passes")
    print("  test_app_jwt_checked_by_fake PASS")


def _auth_of(mut c: Client, i: Int) raises -> String:
    return c.transport().requests[i].header(String("Authorization")).value()


def test_client_remints_before_expiry() raises:
    var s = _setup()
    assert_equal(s.client.app_send(get_authenticated_app()).status, 200)
    _at(s.client, NOW + 479)
    assert_equal(s.client.app_send(get_authenticated_app()).status, 200)
    assert_equal(_auth_of(s.client, 0), _auth_of(s.client, 1), "61 s left: the same JWT")
    _at(s.client, NOW + 480)
    assert_equal(s.client.app_send(get_authenticated_app()).status, 200)
    assert_true(_auth_of(s.client, 1) != _auth_of(s.client, 2), "60 s left: a new JWT")
    _at(s.client, NOW + 1020)
    assert_equal(s.client.app_send(get_authenticated_app()).status, 200, "never an expired JWT")
    print("  test_client_remints_before_expiry PASS")


def test_token_refresh_margin() raises:
    var s = _setup()
    assert_equal(s.client.send(s.inst, get_repository("alice", "app1")).status, 200)
    assert_equal(s.client.transport().state.tokens_minted, 1)
    # A token lives 3600 s: 301 s left at +3299, 300 s left at +3300.
    _at(s.client, NOW + 3299)
    assert_equal(s.client.send(s.inst, get_repository("alice", "app1")).status, 200)
    assert_equal(s.client.transport().state.tokens_minted, 1, "301 s left: cached")
    _at(s.client, NOW + 3300)
    assert_equal(s.client.send(s.inst, get_repository("alice", "app1")).status, 200)
    assert_equal(s.client.transport().state.tokens_minted, 2, "300 s left: refreshed")
    print("  test_token_refresh_margin PASS")


def test_one_repo_token() raises:
    var s = _setup()
    var tok = s.client.repo_contents_read_token(s.inst, s.app1)
    var sent = s.client.transport().requests[0].copy()
    assert_equal(sent.target, String("/app/installations/") + String(s.inst) + String("/access_tokens"))
    assert_equal(
        String(unsafe_from_utf8=Span(sent.body)),
        String('{"repository_ids":[') + String(s.app1) + String('],"permissions":{"contents":"read"}}'),
    )
    var own = s.client.send_with_token(tok, get_contents("alice", "app1", "README.md"))
    assert_equal(own.status, 200, "the token reads its own repository")
    assert_equal(s.client.send_with_token(tok, get_repository("alice", "app2")).status, 404, "not the other repository")
    assert_equal(s.client.send_with_token(tok, get_contents("alice", "app2", "README.md")).status, 404, "nor its files")
    var check = create_check_run(
        "alice",
        "app1",
        CheckRunFields(String("b"), String("0123456789abcdef0123456789abcdef01234567"), String("queued"), String(""), String(""), String(""), String(""), String("")),
    )
    assert_equal(s.client.send_with_token(tok, check).status, 403, "no checks permission")
    var whole = s.client.send(s.inst, get_repository("alice", "app2"))
    assert_equal(whole.status, 200, "the whole-grant token still sees it")
    assert_equal(s.client.transport().state.tokens_minted, 2, "two scopes, two tokens")
    var again = s.client.repo_contents_read_token(s.inst, s.app1)
    assert_equal(again.token, tok.token, "the scoped token is cached under its scope")
    print("  test_one_repo_token PASS")


def test_token_expiry_edges() raises:
    var s = _setup()
    var tok = s.client.repo_contents_read_token(s.inst, s.app1)
    var exp = tok.expires_at
    var raw = GitHubHttpRequest(String("GET"), String("/repos/alice/app1"))
    raw.add_header(String("Authorization"), String("Bearer ") + tok.token)
    s.client.transport().set_now(exp - 1)
    assert_equal(s.client.transport().send(raw).status, 200, "the fake accepts a token 1 s before expiry")
    s.client.transport().set_now(exp)
    assert_equal(s.client.transport().send(raw).status, 401, "and refuses it at expiry")
    _at(s.client, exp - 301)
    assert_equal(s.client.send_with_token(tok, get_repository("alice", "app1")).status, 200, "301 s left")
    _at(s.client, exp - 300)
    var before = s.client.transport().request_count()
    var why = String("")
    try:
        _ = s.client.send_with_token(tok, get_repository("alice", "app1"))
    except e:
        why = String(e)
    assert_equal(github_error_kind(why), String("AUTH"), why)
    assert_equal(s.client.transport().request_count(), before, "a stale caller-held token is not sent")
    print("  test_token_expiry_edges PASS")


def test_401_drops_tokens() raises:
    var s = _setup()
    assert_equal(s.client.send(s.inst, get_repository("alice", "app1")).status, 200)
    s.client.transport().state.tokens.clear()
    var why = String("")
    try:
        _ = s.client.send(s.inst, get_repository("alice", "app1"))
    except e:
        why = String(e)
    assert_equal(github_error_kind(why), String("AUTH"), why)
    assert_equal(s.client.send(s.inst, get_repository("alice", "app1")).status, 200, "a fresh token")
    assert_equal(s.client.transport().state.tokens_minted, 2)
    print("  test_401_drops_tokens PASS")


def test_suspended_installation() raises:
    var s = _setup()
    s.client.transport().state.suspend(s.inst)
    var why = String("")
    try:
        _ = s.client.send(s.inst, list_installation_repositories())
    except e:
        why = String(e)
    assert_equal(github_error_kind(why), String("HTTP_STATUS"), why)
    assert_true(why.find("403") >= 0, why)
    assert_equal(s.client.transport().request_count(), 1, "not retried")
    print("  test_suspended_installation PASS")


def main() raises:
    test_app_jwt_checked_by_fake()
    test_client_remints_before_expiry()
    test_token_refresh_margin()
    test_one_repo_token()
    test_token_expiry_edges()
    test_401_drops_tokens()
    test_suspended_installation()
    print("PASS komira_github_fake client auth")
