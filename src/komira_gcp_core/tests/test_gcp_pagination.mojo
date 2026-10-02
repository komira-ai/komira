# =============================================================================
# test_gcp_pagination.mojo — the pure pageToken paging pieces.
# =============================================================================
#
# This package owns no transport (the one transport seam is komira_http's
# `Connector`), so the walk below is the loop a generated List caller writes:
# `PageCursor` for the bookkeeping, `with_page_token` for the next URL,
# `next_page_token` for the body. It records every URL it would have sent, so
# the assertions are about the requests issued (no pageToken on page 1, the
# previous nextPageToken, percent-encoded, on each later page).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_gcp_core import (
    PageCursor,
    gcp_status_error,
    next_page_token,
    percent_encode,
    with_page_token,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _has(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


comptime _BASE = "https://run.googleapis.com/v2/projects/p/locations/l/services?pageSize=2"


def _walk(
    statuses: List[Int],
    bodies: List[String],
    rpc: String,
    mut urls: List[String],
    max_pages: Int = 1000,
) raises -> Int:
    """The generated caller's GET List loop, over scripted responses."""
    var cursor = PageCursor(max_pages)
    while not cursor.done():
        var i = len(urls)
        urls.append(with_page_token(_BASE, cursor.page_token()))
        if i >= len(bodies):
            raise Error("scripted walk: no more responses")
        var body = _bytes(bodies[i])
        if statuses[i] < 200 or statuses[i] >= 300:
            raise gcp_status_error("GET", rpc, statuses[i], body)
        cursor.advance(next_page_token(body))
    return cursor.pages()


def test_pages_follow_next_page_token() raises:
    var urls = List[String]()
    var pages = _walk(
        [200, 200, 200],
        [
            '{"services": [{}, {}], "nextPageToken": "abc+/="}',
            '{"services": [{}, {}], "nextPageToken": "def"}',
            '{"services": [{}]}',
        ],
        "Services.ListServices",
        urls,
    )
    assert_equal(pages, 3)
    assert_equal(len(urls), 3)
    assert_false(_has(urls[0], "pageToken"))
    assert_true(urls[1].endswith("?pageSize=2&pageToken=abc%2B%2F%3D"))
    assert_true(urls[2].endswith("?pageSize=2&pageToken=def"))


def test_empty_next_page_token_ends_paging() raises:
    var urls = List[String]()
    assert_equal(_walk([200], ['{"nextPageToken": ""}'], "S.List", urls), 1)


def test_a_repeated_token_stops_instead_of_looping() raises:
    var urls = List[String]()
    var raised = False
    try:
        _ = _walk(
            [200, 200, 200],
            ['{"nextPageToken": "same"}', '{"nextPageToken": "same"}', '{}'],
            "S.List",
            urls,
        )
    except e:
        raised = True
        assert_true(_has(String(e), "returned the page token it was sent"))
    assert_true(raised)
    assert_equal(len(urls), 2)


def test_max_pages_bounds_the_walk() raises:
    var urls = List[String]()
    var raised = False
    try:
        _ = _walk(
            [200, 200, 200],
            ['{"nextPageToken": "a"}', '{"nextPageToken": "b"}', '{"nextPageToken": "c"}'],
            "S.List",
            urls,
            max_pages=2,
        )
    except e:
        raised = True
        assert_true(_has(String(e), "more than 2 pages"))
    assert_true(raised)
    assert_equal(len(urls), 2)


def test_an_error_page_raises_without_echo() raises:
    var urls = List[String]()
    var raised = False
    try:
        _ = _walk(
            [200, 403],
            [
                '{"nextPageToken": "x"}',
                '{"error": {"code": 403, "status": "PERMISSION_DENIED", "message": "secret-project-name"}}',
            ],
            "Services.ListServices",
            urls,
        )
    except e:
        raised = True
        var text = String(e)
        assert_true(_has(text, "GET Services.ListServices: HTTP 403, PERMISSION_DENIED"))
        assert_false(_has(text, "secret-project-name"))
    assert_true(raised)
    assert_equal(len(urls), 2)


def test_next_page_token_edges() raises:
    assert_equal(next_page_token(_bytes('{"nextPageToken": "t1"}')), "t1")
    assert_equal(next_page_token(_bytes('{}')), "")
    assert_equal(next_page_token(_bytes('{"nextPageToken": null}')), "")
    for bad in ['{"nextPageToken": 7}', '[1]', 'not json ya29.SECRET']:
        var raised = False
        try:
            _ = next_page_token(_bytes(bad))
        except e:
            raised = True
            assert_false(_has(String(e), "SECRET"))
        assert_true(raised, String("accepted: ") + bad)
    var invalid = _bytes('{"nextPageToken": "')
    invalid.append(0xC0)
    invalid.append(0x80)
    for b in String('"}').as_bytes():
        invalid.append(b)
    var raised = False
    try:
        _ = next_page_token(invalid)
    except e:
        raised = True
        assert_true(_has(String(e), "not valid UTF-8"))
    assert_true(raised)


def test_page_cursor_for_body_tokens() raises:
    var c = PageCursor(max_pages=10)
    assert_equal(c.page_token(), "")
    c.advance("p2")
    assert_equal(c.page_token(), "p2")
    assert_false(c.done())
    c.advance("")
    assert_true(c.done())
    assert_equal(c.pages(), 2)
    var raised = False
    try:
        c.advance("again")
    except:
        raised = True
    assert_true(raised)


def test_url_helpers() raises:
    assert_equal(percent_encode("aZ09-._~"), "aZ09-._~")
    assert_equal(percent_encode("a b/+=&?"), "a%20b%2F%2B%3D%26%3F")
    assert_equal(with_page_token("https://h/x", ""), "https://h/x")
    assert_equal(with_page_token("https://h/x", "t"), "https://h/x?pageToken=t")
    assert_equal(with_page_token("https://h/x?a=1", "t"), "https://h/x?a=1&pageToken=t")


def test_deep_nesting_is_refused_not_recursed() raises:
    # A 2xx list page is as server-chosen as an error body: 100k levels must
    # be refused by komira_json's depth cap (MAX_PARSE_DEPTH = 64), not
    # parsed. The refusal names the byte count and komira_json's reason and
    # nothing of the body: the marker string after the brackets never shows.
    var deep = List[UInt8](capacity=100_020)
    for _ in range(100_000):
        deep.append(UInt8(ord("[")))
    for c in String('"SECRET-MARKER"').as_bytes():
        deep.append(c)
    var raised = False
    try:
        _ = next_page_token(deep)
    except e:
        raised = True
        var m = String(e)
        assert_true(_has(m, "100015-byte"), m)
        assert_true(_has(m, "nesting deeper than the limit of 64"), m)
        assert_false(_has(m, "[["), m)
        assert_false(_has(m, "SECRET"), m)
    assert_true(raised)
    # Depth 64 exactly is read; 65 is refused.
    var at = String('{"nextPageToken": "t", "x": ')
    var over = String('{"nextPageToken": "t", "x": ')
    for _ in range(63):
        at += "["
    for _ in range(64):
        over += "["
    for _ in range(63):
        at += "]"
    for _ in range(64):
        over += "]"
    at += "}"
    over += "}"
    assert_equal(next_page_token(_bytes(at)), "t")
    var refused = False
    try:
        _ = next_page_token(_bytes(over))
    except e:
        refused = True
        assert_true(_has(String(e), "nesting deeper than the limit of 64"), String(e))
    assert_true(refused, "depth 65 was parsed")
    # The same depth inside a token string is only a long token.
    var s = String('{"nextPageToken": "')
    for _ in range(1000):
        s += "["
    s += '"}'
    assert_equal(next_page_token(_bytes(s)).byte_length(), 1000)


def test_escaped_quote_keeps_the_string_open() raises:
    # The depth limit must honour `\"`. Each case is wrong in a DIFFERENT
    # direction under a parser that treats `\"` as the end of the string.
    #
    # (a) 100 `[` that really sit inside the token string, after a `\"`. A
    # guard that ended the string at `\"` would count them and refuse a
    # valid page.
    var a = String('{"nextPageToken": "a\\"')
    for _ in range(100):
        a += "["
    a += '"}'
    var tok = next_page_token(_bytes(a))
    assert_equal(tok.byte_length(), 102)
    assert_true(tok.startswith('a"['))
    # (b) 100 levels of REAL nesting that a guard which ended the string at
    # `\"` would mis-pair as string content: after `"x\""` it would see an
    # extra quote, open a string at `"b"`'s closing quote and never close it,
    # so the brackets after it would go uncounted and slip past the
    # depth limit. The real parser counts them and refuses.
    var b = String('{"nextPageToken": "t", "a": "x\\"", "b": ')
    for _ in range(100):
        b += "["
    for _ in range(100):
        b += "]"
    b += "}"
    var raised = False
    try:
        _ = next_page_token(_bytes(b))
    except e:
        raised = True
        assert_false(_has(String(e), "[["), String(e))
    assert_true(raised, "real nesting past the limit hidden behind \\\" was parsed")


def main() raises:
    test_pages_follow_next_page_token()
    test_empty_next_page_token_ends_paging()
    test_a_repeated_token_stops_instead_of_looping()
    test_max_pages_bounds_the_walk()
    test_an_error_page_raises_without_echo()
    test_next_page_token_edges()
    test_page_cursor_for_body_tokens()
    test_url_helpers()
    test_deep_nesting_is_refused_not_recursed()
    test_escaped_quote_keeps_the_string_open()
    print("all gcp pagination tests passed")
