# =============================================================================
# src/komira_http/tests/test_redirect_policy.mojo — the shared redirect
#   POLICY (`client/redirect_policy.mojo`), pinned as a unit.
# =============================================================================
#
# The policy was lifted out of `OciCopier` so that a second client (the package
# registry uploads) can follow redirects without a second copy of the rules. The
# LOOP stayed in each client. So this file pins the decisions themselves; the
# OCI copy tests (`komira_oci/tests/test_oci_copy_blob_redirect.mojo`, unchanged
# by the lift) pin that `OciCopier` still routes through them.
#
# THE ROWS
#   (1) the status predicate: exactly 301/302/303/307/308, and the look-alikes
#       that are NOT a URL to follow (300, 304, 305, 306) are refused;
#   (2) the hop budget is the one the OCI loop test is sized against;
#   (3) every `Location` shape: the three followed ones split host from path
#       with the query intact, and each refusal comes back as its own KIND —
#       never a raise, never a guess;
#   (4) ★ THE CREDENTIAL ROW — a `Basic` Authorization value (Artifact
#       Registry's `*.pkg.dev` shape) is DROPPED on a cross-host redirect and
#       kept on a same-host one; the rule is not bearer-specific;
#   (5) an A -> B -> B chain never walks the credential onto B, and a chain
#       that comes BACK to A gets it back: the comparison is against the
#       ORIGINAL host at every hop;
#   (6) the host comparison is exact bytes — a case-variant is withheld the
#       credential (fails closed);
#   (7) the Authorization header is recognised in any case, and nothing else
#       is mistaken for it.
#
# Hermetic: pure functions, no transport, no network. Mojo 1.0 (def-only).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http.client.redirect_policy import (
    MAX_REDIRECT_HOPS,
    REDIRECT_REFUSED_EMPTY_HOST,
    REDIRECT_REFUSED_NO_LOCATION,
    REDIRECT_REFUSED_NO_PATH,
    REDIRECT_REFUSED_PLAINTEXT,
    REDIRECT_REFUSED_UNRESOLVABLE,
    REDIRECT_RESOLVED,
    authorization_for_hop,
    carries_credential,
    is_authorization_header,
    is_redirect_status,
    resolve_redirect_location,
)


comptime _INDEX: String = "us-central1-python.pkg.dev"
comptime _STORAGE: String = "storage.googleapis.com"
# `Basic base64("oauth2accesstoken:<token>")` — the shape Artifact Registry's
# `*.pkg.dev` endpoints take. The token part is a fixture, not a credential.
comptime _BASIC: String = "Basic b2F1dGgyYWNjZXNzdG9rZW46eWEyOS5maXh0dXJl"


# =============================================================================
# (1) the status predicate.
# =============================================================================


def test_redirect_statuses_are_exactly_the_five() raises:
    assert_true(is_redirect_status(301), "301 Moved Permanently")
    assert_true(is_redirect_status(302), "302 Found")
    assert_true(is_redirect_status(303), "303 See Other")
    assert_true(is_redirect_status(307), "307 Temporary Redirect")
    assert_true(is_redirect_status(308), "308 Permanent Redirect")
    # Look-alikes in the 3xx range that name no single URL to follow.
    assert_false(is_redirect_status(300), "300 Multiple Choices is not followed")
    assert_false(is_redirect_status(304), "304 Not Modified is not a redirect")
    assert_false(is_redirect_status(305), "305 Use Proxy is not followed")
    assert_false(is_redirect_status(306), "306 is unused")
    # And the statuses callers use as control flow stay theirs.
    assert_false(is_redirect_status(200), "200")
    assert_false(is_redirect_status(201), "201")
    assert_false(is_redirect_status(202), "202")
    assert_false(is_redirect_status(404), "404 means 'not there', not 'go'")
    print("  test_redirect_statuses_are_exactly_the_five: PASS")


# =============================================================================
# (2) the hop budget.
# =============================================================================


def test_hop_budget_is_five() raises:
    # `test_oci_copy_blob_redirect::test_redirect_loop_is_bounded` queues TEN
    # hops and expects the budget to fire first; a budget raised past ten
    # would turn that row into a scripted-queue underflow instead.
    assert_equal(MAX_REDIRECT_HOPS, 5, "the shared hop budget")
    print("  test_hop_budget_is_five: PASS")


# =============================================================================
# (3) every `Location` shape.
# =============================================================================


def test_absolute_https_location_changes_the_host() raises:
    var t = resolve_redirect_location(
        _INDEX, String("https://") + _STORAGE + String("/b/o?sig=deadbeef&x=1")
    )
    assert_equal(t.kind, REDIRECT_RESOLVED, "an absolute https url is followed")
    assert_true(t.is_resolved(), "is_resolved agrees with the kind")
    assert_equal(t.host, _STORAGE, "the host is the url's")
    assert_equal(
        t.path,
        String("/b/o?sig=deadbeef&x=1"),
        "the path keeps its query — a signed url's signature lives there",
    )
    print("  test_absolute_https_location_changes_the_host: PASS")


def test_scheme_relative_location_is_not_read_as_a_path() raises:
    var t = resolve_redirect_location(
        _INDEX, String("//") + _STORAGE + String("/signed")
    )
    assert_equal(t.kind, REDIRECT_RESOLVED, "a scheme-relative url is followed")
    assert_equal(
        t.host,
        _STORAGE,
        "`//host/path` names a HOST — reading it as a path on the current host"
        " would send the request to the wrong server",
    )
    assert_equal(t.path, String("/signed"), "and its path")
    print("  test_scheme_relative_location_is_not_read_as_a_path: PASS")


def test_absolute_path_location_stays_on_the_current_host() raises:
    var loc = String(
        "/artifacts-downloads/namespaces/p/repositories/r/downloads/TOKEN?a=b"
    )
    var t = resolve_redirect_location(_INDEX, loc)
    assert_equal(t.kind, REDIRECT_RESOLVED, "an absolute path is followed")
    assert_equal(t.host, _INDEX, "resolved against the host that issued it")
    assert_equal(t.path, loc, "the path verbatim, query included")
    print("  test_absolute_path_location_stays_on_the_current_host: PASS")


def test_every_refusal_is_its_own_kind_with_nothing_to_follow() raises:
    var empty = resolve_redirect_location(_INDEX, String(""))
    assert_equal(empty.kind, REDIRECT_REFUSED_NO_LOCATION, "no Location")

    var plain = resolve_redirect_location(
        _INDEX, String("http://") + _STORAGE + String("/cleartext")
    )
    assert_equal(
        plain.kind,
        REDIRECT_REFUSED_PLAINTEXT,
        "a plaintext url is REFUSED, not upgraded and not followed",
    )

    var shouting = resolve_redirect_location(
        _INDEX, String("HTTP://") + _STORAGE + String("/cleartext")
    )
    assert_equal(
        shouting.kind,
        REDIRECT_REFUSED_UNRESOLVABLE,
        "scheme matching is exact: an upper-case plaintext scheme is refused"
        " too — it is never read as a path, never followed",
    )

    var host_only = resolve_redirect_location(
        _INDEX, String("https://") + _STORAGE
    )
    assert_equal(
        host_only.kind, REDIRECT_REFUSED_NO_PATH, "a host root is not a resource"
    )
    var host_query = resolve_redirect_location(
        _INDEX, String("https://") + _STORAGE + String("?x=1")
    )
    assert_equal(
        host_query.kind,
        REDIRECT_REFUSED_NO_PATH,
        "a query with no path is still a host root",
    )
    var scheme_rel_host_only = resolve_redirect_location(
        _INDEX, String("//") + _STORAGE
    )
    assert_equal(
        scheme_rel_host_only.kind,
        REDIRECT_REFUSED_NO_PATH,
        "the scheme-relative form refuses a host root the same way",
    )

    var no_host = resolve_redirect_location(_INDEX, String("https:///path"))
    assert_equal(no_host.kind, REDIRECT_REFUSED_EMPTY_HOST, "an empty host")

    var relative = resolve_redirect_location(_INDEX, String("next/hop"))
    assert_equal(
        relative.kind,
        REDIRECT_REFUSED_UNRESOLVABLE,
        "a path-RELATIVE location is refused rather than guessed",
    )

    # A refusal carries nothing a careless caller could follow anyway.
    assert_false(plain.is_resolved(), "a refusal is not resolved")
    assert_equal(plain.host, String(""), "a refusal names no host")
    assert_equal(plain.path, String(""), "a refusal names no path")
    print("  test_every_refusal_is_its_own_kind_with_nothing_to_follow: PASS")


# =============================================================================
# (4) ★ THE CREDENTIAL ROW — Basic auth is dropped on a cross-host redirect.
# =============================================================================


def test_basic_authorization_is_dropped_on_a_cross_host_redirect() raises:
    assert_equal(
        authorization_for_hop(_INDEX, _STORAGE, _BASIC),
        String(""),
        "A `Basic` CREDENTIAL MINTED FOR THE PACKAGE INDEX MUST NOT REACH THE"
        " STORAGE HOST IT REDIRECTS TO — the rule is about the Authorization"
        " VALUE, not about bearer tokens",
    )
    assert_false(
        carries_credential(_INDEX, _STORAGE), "the predicate agrees"
    )
    assert_equal(
        authorization_for_hop(_INDEX, _INDEX, _BASIC),
        _BASIC,
        "a SAME-host hop keeps it byte-for-byte — dropping it unconditionally"
        " would break every server that redirects within itself and still"
        " authorizes",
    )
    assert_equal(
        authorization_for_hop(_INDEX, _STORAGE, String("Bearer ya29.fixture")),
        String(""),
        "and a bearer is scoped by exactly the same rule",
    )
    print("  test_basic_authorization_is_dropped_on_a_cross_host_redirect: PASS")


# =============================================================================
# (5) the comparison is against the ORIGINAL host, at every hop.
# =============================================================================


def test_the_credential_follows_the_original_host_not_the_previous_hop() raises:
    # A client's loop: resolve each Location against the CURRENT host, but ask
    # the credential question against the ORIGINAL one.
    var original = _INDEX
    var current = original.copy()
    var locations = List[String]()
    locations.append(String("https://") + _STORAGE + String("/first"))  # A -> B
    locations.append(String("/second"))  # B -> B (relative, so on B)
    locations.append(String("https://") + _INDEX + String("/third"))  # B -> A
    var sent = List[String]()
    var hosts = List[String]()
    for i in range(len(locations)):
        var t = resolve_redirect_location(current, locations[i])
        assert_true(t.is_resolved(), "every hop in this chain is followable")
        sent.append(authorization_for_hop(original, t.host, _BASIC))
        hosts.append(t.host.copy())
        current = t.host.copy()

    assert_equal(hosts[0], _STORAGE, "hop 1 left the index")
    assert_equal(sent[0], String(""), "hop 1 (A -> B) carries nothing")
    assert_equal(hosts[1], _STORAGE, "hop 2 stayed on the storage host")
    assert_equal(
        sent[1],
        String(""),
        "HOP 2 (B -> B) CARRIES NOTHING — against the PREVIOUS hop it would"
        " look 'same host' and hand the index credential to B",
    )
    assert_equal(hosts[2], _INDEX, "hop 3 came back to the index")
    assert_equal(
        sent[2],
        _BASIC,
        "hop 3 (B -> A) is on the host the credential was minted for",
    )
    print(
        "  test_the_credential_follows_the_original_host_not_the_previous_hop:"
        " PASS"
    )


# =============================================================================
# (6) exact-bytes host comparison fails CLOSED.
# =============================================================================


def test_host_comparison_is_exact_and_fails_closed() raises:
    assert_false(
        carries_credential(_INDEX, String("US-CENTRAL1-PYTHON.PKG.DEV")),
        "a case-variant of the same host is withheld the credential — the"
        " hop answers 401 and says so, which is the safe direction",
    )
    assert_false(
        carries_credential(_INDEX, _INDEX + String(":443")),
        "an explicit port is a different string, and is withheld too",
    )
    assert_false(
        carries_credential(_INDEX, String("evil-") + _INDEX),
        "a prefix-extended host is not the host",
    )
    assert_false(
        carries_credential(_INDEX, _INDEX + String(".evil.example")),
        "a suffix-extended host is not the host",
    )
    print("  test_host_comparison_is_exact_and_fails_closed: PASS")


# =============================================================================
# (7) recognising the Authorization header.
# =============================================================================


def test_authorization_header_is_recognised_in_any_case() raises:
    assert_true(is_authorization_header(String("authorization")), "lower")
    assert_true(is_authorization_header(String("Authorization")), "canonical")
    assert_true(is_authorization_header(String("AUTHORIZATION")), "upper")
    assert_true(is_authorization_header(String("aUtHoRiZaTiOn")), "mixed")
    assert_false(is_authorization_header(String("accept")), "accept")
    assert_false(is_authorization_header(String("")), "empty")
    assert_false(
        is_authorization_header(String("authorizatio")), "a prefix is not it"
    )
    assert_false(
        is_authorization_header(String("authorizations")), "nor an extension"
    )
    assert_false(
        is_authorization_header(String("x-authorization")), "nor a suffix match"
    )
    print("  test_authorization_header_is_recognised_in_any_case: PASS")


def main() raises:
    test_redirect_statuses_are_exactly_the_five()
    test_hop_budget_is_five()
    test_absolute_https_location_changes_the_host()
    test_scheme_relative_location_is_not_read_as_a_path()
    test_absolute_path_location_stays_on_the_current_host()
    test_every_refusal_is_its_own_kind_with_nothing_to_follow()
    test_basic_authorization_is_dropped_on_a_cross_host_redirect()
    test_the_credential_follows_the_original_host_not_the_previous_hop()
    test_host_comparison_is_exact_and_fails_closed()
    test_authorization_header_is_recognised_in_any_case()
    print("test_redirect_policy: ALL PASS")
