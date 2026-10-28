# =============================================================================
# test_auth_header.mojo -- the header a provider supplies, and the checks on it.
# =============================================================================
#
#   NoAuth             supplies no header.
#   StaticAuthHeader   supplies the header it was built with, unchanged, on every
#                      call; building one with a bad header fails.
#   validation         a name must be an HTTP token (a space, a colon, a line
#                      break and non-ASCII are refused), not empty, not over
#                      128 bytes, and not a header the transport writes itself in
#                      any case; a value must be non-empty, not over 8192 bytes
#                      and free of control bytes (a tab is allowed). Each limit is
#                      tested on both sides. No refusal quotes the value, which
#                      is a credential.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg_llm import (
    AUTH_HEADER_MAX_NAME_BYTES,
    AUTH_HEADER_MAX_VALUE_BYTES,
    AuthHeader,
    AuthHeaderProvider,
    NoAuth,
    StaticAuthHeader,
    validate_auth_header,
)


def _header_of[P: AuthHeaderProvider](p: P) raises -> Optional[AuthHeader]:
    return p.header()


def _refusal(name: String, value: String) -> String:
    try:
        validate_auth_header(AuthHeader(name, value))
    except e:
        return String(e)
    return String()


def test_no_auth_supplies_nothing() raises:
    assert_false(Bool(_header_of(NoAuth())))


def test_a_static_header_is_supplied_unchanged_every_time() raises:
    var p = StaticAuthHeader("X-Credential", "scheme abc/+=")
    for _ in range(3):
        var h = p.header()
        assert_true(Bool(h))
        assert_equal(h.value().name, "X-Credential")
        assert_equal(h.value().value, "scheme abc/+=")


def test_a_static_header_is_checked_when_built() raises:
    with assert_raises(contains="not an HTTP token"):
        _ = StaticAuthHeader("bad name", "v")
    with assert_raises(contains="control byte"):
        _ = StaticAuthHeader("X-Credential", "a\nb")


def test_a_valid_header_passes() raises:
    assert_equal(_refusal("X-Credential", "v"), "")
    assert_equal(_refusal("a!#$%&'*+-.^_`|~9Z", "v"), "")
    assert_equal(_refusal("X-Credential", "tab\tinside and spaces"), "")
    assert_equal(_refusal("X-Credential", "café"), "")


def test_the_name_must_be_a_token() raises:
    assert_true("empty" in _refusal("", "v"))
    var bad = List[String]()
    bad.append("has space")
    bad.append("colon:")
    bad.append("line\nbreak")
    bad.append("car\rriage")
    bad.append("quote\"")
    bad.append("paren(")
    bad.append("slash/")
    bad.append("é")
    bad.append("nul" + chr(0))
    for i in range(len(bad)):
        assert_true(
            "not an HTTP token" in _refusal(bad[i], "v"),
            "name " + String(i),
        )


def test_the_name_length_limit_holds_on_both_sides() raises:
    var at = String()
    for _ in range(AUTH_HEADER_MAX_NAME_BYTES):
        at += "a"
    assert_equal(_refusal(at, "v"), "")
    assert_true("longer than 128" in _refusal(at + "a", "v"))


def test_a_header_the_transport_writes_is_refused_in_any_case() raises:
    var owned = List[String]()
    owned.append("host")
    owned.append("Content-Length")
    owned.append("CONTENT-TYPE")
    owned.append("Accept")
    owned.append("Transfer-Encoding")
    owned.append("connection")
    owned.append("Upgrade")
    owned.append("eXpect")
    for i in range(len(owned)):
        assert_true(
            "writes itself" in _refusal(owned[i], "v"), owned[i]
        )
    # A name that merely begins with one is not one.
    assert_equal(_refusal("Host-Alias", "v"), "")
    assert_equal(_refusal("Acceptable", "v"), "")


def test_the_value_rules() raises:
    assert_true("empty" in _refusal("X-Credential", ""))
    var controls = List[String]()
    controls.append("a\rb")
    controls.append("a\nb")
    controls.append("a" + chr(0) + "b")
    controls.append("a" + chr(1) + "b")
    controls.append("a" + chr(31) + "b")
    controls.append("a" + chr(127) + "b")
    for i in range(len(controls)):
        assert_true(
            "control byte" in _refusal("X-Credential", controls[i]),
            "value " + String(i),
        )
    var at = String()
    for _ in range(AUTH_HEADER_MAX_VALUE_BYTES):
        at += "v"
    assert_equal(_refusal("X-Credential", at), "")
    assert_true("longer than 8192" in _refusal("X-Credential", at + "v"))


def test_a_refusal_never_quotes_the_value() raises:
    var secret = "s3cr3t-credential\n"
    var msg = _refusal("X-Credential", secret)
    assert_true(msg.byte_length() > 0)
    assert_false("s3cr3t" in msg, msg)
    var msg2 = _refusal("bad name", "s3cr3t-credential")
    assert_false("s3cr3t" in msg2, msg2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
