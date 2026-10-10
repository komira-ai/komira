# =============================================================================
# test_route_table.mojo — ResourceRouteTable: unrouted is DENY, the pattern
# grammar's edges, first match wins, non-canonical paths and malformed rows
# deny.
# =============================================================================
#
# Defects each test catches:
#   * an unrouted path, or a method that no row names, yields anything but
#     DENY (including a public decision for a missing row);
#   * a recorded refusal does not win over a broader row after it, or a
#     broader row placed first is shadowed (order not honoured);
#   * the segment count is not enforced, a `*` matches zero segments, a
#     `{name}<suffix>` capture accepts the bare suffix (an empty id), or a
#     one-letter capture name is read as a literal;
#   * a `//`, a trailing `/`, a missing leading `/`, or a `.` / `..` segment
#     (also spelled `%2e`) is routed instead of refused;
#   * a `{name}<suffix>` capture that does not compare every byte of the
#     suffix (one wrong byte at each position must miss);
#   * an escape other than `%2e` (`%3e`, `%2f`) is read as a dot, or an
#     escape is decoded before matching a literal;
#   * a malformed governed row (empty kind, a capture its pattern does not
#     have, a capture named twice, an empty capture name on a row that is not
#     kind-wide, a kind-wide row naming a capture) is served instead of
#     refused.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_authz_api import AuthzAction
from komira_resource_gate import (
    ROUTE_OUTCOME_DENY,
    ROUTE_OUTCOME_PUBLIC,
    ResourceRouteTable,
    RouteDecision,
    RouteRule,
    canonical_segments,
)


def _table() -> ResourceRouteTable:
    var rules = List[RouteRule]()
    rules.append(RouteRule.public_route(String("GET"), String("/")))
    rules.append(RouteRule.public_route(String("GET"), String("/health")))
    rules.append(
        RouteRule.deny_route(
            String("GET"), String("/repos/{repo}/admin"), String("not served")
        )
    )
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/repos/{repo}"),
            String("repo"),
            String("repo"),
            AuthzAction.read(),
        )
    )
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/repos/{repo}/*"),
            String("repo"),
            String("repo"),
            AuthzAction.read(),
        )
    )
    rules.append(
        RouteRule.governed(
            String("POST"),
            String("/git/{r}.git/upload"),
            String("repo"),
            String("r"),
            AuthzAction.write(),
        )
    )
    rules.append(
        RouteRule.on_kind(
            String("POST"), String("/repos"), String("repo"), AuthzAction.write()
        )
    )
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/boards/{board}/tasks/{task}"),
            String("board"),
            String("board"),
            AuthzAction.read(),
        )
    )
    # A wildcard row with no narrower row in front of it.
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/files/{f}/*"),
            String("file"),
            String("f"),
            AuthzAction.read(),
        )
    )
    # A three-byte capture segment, the shortest one there is.
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/tags/{t}"),
            String("tag"),
            String("t"),
            AuthzAction.read(),
        )
    )
    # Malformed governed rows: each must deny when it matches.
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/bad/kind/{x}"),
            String(""),
            String("x"),
            AuthzAction.read(),
        )
    )
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/bad/capture/{x}"),
            String("thing"),
            String("y"),
            AuthzAction.read(),
        )
    )
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/bad/twice/{x}/{x}"),
            String("thing"),
            String("x"),
            AuthzAction.read(),
        )
    )
    # A kind-wide row with an empty kind is malformed too.
    rules.append(
        RouteRule.on_kind(
            String("GET"),
            String("/bad/kwkind"),
            String(""),
            AuthzAction.read(),
        )
    )
    # `governed` with an empty `id_capture` is not a kind-wide row.
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/bad/empty/{q}"),
            String("thing"),
            String(""),
            AuthzAction.read(),
        )
    )
    # `{}` has no name, so it is a literal segment.
    rules.append(
        RouteRule.on_kind(
            String("GET"), String("/lit/{}"), String("thing"), AuthzAction.read()
        )
    )
    rules.append(
        RouteRule.on_kind(
            String("GET"), String("/lit2/{}x"), String("thing"), AuthzAction.read()
        )
    )
    # An unterminated `{` is a literal segment too.
    rules.append(
        RouteRule.on_kind(
            String("GET"), String("/brace/{abc"), String("thing"), AuthzAction.read()
        )
    )
    # A pattern that is not canonical matches nothing.
    rules.append(RouteRule.public_route(String("GET"), String("/open//x")))
    return ResourceRouteTable(rules^)


def _expect_deny(t: ResourceRouteTable, method: String, path: String) raises:
    var d = t.route(method, path)
    assert_equal(
        d.outcome(), ROUTE_OUTCOME_DENY, method + " " + path + " must deny"
    )


def _expect(
    t: ResourceRouteTable,
    method: String,
    path: String,
    action: String,
    kind: String,
    id: String,
) raises:
    var d = t.route(method, path)
    assert_true(d.is_governed(), method + " " + path + " must be governed")
    var r = d.requirement()
    assert_equal(r.action.name, action, path)
    assert_equal(r.resource.kind, kind, path)
    assert_equal(r.resource.id, id, path)


def test_unrouted_and_unnamed_method_deny() raises:
    var t = _table()
    _expect_deny(t, "GET", "/nothing/here")
    _expect_deny(t, "GET", "/healthz")
    _expect_deny(t, "DELETE", "/repos/acme")
    _expect_deny(t, "get", "/repos/acme")
    _expect_deny(t, "PUT", "/health")
    # An empty table refuses everything, the root included.
    var empty = ResourceRouteTable(List[RouteRule]())
    _expect_deny(empty, "GET", "/")
    _expect_deny(empty, "GET", "/health")


def test_public_rows() raises:
    var t = _table()
    assert_equal(t.route("GET", "/").outcome(), ROUTE_OUTCOME_PUBLIC)
    assert_equal(t.route("GET", "/health").outcome(), ROUTE_OUTCOME_PUBLIC)


def test_governed_rows() raises:
    var t = _table()
    _expect(t, "GET", "/repos/acme", "read", "repo", "acme")
    _expect(t, "POST", "/repos", "write", "repo", "")
    # The captured id is the segment as sent: not percent-decoded.
    _expect(t, "GET", "/repos/a%2Fb", "read", "repo", "a%2Fb")
    # Three dots is not a dot segment.
    _expect(t, "GET", "/repos/...", "read", "repo", "...")
    # An incomplete escape is an ordinary segment.
    _expect(t, "GET", "/repos/%2", "read", "repo", "%2")
    # An escape is a dot only as `%2e`: a different second or third byte is
    # an ordinary segment.
    _expect(t, "GET", "/repos/%3e", "read", "repo", "%3e")
    _expect(t, "GET", "/repos/%2f", "read", "repo", "%2f")
    # Only `%` starts an escape: another byte before `2e` is not a dot.
    _expect(t, "GET", "/repos/x2e", "read", "repo", "x2e")
    _expect(t, "GET", "/repos/a2eb2e", "read", "repo", "a2eb2e")
    # Other escapes are routed as raw bytes, never decoded: `adm%69n` is not
    # the literal `admin`, so the carve-out row does not refuse it.
    _expect(t, "GET", "/repos/acme/adm%69n", "read", "repo", "acme")
    # The container named by the row is the resource.
    _expect(t, "GET", "/boards/b1/tasks/t9", "read", "board", "b1")


def test_first_match_wins() raises:
    var t = _table()
    # The deny row precedes the wildcard row that would govern this path.
    _expect_deny(t, "GET", "/repos/acme/admin")
    _expect(t, "GET", "/repos/acme/admin2", "read", "repo", "acme")
    # Order matters the other way too: a broad row first shadows a deny row.
    var rules = List[RouteRule]()
    rules.append(
        RouteRule.governed(
            String("GET"),
            String("/repos/{repo}/*"),
            String("repo"),
            String("repo"),
            AuthzAction.read(),
        )
    )
    rules.append(
        RouteRule.deny_route(
            String("GET"), String("/repos/{repo}/admin"), String("too late")
        )
    )
    var shadowed = ResourceRouteTable(rules^)
    _expect(shadowed, "GET", "/repos/acme/admin", "read", "repo", "acme")


def test_segment_count_and_wildcard() raises:
    var t = _table()
    # `/repos/{repo}/*` needs at least one segment after the capture.
    _expect(t, "GET", "/repos/acme/a", "read", "repo", "acme")
    _expect(t, "GET", "/repos/acme/a/b/c", "read", "repo", "acme")
    _expect_deny(t, "GET", "/repos")
    _expect_deny(t, "GET", "/boards/b1/tasks")
    # `*` needs one or more segments: exactly the fixed part does not match.
    _expect(t, "GET", "/files/x/y", "read", "file", "x")
    _expect_deny(t, "GET", "/files/x")
    _expect_deny(t, "GET", "/boards/b1/tasks/t9/extra")


def test_suffix_capture() raises:
    var t = _table()
    _expect(t, "POST", "/git/acme.git/upload", "write", "repo", "acme")
    # One byte longer than the suffix: the shortest segment that matches.
    _expect(t, "POST", "/git/x.git/upload", "write", "repo", "x")
    # The bare suffix would capture an empty id: no match.
    _expect_deny(t, "POST", "/git/.git/upload")
    _expect_deny(t, "POST", "/git/acme.gi/upload")
    # One wrong byte at each position of the suffix `.git`, first to last.
    _expect_deny(t, "POST", "/git/acmeXgit/upload")
    _expect_deny(t, "POST", "/git/acme.Xit/upload")
    _expect_deny(t, "POST", "/git/acme.gXt/upload")
    _expect_deny(t, "POST", "/git/acme.gix/upload")
    _expect_deny(t, "POST", "/git/acme/upload")


def test_one_letter_capture_and_nameless_literal() raises:
    var t = _table()
    _expect(t, "POST", "/git/abc.git/upload", "write", "repo", "abc")
    _expect(t, "GET", "/tags/v1", "read", "tag", "v1")
    _expect(t, "GET", "/lit/{}", "read", "thing", "")
    _expect_deny(t, "GET", "/lit/anything")
    _expect(t, "GET", "/lit2/{}x", "read", "thing", "")
    _expect_deny(t, "GET", "/lit2/ax")
    _expect(t, "GET", "/brace/{abc", "read", "thing", "")
    _expect_deny(t, "GET", "/brace/xyz")


def test_non_canonical_paths_deny() raises:
    var t = _table()
    _expect_deny(t, "GET", "")
    _expect_deny(t, "GET", "health")
    # Without the leading `/` check this would read as `/health`.
    _expect_deny(t, "GET", "xhealth")
    _expect_deny(t, "GET", "//health")
    _expect_deny(t, "GET", "/health/")
    _expect_deny(t, "GET", "/repos//acme")
    _expect_deny(t, "GET", "/repos/acme//a")
    _expect_deny(t, "GET", "/repos/.")
    _expect_deny(t, "GET", "/repos/..")
    _expect_deny(t, "GET", "/repos/acme/../admin")
    _expect_deny(t, "GET", "/repos/%2e")
    _expect_deny(t, "GET", "/repos/%2E%2e")
    _expect_deny(t, "GET", "/repos/.%2e")
    _expect_deny(t, "GET", "/repos/acme/%2e%2e/admin")
    # A non-canonical pattern matches nothing, not even its collapsed form.
    _expect_deny(t, "GET", "/open/x")
    _expect_deny(t, "GET", "/open//x")


def test_canonical_segments() raises:
    var root = canonical_segments("/")
    assert_true(Bool(root))
    assert_equal(len(root.value()), 0)
    var two = canonical_segments("/a/bc")
    assert_true(Bool(two))
    assert_equal(len(two.value()), 2)
    assert_equal(two.value()[0], "a")
    assert_equal(two.value()[1], "bc")
    assert_false(Bool(canonical_segments("/a/")))
    assert_false(Bool(canonical_segments("")))
    assert_false(Bool(canonical_segments("/%2e%2e")))
    var dots3 = canonical_segments("/%2e%2e%2e")
    assert_true(Bool(dots3))


def test_malformed_rows_deny() raises:
    var t = _table()
    _expect_deny(t, "GET", "/bad/kind/k")
    _expect_deny(t, "GET", "/bad/capture/k")
    _expect_deny(t, "GET", "/bad/twice/k/k")
    _expect_deny(t, "GET", "/bad/empty/k")
    _expect_deny(t, "GET", "/bad/kwkind")


def test_denied_flag_wins_over_every_other_field() raises:
    # Rows built with the keyword constructor: `denied` refuses even when the
    # row also names a kind, a capture, or `public`.
    var rules = List[RouteRule]()
    rules.append(
        RouteRule(
            method=String("GET"),
            pattern=String("/x/{id}"),
            kind=String("thing"),
            id_capture=String("id"),
            action=AuthzAction.read(),
            kind_wide=False,
            public=False,
            denied=True,
            deny_reason=String("refused"),
        )
    )
    rules.append(
        RouteRule(
            method=String("GET"),
            pattern=String("/y"),
            kind=String(""),
            id_capture=String(""),
            action=AuthzAction.read(),
            kind_wide=False,
            public=True,
            denied=True,
            deny_reason=String("refused"),
        )
    )
    var t = ResourceRouteTable(rules^)
    _expect_deny(t, "GET", "/x/1")
    _expect_deny(t, "GET", "/y")


def test_kind_wide_flag_alone_makes_a_kind_wide_row() raises:
    # The same row with and without `kind_wide`: only the flag gives an empty
    # id, and a kind-wide row that also names a capture is malformed.
    var rules = List[RouteRule]()
    rules.append(
        RouteRule(
            method=String("GET"),
            pattern=String("/kw/{id}"),
            kind=String("thing"),
            id_capture=String("id"),
            action=AuthzAction.read(),
            kind_wide=True,
            public=False,
            denied=False,
            deny_reason=String(""),
        )
    )
    rules.append(
        RouteRule(
            method=String("GET"),
            pattern=String("/kw0/{id}"),
            kind=String("thing"),
            id_capture=String(""),
            action=AuthzAction.read(),
            kind_wide=False,
            public=False,
            denied=False,
            deny_reason=String(""),
        )
    )
    rules.append(
        RouteRule(
            method=String("GET"),
            pattern=String("/kw1/{id}"),
            kind=String("thing"),
            id_capture=String(""),
            action=AuthzAction.read(),
            kind_wide=True,
            public=False,
            denied=False,
            deny_reason=String(""),
        )
    )
    # A one-byte capture name: still a capture, so still malformed.
    rules.append(
        RouteRule(
            method=String("GET"),
            pattern=String("/kw2/{i}"),
            kind=String("thing"),
            id_capture=String("i"),
            action=AuthzAction.read(),
            kind_wide=True,
            public=False,
            denied=False,
            deny_reason=String(""),
        )
    )
    var t = ResourceRouteTable(rules^)
    _expect_deny(t, "GET", "/kw/1")
    _expect_deny(t, "GET", "/kw2/1")
    _expect_deny(t, "GET", "/kw0/1")
    _expect(t, "GET", "/kw1/1", "read", "thing", "")


def main() raises:
    test_unrouted_and_unnamed_method_deny()
    test_public_rows()
    test_governed_rows()
    test_first_match_wins()
    test_segment_count_and_wildcard()
    test_suffix_capture()
    test_one_letter_capture_and_nameless_literal()
    test_non_canonical_paths_deny()
    test_canonical_segments()
    test_malformed_rows_deny()
    test_denied_flag_wins_over_every_other_field()
    test_kind_wide_flag_alone_makes_a_kind_wide_row()
    print("PASS komira_resource_gate test_route_table")
