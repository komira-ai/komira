# =============================================================================
# test_search_dispatch.mojo: the search HTTP dispatcher over an in-memory store
# =============================================================================
#
# Every test drives `SearchHttpDispatcher.dispatch` with a parsed `HttpRequest`
# over `SharedInMemoryConditionalStore`, the way a server round does.
#
#   * routing: an unknown path is 404, a known path under another verb 405 with
#     an `allow` header, a query string is ignored, an index name with a
#     character outside a-z0-9._- is 400 and writes nothing, a percent-escape is
#     not decoded, a body over the configured limit is 413 and writes nothing.
#   * `_bulk` then `_search` round trip: one split, then two (the second makes
#     `_id` the namespaced `<split-uuid>_<doc_id>`), a filter, a field sort and
#     an aggregation gated against the splits' fast fields.
#   * request errors: malformed JSON, a dangling bulk action, a filter on a
#     field that is not a fast field are 400; a `_bulk` whose items all fail
#     writes nothing; an unknown index answers like an empty one.
#   * the live-split cap: an index over `max_splits_per_search` is 503.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.blocking_runtime import BlockingRuntime
from std.sys.info import CompilationTarget

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_search_http import SearchHttpConfig, SearchHttpDispatcher

comptime _Rt = BlockingRuntime[NoopSink]
comptime Store = SharedInMemoryConditionalStore


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _text(r: HttpResponse) -> String:
    return String(unsafe_from_utf8=Span(r.body))


def _req(method: HttpMethod, path: String, body: String) -> HttpRequest:
    var req = HttpRequest(method.copy(), path.copy())
    req.body = _bytes(body)
    return req^


def _cfg(max_splits: Int = 1024, max_body: Int = 1024 * 1024) raises -> SearchHttpConfig:
    return SearchHttpConfig(
        String("catalog"),
        String("data"),
        String("body"),
        String("node-a"),
        max_body,
        max_splits,
    )


def _new_dispatcher(
    store: Store, worker: Int = 0, epoch_us: Int = 1000, max_splits: Int = 1024,
    max_body: Int = 1024 * 1024,
) raises -> SearchHttpDispatcher[Store]:
    return SearchHttpDispatcher[Store](
        _cfg(max_splits, max_body), store.clone(), worker, Int64(epoch_us)
    )


def _send(
    mut d: SearchHttpDispatcher[Store], method: HttpMethod, path: String, body: String
) raises -> HttpResponse:
    var reactor = _new_reactor()
    return d.dispatch[_Rt](reactor, _req(method, path, body))


def _post(
    mut d: SearchHttpDispatcher[Store], path: String, body: String
) raises -> HttpResponse:
    return _send(d, HttpMethod.post(), path, body)


def _objects_under(store: Store, prefix: String) raises -> Int:
    return len(store.list_with_delimiter(Path.parse(prefix)).objects)


def _count(haystack: String, needle: String) -> Int:
    var n = 0
    var at = 0
    while True:
        var i = haystack.find(needle, at)
        if i < 0:
            return n
        n += 1
        at = i + needle.byte_length()


def _bulk_two() -> String:
    return String(
        '{"index":{"_id":"a"}}\n{"body":"the quick brown fox","n":1,"tag":"x"}\n'
        '{"index":{"_id":"b"}}\n{"body":"a lazy dog sleeps","n":2,"tag":"y"}\n'
    )


# -----------------------------------------------------------------------------
# Routing
# -----------------------------------------------------------------------------


def test_unknown_paths_are_404() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var paths = List[String]()
    paths.append(String("/"))
    paths.append(String("/_bulk"))
    paths.append(String("/idx"))
    paths.append(String("/idx/_count"))
    paths.append(String("/idx/_search/extra"))
    paths.append(String("/a/b/_bulk"))
    paths.append(String("/idx/_search_x"))
    paths.append(String(""))
    for i in range(len(paths)):
        var r = _post(d, paths[i], String("{}"))
        assert_equal(r.status, Int32(404), String("path ") + paths[i])
        assert_true(_text(r).find('"type":"not_found"') >= 0)
    assert_equal(_objects_under(store, "catalog/"), 0)
    assert_equal(_objects_under(store, "data/"), 0)


def test_odd_path_shapes_are_404_not_routed() raises:
    """Empty segments and a missing leading slash do not collapse into a route."""
    var store = Store()
    var d = _new_dispatcher(store)
    var paths = List[String]()
    paths.append(String("//idx/_bulk"))
    paths.append(String("/idx//_bulk"))
    paths.append(String("idx/_bulk"))
    paths.append(String("/idx/_bulk//"))
    paths.append(String("///"))
    paths.append(String("/a/b/c/d/e/f/g/h/i/j"))
    for i in range(len(paths)):
        var r = _post(d, paths[i], _bulk_two())
        assert_equal(r.status, Int32(404), String("path ") + paths[i])
    assert_equal(_objects_under(store, "data/"), 0)


def test_percent_escapes_are_not_decoded() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    # An encoded slash does not split the segment: one segment, no route.
    var r = _post(d, String("/idx%2F_bulk"), _bulk_two())
    assert_equal(r.status, Int32(404))
    # An encoded dot-dot is not decoded into a traversal; the name is refused.
    r = _post(d, String("/%2e%2e/_bulk"), _bulk_two())
    assert_equal(r.status, Int32(400))
    assert_true(_text(r).find("invalid_index_name_exception") >= 0)
    assert_equal(_objects_under(store, "catalog/"), 0)
    assert_equal(_objects_under(store, "data/"), 0)


def test_wrong_verb_is_405_with_allow() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var verbs = List[HttpMethod]()
    verbs.append(HttpMethod.get())
    verbs.append(HttpMethod.put())
    verbs.append(HttpMethod.delete())
    verbs.append(HttpMethod.patch())
    for i in range(len(verbs)):
        var r = _send(d, verbs[i], String("/idx/_bulk"), _bulk_two())
        assert_equal(r.status, Int32(405))
        assert_equal(r.headers[String("allow")], String("POST"))
        assert_true(_text(r).find('"type":"method_not_allowed"') >= 0)
        r = _send(d, verbs[i], String("/idx/_search"), String("{}"))
        assert_equal(r.status, Int32(405))
    assert_equal(_objects_under(store, "data/"), 0)


def test_query_string_in_the_path_is_ignored() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var r = _post(d, String("/idx/_bulk?refresh=true&pretty"), _bulk_two())
    assert_equal(r.status, Int32(200))
    assert_equal(_count(_text(r), '"status":201'), 2)
    r = _post(
        d,
        String("/idx/_search?size=1"),
        String('{"query":{"match":{"body":"fox"}}}'),
    )
    assert_equal(r.status, Int32(200))
    assert_true(_text(r).find('"total":{"value":1,"relation":"eq"}') >= 0)


def test_trailing_slash_is_accepted() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var r = _post(d, String("/idx/_bulk/"), _bulk_two())
    assert_equal(r.status, Int32(200))


def test_invalid_index_names_are_400_and_write_nothing() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var names = List[String]()
    names.append(String("Upper"))
    names.append(String("-lead"))
    names.append(String("_lead"))
    names.append(String(".lead"))
    names.append(String(".."))
    names.append(String("a b"))
    names.append(String("a*"))
    names.append(String("a,b"))
    names.append(String("a%2Fb"))
    names.append(String("a:b"))
    names.append(String("a\\b"))
    names.append(String("café"))
    names.append(String("x" * 256))
    for i in range(len(names)):
        var r = _post(d, String("/") + names[i] + String("/_bulk"), _bulk_two())
        assert_equal(r.status, Int32(400), String("name ") + names[i])
        assert_true(_text(r).find('"type":"invalid_index_name_exception"') >= 0)
        r = _post(
            d,
            String("/") + names[i] + String("/_search"),
            String('{"query":{"match":{"body":"fox"}}}'),
        )
        assert_equal(r.status, Int32(400), String("name ") + names[i])
    assert_equal(_objects_under(store, "catalog/"), 0)
    assert_equal(_objects_under(store, "data/"), 0)


def test_longest_valid_index_name_is_accepted() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var name = String("a" * 255)
    var r = _post(d, String("/") + name + String("/_bulk"), _bulk_two())
    assert_equal(r.status, Int32(200))
    r = _post(d, String("/a.b_c-9/_bulk"), _bulk_two())
    assert_equal(r.status, Int32(200))


def test_body_over_the_limit_is_413_and_writes_nothing() raises:
    var store = Store()
    var d = _new_dispatcher(store, max_body=64)
    var big = String("x" * 65)
    var r = _post(d, String("/idx/_bulk"), big)
    assert_equal(r.status, Int32(413))
    assert_true(_text(r).find('"type":"content_too_long_exception"') >= 0)
    r = _post(d, String("/idx/_search"), big)
    assert_equal(r.status, Int32(413))
    assert_equal(_objects_under(store, "catalog/"), 0)
    assert_equal(_objects_under(store, "data/"), 0)
    # A body of exactly the limit is read (and fails to parse, as a 400).
    r = _post(d, String("/idx/_search"), String("x" * 64))
    assert_equal(r.status, Int32(400))


# -----------------------------------------------------------------------------
# _bulk then _search
# -----------------------------------------------------------------------------


def test_bulk_then_search_roundtrip_one_split() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var r = _post(d, String("/docs/_bulk"), _bulk_two())
    assert_equal(r.status, Int32(200))
    var t = _text(r)
    assert_true(t.find('"errors":false') >= 0)
    assert_true(t.find('"_id":"a"') >= 0)
    assert_true(t.find('"_id":"b"') >= 0)
    assert_equal(_count(t, '"status":201'), 2)

    r = _post(
        d, String("/docs/_search"), String('{"query":{"match":{"body":"fox"}}}')
    )
    assert_equal(r.status, Int32(200))
    t = _text(r)
    assert_true(t.find('"total":{"value":1,"relation":"eq"}') >= 0)
    assert_true(t.find('"_index":"docs"') >= 0)
    assert_true(t.find('"_id":"0"') >= 0)  # one split: the bare doc id
    assert_true(t.find('"_source":{"body":"the quick brown fox"') >= 0)
    assert_true(t.find('"_shards":{"total":1,"successful":1') >= 0)
    assert_false(t.find("lazy dog") >= 0)


def test_two_splits_namespace_the_ids() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    _ = _post(d, String("/docs/_bulk"), _bulk_two())
    _ = _post(
        d,
        String("/docs/_bulk"),
        String('{"index":{}}\n{"body":"another fox appears"}\n'),
    )
    var r = _post(
        d, String("/docs/_search"), String('{"query":{"match":{"body":"fox"}}}')
    )
    assert_equal(r.status, Int32(200))
    var t = _text(r)
    assert_true(t.find('"total":{"value":2,"relation":"eq"}') >= 0)
    assert_true(t.find('"_shards":{"total":2,"successful":2') >= 0)
    # Doc id 0 of both splits: the ids differ by the split uuid prefix.
    assert_equal(_count(t, '_0"'), 2)
    assert_true(t.find('"_id":"0"') < 0)
    assert_true(t.find("the quick brown fox") >= 0)
    assert_true(t.find("another fox appears") >= 0)


def test_filter_sort_and_aggs_over_two_splits() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    _ = _post(d, String("/docs/_bulk"), _bulk_two())
    _ = _post(
        d,
        String("/docs/_bulk"),
        String('{"index":{}}\n{"body":"fox three","n":3,"tag":"x"}\n'),
    )
    var r = _post(
        d,
        String("/docs/_search"),
        String(
            '{"query":{"bool":{"must":[{"match":{"body":"fox"}}],'
            '"filter":[{"range":{"n":{"gte":2}}}]}}}'
        ),
    )
    assert_equal(r.status, Int32(200))
    assert_true(_text(r).find('"total":{"value":1,"relation":"eq"}') >= 0)

    r = _post(
        d,
        String("/docs/_search"),
        String(
            '{"query":{"match":{"body":"fox"}},"sort":[{"n":{"order":"desc"}}]}'
        ),
    )
    assert_equal(r.status, Int32(200))
    var t = _text(r)
    assert_true(t.find('"total":{"value":2,"relation":"eq"}') >= 0)
    assert_true(t.find("fox three") < t.find("quick brown fox"))

    r = _post(
        d,
        String("/docs/_search"),
        String(
            '{"size":0,"aggs":{"s":{"sum":{"field":"n"}},'
            '"by":{"terms":{"field":"tag"}}}}'
        ),
    )
    assert_equal(r.status, Int32(200))
    t = _text(r)
    assert_true(t.find('"aggregations":{') >= 0)
    assert_true(t.find('"value":6') >= 0)
    assert_true(t.find('"key":"x","doc_count":2') >= 0)


def test_pagination_applies_once_over_the_merged_splits() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    for i in range(3):
        _ = _post(
            d,
            String("/docs/_bulk"),
            String('{"index":{}}\n{"body":"fox ') + String(i) + String('","n":') + String(i) + String("}\n"),
        )
    var r = _post(
        d,
        String("/docs/_search"),
        String(
            '{"query":{"match":{"body":"fox"}},"sort":[{"n":"asc"}],'
            '"from":1,"size":1}'
        ),
    )
    assert_equal(r.status, Int32(200))
    var t = _text(r)
    assert_true(t.find('"total":{"value":3,"relation":"eq"}') >= 0)
    assert_equal(_count(t, '"_source"'), 1)
    assert_true(t.find("fox 1") >= 0)


# -----------------------------------------------------------------------------
# Request errors
# -----------------------------------------------------------------------------


def test_malformed_requests_are_400() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var r = _post(d, String("/docs/_search"), String("{not json"))
    assert_equal(r.status, Int32(400))
    assert_true(_text(r).find('"type":"parse_exception"') >= 0)
    r = _post(d, String("/docs/_search"), String('{"size":5}'))
    assert_equal(r.status, Int32(400))
    r = _post(d, String("/docs/_search"), String(""))
    assert_equal(r.status, Int32(400))
    # A dangling action line has no source: the whole request is refused.
    r = _post(d, String("/docs/_bulk"), String('{"index":{}}\n'))
    assert_equal(r.status, Int32(400))
    assert_equal(_objects_under(store, "data/"), 0)


def test_unfiltered_field_is_400_after_indexing() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    _ = _post(d, String("/docs/_bulk"), _bulk_two())
    var r = _post(
        d,
        String("/docs/_search"),
        String(
            '{"query":{"bool":{"must":[{"match":{"body":"fox"}}],'
            '"filter":[{"term":{"nosuch":"v"}}]}}}'
        ),
    )
    assert_equal(r.status, Int32(400))
    assert_true(_text(r).find('"type":"parse_exception"') >= 0)


def test_empty_bulk_and_all_failed_bulk_write_nothing() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var r = _post(d, String("/docs/_bulk"), String(""))
    assert_equal(r.status, Int32(200))
    assert_true(_text(r).find('"items":[]') >= 0)
    # Both items fail (no text field): HTTP 200, errors true, no split.
    r = _post(
        d,
        String("/docs/_bulk"),
        String('{"index":{}}\n{"title":"x"}\n{"index":{}}\n{"title":"y"}\n'),
    )
    assert_equal(r.status, Int32(200))
    var t = _text(r)
    assert_true(t.find('"errors":true') >= 0)
    assert_equal(_count(t, '"status":400'), 2)
    assert_equal(_objects_under(store, "data/"), 0)
    assert_equal(_objects_under(store, "catalog/"), 0)


def test_a_bad_item_fails_alone() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var r = _post(
        d,
        String("/docs/_bulk"),
        String('{"index":{"_id":"1"}}\n{"body":"good one"}\n{"index":{"_id":"2"}}\n{"title":"bad"}\n'),
    )
    assert_equal(r.status, Int32(200))
    var t = _text(r)
    assert_true(t.find('"errors":true') >= 0)
    assert_equal(_count(t, '"status":201'), 1)
    assert_equal(_count(t, '"status":400'), 1)
    r = _post(
        d, String("/docs/_search"), String('{"query":{"match":{"body":"good"}}}')
    )
    assert_true(_text(r).find('"total":{"value":1,"relation":"eq"}') >= 0)


def test_unknown_index_answers_like_an_empty_one() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    var r = _post(
        d, String("/nothing/_search"), String('{"query":{"match":{"body":"fox"}}}')
    )
    assert_equal(r.status, Int32(200))
    var t = _text(r)
    assert_true(t.find('"total":{"value":0,"relation":"eq"}') >= 0)
    assert_true(t.find('"hits":[]') >= 0)


def test_indexes_do_not_see_each_other() raises:
    var store = Store()
    var d = _new_dispatcher(store)
    _ = _post(d, String("/one/_bulk"), _bulk_two())
    var r = _post(
        d, String("/two/_search"), String('{"query":{"match":{"body":"fox"}}}')
    )
    assert_true(_text(r).find('"total":{"value":0') >= 0)


def test_a_second_dispatcher_on_the_store_sees_the_splits() raises:
    var store = Store()
    var writer = _new_dispatcher(store, 0)
    _ = _post(writer, String("/docs/_bulk"), _bulk_two())
    var other = _new_dispatcher(store, 1, 2000)
    _ = _post(other, String("/docs/_bulk"), _bulk_two())
    var r = _post(
        other, String("/docs/_search"), String('{"query":{"match":{"body":"fox"}}}')
    )
    assert_true(_text(r).find('"total":{"value":2') >= 0)
    r = _post(
        writer, String("/docs/_search"), String('{"query":{"match":{"body":"fox"}}}')
    )
    assert_true(_text(r).find('"total":{"value":2') >= 0)


def test_split_cap_refuses_a_search_with_503() raises:
    var store = Store()
    var d = _new_dispatcher(store, max_splits=2)
    for _i in range(3):
        _ = _post(d, String("/docs/_bulk"), _bulk_two())
    var r = _post(
        d, String("/docs/_search"), String('{"query":{"match":{"body":"fox"}}}')
    )
    assert_equal(r.status, Int32(503))
    assert_true(_text(r).find('"type":"search_unavailable_exception"') >= 0)
    # Within the cap the same search is served.
    var d2 = _new_dispatcher(store, 1, 5000, max_splits=3)
    r = _post(
        d2, String("/docs/_search"), String('{"query":{"match":{"body":"fox"}}}')
    )
    assert_equal(r.status, Int32(200))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
