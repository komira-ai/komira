# =============================================================================
# komira_github/tests/test_token_cache.mojo -- reading GitHub's token answer
#   and the cache's refresh margin.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * test_read_answer: GitHub's documented 201 body gives the token and its
#     expiry in Unix seconds; a body with no token, an empty one, a
#     non-string one, a bad or missing `expires_at`, one already expired
#     (expires_at == now) or not JSON is refused as BAD_RESPONSE without
#     quoting the token.
#   * test_refresh_margin: `token_is_fresh` at expires_at - 301 (fresh),
#     - 300 and - 299 (stale). Catches REFRESH AT EXPIRY (fresh until
#     expires_at) and an off-by-one margin.
#   * test_cache_scopes: a whole-grant token and a scoped token of the same
#     installation are kept apart; `put` replaces only its own scope; `get`
#     after the margin returns nothing; `invalidate` drops every scope of
#     one installation and nothing of another.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_github import (
    INSTALLATION_TOKEN_REFRESH_MARGIN_S,
    InstallationToken,
    InstallationTokenCache,
    github_error_kind,
    read_installation_token,
    token_is_fresh,
)


comptime NOW: Int64 = 1_790_856_000  # 2026-10-01T12:00:00Z
comptime TOKEN = "ghs_16C7e42F292c6912E7710c838347Ae178B4a"


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _read(body: String, now: Int64 = NOW) -> String:
    try:
        var t = read_installation_token(_b(body), 7, String(""), now)
        return t.token + String(" ") + String(t.expires_at)
    except e:
        return String("REFUSED ") + String(e)


def test_read_answer() raises:
    var doc = String('{"token":"') + TOKEN + String(
        '","expires_at":"2026-10-01T13:00:00Z","permissions":{"issues":"write","contents":"read"},'
        + '"repository_selection":"selected"}'
    )
    assert_equal(_read(doc), String(TOKEN) + String(" ") + String(NOW + 3600))
    var bad = List[String]()
    bad.append(String('{"expires_at":"2026-10-01T13:00:00Z"}'))
    bad.append(String('{"token":"","expires_at":"2026-10-01T13:00:00Z"}'))
    bad.append(String('{"token":17,"expires_at":"2026-10-01T13:00:00Z"}'))
    bad.append(String('{"token":"') + TOKEN + String('"}'))
    bad.append(String('{"token":"') + TOKEN + String('","expires_at":"tomorrow"}'))
    bad.append(String('{"token":"') + TOKEN + String('","expires_at":1790859600}'))
    bad.append(String('{"token":"') + TOKEN + String('","expires_at":"2026-10-01T12:00:00Z"}'))
    bad.append(String("not json"))
    bad.append(String('["token"]'))
    var accepted = String("")
    var leaked = String("")
    for i in range(len(bad)):
        var r = _read(bad[i])
        if not r.startswith("REFUSED ") or github_error_kind(String(r[byte = 8 : r.byte_length()])) != "BAD_RESPONSE":
            accepted += String("[") + String(i) + String("] ")
        if r.find(TOKEN) >= 0:
            leaked += String("[") + String(i) + String("] ")
    assert_equal(accepted, String(""), "malformed answers are refused")
    assert_equal(leaked, String(""), "no refusal quotes the token")
    assert_true(_read(String('{"token":"t","expires_at":"2026-10-01T12:00:01Z"}')).startswith("t "), "1 s left is read")
    print("  test_read_answer PASS")


def test_refresh_margin() raises:
    assert_equal(INSTALLATION_TOKEN_REFRESH_MARGIN_S, 300)
    var exp = NOW + 3600
    assert_true(token_is_fresh(exp, exp - 301), "301 s left: fresh")
    assert_false(token_is_fresh(exp, exp - 300), "300 s left: refreshed")
    assert_false(token_is_fresh(exp, exp - 299), "299 s left: refreshed")
    assert_false(token_is_fresh(exp, exp), "at expiry: refreshed")
    print("  test_refresh_margin PASS")


def test_cache_scopes() raises:
    var cache = InstallationTokenCache()
    var scope = String('{"repository_ids":[5],"permissions":{"contents":"read"}}')
    cache.put(InstallationToken(String("whole-7"), 7, String(""), NOW + 3600))
    cache.put(InstallationToken(String("scoped-7"), 7, scope, NOW + 3600))
    cache.put(InstallationToken(String("whole-8"), 8, String(""), NOW + 3600))
    assert_equal(cache.get(7, String(""), NOW).value().token, String("whole-7"))
    assert_equal(cache.get(7, scope, NOW).value().token, String("scoped-7"))
    assert_false(Bool(cache.get(9, String(""), NOW)), "another installation")
    cache.put(InstallationToken(String("whole-7b"), 7, String(""), NOW + 4000))
    assert_equal(len(cache), 3, "put replaces its own scope")
    assert_equal(cache.get(7, String(""), NOW).value().token, String("whole-7b"))
    assert_equal(cache.get(7, scope, NOW).value().token, String("scoped-7"), "the other scope is kept")
    assert_true(Bool(cache.get(7, scope, NOW + 3299)), "fresh at 301 s left")
    assert_false(Bool(cache.get(7, scope, NOW + 3300)), "stale at 300 s left")
    cache.invalidate(7)
    assert_false(Bool(cache.get(7, String(""), NOW)), "invalidated")
    assert_false(Bool(cache.get(7, scope, NOW)), "every scope")
    assert_equal(cache.get(8, String(""), NOW).value().token, String("whole-8"), "another installation is kept")
    print("  test_cache_scopes PASS")


def main() raises:
    test_read_answer()
    test_refresh_margin()
    test_cache_scopes()
    print("PASS komira_github token cache")
