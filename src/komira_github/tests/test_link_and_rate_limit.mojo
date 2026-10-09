# =============================================================================
# komira_github/tests/test_link_and_rate_limit.mojo -- the Link header and the
#   rate-limit verdicts and latch.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * test_link_github_example: GitHub's documented Link example (prev,
#     next, last, first; next in SECOND position) gives page 4; next in LAST
#     position, an unquoted rel, a rel list ("next last") and extra
#     parameters are read; a Link with no next (the last page) gives 0.
#     Catches a parser that reads only the first link-value, only quoted
#     rels, or `last` as `next`.
#   * test_link_page_parameter: only the `page` key is read (per_page=50
#     before page=3 gives 3: catches a suffix match on the key); a next link
#     without page, with page=0, page=07, a 10-digit page or a non-digit is
#     refused; two next links are refused.
#   * test_classify: each documented answer: retry-after (secondary, now +
#     value; 0 floored to 1 s), x-ratelimit-remaining 0 (primary, the reset
#     instant; a reset in the past floored to now + 1), a bare 429
#     (secondary, 60 s), a 403 naming a secondary limit (secondary, 60 s,
#     doubling with the streak, capped at 3600), and answers that are NOT
#     limits (a plain 403, a 404 with retry-after, remaining 1, a 200).
#   * test_latch: the latch refuses before the resume instant and allows at
#     it (`<` not `<=`), a primary limit holds only its own key while a
#     secondary one holds every key, a later instant is never shortened by
#     an earlier one, and a non-limit answer resets the secondary streak.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_github import (
    GitHubHeader,
    RATE_LIMIT_NONE,
    RATE_LIMIT_PRIMARY,
    RATE_LIMIT_SECONDARY,
    RateLimitLatch,
    RateLimitVerdict,
    classify_rate_limit,
    github_error_kind,
    link_next_page,
    secondary_backoff_s,
)


comptime NOW: Int64 = 1_800_000_000


def _next(link: String) -> String:
    try:
        return String(link_next_page(link))
    except e:
        return String("REFUSED ") + String(e)


def test_link_github_example() raises:
    var doc = String(
        '<https://api.github.com/repositories/1300192/issues?page=2>; rel="prev", '
        + '<https://api.github.com/repositories/1300192/issues?page=4>; rel="next", '
        + '<https://api.github.com/repositories/1300192/issues?page=515>; rel="last", '
        + '<https://api.github.com/repositories/1300192/issues?page=1>; rel="first"'
    )
    assert_equal(_next(doc), String("4"), "GitHub's documented example")
    assert_equal(
        _next(String('<https://x.example/a?page=9>; rel="last", <https://x.example/a?page=3>; rel="next"')),
        String("3"),
        "next in last position",
    )
    assert_equal(_next(String("<https://x.example/a?page=5>;rel=next")), String("5"), "unquoted rel")
    assert_equal(
        _next(String('<https://x.example/a?page=6>; title="a, b"; rel="next last"')),
        String("6"),
        "a rel list and a quoted comma",
    )
    assert_equal(
        _next(String('<https://x.example/a?page=1>; rel="prev", <https://x.example/a?page=5>; rel="last"')),
        String("0"),
        "no next: the last page",
    )
    assert_equal(_next(String('<https://x.example/a?page=5>; rel="nextpage"')), String("0"), "rel nextpage is not next")
    assert_equal(_next(String('<https://x.example/a?page=5>; rel="Next"')), String("5"), "rel is case-insensitive")
    print("  test_link_github_example PASS")


def test_link_page_parameter() raises:
    assert_equal(_next(String('<https://x.example/a?per_page=50&page=3>; rel="next"')), String("3"))
    assert_equal(_next(String('<https://x.example/a?page=3&per_page=50>; rel="next"')), String("3"))
    assert_equal(_next(String('<https://x.example/a?xpage=8&page=3>; rel="next"')), String("3"))
    var refused = List[String]()
    refused.append(String('<https://x.example/a?per_page=50>; rel="next"'))
    refused.append(String('<https://x.example/a?after=Y3Vyc29y>; rel="next"'))
    refused.append(String('<https://x.example/a?page=0>; rel="next"'))
    refused.append(String('<https://x.example/a?page=07>; rel="next"'))
    refused.append(String('<https://x.example/a?page=1234567890>; rel="next"'))
    refused.append(String('<https://x.example/a?page=3x>; rel="next"'))
    refused.append(String('<https://x.example/a?page=>; rel="next"'))
    refused.append(String('<https://x.example/a?page=2>; rel="next", <https://x.example/a?page=3>; rel="next"'))
    refused.append(String('https://x.example/a?page=2; rel="next"'))
    refused.append(String('<https://x.example/a?page=2; rel="next"'))
    var accepted = String("")
    for i in range(len(refused)):
        if not _next(refused[i]).startswith("REFUSED "):
            accepted += String("[") + String(i) + String("] ")
    assert_equal(accepted, String(""), "malformed next links are refused")
    var r0 = _next(refused[0])
    assert_equal(github_error_kind(String(r0[byte = 8 : r0.byte_length()])), String("BAD_RESPONSE"))
    print("  test_link_page_parameter PASS")


def _h(name: String, value: String) -> GitHubHeader:
    return GitHubHeader(name, value)


def _body(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    b.extend(Span(s.as_bytes()))
    return b^


def _v(status: Int, var headers: List[GitHubHeader], body: String, streak: Int = 0) -> RateLimitVerdict:
    return classify_rate_limit(status, headers, _body(body), NOW, streak)


def test_classify() raises:
    var h = List[GitHubHeader]()
    h.append(_h("Retry-After", "30"))
    var v = _v(403, h^, "{}")
    assert_equal(v.kind, RATE_LIMIT_SECONDARY)
    assert_equal(v.resume_at, NOW + 30)
    var h0 = List[GitHubHeader]()
    h0.append(_h("retry-after", "0"))
    assert_equal(_v(429, h0^, "{}").resume_at, NOW + 1, "retry-after 0 still waits 1 s")
    var hp = List[GitHubHeader]()
    hp.append(_h("x-ratelimit-remaining", "0"))
    hp.append(_h("x-ratelimit-reset", String(NOW + 900)))
    var vp = _v(403, hp^, "{}")
    assert_equal(vp.kind, RATE_LIMIT_PRIMARY)
    assert_equal(vp.resume_at, NOW + 900)
    var hpast = List[GitHubHeader]()
    hpast.append(_h("x-ratelimit-remaining", "0"))
    hpast.append(_h("x-ratelimit-reset", String(NOW - 5)))
    assert_equal(_v(429, hpast^, "{}").resume_at, NOW + 1, "a reset in the past waits 1 s")
    var bare = _v(429, List[GitHubHeader](), "{}")
    assert_equal(bare.kind, RATE_LIMIT_SECONDARY)
    assert_equal(bare.resume_at, NOW + 60)
    var msg = String('{"message":"You have exceeded a SECONDARY rate limit. Please wait."}')
    assert_equal(_v(403, List[GitHubHeader](), msg).kind, RATE_LIMIT_SECONDARY)
    assert_equal(_v(403, List[GitHubHeader](), msg, 0).resume_at, NOW + 60)
    assert_equal(_v(403, List[GitHubHeader](), msg, 1).resume_at, NOW + 120)
    assert_equal(_v(403, List[GitHubHeader](), msg, 2).resume_at, NOW + 240)
    assert_equal(_v(403, List[GitHubHeader](), msg, 30).resume_at, NOW + 3600)
    assert_equal(_v(403, List[GitHubHeader](), String('{"message":"abuse detection mechanism"}')).kind, RATE_LIMIT_SECONDARY)
    assert_equal(secondary_backoff_s(5), 1920)
    assert_equal(secondary_backoff_s(6), 3600)
    var not_limits = String("")
    if _v(403, List[GitHubHeader](), String('{"message":"Resource not accessible by integration"}')).kind != RATE_LIMIT_NONE:
        not_limits += "plain-403 "
    var h404 = List[GitHubHeader]()
    h404.append(_h("retry-after", "30"))
    if _v(404, h404^, "{}").kind != RATE_LIMIT_NONE:
        not_limits += "404 "
    var h1 = List[GitHubHeader]()
    h1.append(_h("x-ratelimit-remaining", "1"))
    if _v(403, h1^, "{}").kind != RATE_LIMIT_NONE:
        not_limits += "remaining-1 "
    var h200 = List[GitHubHeader]()
    h200.append(_h("x-ratelimit-remaining", "0"))
    if _v(200, h200^, "{}").kind != RATE_LIMIT_NONE:
        not_limits += "200 "
    assert_equal(not_limits, String(""), "answers that are not limits")
    print("  test_classify PASS")


def _refused(latch: RateLimitLatch, key: String, now: Int64) -> Bool:
    try:
        latch.check(key, now)
    except e:
        return github_error_kind(String(e)) == "RATE_LIMITED"
    return False


def test_latch() raises:
    var latch = RateLimitLatch()
    assert_false(_refused(latch, "installation:1", NOW), "nothing recorded")
    latch.record("installation:1", RateLimitVerdict(RATE_LIMIT_PRIMARY, NOW + 100))
    assert_true(_refused(latch, "installation:1", NOW + 99), "primary holds its key")
    assert_false(_refused(latch, "installation:1", NOW + 100), "and lets it go at the instant")
    assert_false(_refused(latch, "installation:2", NOW), "primary does not hold another key")
    latch.record("installation:1", RateLimitVerdict(RATE_LIMIT_PRIMARY, NOW + 50))
    assert_true(_refused(latch, "installation:1", NOW + 99), "an earlier instant does not shorten it")
    latch.record("installation:2", RateLimitVerdict(RATE_LIMIT_SECONDARY, NOW + 60))
    assert_equal(latch.secondary_streak, 1)
    assert_true(_refused(latch, "app", NOW + 59), "secondary holds every key")
    assert_true(_refused(latch, "installation:3", NOW + 59), "secondary holds every key")
    assert_false(_refused(latch, "installation:3", NOW + 60), "until its instant")
    latch.record("app", RateLimitVerdict(RATE_LIMIT_SECONDARY, NOW + 10))
    assert_equal(latch.secondary_streak, 2)
    assert_true(_refused(latch, "app", NOW + 59), "an earlier secondary instant does not shorten it")
    latch.record("app", RateLimitVerdict(RATE_LIMIT_NONE, 0))
    assert_equal(latch.secondary_streak, 0, "a non-limit answer resets the streak")
    print("  test_latch PASS")


def main() raises:
    test_link_github_example()
    test_link_page_parameter()
    test_classify()
    test_latch()
    print("PASS komira_github link and rate limit")
