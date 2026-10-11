# =============================================================================
# test_presented_credential.mojo — the credential a `Principal` carries is
# readable only through `expose()` and never printable.
# =============================================================================
#
#   - `PresentedCredential` and `Principal` do not conform to `Writable`, the
#     trait every `print`, `String(...)` and formatting call goes through, so
#     none of them reaches the token. Declaring it (a `write_to` that prints
#     the value) turns this test red.
#   - `redacted()` is one fixed text with nothing of the value in it, not even
#     its length: two credentials of different lengths redact the same.
#   - `expose()` returns the value byte for byte.
#   - `with_presented` attaches the credential and keeps scheme, subject and
#     claims; a second call replaces the first credential.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_server.middleware import PresentedCredential, Principal

comptime _TOKEN = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1LTEifQ.c2ln"


def test_not_printable() raises:
    comptime cred_writable = conforms_to(PresentedCredential, Writable)
    comptime principal_writable = conforms_to(Principal, Writable)
    assert_false(cred_writable, "PresentedCredential must not be Writable")
    assert_false(principal_writable, "Principal must not be Writable")


def test_redacted_holds_nothing_of_the_value() raises:
    var long = PresentedCredential(String(_TOKEN))
    var short = PresentedCredential(String("x"))
    assert_equal(long.redacted(), String("PresentedCredential(<redacted>)"))
    assert_equal(short.redacted(), long.redacted(), "the length does not show")
    assert_false(String(_TOKEN) in long.redacted())


def test_expose_returns_the_value() raises:
    var cred = PresentedCredential(String(_TOKEN))
    assert_equal(cred.expose(), String(_TOKEN))
    assert_equal(PresentedCredential(String("")).expose(), String(""))


def test_with_presented_attaches_and_replaces() raises:
    var p = Principal(scheme=String("jwt"), subject=String("u-1")).with_claim(
        String("scope"), String("read")
    ).with_presented(PresentedCredential(String(_TOKEN)))
    assert_equal(p.scheme, String("jwt"))
    assert_equal(p.subject, String("u-1"))
    assert_equal(p.claims.get(String("scope")).value(), String("read"))
    assert_true(Bool(p.presented), "with_presented attaches the credential")
    assert_equal(p.presented.value().expose(), String(_TOKEN))

    var q = p^.with_presented(PresentedCredential(String("second")))
    assert_equal(q.presented.value().expose(), String("second"))
    assert_equal(q.claims.len(), 1, "replacing the credential keeps the claims")


def main() raises:
    test_not_printable()
    test_redacted_holds_nothing_of_the_value()
    test_expose_returns_the_value()
    test_with_presented_attaches_and_replaces()
    print("PASS test_presented_credential")
