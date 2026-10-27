# =============================================================================
# test_query_route.mojo -- POST /query and POST /query-federated.
# =============================================================================
#
# The dispatcher is called directly over an in-memory store and a stub embedder
# and model. The graph is written through /ingest-structured, so the warm set
# the write leaves behind is the one a query reads.
#
#   auth         a query without the token, or with another, is 401 and learns
#                nothing; the wrong method is 405.
#   identical    the same data answers byte for byte from the warm set, from a
#                cold server over the same store, and from a set loaded by hand.
#   federated    two partitions merge into one ranked result, whatever order
#                they are named in, with each node's partition as provenance.
#   facet        only entities whose facet is exactly the filter's.
#   partition    a /query names one partition or reads the default one.
#   synthesis    the host's prompt, and the default one, reach the model
#                unchanged with the evidence pack; a model error is a clean 502;
#                a request can decline or demand an answer.
#   limits       an oversize body and an oversize query text are 413; a body the
#                caller got wrong is 400 and nothing is echoed back.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher
from komira_json import JsonValue, parse_json_bytes
from komira_kg import (
    IngestConfig,
    SnapshotWorkingSet,
    StubEmbedder,
    StubLlmClient,
)
from komira_kg_capture import (
    CaptureConfig,
    CaptureDispatcher,
    DEFAULT_SYNTHESIS_PROMPT,
    FixedClock,
    NoRoutes,
    QueryConfig,
    QuerySpec,
    build_query_result,
)
from komira_kg_format import KgSnapshotStore
from komira_kg_sources import EmptyAdapterRegistry
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime DIM = 4
comptime TOKEN = "tok-test-1"
comptime Server = CaptureDispatcher[
    Backend, StubLlmClient, StubEmbedder, EmptyAdapterRegistry, NoRoutes, FixedClock
]

comptime ADA = "Ada Lovelace"
comptime ACME = "Acme Labs"
comptime MIRA = "Mira Quill"
comptime BOLT = "Bolt Co"
comptime ZED = "Zed Corp"


def _vec(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    v.append(c)
    v.append(d)
    return v^


def _emb() raises -> StubEmbedder:
    var emb = StubEmbedder(DIM)
    emb.add_vector(ADA, _vec(1.0, 0.0, 0.0, 0.0))
    emb.add_vector(ACME, _vec(0.0, 1.0, 0.0, 0.0))
    emb.add_vector(MIRA, _vec(0.9, 0.1, 0.0, 0.0))
    emb.add_vector(BOLT, _vec(0.0, 0.0, 1.0, 0.0))
    emb.add_vector(ZED, _vec(0.7, 0.0, 0.7, 0.0))
    emb.add_vector("Ada Lovelace D", _vec(0.0, 0.0, 0.0, 1.0))
    emb.add_vector("alpha", _vec(1.0, 0.0, 0.0, 0.0))
    emb.add_vector("ada", _vec(0.0, 0.0, 0.0, -1.0))
    emb.add_vector("x", _vec(0.0, 0.0, 0.0, -1.0))
    return emb^


# The answer the model gives for "alpha" in partition p1: the pack the server
# builds for that result, spelled out.
comptime PACK_ALPHA_P1 = (
    "QUESTION: alpha\n\nEVIDENCE PACK\nEntities:\n- Ada Lovelace (entity)\n"
    "- Acme Labs (entity)\nRelations:\n"
    "- Ada Lovelace -> Acme Labs: Ada Lovelace works_at Acme Labs\n"
)


def _config() raises -> CaptureConfig:
    return CaptureConfig(TOKEN, "default-p", 4096, 100, IngestConfig.default())


def _server(
    var shared: Backend, var llm: StubLlmClient, var query: QueryConfig, var config: CaptureConfig
) raises -> Server:
    return Server(
        Kg(shared^, "g"),
        llm^,
        _emb(),
        EmptyAdapterRegistry(),
        NoRoutes(),
        FixedClock(Int64(5000)),
        config^,
        query^,
    )


def _plain(shared: Backend) raises -> Server:
    return _server(shared.clone(), StubLlmClient(), QueryConfig.default(), _config())


def _backend() -> UInt8:
    comptime if CompilationTarget.is_linux():
        return BACKEND_EPOLL
    return BACKEND_KQUEUE


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _request(
    method: HttpMethod, path: String, query: String, body: String, token: String
) -> HttpRequest:
    var r = HttpRequest(method, path)
    r.query_string = query
    r.body = _bytes(body)
    if len(token.as_bytes()) > 0:
        r.headers["authorization"] = "Bearer " + token
    return r^


def _call[D: RequestDispatcher](mut server: D, var req: HttpRequest) raises -> HttpResponse:
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _backend())
    return server.dispatch[BlockingRuntime[NoopSink]](reactor, req^)


def _json(r: HttpResponse) raises -> JsonValue:
    return parse_json_bytes(r.body)


def _text(r: HttpResponse) -> String:
    return String(from_utf8_lossy=Span(r.body))


def _ingest(
    mut app: Server, partition: String, facet: String, uuid: String, names: String, edge: String
) raises:
    """Write entities (a JSON list body) and one edge through the server."""
    var body = '{"entities":[' + names + '],"edges":[' + edge + '],"uuid":"' + uuid + '","partition":"' + partition + '","facet":"' + facet + '"}'
    var r = _call(app, _request(HttpMethod.post(), "/ingest-structured", "", body, TOKEN))
    assert_equal(Int(r.status), 200, _text(r))


def _seed(mut app: Server) raises:
    _ingest(
        app, "p1", "fa", "u1",
        '{"name":"Ada Lovelace"},{"name":"Acme Labs"}',
        '{"subject":"Ada Lovelace","predicate":"works_at","object":"Acme Labs"}',
    )
    _ingest(
        app, "p2", "fb", "u2",
        '{"name":"Mira Quill"},{"name":"Bolt Co"}',
        '{"subject":"Mira Quill","predicate":"knows","object":"Bolt Co"}',
    )


def _query(mut app: Server, body: String, query: String = "") raises -> HttpResponse:
    return _call(app, _request(HttpMethod.post(), "/query", query, body, TOKEN))


def _federated(mut app: Server, body: String, query: String = "") raises -> HttpResponse:
    return _call(app, _request(HttpMethod.post(), "/query-federated", query, body, TOKEN))


def _labels(r: HttpResponse) raises -> List[String]:
    var nodes = _json(r).get("nodes")
    var out = List[String]()
    for i in range(nodes.array_len()):
        out.append(nodes.element_at(i).get("label").as_string())
    return out^


def _assert_labels(r: HttpResponse, var want: List[String]) raises:
    assert_equal(Int(r.status), 200, _text(r))
    var got = _labels(r)
    assert_equal(len(got), len(want), _text(r))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _l(*items: String) -> List[String]:
    var out = List[String]()
    for i in range(len(items)):
        out.append(items[i].copy())
    return out^


# --- auth --------------------------------------------------------------------


def test_a_query_without_the_token_is_refused_and_learns_nothing() raises:
    var shared = Backend()
    var app = _plain(shared)
    _seed(app)
    var paths = _l("/query", "/query-federated")
    for i in range(len(paths)):
        var none = _call(app, _request(HttpMethod.post(), paths[i], "", '{"q":"alpha"}', ""))
        assert_equal(Int(none.status), 401)
        assert_equal(none.headers["www-authenticate"], "Bearer")
        assert_false("Ada" in _text(none))
        var wrong = _call(app, _request(HttpMethod.post(), paths[i], "", '{"q":"alpha"}', "tok-test-2"))
        assert_equal(Int(wrong.status), 401)
        var get = _call(app, _request(HttpMethod.get(), paths[i], "", "", ""))
        assert_equal(Int(get.status), 401)


def test_a_query_with_another_method_is_405() raises:
    var app = _plain(Backend())
    var paths = _l("/query", "/query-federated")
    for i in range(len(paths)):
        var r = _call(app, _request(HttpMethod.get(), paths[i], "", "", TOKEN))
        assert_equal(Int(r.status), 405)
        assert_equal(r.headers["allow"], "POST")


# --- warm and snapshot -------------------------------------------------------


def test_the_warm_set_and_the_snapshot_answer_alike() raises:
    var shared = Backend()
    var warm = _plain(shared)
    _seed(warm)

    var spec = QuerySpec("alpha", 16, _l("p1"), "", Optional[Int64](), Optional[Bool](), False)
    var by_hand = build_query_result(
        _emb(), SnapshotWorkingSet.load_latest(warm.store_ref()), spec, QueryConfig.default()
    ).serialize()

    var from_warm = _query(warm, '{"q":"alpha","partition":"p1"}')
    assert_equal(Int(from_warm.status), 200)
    _assert_labels(from_warm, _l(ADA, ACME))
    var cold = _plain(shared)
    var from_snapshot = _query(cold, '{"q":"alpha","partition":"p1"}')
    assert_equal(_text(from_warm), _text(from_snapshot))
    assert_equal(_text(from_warm), by_hand)

    var fed_warm = _federated(warm, '{"q":"alpha","partitions":["p1","p2"]}')
    var fed_cold = _federated(cold, '{"q":"alpha","partitions":["p1","p2"]}')
    assert_equal(_text(fed_warm), _text(fed_cold))
    assert_true(len(_labels(fed_warm)) >= 4)


def test_a_write_is_seen_by_the_next_query_warm_and_cold() raises:
    var shared = Backend()
    var warm = _plain(shared)
    _seed(warm)
    var before = _query(warm, '{"q":"alpha","partition":"p1"}')
    _assert_labels(before, _l(ADA, ACME))

    _ingest(warm, "p1", "fa", "u3", '{"name":"Zed Corp"}', '{"subject":"Ada Lovelace","predicate":"met","object":"Zed Corp"}')
    var after = _query(warm, '{"q":"alpha","partition":"p1"}')
    var cold = _plain(shared)
    var after_cold = _query(cold, '{"q":"alpha","partition":"p1"}')
    assert_equal(_text(after), _text(after_cold))
    var labels = _labels(after)
    assert_equal(len(labels), 3)
    assert_equal(labels[0], ADA)
    assert_equal(labels[1], ZED)  # a semantic seed (0.7), ahead of the neighbour
    assert_equal(labels[2], ACME)
    assert_true(_text(before) != _text(after))


def test_a_query_writes_nothing() raises:
    var shared = Backend()
    var app = _plain(shared)
    _seed(app)
    var head = app.store_ref().latest_snapshot_id()
    _ = _query(app, '{"q":"alpha","partition":"p1"}')
    _ = _federated(app, '{"q":"alpha","partitions":["p1","p2"]}')
    assert_equal(app.store_ref().latest_snapshot_id(), head)


def test_an_empty_graph_answers_with_an_empty_result() raises:
    var app = _plain(Backend())
    var r = _query(app, '{"q":"alpha"}')
    assert_equal(Int(r.status), 200)
    var doc = _json(r)
    assert_equal(doc.get("nodes").array_len(), 0)
    assert_equal(doc.get("mode").as_string(), "query")
    assert_equal(doc.get("answer").as_string(), "")
    var f = _federated(app, '{"q":"alpha"}')
    assert_equal(Int(f.status), 200)
    assert_equal(_json(f).get("mode").as_string(), "federated_query")


# --- partitions and the facet ------------------------------------------------


def test_a_query_reads_one_partition_the_one_it_names_or_the_default() raises:
    var shared = Backend()
    var app = _plain(shared)
    _seed(app)
    _ingest(app, "default-p", "fd", "u9", '{"name":"Ada Lovelace D"}', '{"subject":"Ada Lovelace D","predicate":"is","object":"Ada Lovelace D"}')
    _assert_labels(_query(app, '{"q":"alpha"}', "partition=p2"), _l(MIRA, BOLT))
    _assert_labels(_query(app, '{"q":"alpha","partition":"p2"}'), _l(MIRA, BOLT))
    # The query string wins over the body.
    _assert_labels(_query(app, '{"q":"alpha","partition":"p1"}', "partition=p2"), _l(MIRA, BOLT))
    # No partition: the server's default, which holds only its own entity.
    _assert_labels(_query(app, '{"q":"ada"}'), _l("Ada Lovelace D"))
    _assert_labels(_federated(app, '{"q":"ada"}'), _l("Ada Lovelace D"))
    # A partition nobody wrote.
    _assert_labels(_query(app, '{"q":"ada","partition":"nobody"}'), _l())


def test_the_facet_filter_is_applied_exactly() raises:
    var app = _plain(Backend())
    _seed(app)
    _assert_labels(_federated(app, '{"q":"alpha","partitions":["p1","p2"],"facet":"fa"}'), _l(ADA, ACME))
    _assert_labels(_federated(app, '{"q":"alpha","partitions":["p1","p2"],"facet":"fb"}'), _l(MIRA, BOLT))
    _assert_labels(_query(app, '{"q":"alpha","partition":"p1","facet":"f"}'), _l())
    _assert_labels(_query(app, '{"q":"alpha","partition":"p1","facet":"FA"}'), _l())
    _assert_labels(_query(app, '{"q":"alpha","partition":"p1","facet":"fb"}'), _l())
    _assert_labels(_query(app, '{"q":"alpha","partition":"p1","facet":"fa"}'), _l(ADA, ACME))
    # The query string's facet wins over the body's.
    _assert_labels(_query(app, '{"q":"alpha","partition":"p1","facet":"fb"}', "facet=fa"), _l(ADA, ACME))
    # An empty facet is no filter.
    _assert_labels(_query(app, '{"q":"alpha","partition":"p1","facet":""}'), _l(ADA, ACME))


def test_federated_partitions_merge_in_one_deterministic_order() raises:
    var app = _plain(Backend())
    _seed(app)
    var ab = _federated(app, '{"q":"alpha","partitions":["p1","p2"]}')
    var ba = _federated(app, '{"q":"alpha","partitions":["p2","p1"]}')
    var qs = _federated(app, '{"q":"alpha"}', "partitions=p2,p1,p2")
    var both = _federated(app, '{"q":"alpha","partitions":["p1"]}', "partitions=p2")
    assert_equal(_text(ab), _text(ba))
    assert_equal(_text(ab), _text(qs))
    assert_equal(_text(ab), _text(both))
    # Ada (1.0) and Mira (0.994) seed, then their neighbours.
    var labels = _labels(ab)
    assert_equal(labels[0], ADA)
    assert_equal(labels[1], MIRA)
    assert_equal(len(labels), 4)
    var doc = _json(ab)
    assert_equal(doc.get("mode").as_string(), "federated_query")
    assert_equal(doc.get("provenance").array_len(), 4)
    var sources = List[String]()
    for i in range(4):
        sources.append(doc.get("provenance").element_at(i).get("source").as_string())
    assert_equal(sources[0], "partition:p1")
    assert_equal(sources[1], "partition:p2")
    assert_equal(doc.get("edges").array_len(), 2)
    # One partition alone gives only its own seeds.
    var one = _federated(app, '{"q":"alpha","partitions":["p2"]}')
    var one_labels = _labels(one)
    assert_equal(one_labels[0], MIRA)
    assert_equal(len(one_labels), 2)


def test_k_bounds_the_nodes_and_the_as_of_filter_reaches_the_route() raises:
    var app = _plain(Backend())
    _seed(app)
    _assert_labels(_query(app, '{"q":"alpha","partition":"p1","k":1}'), _l(ADA))
    var early = _query(app, '{"q":"alpha","partition":"p1","as_of":0}')
    # The ingest stamped the edge's start with the server's clock (5000).
    _assert_labels(early, _l(ADA))
    assert_equal(_json(early).get("edges").array_len(), 0)
    var now = _query(app, '{"q":"alpha","partition":"p1","as_of":5000}')
    _assert_labels(now, _l(ADA, ACME))
    assert_equal(_json(now).get("edges").array_len(), 1)


# --- synthesis ---------------------------------------------------------------


def test_the_prompt_and_the_evidence_reach_the_model_unchanged() raises:
    var prompt = String("Answer in one word. Say 'ok' if sure.\nSecond line: é\t!")
    var llm = StubLlmClient()
    llm.add_synthesis(prompt, PACK_ALPHA_P1, "ANSWER-ONE")
    var query = QueryConfig(prompt.copy(), 16, 100, 4096, 32, 64, 0.5)
    var app = _server(Backend(), llm^, query^, _config())
    _seed(app)
    var r = _query(app, '{"q":"alpha","partition":"p1"}')
    assert_equal(Int(r.status), 200, _text(r))
    var doc = _json(r)
    assert_equal(doc.get("answer").as_string(), "ANSWER-ONE")
    assert_equal(doc.get("nodes").array_len(), 2)


def test_the_default_prompt_is_neutral_and_reaches_the_model() raises:
    var llm = StubLlmClient()
    llm.add_synthesis(DEFAULT_SYNTHESIS_PROMPT, PACK_ALPHA_P1, "DEFAULT-ANSWER")
    var app = _server(Backend(), llm^, QueryConfig.default(), _config())
    _seed(app)
    var r = _query(app, '{"q":"alpha","partition":"p1"}')
    assert_equal(_json(r).get("answer").as_string(), "DEFAULT-ANSWER")
    # The federated route asks the model with the same prompt.
    var f = _federated(app, '{"q":"alpha","partitions":["p1"]}')
    assert_equal(_json(f).get("answer").as_string(), "DEFAULT-ANSWER")


def test_a_model_error_is_a_clean_error_response() raises:
    var llm = StubLlmClient()
    llm.add_synthesis("some other prompt", "some other pack", "never")
    var app = _server(Backend(), llm^, QueryConfig.default(), _config())
    _seed(app)
    var r = _query(app, '{"q":"alpha","partition":"p1"}')
    assert_equal(Int(r.status), 502)
    assert_equal(_text(r), '{"error":"the model could not answer"}')
    assert_false("StubLlmClient" in _text(r))
    assert_false("prompt" in _text(r))
    # Declining the answer skips the model, and so the error.
    var declined = _query(app, '{"q":"alpha","partition":"p1","synthesize":false}')
    assert_equal(Int(declined.status), 200)
    assert_equal(_json(declined).get("answer").as_string(), "")
    assert_equal(_json(declined).get("nodes").array_len(), 2)


def test_a_server_without_a_model_answers_with_the_subgraph_alone() raises:
    var app = _plain(Backend())
    _seed(app)
    var r = _query(app, '{"q":"alpha","partition":"p1"}')
    assert_equal(Int(r.status), 200)
    assert_equal(_json(r).get("answer").as_string(), "")
    var off = _query(app, '{"q":"alpha","partition":"p1","synthesize":false}')
    assert_equal(_text(r), _text(off))
    var demanded = _query(app, '{"q":"alpha","partition":"p1","synthesize":true}')
    assert_equal(Int(demanded.status), 501)


def test_a_model_answers_an_empty_graph_too() raises:
    var llm = StubLlmClient()
    llm.add_synthesis(DEFAULT_SYNTHESIS_PROMPT, "QUESTION: alpha\n\nEVIDENCE PACK\nEntities:\nRelations:\n", "nothing known")
    var app = _server(Backend(), llm^, QueryConfig.default(), _config())
    var r = _query(app, '{"q":"alpha","synthesize":true}')
    assert_equal(Int(r.status), 200, _text(r))
    assert_equal(_json(r).get("answer").as_string(), "nothing known")


# --- limits and malformed bodies ----------------------------------------------


def test_an_oversize_query_is_refused() raises:
    var small_body = CaptureConfig(TOKEN, "default-p", 64, 100, IngestConfig.default())
    var app = _server(Backend(), StubLlmClient(), QueryConfig.default(), small_body^)
    var big = String('{"q":"')
    for _ in range(80):
        big += "x"
    big += '"}'
    var r = _query(app, big)
    assert_equal(Int(r.status), 413)
    assert_true("64" in _text(r))
    assert_false("xxxx" in _text(r))

    var short_text = QueryConfig("p", 16, 100, 8, 32, 64, 0.5)
    var app2 = _server(Backend(), StubLlmClient(), short_text^, _config())
    var over = _query(app2, '{"q":"xxxxxxxxx"}')
    assert_equal(Int(over.status), 413)
    assert_true("8 bytes" in _text(over))
    assert_equal(Int(_federated(app2, '{"q":"xxxxxxxxx"}').status), 413)
    var edge = _query(app2, '{"q":"xxxxxxxx"}')
    assert_equal(Int(edge.status), 200)


def test_a_body_the_caller_got_wrong_is_400_and_nothing_is_echoed_from_inside() raises:
    var small = QueryConfig("p", 16, 100, 4096, 2, 64, 0.5)
    var app = _server(Backend(), StubLlmClient(), small^, _config())
    var bodies = _l(
        "",
        "{not json",
        "[]",
        "{}",
        '{"q":5}',
        '{"q":""}',
        '{"q":"x","k":0}',
        '{"q":"x","k":-1}',
        '{"q":"x","k":1.5}',
        '{"q":"x","k":101}',
        '{"q":"x","k":"3"}',
        '{"q":"x","as_of":"now"}',
        '{"q":"x","synthesize":"yes"}',
        '{"q":"x","facet":5}',
        '{"q":"x","partition":5}',
        '{"q":"x","q":"y"}',
        '{"q":"x","partition":"bad\\u0001"}',
    )
    for i in range(len(bodies)):
        var r = _query(app, bodies[i])
        assert_equal(Int(r.status), 400, "query body " + String(i) + ": " + bodies[i])
        assert_true("malformed query" in _text(r))
    var fed = _l(
        '{"q":"x","partitions":"p1"}',
        '{"q":"x","partitions":[5]}',
        '{"q":"x","partitions":["a","b","c"]}',
    )
    for i in range(len(fed)):
        var r = _federated(app, fed[i])
        assert_equal(Int(r.status), 400, fed[i])
    var qs = _l("partition=%zz", "partition=bad%01", "facet=bad%01", "facet=%ff")
    for i in range(len(qs)):
        assert_equal(Int(_query(app, '{"q":"x"}', qs[i]).status), 400, qs[i])
    var long = String("")
    for _ in range(300):
        long += "p"
    assert_equal(Int(_query(app, '{"q":"x"}', "partition=" + long).status), 400)
    assert_equal(Int(_federated(app, '{"q":"x"}', "partitions=a,b,c").status), 400)
    # Within the limits, the same server answers.
    assert_equal(Int(_federated(app, '{"q":"x"}', "partitions=a,b").status), 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
