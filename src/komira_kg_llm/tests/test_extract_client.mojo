# =============================================================================
# test_extract_client.mojo -- choosing between extracting by rules and by a model.
# =============================================================================
#
# The extractor and the model here are komira_kg's stubs, each answering a
# different name for the same text, so the answer shows which one was asked.
#
#   rules         extract goes to the extractor; both judgments are False even
#                 where the model would say yes (the model is not asked, shown
#                 by a model whose every judgment is yes); synthesis uses the
#                 model if there is one.
#   model         extract and both judgments go to the model; synthesis too; the
#                 extractor is not asked.
#   selection     a mode is normalised (an unknown integer is rules, never
#                 model); a name from a flag is parsed (model in any ASCII case
#                 is model, everything else, the empty string and a typo
#                 included, is rules); model without a model is an error in both
#                 spellings, and rules without one is fine.
#   synthesis     has_synthesis follows the model, in either mode; asking
#                 without a model is an error.
#   trait         a function generic over LlmClient instantiates with it.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg import LlmClient, StubExtractor, StubLlmClient
from komira_kg_format import EntityMention, Extraction, Triple
from komira_kg_llm import KgExtractClient
from komira_kg_mode import EXTRACT_MODE_MODEL, EXTRACT_MODE_RULES


comptime _Client = KgExtractClient[StubExtractor, StubLlmClient]


def _one_entity(name: String) -> Extraction:
    var entities = List[EntityMention]()
    entities.append(EntityMention(name, "", ""))
    return Extraction(entities^, List[Triple]())


def _extractor() -> StubExtractor:
    var e = StubExtractor()
    e.add_extraction_any_context("the text", _one_entity("from rules"))
    return e^


def _model(synthesis: Bool = True) -> StubLlmClient:
    var m = StubLlmClient()
    m.add_extraction_any_context("the text", _one_entity("from model"))
    m.add_contradiction("new", "old", True)
    m.add_same_entity("a", "b", True)
    if synthesis:
        m.add_synthesis("sys", "usr", "model answer")
    return m^


def _name(c: _Client) raises -> String:
    var ex = c.extract("the text", List[EntityMention]())
    return ex.entities[0].name


def _generic[L: LlmClient](l: L) raises -> String:
    return l.extract("the text", List[EntityMention]()).entities[0].name


def test_rules_mode_extracts_with_the_extractor_and_judges_false() raises:
    var c = _Client(EXTRACT_MODE_RULES, _extractor(), Optional[StubLlmClient](_model()))
    assert_equal(c.mode(), EXTRACT_MODE_RULES)
    assert_equal(_name(c), "from rules")
    # The model would say yes to both; in rules mode it is not asked.
    assert_false(c.judge_contradiction("new", "old"))
    assert_false(c.judge_same_entity("a", "", "b", ""))


def test_model_mode_sends_everything_to_the_model() raises:
    var c = _Client(EXTRACT_MODE_MODEL, _extractor(), Optional[StubLlmClient](_model()))
    assert_equal(c.mode(), EXTRACT_MODE_MODEL)
    assert_equal(_name(c), "from model")
    assert_true(c.judge_contradiction("new", "old"))
    assert_false(c.judge_contradiction("old", "new"))
    assert_true(c.judge_same_entity("a", "", "b", ""))
    assert_false(c.judge_same_entity("b", "", "a", ""))
    assert_equal(c.synthesize("sys", "usr"), "model answer")


def test_rules_mode_needs_no_model() raises:
    var c = _Client(EXTRACT_MODE_RULES, _extractor(), Optional[StubLlmClient]())
    assert_equal(_name(c), "from rules")
    assert_false(c.has_synthesis())
    assert_false(c.judge_contradiction("new", "old"))
    with assert_raises(contains="no model was given"):
        _ = c.synthesize("sys", "usr")


def test_rules_mode_synthesises_with_the_model_it_has() raises:
    var c = _Client(EXTRACT_MODE_RULES, _extractor(), Optional[StubLlmClient](_model()))
    assert_true(c.has_synthesis())
    assert_equal(c.synthesize("sys", "usr"), "model answer")
    # A model that cannot synthesise is reported as such.
    var none = _Client(
        EXTRACT_MODE_RULES, _extractor(), Optional[StubLlmClient](_model(False))
    )
    assert_false(none.has_synthesis())


def test_model_mode_reports_the_synthesis_of_its_model() raises:
    var yes = _Client(EXTRACT_MODE_MODEL, _extractor(), Optional[StubLlmClient](_model()))
    assert_true(yes.has_synthesis())
    var no = _Client(
        EXTRACT_MODE_MODEL, _extractor(), Optional[StubLlmClient](_model(False))
    )
    assert_false(no.has_synthesis())


def test_an_unknown_mode_is_rules_never_model() raises:
    var unknown = List[Int]()
    unknown.append(-1)
    unknown.append(2)
    unknown.append(3)
    unknown.append(1000)
    for i in range(len(unknown)):
        var c = _Client(unknown[i], _extractor(), Optional[StubLlmClient](_model()))
        assert_equal(c.mode(), EXTRACT_MODE_RULES)
        assert_equal(_name(c), "from rules")
        assert_false(c.judge_contradiction("new", "old"))


def test_a_name_from_a_flag_selects_the_mode() raises:
    var model = List[String]()
    model.append("model")
    model.append("MODEL")
    model.append("Model")
    for i in range(len(model)):
        var c = _Client.from_flag(model[i], _extractor(), Optional[StubLlmClient](_model()))
        assert_equal(c.mode(), EXTRACT_MODE_MODEL)
        assert_equal(_name(c), "from model")
    var rules = List[String]()
    rules.append("rules")
    rules.append("")
    rules.append("modle")
    rules.append("model ")
    rules.append("1")
    for i in range(len(rules)):
        var c = _Client.from_flag(rules[i], _extractor(), Optional[StubLlmClient](_model()))
        assert_equal(c.mode(), EXTRACT_MODE_RULES)
        assert_equal(_name(c), "from rules")


def test_model_mode_without_a_model_is_an_error() raises:
    with assert_raises(contains="the mode is model but no model was given"):
        _ = _Client(EXTRACT_MODE_MODEL, _extractor(), Optional[StubLlmClient]())
    with assert_raises(contains="the mode is model but no model was given"):
        _ = _Client.from_flag("model", _extractor(), Optional[StubLlmClient]())


def test_the_client_satisfies_the_trait() raises:
    var c = _Client(EXTRACT_MODE_MODEL, _extractor(), Optional[StubLlmClient](_model()))
    assert_equal(_generic(c^), "from model")
    var r = _Client(EXTRACT_MODE_RULES, _extractor(), Optional[StubLlmClient]())
    assert_equal(_generic(r^), "from rules")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
