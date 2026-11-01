# =============================================================================
# test_embedder.mojo -- EmbeddingsWireEmbedder over a scripted transport.
# =============================================================================
#
#   trait         a function generic over Embedder instantiates with it, and the
#                 vectors keep the width it reports, at two dimensions.
#   request       the model id and the text reach the transport (a scripted row
#                 answers only a request that holds them); a batch is one
#                 request; an empty batch makes none (the transport has no row,
#                 so a request would fail the test).
#   order         a single text and a batch come back in input order, also when
#                 the server lists the rows by index out of order.
#   refusals      a model id that is empty, a dimension that is not positive, a
#                 response of another width, a response with the wrong row count,
#                 a malformed response and a request the transport cannot answer
#                 are all errors, none a partial result.
#   scripted      the scripted transport answers the first matching row and
#                 quotes the beginning of a request that matches none.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_kg import Embedder
from komira_kg_llm import EmbeddingsWireEmbedder, ScriptedEmbedTransport


def _embedder(
    var transport: ScriptedEmbedTransport, dimension: Int
) raises -> EmbeddingsWireEmbedder[ScriptedEmbedTransport]:
    return EmbeddingsWireEmbedder[ScriptedEmbedTransport](
        transport^, "emb-model", dimension
    )


def _width_of[E: Embedder](e: E, text: String) raises -> Int:
    return len(e.embed(text))


def test_the_embedder_satisfies_the_trait_at_two_dimensions() raises:
    var t3 = ScriptedEmbedTransport()
    t3.add("", '{"data":[{"embedding":[1,2,3]}]}')
    var e3 = _embedder(t3^, 3)
    assert_equal(e3.dimension(), 3)
    assert_equal(_width_of(e3, "x"), 3)
    var t5 = ScriptedEmbedTransport()
    t5.add("", '{"data":[{"embedding":[1,2,3,4,5]}]}')
    var e5 = _embedder(t5^, 5)
    assert_equal(e5.dimension(), 5)
    assert_equal(_width_of(e5, "x"), 5)


def test_the_model_and_the_text_reach_the_transport() raises:
    var t = ScriptedEmbedTransport()
    # Only a request that names the model and holds the text is answered.
    t.add('"model":"emb-model"', '{"data":[{"embedding":[1,2]}]}')
    var e = _embedder(t^, 2)
    var v = e.embed("the text")
    assert_equal(v[0], 1.0)
    var t2 = ScriptedEmbedTransport()
    t2.add("the text", '{"data":[{"embedding":[7,8]}]}')
    var e2 = _embedder(t2^, 2)
    assert_equal(e2.embed("the text")[1], 8.0)
    # A request without it is not answered.
    with assert_raises(contains="no row matches the request"):
        _ = e2.embed("another text")


def test_a_batch_is_one_request_in_input_order() raises:
    var t = ScriptedEmbedTransport()
    t.add(
        '"input":["first","second","third"]',
        '{"data":[{"index":2,"embedding":[3,3]},{"index":0,"embedding":[1,1]},'
        '{"index":1,"embedding":[2,2]}]}',
    )
    var e = _embedder(t^, 2)
    var texts = List[String]()
    texts.append("first")
    texts.append("second")
    texts.append("third")
    var rows = e.embed_batch(texts)
    assert_equal(len(rows), 3)
    assert_equal(rows[0][0], 1.0)
    assert_equal(rows[1][0], 2.0)
    assert_equal(rows[2][0], 3.0)


def test_an_empty_batch_makes_no_request() raises:
    var e = _embedder(ScriptedEmbedTransport(), 2)
    assert_equal(len(e.embed_batch(List[String]())), 0)


def test_the_constructor_refuses_an_empty_model_and_a_bad_dimension() raises:
    with assert_raises(contains="model id is empty"):
        _ = EmbeddingsWireEmbedder[ScriptedEmbedTransport](
            ScriptedEmbedTransport(), "", 4
        )
    with assert_raises(contains="dimension must be positive, got 0"):
        _ = EmbeddingsWireEmbedder[ScriptedEmbedTransport](
            ScriptedEmbedTransport(), "m", 0
        )
    with assert_raises(contains="dimension must be positive, got -3"):
        _ = EmbeddingsWireEmbedder[ScriptedEmbedTransport](
            ScriptedEmbedTransport(), "m", -3
        )


def test_a_response_of_the_wrong_shape_is_refused() raises:
    var wide = ScriptedEmbedTransport()
    wide.add("", '{"data":[{"embedding":[1,2,3]}]}')
    with assert_raises(contains="3 components, the embedder's dimension is 2"):
        _ = _embedder(wide^, 2).embed("x")
    var many = ScriptedEmbedTransport()
    many.add("", '{"data":[{"embedding":[1,2]},{"embedding":[1,2]}]}')
    with assert_raises(contains="2 rows for 1 inputs"):
        _ = _embedder(many^, 2).embed("x")
    var bad = ScriptedEmbedTransport()
    bad.add("", "not json")
    with assert_raises(contains="JsonError"):
        _ = _embedder(bad^, 2).embed("x")
    var err = ScriptedEmbedTransport()
    err.add("", '{"error":{"message":"overloaded"}}')
    with assert_raises(contains="overloaded"):
        _ = _embedder(err^, 2).embed("x")


def test_the_scripted_transport_answers_the_first_matching_row() raises:
    var t = ScriptedEmbedTransport()
    t.add("alpha", "one")
    t.add("", "catch-all")
    t.add("alpha", "never reached")
    assert_equal(t.complete("an alpha request"), "one")
    assert_equal(t.complete("something else"), "catch-all")
    var empty = ScriptedEmbedTransport()
    with assert_raises(contains="ScriptedEmbedTransport: no row matches"):
        _ = empty.complete("short request")
    var long_request = String()
    for _ in range(100):
        long_request += "0123456789"
    try:
        _ = empty.complete(long_request)
    except e:
        var msg = String(e)
        assert_true("0123456789" in msg)
        # Only the beginning of a long request is quoted.
        assert_true(msg.byte_length() < 300, String(msg.byte_length()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
