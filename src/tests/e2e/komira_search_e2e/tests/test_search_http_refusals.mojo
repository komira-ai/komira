# =============================================================================
# test_search_http_refusals.mojo -- what the search front door refuses, and
# per-item bulk failure, as real HTTP requests
# =============================================================================
#
# Same fixture as test_search_http_front_door: a dispatcher over a
# `LocalFsConditionalStore` in TEST_TMPDIR behind a loopback `HttpServer`, and
# raw HTTP/1.1 requests over real sockets. The dispatcher is built with a 512
# byte body limit and a 4 line `_bulk` limit so the 413 cases are small.
#
#   * test_refusals_have_their_status_and_error_type -- one request per case,
#     each a fresh connection to the same server; each reply must carry the
#     status and the `error.type` below, and a body that is JSON with the same
#     `status`:
#       malformed JSON search body ............ 400 parse_exception
#       a `_bulk` whose last action has no source 400 parse_exception
#       an unsupported query option (min_score) 400 parse_exception
#       `?size=1`, `?from=5`, `?q=fox`, `?sort=n` 400 illegal_argument_exception
#         (parameters that would change the result set, refused rather than
#         ignored) -- but `?pretty` and `?refresh=true` are accepted (200)
#       an upper-case, a `_all`, a percent-escaped
#         and a comma list of indices ......... 400 invalid_index_name_exception
#       `/docs`, `/_cluster/health`, `/docs/_count`, `/docs/_search/extra`,
#         `/_bulk` (no index) ................. 404 not_found
#       GET and PUT on `_search` and `_bulk` .. 405 method_not_allowed, `allow: POST`
#       a body of 600 bytes ................... 413 content_too_long_exception
#       a `_bulk` of 5 lines (limit 4) ........ 413 content_too_long_exception
#     After the battery a search of the index answers 200 with total 0: no
#     refusal indexed anything, and the server went on serving. Catches a
#     refusal that becomes a 500, a 200 or a dropped connection, a wrong error
#     type, a missing `allow` header, and a refusal that writes before it
#     refuses.
#   * test_bulk_partial_success_over_http -- one `_bulk` of five lines-pairs in
#     which items 1 (no text field), 3 (a `create` action) and 4 (a source that
#     is not JSON) are bad. The reply is 200 with errors true and one item per
#     action in wire order: 201, 400, 400, 201, 400, each failed item keyed by
#     its own verb and carrying an error type. The two good documents are
#     searchable by their words, their `_source` byte-exact, and the three bad
#     ones are not. Catches a bad item failing the whole request, good items
#     lost with it, items out of order, and a bad document that is indexed.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_json import parse_json_value
from komira_runtime_paths import test_tmpdir

from komira_search_e2e.http_wire import (
    WireReply,
    exchange,
    new_front_door,
    post,
    request_bytes,
)

comptime _MAX_BODY = 512
comptime _MAX_BULK_LINES = 4


struct _Case(Copyable, Movable):
    var label: String
    var request: List[UInt8]
    var status: Int
    var error_type: String

    def __init__(out self, label: String, var request: List[UInt8], status: Int, error_type: String):
        self.label = label.copy()
        self.request = request^
        self.status = status
        self.error_type = error_type.copy()

    def __init__(out self, *, copy: Self):
        self.label = copy.label.copy()
        self.request = copy.request.copy()
        self.status = copy.status
        self.error_type = copy.error_type.copy()


def _padding(n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += String("a")
    return out^


def _cases() -> List[_Case]:
    var q = String('{"query":{"match":{"body":"fox"}}}')
    var out = List[_Case]()
    out.append(_Case("malformed json", post(String("/docs/_search"), String('{"query":')), 400, String("parse_exception")))
    out.append(_Case("dangling bulk action", post(String("/docs/_bulk"), String('{"index":{}}\n')), 400, String("parse_exception")))
    out.append(_Case(
        "min_score",
        post(String("/docs/_search"), String('{"query":{"match":{"body":"fox"}},"min_score":1}')),
        400, String("parse_exception"),
    ))
    var params = List[String]()
    params.append(String("size=1"))
    params.append(String("from=5"))
    params.append(String("q=fox"))
    params.append(String("sort=n"))
    for i in range(len(params)):
        out.append(_Case(
            "param " + params[i],
            post(String("/docs/_search?") + params[i], q),
            400, String("illegal_argument_exception"),
        ))
    var bad = List[String]()
    bad.append(String("/Docs/_search"))
    bad.append(String("/_all/_search"))
    bad.append(String("/%2e%2e/_search"))
    bad.append(String("/a,b/_bulk"))
    for i in range(len(bad)):
        out.append(_Case("index " + bad[i], post(bad[i], q), 400, String("invalid_index_name_exception")))
    var missing = List[String]()
    missing.append(String("/docs"))
    missing.append(String("/_cluster/health"))
    missing.append(String("/docs/_count"))
    missing.append(String("/docs/_search/extra"))
    missing.append(String("/_bulk"))
    for i in range(len(missing)):
        out.append(_Case("route " + missing[i], post(missing[i], q), 404, String("not_found")))
    var verbs = List[String]()
    verbs.append(String("GET"))
    verbs.append(String("PUT"))
    for v in range(len(verbs)):
        out.append(_Case(verbs[v] + " _search", request_bytes(verbs[v], String("/docs/_search"), String("")), 405, String("method_not_allowed")))
        out.append(_Case(verbs[v] + " _bulk", request_bytes(verbs[v], String("/docs/_bulk"), String("")), 405, String("method_not_allowed")))
    out.append(_Case(
        "body over the limit",
        post(String("/docs/_search"), String('{"query":{"match":{"body":"') + _padding(600) + String('"}}}')),
        413, String("content_too_long_exception"),
    ))
    var lines = String()
    for i in range(5):
        lines += String('{"index":{}}\n') if i % 2 == 0 else String('{"body":"a"}\n')
    out.append(_Case("bulk line limit", post(String("/docs/_bulk"), lines), 413, String("content_too_long_exception")))
    return out^


def test_refusals_have_their_status_and_error_type() raises:
    var root = test_tmpdir() + String("/refusals")
    var cases = _cases()
    var script = List[List[UInt8]]()
    for i in range(len(cases)):
        script.append(cases[i].request.copy())
    # The accepted look-alikes and the final empty-index search.
    var q = String('{"query":{"match":{"body":"fox"}}}')
    script.append(post(String("/docs/_search?pretty"), q))
    script.append(post(String("/docs/_search?refresh=true"), q))
    script.append(post(String("/docs/_search"), q))
    var dispatcher = new_front_door(root, String("node-a"), 1000, _MAX_BODY, _MAX_BULK_LINES)
    var replies = exchange(dispatcher^, script^)
    assert_equal(len(replies), len(cases) + 3, "one reply per request")
    for i in range(len(cases)):
        ref c = cases[i]
        ref r = replies[i]
        assert_equal(r.status, c.status, c.label + ": status")
        assert_true(
            r.head.find(String("content-type: application/json")) >= 0,
            c.label + ": JSON content type: " + r.head,
        )
        var root_json = parse_json_value(r.body)
        assert_equal(Int(root_json.get(String("status")).as_int64()), c.status, c.label + ": body status")
        assert_equal(
            root_json.get(String("error")).get(String("type")).as_string(),
            c.error_type,
            c.label + ": error type",
        )
        if c.status == 405:
            assert_true(r.head.find(String("allow: post")) >= 0, c.label + ": allow header: " + r.head)
    var n = len(cases)
    assert_equal(replies[n].status, 200, "?pretty is accepted")
    assert_equal(replies[n + 1].status, 200, "?refresh=true is accepted")
    var last = replies[n + 2].copy()
    assert_equal(last.status, 200, "search after the battery")
    var total = parse_json_value(last.body).get(String("hits")).get(String("total"))
    assert_equal(Int(total.get(String("value")).as_int64()), 0, "nothing was indexed")
    print("  test_refusals_have_their_status_and_error_type PASS")


def test_bulk_partial_success_over_http() raises:
    var root = test_tmpdir() + String("/partial")
    var good_a = String('{"body":"alpha quick fox"}')
    var good_b = String('{"body":"beta slow fox"}')
    var bulk = (
        String('{"index":{"_id":"a"}}\n') + good_a + String("\n")
        + String('{"index":{"_id":"b"}}\n{"n":1}\n')
        + String('{"index":{"_id":"c"}}\n') + good_b + String("\n")
        + String('{"create":{"_id":"d"}}\n{"body":"gamma fox"}\n')
        + String('{"index":{"_id":"e"}}\nthis is not json\n')
    )
    var script = List[List[UInt8]]()
    script.append(post(String("/docs/_bulk"), bulk))
    script.append(post(String("/docs/_search"), String('{"query":{"match":{"body":"fox"}},"size":10}')))
    script.append(post(String("/docs/_search"), String('{"query":{"match":{"body":"gamma"}}}')))
    var replies = exchange(new_front_door(root, String("node-a"), 1000), script^)
    assert_equal(replies[0].status, 200, "a bulk with bad items is still 200")
    var body = parse_json_value(replies[0].body)
    assert_true(body.get(String("errors")).as_bool(), "errors == true")
    var items = body.get(String("items"))
    assert_equal(len(items.children), 5, "one item per action")
    var verbs = List[String]()
    verbs.append(String("index"))
    verbs.append(String("index"))
    verbs.append(String("index"))
    verbs.append(String("create"))
    verbs.append(String("index"))
    var statuses = List[Int]()
    statuses.append(201)
    statuses.append(400)
    statuses.append(201)
    statuses.append(400)
    statuses.append(400)
    for i in range(5):
        var item = items.element_at(i)
        assert_true(item.has(verbs[i]), "item " + String(i) + " keyed by " + verbs[i])
        var inner = item.get(verbs[i])
        assert_equal(Int(inner.get(String("status")).as_int64()), statuses[i], "item " + String(i) + " status")
        if statuses[i] == 400:
            assert_true(
                len(inner.get(String("error")).get(String("type")).as_string().as_bytes()) > 0,
                "item " + String(i) + " names its error type",
            )
    # Only the two good documents are searchable, byte-exact, in order.
    assert_equal(replies[1].status, 200, "search status")
    var hits = parse_json_value(replies[1].body).get(String("hits"))
    assert_equal(Int(hits.get(String("total")).get(String("value")).as_int64()), 2, "two documents match fox")
    var rows = hits.get(String("hits"))
    var sources = List[String]()
    for i in range(len(rows.children)):
        sources.append(rows.element_at(i).get(String("_source")).serialize())
    assert_equal(len(sources), 2, "two hits")
    assert_true(
        (sources[0] == good_a and sources[1] == good_b) or (sources[0] == good_b and sources[1] == good_a),
        "the sources are exactly the two good documents: " + sources[0] + " | " + sources[1],
    )
    # The `create` document carried the word gamma and was refused.
    var gamma = parse_json_value(replies[2].body).get(String("hits")).get(String("total"))
    assert_equal(Int(gamma.get(String("value")).as_int64()), 0, "the refused create is not searchable")
    print("  test_bulk_partial_success_over_http PASS")


def main() raises:
    test_refusals_have_their_status_and_error_type()
    test_bulk_partial_success_over_http()
    print("PASS komira_search_e2e search http refusals")
