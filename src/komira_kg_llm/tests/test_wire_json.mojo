# =============================================================================
# test_wire_json.mojo -- the request bodies and response readers of the two wires.
# =============================================================================
#
#   chat request       the model, the two messages in order with their roles, and
#                      no response_format unless a schema is given; any text (quotes,
#                      backslash, line breaks, NUL and other control bytes,
#                      non-ASCII) is read back from the body unchanged; a schema
#                      that is not a JSON object is refused.
#   chat response      the first choice's text; refusals for malformed JSON, a
#                      body that is not an object, an error object (its message
#                      quoted and cut), a null error beside a good answer (which
#                      is not an error), no choices, an empty or non-array
#                      choices, a choice without a message, a message without
#                      content, and content that is not text.
#   embeddings request the model and the texts in order, text unchanged.
#   embeddings response rows in input order or by index; refusals for the wrong
#                      count, a missing or non-array embedding, the wrong width
#                      (either side), a component that is not a number (a string,
#                      null), not finite (overflow to infinity) , a non-integer,
#                      negative, too large or repeated index; the error object.
#   bounded_text       cuts at a character boundary and keeps a short text whole.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_json import parse_json_value
from komira_kg_llm.wire_json import (
    WIRE_ERROR_QUOTE_BYTES,
    bounded_text,
    chat_message_content,
    chat_request_json,
    embeddings_request_json,
    parse_embeddings,
)


def _chat_error(body: String) -> String:
    try:
        _ = chat_message_content(body)
    except e:
        return String(e)
    return String()


def _embed_error(body: String, expected: Int, dimension: Int) -> String:
    try:
        _ = parse_embeddings(body, expected, dimension)
    except e:
        return String(e)
    return String()


def test_a_chat_request_has_the_model_and_two_messages() raises:
    var body = chat_request_json("the-model", "sys text", "user text", "")
    var v = parse_json_value(body)
    assert_equal(v.get("model").as_string(), "the-model")
    var messages = v.get("messages")
    assert_equal(messages.array_len(), 2)
    assert_equal(messages.element_at(0).get("role").as_string(), "system")
    assert_equal(messages.element_at(0).get("content").as_string(), "sys text")
    assert_equal(messages.element_at(1).get("role").as_string(), "user")
    assert_equal(messages.element_at(1).get("content").as_string(), "user text")
    assert_false(v.has("response_format"))
    assert_equal(v.num_members(), 2)


def test_any_text_reaches_the_body_unchanged() raises:
    var tricky = String('quote " backslash \\ slash / ')
    tricky += "line\nbreak\rreturn\ttab"
    tricky += " nul " + chr(0) + " bel " + chr(7) + " us " + chr(31)
    tricky += " é ü 日本語 🙂 \\n literal"
    var body = chat_request_json(tricky, tricky + "1", tricky + "2", "")
    var v = parse_json_value(body)
    assert_equal(v.get("model").as_string(), tricky)
    var messages = v.get("messages")
    assert_equal(messages.element_at(0).get("content").as_string(), tricky + "1")
    assert_equal(messages.element_at(1).get("content").as_string(), tricky + "2")


def test_a_response_schema_is_attached_as_json() raises:
    var schema = '{"type":"object","properties":{"a":{"type":"string"}}}'
    var v = parse_json_value(chat_request_json("m", "s", "u", schema))
    var format = v.get("response_format")
    assert_equal(format.get("type").as_string(), "json_schema")
    assert_equal(format.get("json_schema").get("name").as_string(), "extraction")
    assert_equal(format.get("json_schema").get("schema").serialize(), schema)
    with assert_raises(contains="not a JSON object"):
        _ = chat_request_json("m", "s", "u", "[1,2]")
    with assert_raises(contains="JsonError"):
        _ = chat_request_json("m", "s", "u", "{oops")


def test_the_text_of_the_first_choice_is_returned() raises:
    var body = (
        '{"id":"x","choices":[{"index":0,"message":{"role":"assistant",'
        '"content":"first é"}},{"message":{"content":"second"}}],'
        '"usage":{"n":1}}'
    )
    assert_equal(chat_message_content(body), "first é")
    # A server that always includes `error` says null on success.
    var with_null = '{"error":null,"choices":[{"message":{"content":"ok"}}]}'
    assert_equal(chat_message_content(with_null), "ok")
    assert_equal(
        chat_message_content('{"choices":[{"message":{"content":""}}]}'), ""
    )


def test_a_chat_response_is_checked() raises:
    assert_true("JsonError" in _chat_error("{not json"))
    assert_true("JsonError" in _chat_error(""))
    assert_true("not a JSON object" in _chat_error("[1]"))
    assert_true("not a JSON object" in _chat_error('"text"'))
    assert_true("no 'choices'" in _chat_error("{}"))
    assert_true("non-empty array" in _chat_error('{"choices":[]}'))
    assert_true("non-empty array" in _chat_error('{"choices":{}}'))
    assert_true("no 'message'" in _chat_error('{"choices":[{}]}'))
    assert_true("no 'message'" in _chat_error('{"choices":[3]}'))
    assert_true("no 'content'" in _chat_error('{"choices":[{"message":{}}]}'))
    assert_true("no 'content'" in _chat_error('{"choices":[{"message":"x"}]}'))
    assert_true(
        "not text" in _chat_error('{"choices":[{"message":{"content":null}}]}')
    )
    assert_true(
        "not text" in _chat_error('{"choices":[{"message":{"content":["a"]}}]}')
    )


def test_a_server_error_is_quoted_and_cut() raises:
    assert_true(
        "server error: model is loading"
        in _chat_error('{"error":{"message":"model is loading"}}')
    )
    assert_true(
        "no message" in _chat_error('{"error":{"code":5}}')
    )
    assert_true("no message" in _chat_error('{"error":"flat string"}'))
    assert_true("no message" in _chat_error('{"error":{"message":7}}'))
    var long_message = String()
    for _ in range(300):
        long_message += "abcdefghij"
    var err = _chat_error('{"error":{"message":"' + long_message + '"}}')
    assert_true(err.byte_length() < WIRE_ERROR_QUOTE_BYTES + 40, String(err.byte_length()))
    assert_true("abcdefghij" in err)
    # The same object is refused by the embeddings reader.
    assert_true(
        "server error: busy" in _embed_error('{"error":{"message":"busy"}}', 1, 2)
    )


def test_an_embeddings_request_has_the_model_and_the_texts() raises:
    var texts = List[String]()
    texts.append('a "b"')
    texts.append("line\nbreak é")
    texts.append("")
    var v = parse_json_value(embeddings_request_json("emb-model", texts))
    assert_equal(v.get("model").as_string(), "emb-model")
    var input = v.get("input")
    assert_equal(input.array_len(), 3)
    for i in range(3):
        assert_equal(input.element_at(i).as_string(), texts[i])
    assert_equal(v.num_members(), 2)


def test_rows_come_back_in_input_order() raises:
    var plain = parse_embeddings(
        '{"data":[{"embedding":[1,2]},{"embedding":[3,4]}]}', 2, 2
    )
    assert_equal(len(plain), 2)
    assert_equal(plain[0][0], 1.0)
    assert_equal(plain[0][1], 2.0)
    assert_equal(plain[1][0], 3.0)
    assert_equal(plain[1][1], 4.0)
    var shuffled = parse_embeddings(
        '{"data":[{"index":2,"embedding":[5,6]},{"index":0,"embedding":[1,2]},'
        '{"index":1,"embedding":[3.5,-4e0]}],"model":"m","usage":{}}',
        3,
        2,
    )
    assert_equal(shuffled[0][0], 1.0)
    assert_equal(shuffled[1][0], 3.5)
    assert_equal(shuffled[1][1], -4.0)
    assert_equal(shuffled[2][1], 6.0)


def test_the_row_count_must_match() raises:
    assert_true("1 rows for 2 inputs" in _embed_error('{"data":[{"embedding":[1]}]}', 2, 1))
    assert_true("3 rows for 2 inputs" in _embed_error(
        '{"data":[{"embedding":[1]},{"embedding":[1]},{"embedding":[1]}]}', 2, 1
    ))
    assert_true("0 rows for 1 inputs" in _embed_error('{"data":[]}', 1, 1))
    assert_equal(len(parse_embeddings('{"data":[]}', 0, 1)), 0)


def test_the_envelope_is_checked() raises:
    assert_true("JsonError" in _embed_error("{nope", 1, 1))
    assert_true("not a JSON object" in _embed_error("[]", 1, 1))
    assert_true("no 'data'" in _embed_error("{}", 1, 1))
    assert_true("not an array" in _embed_error('{"data":{}}', 1, 1))
    assert_true("no 'embedding'" in _embed_error('{"data":[{}]}', 1, 1))
    assert_true("no 'embedding'" in _embed_error('{"data":[7]}', 1, 1))
    assert_true(
        "'embedding' is not an array" in _embed_error('{"data":[{"embedding":"12"}]}', 1, 1)
    )


def test_each_row_must_have_the_dimension() raises:
    var short = '{"data":[{"embedding":[1,2]}]}'
    var long = '{"data":[{"embedding":[1,2,3,4]}]}'
    assert_true("2 components, the embedder's dimension is 3" in _embed_error(short, 1, 3))
    assert_true("4 components, the embedder's dimension is 3" in _embed_error(long, 1, 3))
    assert_equal(_embed_error(short, 1, 2), "")
    # The second row is the wrong one.
    assert_true("row 1 has 1 components" in _embed_error(
        '{"data":[{"embedding":[1,2]},{"embedding":[3]}]}', 2, 2
    ))
    assert_true("0 components" in _embed_error('{"data":[{"embedding":[]}]}', 1, 2))


def test_every_component_must_be_a_finite_number() raises:
    assert_true("component 1 is not a number" in _embed_error('{"data":[{"embedding":[1,"2"]}]}', 1, 2))
    assert_true("component 0 is not a number" in _embed_error('{"data":[{"embedding":[null,2]}]}', 1, 2))
    assert_true("component 1 is not a number" in _embed_error('{"data":[{"embedding":[1,true]}]}', 1, 2))
    assert_true("component 1 is not a number" in _embed_error('{"data":[{"embedding":[1,[2]]}]}', 1, 2))
    assert_true("component 0 is not finite" in _embed_error('{"data":[{"embedding":[1e999,2]}]}', 1, 2))
    assert_true("component 1 is not finite" in _embed_error('{"data":[{"embedding":[1,-1e999]}]}', 1, 2))
    assert_equal(_embed_error('{"data":[{"embedding":[1e300,-1e-300]}]}', 1, 2), "")


def test_the_index_must_be_a_permutation() raises:
    assert_true("not an integer" in _embed_error('{"data":[{"index":"0","embedding":[1]}]}', 1, 1))
    assert_true("not an integer" in _embed_error('{"data":[{"index":0.5,"embedding":[1]}]}', 1, 1))
    assert_true("outside 0 to 0" in _embed_error('{"data":[{"index":1,"embedding":[1]}]}', 1, 1))
    assert_true("outside 0 to 1" in _embed_error(
        '{"data":[{"index":-1,"embedding":[1]},{"index":0,"embedding":[1]}]}', 2, 1
    ))
    assert_true("two rows answer input 1" in _embed_error(
        '{"data":[{"index":1,"embedding":[1]},{"index":1,"embedding":[2]}]}', 2, 1
    ))
    # A row without an index takes its own position; a repeat of that position
    # is a conflict like any other.
    assert_true("two rows answer input 0" in _embed_error(
        '{"data":[{"embedding":[1]},{"index":0,"embedding":[2]}]}', 2, 1
    ))
    assert_true("outside 0 to 1" in _embed_error(
        '{"data":[{"index":9223372036854775807,"embedding":[1]},{"embedding":[2]}]}', 2, 1
    ))


def test_bounded_text_cuts_between_characters() raises:
    assert_equal(bounded_text("abc", 3), "abc")
    assert_equal(bounded_text("abc", 10), "abc")
    assert_equal(bounded_text("abcd", 3), "abc")
    assert_equal(bounded_text("", 0), "")
    assert_equal(bounded_text("abc", 0), "")
    # "é" is two bytes: a cut inside it backs off to before it.
    assert_equal(bounded_text("aéb", 2), "a")
    assert_equal(bounded_text("aéb", 3), "aé")
    # "日" is three bytes.
    assert_equal(bounded_text("日本", 4), "日")
    assert_equal(bounded_text("日本", 6), "日本")
    assert_equal(bounded_text("é", 1), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
