# =============================================================================
# test_chat_client.mojo -- ChatCompletionsLlmClient over a scripted transport.
# =============================================================================
#
#   trait         a function generic over LlmClient instantiates with it, and the
#                 client always reports synthesis.
#   prompts       the model id, the caller's system text and the filled-in user
#                 message reach the transport (a scripted row answers only a
#                 request that holds them): extraction, each judgment and
#                 synthesis; two different prompts give two different requests;
#                 a response schema is attached only when the prompt has one.
#   extraction    the answer is read as entities and triples: all fields, a text
#                 in a fenced block, a trailing stop token, braces and escaped
#                 quotes inside strings, the first of two objects, missing
#                 arrays, entries without a name, subject or object skipped,
#                 fields of the wrong type read as empty, a triple open from the
#                 start (valid_at 0, invalid_at the open-interval sentinel), and
#                 entities already found named in the prompt.
#   refusals      no object, an object that is not closed, an object that is not
#                 JSON, a top-level array, and a response that is not a chat
#                 response are errors.
#   judgments     yes, Yes., TRUE, y and "yes, because" are yes; no, an empty
#                 answer, an unsure answer and a word that merely begins with the
#                 letters are no.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_json import JsonValue
from komira_kg import LlmClient
from komira_kg_format import EntityMention, Extraction, TS_OPEN_SENTINEL
from komira_kg_llm import (
    ChatCompletionsLlmClient,
    ExtractionPrompt,
    JudgmentPrompt,
    ScriptedChatTransport,
)


comptime _Client = ChatCompletionsLlmClient[ScriptedChatTransport]


def _reply(content: String) raises -> String:
    """A chat response whose first choice holds `content`."""
    var message = JsonValue.empty_object()
    message.set_member("role", JsonValue.from_string("assistant"))
    message.set_member("content", JsonValue.from_string(content))
    var choice = JsonValue.empty_object()
    choice.set_member("message", message^)
    var choices = JsonValue.empty_array()
    choices.push(choice^)
    var root = JsonValue.empty_object()
    root.set_member("choices", choices^)
    return root.serialize()


def _client(
    var transport: ScriptedChatTransport,
    prompt: ExtractionPrompt = ExtractionPrompt.neutral(),
) raises -> _Client:
    return _Client(transport^, "chat-model", prompt.copy(), JudgmentPrompt.neutral())


def _extract(content: String) raises -> Extraction:
    var t = ScriptedChatTransport()
    t.add("", _reply(content))
    return _client(t^).extract("some text", List[EntityMention]())


def _extract_error(content: String) -> String:
    try:
        _ = _extract(content)
    except e:
        return String(e)
    return String()


def _answer(content: String, judge_new: Bool) raises -> Bool:
    var t = ScriptedChatTransport()
    t.add("", _reply(content))
    var c = _client(t^)
    if judge_new:
        return c.judge_contradiction("new", "old")
    return c.judge_same_entity("a", "", "b", "")


def _drive[L: LlmClient](l: L) raises -> Bool:
    return l.has_synthesis()


def test_the_client_satisfies_the_trait() raises:
    var c = _client(ScriptedChatTransport())
    assert_true(_drive(c^))


def test_extraction_reads_every_field() raises:
    var ex = _extract(
        '{"entities":[{"name":"Ann","entity_type":"person","summary":"a"},'
        '{"name":"Bo"}],"triples":[{"subject":"Ann","predicate":"knows",'
        '"object":"Bo","fact":"Ann knows Bo"}]}'
    )
    assert_equal(len(ex.entities), 2)
    assert_equal(ex.entities[0].name, "Ann")
    assert_equal(ex.entities[0].entity_type, "person")
    assert_equal(ex.entities[0].summary, "a")
    assert_equal(ex.entities[1].name, "Bo")
    assert_equal(ex.entities[1].entity_type, "")
    assert_equal(ex.entities[1].summary, "")
    assert_equal(len(ex.triples), 1)
    assert_equal(ex.triples[0].subject_name, "Ann")
    assert_equal(ex.triples[0].predicate, "knows")
    assert_equal(ex.triples[0].object_name, "Bo")
    assert_equal(ex.triples[0].fact, "Ann knows Bo")
    # Undated: open from the start of time, until ingest dates it.
    assert_equal(ex.triples[0].valid_at, Int64(0))
    assert_equal(ex.triples[0].invalid_at, TS_OPEN_SENTINEL)


def test_extraction_finds_the_object_in_the_text_around_it() raises:
    var obj = '{"entities":[{"name":"Ann"}],"triples":[]}'
    var fenced = _extract("Here it is:\n```json\n" + obj + "\n```\nDone.")
    assert_equal(len(fenced.entities), 1)
    var stopped = _extract(obj + "<|end|>")
    assert_equal(len(stopped.entities), 1)
    # Braces and escaped quotes inside strings do not end the object early.
    var braces = _extract(
        '{"entities":[{"name":"a } b { \\" c","summary":"}"}],"triples":[]}'
    )
    assert_equal(len(braces.entities), 1)
    assert_equal(braces.entities[0].name, 'a } b { " c')
    assert_equal(braces.entities[0].summary, "}")
    # An escaped backslash before the closing quote does end the string.
    var slash = _extract('{"entities":[{"name":"x\\\\"}],"triples":[]} {"entities":[]}')
    assert_equal(slash.entities[0].name, "x\\")
    # Only the first object is read.
    var two = _extract(obj + ' {"entities":[{"name":"Other"}]}')
    assert_equal(len(two.entities), 1)
    assert_equal(two.entities[0].name, "Ann")


def test_extraction_skips_what_it_cannot_use() raises:
    var ex = _extract(
        '{"entities":[{"name":""},{"entity_type":"t"},{"name":7},'
        '{"name":"Keep","entity_type":5,"summary":null},"text",null],'
        '"triples":[{"subject":"","predicate":"p","object":"o"},'
        '{"subject":"s","predicate":"p","object":""},'
        '{"subject":"s","object":"o"},{"subject":3,"object":"o"},'
        '{"subject":"s","predicate":4,"object":"o","fact":false}]}'
    )
    assert_equal(len(ex.entities), 1)
    assert_equal(ex.entities[0].name, "Keep")
    assert_equal(ex.entities[0].entity_type, "")
    assert_equal(ex.entities[0].summary, "")
    assert_equal(len(ex.triples), 2)
    assert_equal(ex.triples[0].predicate, "")
    assert_equal(ex.triples[0].fact, "")
    assert_equal(ex.triples[1].predicate, "")
    assert_equal(ex.triples[1].fact, "")


def test_missing_or_mistyped_arrays_are_empty() raises:
    var none = _extract("{}")
    assert_equal(len(none.entities), 0)
    assert_equal(len(none.triples), 0)
    var wrong = _extract('{"entities":"x","triples":{"a":1}}')
    assert_equal(len(wrong.entities), 0)
    assert_equal(len(wrong.triples), 0)


def test_an_answer_without_a_usable_object_is_refused() raises:
    assert_true("no JSON object" in _extract_error("nothing to see"))
    assert_true("no JSON object" in _extract_error(""))
    assert_true("no JSON object" in _extract_error('["a"]'))
    assert_true("not closed" in _extract_error('{"entities":['))
    assert_true("not closed" in _extract_error('{"a":"}'))
    assert_true("JsonError" in _extract_error("{entities: 1}"))
    assert_true("JsonError" in _extract_error('{"a":1,}'))


def test_a_response_that_is_not_a_chat_response_is_refused() raises:
    var t = ScriptedChatTransport()
    t.add("", '{"choices":[]}')
    with assert_raises(contains="non-empty array"):
        _ = _client(t^).extract("t", List[EntityMention]())
    var u = ScriptedChatTransport()
    u.add("", "plain text")
    with assert_raises(contains="JsonError"):
        _ = _client(u^).judge_contradiction("a", "b")
    var v = ScriptedChatTransport()
    v.add("", '{"error":{"message":"rate limited"}}')
    with assert_raises(contains="rate limited"):
        _ = _client(v^).synthesize("s", "u")


def test_a_judgment_is_yes_only_for_yes() raises:
    var yes = List[String]()
    yes.append("yes")
    yes.append("Yes.")
    yes.append("  YES")
    yes.append('"yes"')
    yes.append("true")
    yes.append("TRUE.")
    yes.append("y")
    yes.append("yes, because they match")
    yes.append("\n\n- Yes")
    for i in range(len(yes)):
        assert_true(_answer(yes[i], True), yes[i])
        assert_true(_answer(yes[i], False), yes[i])
    var no = List[String]()
    no.append("no")
    no.append("No.")
    no.append("false")
    no.append("")
    no.append("12345")
    no.append("maybe")
    no.append("I think so")
    no.append("yesterday")
    no.append("truest")
    no.append("n")
    for i in range(len(no)):
        assert_false(_answer(no[i], True), no[i])
        assert_false(_answer(no[i], False), no[i])


def test_the_model_the_system_text_and_the_user_message_reach_the_transport() raises:
    var prompt = ExtractionPrompt(
        "system one", "ONE<{text}>{known}", List[String](), ""
    )
    var t = ScriptedChatTransport()
    t.add(
        '"model":"chat-model"',
        _reply('{"entities":[{"name":"Matched"}],"triples":[]}'),
    )
    var c = _client(t^, prompt)
    var found = List[EntityMention]()
    found.append(EntityMention("Known Name", "", ""))
    var ex = c.extract("the body", found)
    assert_equal(ex.entities[0].name, "Matched")
    # The scripted rows below match only on the system text and the user message
    # that two different prompts produce.
    var a = ExtractionPrompt("system one", "ONE<{text}>", List[String](), "")
    var b = ExtractionPrompt("system two", "TWO[{text}]", List[String](), "")
    var ta = ScriptedChatTransport()
    ta.add('"content":"system one"', _reply('{"entities":[{"name":"A"}]}'))
    var tb = ScriptedChatTransport()
    tb.add('"content":"system two"', _reply('{"entities":[{"name":"B"}]}'))
    var ca = _client(ta^, a)
    var cb = _client(tb^, b)
    assert_equal(ca.extract("x", List[EntityMention]()).entities[0].name, "A")
    assert_equal(cb.extract("x", List[EntityMention]()).entities[0].name, "B")
    var ta2 = ScriptedChatTransport()
    ta2.add('"content":"ONE<same>"', _reply('{"entities":[{"name":"A2"}]}'))
    var tb2 = ScriptedChatTransport()
    tb2.add('"content":"TWO[same]"', _reply('{"entities":[{"name":"B2"}]}'))
    assert_equal(_client(ta2^, a).extract("same", List[EntityMention]()).entities[0].name, "A2")
    assert_equal(_client(tb2^, b).extract("same", List[EntityMention]()).entities[0].name, "B2")
    # The names already found are in the user message.
    var tk = ScriptedChatTransport()
    tk.add("- Known Name", _reply('{"entities":[{"name":"K"}]}'))
    var ck = _client(tk^, ExtractionPrompt("s", "{text}{known}", List[String](), ""))
    assert_equal(ck.extract("x", found).entities[0].name, "K")


def test_the_schema_is_attached_only_when_the_prompt_has_one() raises:
    var plain = ScriptedChatTransport()
    plain.add("response_format", "WRONG")
    plain.add("", _reply('{"entities":[{"name":"P"}]}'))
    # The first row would match a request with a schema; it must not be reached.
    assert_equal(
        _client(plain^).extract("x", List[EntityMention]()).entities[0].name, "P"
    )
    var schema = ExtractionPrompt(
        "s", "{text}", List[String](), '{"type":"object"}'
    )
    var with_schema = ScriptedChatTransport()
    with_schema.add(
        '"response_format":{"type":"json_schema","json_schema":{"name":"extraction","schema":{"type":"object"}}}',
        _reply('{"entities":[{"name":"S"}]}'),
    )
    assert_equal(
        _client(with_schema^, schema).extract("x", List[EntityMention]()).entities[0].name,
        "S",
    )


def test_judgments_and_synthesis_send_the_messages_they_should() raises:
    var t = ScriptedChatTransport()
    t.add("NEW: the new\\nOLD: the old", _reply("yes"))
    assert_true(_client(t^).judge_contradiction("the new", "the old"))
    var u = ScriptedChatTransport()
    u.add("A: Ann (the first)\\nB: Anne\\n", _reply("yes"))
    assert_true(_client(u^).judge_same_entity("Ann", "the first", "Anne", ""))
    # The judgments use the judgment system text.
    var j = ScriptedChatTransport()
    j.add('"content":"Answer the question with ONLY', _reply("yes"))
    assert_true(_client(j^).judge_contradiction("a", "b"))
    # Synthesis sends exactly the two messages it was given.
    var s = ScriptedChatTransport()
    s.add(
        '"messages":[{"role":"system","content":"S text"},{"role":"user","content":"U text"}]',
        _reply("the answer"),
    )
    assert_equal(_client(s^).synthesize("S text", "U text"), "the answer")


def test_the_constructor_refuses_an_empty_model() raises:
    with assert_raises(contains="model id is empty"):
        _ = _Client(
            ScriptedChatTransport(),
            "",
            ExtractionPrompt.neutral(),
            JudgmentPrompt.neutral(),
        )


def test_the_scripted_transport_answers_the_first_matching_row() raises:
    var t = ScriptedChatTransport()
    t.add("alpha", "one")
    t.add("", "catch-all")
    assert_equal(t.complete("an alpha request"), "one")
    assert_equal(t.complete("something else"), "catch-all")
    var empty = ScriptedChatTransport()
    with assert_raises(contains="ScriptedChatTransport: no row matches"):
        _ = empty.complete("request")
    var long_request = String()
    for _ in range(100):
        long_request += "0123456789"
    try:
        _ = empty.complete(long_request)
    except e:
        assert_true(String(e).byte_length() < 300)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
