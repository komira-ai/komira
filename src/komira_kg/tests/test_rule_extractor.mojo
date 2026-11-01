# =============================================================================
# test_rule_extractor.mojo -- RuleExtractor over made-up rule sets.
# =============================================================================
#
#   fixed output   a stated rule set on a stated text gives exactly these
#                  entities (name, type, summary) and these triples (subject,
#                  predicate, object, fact, valid_at, invalid_at), in this order.
#   rules are data two rule sets with different types, matchers and predicates
#                  give two vocabularies from the same code on the same text, and
#                  the empty rule set gives nothing.
#   order          the first rule to find a name decides its type, a name is
#                  kept once, and a stop name is dropped ignoring ASCII case.
#   edges          an empty predicate turns edges off, the entity cap bounds
#                  them, and a cap of zero gives none.
#   gleaning       the same call twice gives the same answer; given the first
#                  pass's entities the answer is empty; given some of them, only
#                  the missing entities and the edges touching one come back.
#   trait          a function generic over Extractor accepts it.
#   refusals       a negative cap and an empty stop name are refused.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_kg import Extractor, Rule, RuleExtractor
from komira_kg_format import EntityMention, Extraction, TS_OPEN_SENTINEL


def _strings(a: String, b: String = "", c: String = "") -> List[String]:
    var w = List[String]()
    w.append(a)
    if len(b.as_bytes()) > 0:
        w.append(b)
    if len(c.as_bytes()) > 0:
        w.append(c)
    return w^


def _set_a(max_entities: Int = 12) raises -> RuleExtractor:
    var rules = List[Rule]()
    rules.append(Rule.token_pattern("tag", "#[a-z]+"))
    rules.append(Rule.word_list("code", _strings("alpha", "beta", "note")))
    rules.append(Rule.email("handle"))
    return RuleExtractor(
        rules^, _strings("NOTE"), String("co_occurs_with"), max_entities
    )


def _set_b() raises -> RuleExtractor:
    var rules = List[Rule]()
    rules.append(Rule.token_pattern("ref", "[A-Z]+-\\d+"))
    rules.append(Rule.verb_prefix("action", _strings("open", "close")))
    return RuleExtractor(rules^, List[String](), String("mentions"), 12)


comptime TEXT_A = "Note: alpha uses #red and #blue, note ann@x.example about beta. #red again"
comptime TEXT_AB = "open note AB-1 then note ann@x.example about #red alpha"


def _count_summaries_empty(ex: Extraction) -> Bool:
    for i in range(len(ex.entities)):
        if len(ex.entities[i].summary.as_bytes()) != 0:
            return False
    return True


def test_a_rule_set_on_fixed_text_gives_fixed_entities_and_triples() raises:
    var x = _set_a()
    var ex = x.extract(TEXT_A, List[EntityMention]())
    assert_equal(ex.num_entities(), 5)
    assert_equal(ex.entities[0].name, "#red")
    assert_equal(ex.entities[0].entity_type, "tag")
    assert_equal(ex.entities[1].name, "#blue")
    assert_equal(ex.entities[1].entity_type, "tag")
    assert_equal(ex.entities[2].name, "alpha")
    assert_equal(ex.entities[2].entity_type, "code")
    assert_equal(ex.entities[3].name, "beta")
    assert_equal(ex.entities[3].entity_type, "code")
    assert_equal(ex.entities[4].name, "ann@x.example")
    assert_equal(ex.entities[4].entity_type, "handle")
    assert_true(_count_summaries_empty(ex))
    # Five findings: every pair, in (i, j) order.
    assert_equal(ex.num_triples(), 10)
    assert_equal(ex.triples[0].subject_name, "#red")
    assert_equal(ex.triples[0].predicate, "co_occurs_with")
    assert_equal(ex.triples[0].object_name, "#blue")
    assert_equal(ex.triples[0].fact, "#red co_occurs_with #blue")
    assert_equal(ex.triples[0].valid_at, Int64(0))
    assert_equal(ex.triples[0].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(ex.triples[3].object_name, "ann@x.example")
    assert_equal(ex.triples[4].subject_name, "#blue")
    assert_equal(ex.triples[4].object_name, "alpha")
    assert_equal(ex.triples[9].subject_name, "beta")
    assert_equal(ex.triples[9].object_name, "ann@x.example")
    assert_equal(ex.triples[9].fact, "beta co_occurs_with ann@x.example")
    assert_equal(ex.triples[9].invalid_at, TS_OPEN_SENTINEL)


def test_two_rule_sets_give_two_vocabularies_from_the_same_code() raises:
    var a = _set_a().extract(TEXT_AB, List[EntityMention]())
    var b = _set_b().extract(TEXT_AB, List[EntityMention]())
    # Set A reads tags, codes and addresses.
    assert_equal(a.num_entities(), 3)
    assert_equal(a.entities[0].name, "#red")
    assert_equal(a.entities[0].entity_type, "tag")
    assert_equal(a.entities[1].name, "alpha")
    assert_equal(a.entities[1].entity_type, "code")
    assert_equal(a.entities[2].name, "ann@x.example")
    assert_equal(a.entities[2].entity_type, "handle")
    assert_equal(a.num_triples(), 3)
    assert_equal(a.triples[0].predicate, "co_occurs_with")
    # Set B reads references and actions, and relates them differently.
    assert_equal(b.num_entities(), 2)
    assert_equal(b.entities[0].name, "AB-1")
    assert_equal(b.entities[0].entity_type, "ref")
    assert_equal(b.entities[1].name, "open note")
    assert_equal(b.entities[1].entity_type, "action")
    assert_equal(b.num_triples(), 1)
    assert_equal(b.triples[0].subject_name, "AB-1")
    assert_equal(b.triples[0].predicate, "mentions")
    assert_equal(b.triples[0].object_name, "open note")
    assert_equal(b.triples[0].fact, "AB-1 mentions open note")


def test_the_empty_rule_set_finds_nothing() raises:
    var x = RuleExtractor(
        List[Rule](), List[String](), String("co_occurs_with"), 12
    )
    var ex = x.extract(TEXT_A, List[EntityMention]())
    assert_equal(ex.num_entities(), 0)
    assert_equal(ex.num_triples(), 0)
    assert_equal(x.num_rules(), 0)
    assert_equal(_set_a().num_rules(), 3)


def test_the_first_rule_to_find_a_name_decides_its_type() raises:
    var rules = List[Rule]()
    rules.append(Rule.word_list("first", _strings("shared")))
    rules.append(Rule.word_list("second", _strings("shared", "other")))
    var x = RuleExtractor(rules^, List[String](), String(""), 12)
    var ex = x.extract("other shared shared", List[EntityMention]())
    assert_equal(ex.num_entities(), 2)
    assert_equal(ex.entities[0].name, "shared")
    assert_equal(ex.entities[0].entity_type, "first")
    assert_equal(ex.entities[1].name, "other")
    assert_equal(ex.entities[1].entity_type, "second")


def test_a_stop_name_is_dropped_ignoring_case() raises:
    var x = _set_a()
    var ex = x.extract("Note note NOTE alpha", List[EntityMention]())
    assert_equal(ex.num_entities(), 1)
    assert_equal(ex.entities[0].name, "alpha")
    assert_equal(ex.num_triples(), 0)


def test_an_empty_predicate_turns_edges_off() raises:
    var rules = List[Rule]()
    rules.append(Rule.word_list("code", _strings("alpha", "beta")))
    var x = RuleExtractor(rules^, List[String](), String(""), 12)
    var ex = x.extract("alpha beta", List[EntityMention]())
    assert_equal(ex.num_entities(), 2)
    assert_equal(ex.num_triples(), 0)


def test_the_entity_cap_bounds_the_edges() raises:
    var text = "alpha beta #red #blue"
    var capped = _set_a(3).extract(text, List[EntityMention]())
    assert_equal(capped.num_entities(), 4)
    assert_equal(capped.num_triples(), 3)  # the first three findings: 3 pairs
    assert_equal(capped.triples[2].subject_name, "#blue")
    assert_equal(capped.triples[2].object_name, "alpha")
    var two = _set_a(2).extract(text, List[EntityMention]())
    assert_equal(two.num_triples(), 1)
    var none = _set_a(0).extract(text, List[EntityMention]())
    assert_equal(none.num_entities(), 4)
    assert_equal(none.num_triples(), 0)
    var one = _set_a(1).extract(text, List[EntityMention]())
    assert_equal(one.num_triples(), 0)


def test_the_same_call_gives_the_same_answer() raises:
    var x = _set_a()
    var first = x.extract(TEXT_A, List[EntityMention]())
    var again = x.extract(TEXT_A, List[EntityMention]())
    assert_equal(first.num_entities(), again.num_entities())
    assert_equal(first.num_triples(), again.num_triples())
    for i in range(first.num_entities()):
        assert_equal(first.entities[i].name, again.entities[i].name)
    for i in range(first.num_triples()):
        assert_equal(first.triples[i].fact, again.triples[i].fact)


def test_given_the_first_pass_the_second_pass_finds_nothing() raises:
    var x = _set_a()
    var first = x.extract(TEXT_A, List[EntityMention]())
    var found = List[EntityMention]()
    for i in range(first.num_entities()):
        found.append(first.entities[i].copy())
    var second = x.extract(TEXT_A, found)
    assert_equal(second.num_entities(), 0)
    assert_equal(second.num_triples(), 0)


def test_seeded_entities_leave_only_what_touches_something_new() raises:
    var x = _set_a()
    var seeded = List[EntityMention]()
    seeded.append(EntityMention("#red", "anything", "a summary"))
    seeded.append(EntityMention("alpha", "anything", ""))
    var ex = x.extract("#red alpha beta", seeded)
    # Only "beta" is new, and only the pairs that include it come back.
    assert_equal(ex.num_entities(), 1)
    assert_equal(ex.entities[0].name, "beta")
    assert_equal(ex.entities[0].entity_type, "code")
    assert_equal(ex.num_triples(), 2)
    assert_equal(ex.triples[0].subject_name, "#red")
    assert_equal(ex.triples[0].object_name, "beta")
    assert_equal(ex.triples[1].subject_name, "alpha")
    assert_equal(ex.triples[1].object_name, "beta")


def test_multibyte_names_come_back_whole() raises:
    var rules = List[Rule]()
    rules.append(Rule.delimited("span", "«", "»"))
    var x = RuleExtractor(rules^, List[String](), String("with"), 12)
    var ex = x.extract("voir «naïve café» et «日本»", List[EntityMention]())
    assert_equal(ex.num_entities(), 2)
    assert_equal(ex.entities[0].name, "naïve café")
    assert_equal(ex.entities[1].name, "日本")
    assert_equal(ex.triples[0].fact, "naïve café with 日本")


def _entity_count[X: Extractor](x: X, text: String) raises -> Int:
    return x.extract(text, List[EntityMention]()).num_entities()


def test_it_satisfies_the_extractor_trait() raises:
    assert_equal(_entity_count(_set_a(), "alpha beta"), 2)


def test_a_bad_configuration_is_refused() raises:
    with assert_raises(contains="max_cooccurrence_entities is negative"):
        _ = RuleExtractor(List[Rule](), List[String](), String("p"), -1)
    var stops = List[String]()
    stops.append("ok")
    stops.append("")
    with assert_raises(contains="stop name 1 is empty"):
        _ = RuleExtractor(List[Rule](), stops^, String("p"), 12)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
