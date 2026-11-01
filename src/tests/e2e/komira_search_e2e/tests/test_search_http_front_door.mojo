# =============================================================================
# test_search_http_front_door.mojo -- _bulk then _search over a real socket
# =============================================================================
#
# The front door of the search shim, end to end: a `SearchHttpDispatcher` over
# a `LocalFsConditionalStore` rooted in the run's TEST_TMPDIR, mounted behind a
# real `HttpServer` on 127.0.0.1 port 0, driven with raw HTTP/1.1 bytes (see
# http_wire.mojo). Each test uses its own directory under TEST_TMPDIR.
#
#   * test_bulk_then_search_ranks_the_corpus -- POST /docs/_bulk of five
#     documents (one split), POST /docs/_search for "quick fox". Asserts the
#     bulk reply (errors false, five 201 items echoing the client `_id`s), then
#     the search reply: the hit order [1, 0, 2, 3] (document 4 does not
#     match), each `_score` within 1e-9 of the BM25 value derived below, each
#     `_source` equal byte for byte to the document line sent, `hits.total`
#     4 with relation `eq`, `max_score` the top score, and `_shards` 1/1/0/0.
#     Catches a ranking or scoring change anywhere from the analyzer to the
#     envelope, a `_source` that is re-encoded, and a count that is capped.
#   * test_restarted_dispatcher_answers_the_same -- the same search through a
#     NEW dispatcher (new store handle, new epoch, new server) over the same
#     directory, as after a restart, returns hits identical to the first run,
#     and a bulk through the restarted dispatcher adds a second split whose
#     document is found beside the first five. Catches an index that lives only
#     in the writer's memory and a restarted writer that reuses a split key.
#
# The expected scores, re-derived from the BM25 definition (the engine's
# defaults: k1 = 1.2, b = 0.75, the modern form without a (k1 + 1) numerator),
# not read back from the engine. Query terms {quick, fox}; N = 5 documents;
# quick is in three documents (0, 1, 3), fox in three (0, 1, 2), so
# idf = ln(1 + (N - n + 0.5) / (n + 0.5)) = ln(12/7) = 0.5389965007326871.
# Document lengths count the indexed terms, and "the" is a stop word, so they
# are [4, 6, 3, 3, 3] and avgdl = 19 / 5 = 3.8. A term's factor is
# tf / (tf + k1 * (1 - b + b * dl / avgdl)):
#   doc 1 (dl 6): quick tf 2, fox tf 3 -> 0.63220722709 (engine: 0.63220722703)
#   doc 0 (dl 4): quick tf 1, fox tf 1 -> 0.47966901705
#   doc 2 (dl 3): fox tf 1             -> 0.26808726476
#   doc 3 (dl 3): quick tf 1           -> 0.26808726476
# Documents 2 and 3 tie exactly and keep document order. (The engine's value
# differs from this double-precision formula by about 6e-11, inside the 1e-9
# tolerance, because it stores the document length norm in a narrower type.)
# =============================================================================

from std.math import log
from std.testing import assert_equal, assert_true

from komira_json import parse_json_value
from komira_runtime_paths import test_tmpdir

from komira_search_e2e.http_wire import (
    WireReply,
    bytes_of,
    exchange,
    new_front_door,
    post,
)

comptime _K1: Float64 = 1.2
comptime _B: Float64 = 0.75
comptime _AVGDL: Float64 = 3.8


def _idf() -> Float64:
    return log(1.0 + (5.0 - 3.0 + 0.5) / (3.0 + 0.5))


def _bm25(tf_quick: Int, tf_fox: Int, dl: Int) -> Float64:
    var norm = _K1 * (1.0 - _B + _B * Float64(dl) / _AVGDL)
    var out = Float64(0)
    if tf_quick > 0:
        out += Float64(tf_quick) / (Float64(tf_quick) + norm)
    if tf_fox > 0:
        out += Float64(tf_fox) / (Float64(tf_fox) + norm)
    return _idf() * out


def _score_of(doc: Int) -> Float64:
    if doc == 1:
        return _bm25(2, 3, 6)
    if doc == 0:
        return _bm25(1, 1, 4)
    if doc == 2:
        return _bm25(0, 1, 3)
    return _bm25(1, 0, 3)  # doc 3


def _doc(i: Int) -> String:
    if i == 0:
        return String('{"body":"quick brown fox jumps"}')
    if i == 1:
        return String('{"body":"the quick quick fox fox fox runs"}')
    if i == 2:
        return String('{"body":"slow fox sleeps"}')
    if i == 3:
        return String('{"body":"quick rabbit hops"}')
    return String('{"body":"lazy dog naps"}')


def _bulk_body() -> String:
    var out = String()
    for i in range(5):
        out += String('{"index":{"_id":"') + String(i) + String('"}}\n') + _doc(i) + String("\n")
    return out^


def _search_body() -> String:
    return String('{"query":{"match":{"body":"quick fox"}},"size":10}')


def _assert_close(actual: Float64, expected: Float64, label: String) raises:
    var diff = actual - expected
    if diff < Float64(0):
        diff = -diff
    assert_true(
        diff < Float64(1e-9),
        label + " = " + String(actual) + ", expected " + String(expected),
    )


def _assert_bulk_reply(reply: WireReply, ids: List[String]) raises:
    var docs = len(ids)
    assert_equal(reply.status, 200, "bulk status")
    assert_true(
        reply.head.find(String("content-type: application/json")) >= 0,
        "bulk is JSON: " + reply.head,
    )
    var root = parse_json_value(reply.body)
    assert_true(not root.get(String("errors")).as_bool(), "bulk errors == false")
    var items = root.get(String("items"))
    assert_equal(len(items.children), docs, "bulk item count")
    for i in range(docs):
        var item = items.element_at(i).get(String("index"))
        assert_equal(Int(item.get(String("status")).as_int64()), 201, "item status")
        assert_equal(item.get(String("_id")).as_string(), ids[i], "item _id echo")


def _assert_ranked_reply(reply: WireReply) raises:
    assert_equal(reply.status, 200, "search status")
    var root = parse_json_value(reply.body)
    var shards = root.get(String("_shards"))
    assert_equal(Int(shards.get(String("total")).as_int64()), 1, "_shards.total")
    assert_equal(Int(shards.get(String("successful")).as_int64()), 1, "_shards.successful")
    assert_equal(Int(shards.get(String("skipped")).as_int64()), 0, "_shards.skipped")
    assert_equal(Int(shards.get(String("failed")).as_int64()), 0, "_shards.failed")
    assert_true(not root.get(String("timed_out")).as_bool(), "timed_out == false")
    var hits = root.get(String("hits"))
    var total = hits.get(String("total"))
    assert_equal(Int(total.get(String("value")).as_int64()), 4, "hits.total.value")
    assert_equal(total.get(String("relation")).as_string(), String("eq"), "relation")
    _assert_close(hits.get(String("max_score")).as_float64(), _score_of(1), "max_score")
    var rows = hits.get(String("hits"))
    assert_equal(len(rows.children), 4, "hits.hits length")
    var order = List[Int]()
    order.append(1)
    order.append(0)
    order.append(2)
    order.append(3)
    for rank in range(4):
        var hit = rows.element_at(rank)
        var label = "hit " + String(rank) + " "
        assert_equal(hit.get(String("_index")).as_string(), String("docs"), label + "_index")
        assert_equal(hit.get(String("_id")).as_string(), String(order[rank]), label + "_id")
        _assert_close(hit.get(String("_score")).as_float64(), _score_of(order[rank]), label + "_score")
        # Byte-exact: the `_source` object serializes to the line that was sent,
        # and that line appears verbatim in the reply body.
        var line = _doc(order[rank])
        assert_equal(hit.get(String("_source")).serialize(), line, label + "_source")
        assert_true(
            reply.body.find(String('"_source":') + line) >= 0,
            label + "_source verbatim in the wire body",
        )


def _five_ids() -> List[String]:
    var ids = List[String]()
    for i in range(5):
        ids.append(String(i))
    return ids^


def test_bulk_then_search_ranks_the_corpus() raises:
    var root = test_tmpdir() + String("/front_door")
    var script = List[List[UInt8]]()
    script.append(post(String("/docs/_bulk"), _bulk_body()))
    script.append(post(String("/docs/_search"), _search_body()))
    var replies = exchange(new_front_door(root, String("node-a"), 1000), script^)
    assert_equal(len(replies), 2, "two replies")
    _assert_bulk_reply(replies[0], _five_ids())
    _assert_ranked_reply(replies[1])
    print("  test_bulk_then_search_ranks_the_corpus PASS")


def test_restarted_dispatcher_answers_the_same() raises:
    var root = test_tmpdir() + String("/restart")
    var first = List[List[UInt8]]()
    first.append(post(String("/docs/_bulk"), _bulk_body()))
    first.append(post(String("/docs/_search"), _search_body()))
    var before = exchange(new_front_door(root, String("node-a"), 1000), first^)
    _assert_ranked_reply(before[1])

    # A new server, store handle and dispatcher over the same directory.
    var again = List[List[UInt8]]()
    again.append(post(String("/docs/_search"), _search_body()))
    var after = exchange(new_front_door(root, String("node-a"), 2000), again^)
    _assert_ranked_reply(after[0])
    var hits_before = parse_json_value(before[1].body).get(String("hits")).serialize()
    var hits_after = parse_json_value(after[0].body).get(String("hits")).serialize()
    assert_equal(hits_after, hits_before, "hits after the restart equal the hits before")

    # The restarted writer lands a second split next to the first.
    var more = List[List[UInt8]]()
    more.append(
        post(
            String("/docs/_bulk"),
            String('{"index":{"_id":"x"}}\n{"body":"quick quick quick fox fox fox fox"}\n'),
        )
    )
    more.append(post(String("/docs/_search"), _search_body()))
    var third = exchange(new_front_door(root, String("node-a"), 3000), more^)
    var one = List[String]()
    one.append(String("x"))
    _assert_bulk_reply(third[0], one)
    assert_equal(third[1].status, 200, "search after the second bulk")
    var total = parse_json_value(third[1].body).get(String("hits")).get(String("total"))
    assert_equal(Int(total.get(String("value")).as_int64()), 5, "five matches across two splits")
    print("  test_restarted_dispatcher_answers_the_same PASS")


def main() raises:
    test_bulk_then_search_ranks_the_corpus()
    test_restarted_dispatcher_answers_the_same()
    print("PASS komira_search_e2e search http front door")
