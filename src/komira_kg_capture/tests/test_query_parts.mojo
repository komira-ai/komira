# =============================================================================
# test_query_parts.mojo -- the query configuration, request and evidence pack.
# =============================================================================
#
#   config      the neutral defaults; each refusal of `QueryConfig`.
#   request     what `parse_query_request` reads: defaults, the query string
#               over the body, the lists, the facet, and each refusal.
#   evidence    the exact text of the evidence pack, its caps, and the prompt
#               going to the model as given.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg import StubLlmClient
from komira_kg_capture import (
    DEFAULT_SYNTHESIS_PROMPT,
    QueryConfig,
    SYNTHESIS_MAX_EDGES,
    SYNTHESIS_MAX_NODES,
    SYNTHESIS_PROMPT_MAX_BYTES,
    evidence_pack,
    parse_query_request,
    synthesize_answer,
)
from komira_kg_format import KgQueryResult, ResultEdge, ResultNode


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


# --- config ------------------------------------------------------------------


def test_the_default_configuration_is_neutral() raises:
    var cfg = QueryConfig.default()
    assert_equal(cfg.synthesis_prompt, DEFAULT_SYNTHESIS_PROMPT)
    assert_true(len(cfg.synthesis_prompt.as_bytes()) > 0)
    assert_equal(cfg.default_k, 16)
    assert_equal(cfg.max_k, 1000)
    assert_equal(cfg.max_query_bytes, 4096)
    assert_equal(cfg.max_partitions, 32)
    assert_equal(cfg.per_partition_cap, 64)
    assert_equal(cfg.similarity_floor, 0.5)
    var same = QueryConfig(DEFAULT_SYNTHESIS_PROMPT, 16, 1000, 4096, 32, 64, 0.5)
    assert_equal(same.max_k, cfg.max_k)


def test_a_configuration_with_a_bad_value_is_refused() raises:
    var long = String("")
    for _ in range(SYNTHESIS_PROMPT_MAX_BYTES + 1):
        long += "p"
    var edge = String("")
    for _ in range(SYNTHESIS_PROMPT_MAX_BYTES):
        edge += "p"
    _ = QueryConfig(edge^, 1, 1, 1, 1, 1, -1.0)
    _ = QueryConfig("p", 1, 1, 1, 1, 1, 1.0)
    with assert_raises(contains="must not be empty"):
        _ = QueryConfig("", 16, 100, 4096, 32, 64, 0.5)
    with assert_raises(contains="is over"):
        _ = QueryConfig(long^, 16, 100, 4096, 32, 64, 0.5)
    with assert_raises(contains="at least 1"):
        _ = QueryConfig("p", 0, 100, 4096, 32, 64, 0.5)
    with assert_raises(contains="at least 1"):
        _ = QueryConfig("p", 16, 0, 4096, 32, 64, 0.5)
    with assert_raises(contains="not be over"):
        _ = QueryConfig("p", 17, 16, 4096, 32, 64, 0.5)
    with assert_raises(contains="max_query_bytes"):
        _ = QueryConfig("p", 16, 100, 0, 32, 64, 0.5)
    with assert_raises(contains="max_partitions"):
        _ = QueryConfig("p", 16, 100, 4096, 0, 64, 0.5)
    with assert_raises(contains="per_partition_cap"):
        _ = QueryConfig("p", 16, 100, 4096, 32, 0, 0.5)
    with assert_raises(contains="similarity_floor"):
        _ = QueryConfig("p", 16, 100, 4096, 32, 64, 1.5)
    with assert_raises(contains="similarity_floor"):
        _ = QueryConfig("p", 16, 100, 4096, 32, 64, -1.5)
    with assert_raises(contains="similarity_floor"):
        _ = QueryConfig("p", 16, 100, 4096, 32, 64, Float64.MAX_FINITE * 2.0)


# --- request -----------------------------------------------------------------


def test_a_minimal_request_takes_the_defaults() raises:
    var cfg = QueryConfig.default()
    var one = parse_query_request(_bytes('{"q":"hello"}'), "", False, "dflt", cfg)
    assert_equal(one.text, "hello")
    assert_equal(one.k, 16)
    assert_equal(len(one.partitions), 1)
    assert_equal(one.partitions[0], "dflt")
    assert_equal(one.facet, "")
    assert_false(Bool(one.as_of))
    assert_false(Bool(one.synthesize))
    assert_false(one.federated)
    var many = parse_query_request(_bytes('{"q":"hello"}'), "", True, "dflt", cfg)
    assert_true(many.federated)
    assert_equal(many.partitions[0], "dflt")


def test_every_member_is_read() raises:
    var cfg = QueryConfig.default()
    var body = '{"q":"é ü","k":5,"as_of":-3,"partition":"pa","facet":"fx","synthesize":false}'
    var r = parse_query_request(_bytes(body), "", False, "dflt", cfg)
    assert_equal(r.text, "é ü")
    assert_equal(r.k, 5)
    assert_equal(r.as_of.value(), Int64(-3))
    assert_equal(r.partitions[0], "pa")
    assert_equal(r.facet, "fx")
    assert_false(r.synthesize.value())
    var yes = parse_query_request(_bytes('{"q":"a","synthesize":true}'), "", False, "d", cfg)
    assert_true(yes.synthesize.value())
    var edge = parse_query_request(_bytes('{"q":"a","k":1000}'), "", False, "d", cfg)
    assert_equal(edge.k, 1000)


def test_the_query_string_wins_and_lists_union() raises:
    var cfg = QueryConfig.default()
    var one = parse_query_request(
        _bytes('{"q":"a","partition":"body","facet":"body"}'), "partition=qs&facet=qs", False, "d", cfg
    )
    assert_equal(one.partitions[0], "qs")
    assert_equal(one.facet, "qs")
    var enc = parse_query_request(_bytes('{"q":"a"}'), "partition=a%20b&facet=%C3%A9", False, "d", cfg)
    assert_equal(enc.partitions[0], "a b")
    assert_equal(enc.facet, "é")

    var fed = parse_query_request(
        _bytes('{"q":"a","partitions":["x","","y","x"]}'), "partitions=z,,y,", True, "d", cfg
    )
    assert_equal(len(fed.partitions), 3)
    assert_equal(fed.partitions[0], "z")
    assert_equal(fed.partitions[1], "y")
    assert_equal(fed.partitions[2], "x")
    # A single query ignores the federated list, and the other way round.
    var ignores = parse_query_request(_bytes('{"q":"a","partitions":["x"]}'), "partitions=y", False, "d", cfg)
    assert_equal(ignores.partitions[0], "d")
    var ignores2 = parse_query_request(_bytes('{"q":"a","partition":"x"}'), "partition=y", True, "d", cfg)
    assert_equal(ignores2.partitions[0], "d")


def test_a_bad_request_is_refused_with_a_description() raises:
    var cfg = QueryConfig("p", 16, 100, 4096, 2, 64, 0.5)
    var long = String("")
    for _ in range(300):
        long += "p"
    with assert_raises(contains="hold"):
        _ = parse_query_request(_bytes(""), "", False, "d", cfg)
    with assert_raises(contains="must be a JSON object"):
        _ = parse_query_request(_bytes("[1]"), "", False, "d", cfg)
    with assert_raises(contains="'q' is required"):
        _ = parse_query_request(_bytes("{}"), "", False, "d", cfg)
    with assert_raises(contains="'q' must be a string"):
        _ = parse_query_request(_bytes('{"q":1}'), "", False, "d", cfg)
    with assert_raises(contains="'q' must not be empty"):
        _ = parse_query_request(_bytes('{"q":""}'), "", False, "d", cfg)
    with assert_raises(contains="'k' must be an integer"):
        _ = parse_query_request(_bytes('{"q":"a","k":2.5}'), "", False, "d", cfg)
    with assert_raises(contains="'k' must be from 1 to 100"):
        _ = parse_query_request(_bytes('{"q":"a","k":0}'), "", False, "d", cfg)
    with assert_raises(contains="'k' must be from 1 to 100"):
        _ = parse_query_request(_bytes('{"q":"a","k":101}'), "", False, "d", cfg)
    with assert_raises(contains="'as_of' must be an integer"):
        _ = parse_query_request(_bytes('{"q":"a","as_of":"1"}'), "", False, "d", cfg)
    with assert_raises(contains="'synthesize'"):
        _ = parse_query_request(_bytes('{"q":"a","synthesize":1}'), "", False, "d", cfg)
    with assert_raises(contains="'facet' must be a string"):
        _ = parse_query_request(_bytes('{"q":"a","facet":1}'), "", False, "d", cfg)
    with assert_raises(contains="'partition' must be a string"):
        _ = parse_query_request(_bytes('{"q":"a","partition":1}'), "", False, "d", cfg)
    with assert_raises(contains="array of strings"):
        _ = parse_query_request(_bytes('{"q":"a","partitions":"x"}'), "", True, "d", cfg)
    with assert_raises(contains="array of strings"):
        _ = parse_query_request(_bytes('{"q":"a","partitions":[1]}'), "", True, "d", cfg)
    with assert_raises(contains="the most allowed is 2"):
        _ = parse_query_request(_bytes('{"q":"a"}'), "partitions=a,b,c", True, "d", cfg)
    with assert_raises(contains="partition"):
        _ = parse_query_request(_bytes('{"q":"a"}'), "partition=" + long, False, "d", cfg)
    with assert_raises(contains="facet"):
        _ = parse_query_request(_bytes('{"q":"a"}'), "facet=" + long, False, "d", cfg)
    with assert_raises(contains="percent"):
        _ = parse_query_request(_bytes('{"q":"a"}'), "facet=%zz", False, "d", cfg)
    with assert_raises():
        _ = parse_query_request(_bytes('{"q":"a","q":"b"}'), "", False, "d", cfg)
    with assert_raises():
        _ = parse_query_request(_bytes("{not json"), "", False, "d", cfg)


# --- evidence ----------------------------------------------------------------


def _node(id: Int64, label: String, type: String) -> ResultNode:
    return ResultNode(id, label.copy(), type.copy(), 1.0)


def test_the_evidence_pack_is_exactly_the_documented_text() raises:
    var r = KgQueryResult("m", "l")
    r.add_node(_node(1, "Ada", "entity"))
    r.add_node(_node(2, "Acme", "entity"))
    r.add_edge(ResultEdge(1, 2, "works_at", 0, ""))
    r.add_edge(ResultEdge(2, 77, "owns", 0, ""))
    var pack = evidence_pack(r, "who?")
    assert_equal(
        pack,
        "QUESTION: who?\n\nEVIDENCE PACK\nEntities:\n- Ada (entity)\n- Acme (entity)\n"
        "Relations:\n- Ada -> Acme: works_at\n- Acme -> 77: owns\n",
    )
    assert_equal(
        evidence_pack(KgQueryResult("m", "l"), "q"),
        "QUESTION: q\n\nEVIDENCE PACK\nEntities:\nRelations:\n",
    )


def test_the_evidence_pack_is_bounded() raises:
    var r = KgQueryResult("m", "l")
    for i in range(SYNTHESIS_MAX_NODES + 10):
        r.add_node(_node(Int64(i), "n" + String(i), "entity"))
    for i in range(SYNTHESIS_MAX_EDGES + 10):
        r.add_edge(ResultEdge(0, 1, "e" + String(i), 0, ""))
    var pack = evidence_pack(r, "q")
    var lines = pack.split("\n")
    # QUESTION, blank, header, "Entities:", the nodes, "Relations:", the edges, "".
    assert_equal(len(lines), 4 + SYNTHESIS_MAX_NODES + 1 + SYNTHESIS_MAX_EDGES + 1)
    assert_true("n31" in pack)
    assert_false("n32" in pack)
    assert_true("e47" in pack)
    assert_false("e48" in pack)


def test_the_prompt_goes_to_the_model_as_given() raises:
    var r = KgQueryResult("m", "l")
    r.add_node(_node(1, "Ada", "entity"))
    var llm = StubLlmClient()
    var prompt = String("  Keep this EXACT,\n  whitespace and all.  ")
    llm.add_synthesis(prompt, evidence_pack(r, "q"), "yes")
    assert_equal(synthesize_answer(llm, r, "q", prompt), "yes")
    with assert_raises(contains="no answer registered"):
        _ = synthesize_answer(llm, r, "q", "Keep this EXACT,\n  whitespace and all.")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
