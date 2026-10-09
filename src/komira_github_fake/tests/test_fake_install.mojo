# =============================================================================
# komira_github_fake/tests/test_fake_install.mojo -- the fake installs an App
#   only on repositories the installing person administers.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * test_admin_installs: an administrator of every chosen repository
#     installs; the installation holds exactly those repositories and
#     permissions, and an installation token minted for it (through the
#     real client) covers them.
#   * test_non_admin_refused: a WRITE collaborator is refused; a person who
#     administers the first two repositories but not the LAST is refused;
#     one who administers none but the last is refused. Nothing is installed
#     by a refused call. Catches the FAKE ACCEPTING A NON-ADMIN INSTALL, and
#     a check of the first repository only.
#   * test_other_refusals: a repository of another account (last position),
#     a permission the App does not ask for (actions:write, contents:write;
#     last position), an unknown repository and an empty list are refused.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_github import AppCredentials, GitHubAppClient, ManualUnixClock, get_repository

from komira_github_fake import FakeGitHub, app_public_key_from_pkcs8


comptime NOW: Int64 = 1_790_856_000


def _key() raises -> List[UInt8]:
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _names(a: String, b: String = String("")) -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    return out^


def _ids(a: Int64, b: Int64 = 0, c: Int64 = 0) -> List[Int64]:
    var out = List[Int64]()
    out.append(a)
    if b > 0:
        out.append(b)
    if c > 0:
        out.append(c)
    return out^


def _perms() -> List[String]:
    var p = List[String]()
    p.append(String("metadata:read"))
    p.append(String("contents:read"))
    return p^


def _refusal(mut fake: FakeGitHub, account: String, by: String, var ids: List[Int64], var perms: List[String]) -> String:
    try:
        _ = fake.state.install(account, by, ids^, perms^)
    except e:
        return String(e)
    return String("")


def test_admin_installs() raises:
    var fake = FakeGitHub(String("12345"), app_public_key_from_pkcs8(_key()), NOW)
    var a = fake.state.add_repo("alice", "app1", _names("alice"))
    var b = fake.state.add_repo("alice", "app2", _names("alice", "carol"))
    var inst = fake.state.install("alice", "alice", _ids(a, b), _perms())
    assert_equal(len(fake.state.installations), 1)
    assert_equal(len(fake.state.installations[0].repo_ids), 2)
    assert_equal(fake.state.installations[0].installed_by, String("alice"))
    var client = GitHubAppClient[FakeGitHub, ManualUnixClock](fake^, AppCredentials(String("12345"), _key()), ManualUnixClock(NOW))
    assert_equal(client.send(inst, get_repository("alice", "app1")).status, 200)
    assert_equal(client.send(inst, get_repository("alice", "app2")).status, 200)
    print("  test_admin_installs PASS")


def test_non_admin_refused() raises:
    var fake = FakeGitHub(String("12345"), app_public_key_from_pkcs8(_key()), NOW)
    var r1 = fake.state.add_repo("acme", "one", _names("owner", "carol"))
    var r2 = fake.state.add_repo("acme", "two", _names("owner", "carol"))
    var r3 = fake.state.add_repo("acme", "three", _names("owner", "dave"))
    fake.state.set_collaborator(r1, "bob", "write")
    var why = _refusal(fake, "acme", "bob", _ids(r1), _perms())
    assert_true(why.find("bob does not administer acme/one") >= 0, "a write collaborator is refused")
    why = _refusal(fake, "acme", "carol", _ids(r1, r2, r3), _perms())
    assert_true(why.find("carol does not administer acme/three") >= 0, "the last repository is checked")
    why = _refusal(fake, "acme", "dave", _ids(r1, r2, r3), _perms())
    assert_true(why.find("dave does not administer acme/one") >= 0, "the first repository is checked")
    assert_equal(len(fake.state.installations), 0, "nothing installed by a refused call")
    assert_equal(_refusal(fake, "acme", "owner", _ids(r1, r2, r3), _perms()), String(""), "the owner may")
    print("  test_non_admin_refused PASS")


def test_other_refusals() raises:
    var fake = FakeGitHub(String("12345"), app_public_key_from_pkcs8(_key()), NOW)
    var a = fake.state.add_repo("alice", "app1", _names("alice"))
    var x = fake.state.add_repo("mallory", "x", _names("alice", "mallory"))
    var refused = String("")
    if _refusal(fake, "alice", "alice", _ids(a, x), _perms()).byte_length() == 0:
        refused += "foreign-repo "
    var p = _perms()
    p.append(String("actions:write"))
    if _refusal(fake, "alice", "alice", _ids(a), p^).byte_length() == 0:
        refused += "actions-write "
    var p2 = _perms()
    p2.append(String("contents:write"))
    if _refusal(fake, "alice", "alice", _ids(a), p2^).byte_length() == 0:
        refused += "contents-write "
    if _refusal(fake, "alice", "alice", _ids(a, 99999), _perms()).byte_length() == 0:
        refused += "unknown-repo "
    if _refusal(fake, "alice", "alice", List[Int64](), _perms()).byte_length() == 0:
        refused += "empty "
    assert_equal(refused, String(""), "each is refused")
    assert_equal(len(fake.state.installations), 0)
    var p3 = List[String]()
    p3.append(String("checks:write"))
    p3.append(String("actions:read"))
    assert_equal(_refusal(fake, "alice", "alice", _ids(a), p3^), String(""), "permissions the App asks for")
    print("  test_other_refusals PASS")


def main() raises:
    test_admin_installs()
    test_non_admin_refused()
    test_other_refusals()
    print("PASS komira_github_fake install")
