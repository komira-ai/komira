# TestAuthVerifier (a test/dev fixture). What each case catches:
# - the right password is accepted, per user (a verifier that checks only the
#   username, or only that some user has the password, fails);
# - a wrong password, a prefix of the right one, a longer one that starts with
#   it, a different case, and the empty password are refused (a comparison
#   limited to the shorter length, or to the first block, accepts one);
# - a missing user is refused, including with another user's password and with
#   the empty name;
# - add_user for an existing name replaces the password: the old one is
#   refused and the new one accepted;
# - the trait is usable through a generic function, as a server uses it;
# - a copy keeps the table.
# Constant time is a property of the comparison and is not measurable by an
# assertion; the cases above pin the results every such comparison must give.

from std.testing import assert_false, assert_true

from komira_mail_auth import TestAuthVerifier, MailAuthVerifier


def _check[V: MailAuthVerifier](v: V, user: String, pw: String) -> Bool:
    return v.verify(user, pw)


def _table() -> TestAuthVerifier:
    var v = TestAuthVerifier()
    v.add_user("alice", "correct horse")
    v.add_user("bob", "battery staple")
    return v^


def test_accepts_right() raises:
    var v = _table()
    assert_true(v.verify("alice", "correct horse"))
    assert_true(v.verify("bob", "battery staple"))
    assert_true(_check(v.copy(), "alice", "correct horse"))


def test_rejects_wrong() raises:
    var v = _table()
    assert_false(v.verify("alice", "battery staple"))
    assert_false(v.verify("alice", "wrong"))
    assert_false(v.verify("alice", "correct hors"))
    assert_false(v.verify("alice", "correct horse!"))
    assert_false(v.verify("alice", "correct horse" + String(" and more")))
    assert_false(v.verify("alice", "Correct horse"))
    assert_false(v.verify("alice", ""))
    assert_false(v.verify("bob", "correct horse"))


def test_rejects_missing_user() raises:
    var v = _table()
    assert_false(v.verify("carol", "correct horse"))
    assert_false(v.verify("carol", ""))
    assert_false(v.verify("", "correct horse"))
    assert_false(v.verify("Alice", "correct horse"))
    assert_false(v.verify("alic", "correct horse"))
    assert_false(TestAuthVerifier().verify("alice", "correct horse"))


def test_replace() raises:
    var v = _table()
    v.add_user("alice", "new password")
    assert_false(v.verify("alice", "correct horse"))
    assert_true(v.verify("alice", "new password"))
    assert_true(v.verify("bob", "battery staple"))


def test_unknown_user_cannot_pass_with_decoy() raises:
    # The unknown-user path compares against a decoy digest; no password may
    # make it succeed.
    var v = _table()
    assert_false(v.verify("carol", "komira_mail_auth: unknown user"))


def main() raises:
    test_accepts_right()
    test_rejects_wrong()
    test_rejects_missing_user()
    test_replace()
    test_unknown_user_cannot_pass_with_decoy()
    print("test_test_auth_verifier: OK")
