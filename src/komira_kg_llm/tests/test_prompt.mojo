# =============================================================================
# test_prompt.mojo -- the prompts a chat client is given, and how they are filled
# in.
# =============================================================================
#
#   construction   an extraction prompt needs a system text and a user template
#                  with {text}, entity types that are not empty, and a response
#                  schema that is empty or a JSON object; a judgment prompt needs
#                  a system text, {new} and {old}, {a} and {b}. Each refusal has
#                  its own case.
#   user message   {text} is replaced by the text as given; {known} lists the
#                  entities already found by name, or is empty; {types} lists the
#                  caller's types, or is empty; a placeholder the template does
#                  not use is not added; a brace that names no placeholder stays.
#   one pass       text that holds a placeholder (even {known}) is not replaced
#                  again; unbalanced braces, a brace at the end and a name that
#                  runs past the end are kept.
#   judgments      {new} {old} and {a} {b}, with a summary in parentheses only
#                  when there is one.
#   neutral        the neutral prompts build, name no domain, carry the contract
#                  of the extraction answer, and the neutral schema is a JSON
#                  object with the keys the client reads.
#   genericity     two different prompts through the same code give two
#                  different messages.
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
from komira_kg_format import EntityMention
from komira_kg_llm import (
    ExtractionPrompt,
    JudgmentPrompt,
    neutral_response_schema,
)


def _none() -> List[EntityMention]:
    return List[EntityMention]()


def _found(names: List[String]) -> List[EntityMention]:
    var out = List[EntityMention]()
    for i in range(len(names)):
        out.append(EntityMention(names[i], "kind", "summary"))
    return out^


def _types(names: List[String]) -> List[String]:
    return names.copy()


def test_an_extraction_prompt_is_checked() raises:
    with assert_raises(contains="system text is empty"):
        _ = ExtractionPrompt("", "{text}", List[String](), "")
    with assert_raises(contains="no {text}"):
        _ = ExtractionPrompt("sys", "no placeholder", List[String](), "")
    with assert_raises(contains="no {text}"):
        _ = ExtractionPrompt("sys", "{known}{types}", List[String](), "")
    var types = List[String]()
    types.append("one")
    types.append("")
    with assert_raises(contains="an entity type is empty"):
        _ = ExtractionPrompt("sys", "{text}", types^, "")
    with assert_raises(contains="not a JSON object"):
        _ = ExtractionPrompt("sys", "{text}", List[String](), "[1]")
    with assert_raises(contains="JsonError"):
        _ = ExtractionPrompt("sys", "{text}", List[String](), "{not json")
    var ok = ExtractionPrompt("sys", "{text}", List[String](), '{"type":"object"}')
    assert_equal(ok.system_text, "sys")
    assert_equal(ok.response_schema, '{"type":"object"}')


def test_a_judgment_prompt_is_checked() raises:
    with assert_raises(contains="system text is empty"):
        _ = JudgmentPrompt("", "{new} {old}", "{a} {b}")
    with assert_raises(contains="needs {new} and {old}"):
        _ = JudgmentPrompt("s", "{old}", "{a} {b}")
    with assert_raises(contains="needs {new} and {old}"):
        _ = JudgmentPrompt("s", "{new}", "{a} {b}")
    with assert_raises(contains="needs {a} and {b}"):
        _ = JudgmentPrompt("s", "{new} {old}", "{a}")
    with assert_raises(contains="needs {a} and {b}"):
        _ = JudgmentPrompt("s", "{new} {old}", "{b}")
    var ok = JudgmentPrompt("s", "{old} then {new}", "{b}/{a}")
    assert_equal(ok.render_contradiction("N", "O"), "O then N")


def test_the_text_is_substituted_as_given() raises:
    var p = ExtractionPrompt("s", "[{text}]", List[String](), "")
    assert_equal(p.render_user("plain", _none()), "[plain]")
    assert_equal(p.render_user("", _none()), "[]")
    assert_equal(
        p.render_user('quote " and \\ and\nnewline é', _none()),
        '[quote " and \\ and\nnewline é]',
    )


def test_known_entities_and_types_are_listed_only_when_present() raises:
    var p = ExtractionPrompt("s", "{text}|{known}|{types}", List[String](), "")
    assert_equal(p.render_user("t", _none()), "t||")
    var names = List[String]()
    names.append("Alpha")
    names.append("Beta")
    var with_known = p.render_user("t", _found(names))
    assert_true(with_known.startswith("t|Entities already found"), with_known)
    assert_true("- Alpha\n- Beta\n|" in with_known, with_known)
    assert_true(with_known.endswith("|"), with_known)
    var kinds = List[String]()
    kinds.append("person")
    kinds.append("place")
    var q = ExtractionPrompt("s", "{text}|{known}|{types}", kinds^, "")
    var with_types = q.render_user("t", _none())
    assert_true(with_types.startswith("t||Entity types"), with_types)
    assert_true(with_types.endswith("- person\n- place\n"), with_types)


def test_a_template_may_leave_placeholders_out() raises:
    var p = ExtractionPrompt("s", "just {text}", List[String](), "")
    var names = List[String]()
    names.append("Alpha")
    assert_equal(p.render_user("t", _found(names)), "just t")


def test_substitution_is_one_pass() raises:
    var p = ExtractionPrompt("s", "{text}|{known}", List[String](), "")
    var names = List[String]()
    names.append("{text}")
    # The text holds {known}; the known entity's name holds {text}. Neither is
    # replaced again.
    var out = p.render_user("see {known} and {text}", _found(names))
    assert_true(out.startswith("see {known} and {text}|"), out)
    assert_true("- {text}\n" in out, out)


def test_braces_that_name_no_placeholder_stay() raises:
    var p = ExtractionPrompt("s", "{text}{ {unknown} {} {{text}} } {tex", List[String](), "")
    assert_equal(
        p.render_user("T", _none()),
        "T{ {unknown} {} {T} } {tex",
    )
    var q = ExtractionPrompt("s", "{text}{", List[String](), "")
    assert_equal(q.render_user("T", _none()), "T{")
    var r = ExtractionPrompt("s", "{text}{tex", List[String](), "")
    assert_equal(r.render_user("T", _none()), "T{tex")
    var s = ExtractionPrompt("s", "{text}{text", List[String](), "")
    assert_equal(s.render_user("T", _none()), "T{text")


def test_judgments_are_filled_in() raises:
    var p = JudgmentPrompt.neutral()
    var c = p.render_contradiction("it is open", "it is closed")
    assert_true("NEW: it is open\n" in c, c)
    assert_true("OLD: it is closed\n" in c, c)
    var same = p.render_same_entity("Ann", "", "Ann B", "a person")
    assert_true("A: Ann\n" in same, same)
    assert_true("B: Ann B (a person)\n" in same, same)
    var both = p.render_same_entity("X", "x summary", "Y", "")
    assert_true("A: X (x summary)\n" in both, both)
    assert_true("B: Y\n" in both, both)
    # Text holding a placeholder is not substituted again.
    var tricky = p.render_contradiction("{old}", "{new}")
    assert_true("NEW: {old}\n" in tricky, tricky)
    assert_true("OLD: {new}\n" in tricky, tricky)


def test_the_neutral_prompts() raises:
    var e = ExtractionPrompt.neutral()
    assert_true(e.system_text.byte_length() > 0)
    assert_true("{text}" in e.user_template)
    assert_equal(len(e.entity_types), 0)
    assert_equal(e.response_schema, "")
    # The contract of the answer is stated, so a custom prompt can copy it.
    for key in ["entities", "triples", "subject", "predicate", "object", "fact", "name"]:
        assert_true(String(key) in e.system_text, key)
    var j = JudgmentPrompt.neutral()
    assert_true("yes" in j.system_text and "no" in j.system_text)
    assert_true("{new}" in j.contradiction_template)
    assert_true("{a}" in j.same_entity_template)
    var schema = parse_json_value(neutral_response_schema())
    assert_true(schema.is_object())
    assert_true(schema.get("properties").has("entities"))
    assert_true(schema.get("properties").has("triples"))
    # The neutral schema is accepted as a response schema.
    var with_schema = ExtractionPrompt(
        e.system_text, e.user_template, List[String](), neutral_response_schema()
    )
    assert_equal(with_schema.response_schema, neutral_response_schema())


def test_two_prompts_give_two_messages_from_the_same_code() raises:
    var a = ExtractionPrompt("system a", "A says: {text}", List[String](), "")
    var b = ExtractionPrompt("system b", "{text} <- B says", List[String](), "")
    assert_equal(a.render_user("same", _none()), "A says: same")
    assert_equal(b.render_user("same", _none()), "same <- B says")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
