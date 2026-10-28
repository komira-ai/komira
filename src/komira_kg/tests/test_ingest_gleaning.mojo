# =============================================================================
# test_ingest_gleaning.mojo -- the bounded extraction loop of one episode (a
#   table-driven stub model; no network, no wall clock, no environment).
# =============================================================================
#
#   union       the first pass and each gleaning pass fold into one extraction,
#               in first-seen order; `max_gleanings` 0 asks once.
#   ending      a pass that adds nothing ends the loop however large the limit.
#   repeats     a mention already held, and a triple already held field for
#               field, are not added again and do not count as new.
#   seed        the known entities of the partition ground every pass and are
#               not part of the result.
#   config      the knobs the ingest cannot run with are refused.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
)

from komira_kg import IngestConfig, StubLlmClient, run_gleaning
from komira_kg_format import EntityMention, Extraction, TS_OPEN_SENTINEL, Triple

comptime TEXT = "the body"


def _m(name: String) -> EntityMention:
    return EntityMention(name, "", "")


def _t(subject: String, object: String, fact: String) -> Triple:
    return Triple(subject, "rel", object, fact, Int64(1), TS_OPEN_SENTINEL)


def _ext(names: List[String], triples: List[Triple]) -> Extraction:
    var ms = List[EntityMention]()
    for i in range(len(names)):
        ms.append(_m(names[i]))
    return Extraction(ms^, triples.copy())


def _names(spec: String) -> List[String]:
    """Space-separated names; "" for none."""
    var out = List[String]()
    for part in spec.split(" "):
        if part.byte_length() > 0:
            out.append(String(part))
    return out^


def _none() -> List[Triple]:
    return List[Triple]()


def _one(a: Triple) -> List[Triple]:
    var out = List[Triple]()
    out.append(a.copy())
    return out^


def _two(a: Triple, b: Triple) -> List[Triple]:
    var out = _one(a)
    out.append(b.copy())
    return out^


def _two_pass_model() raises -> StubLlmClient:
    var llm = StubLlmClient()
    llm.add_extraction(
        TEXT, 0, _ext(_names("A B"), _one(_t("A", "B", "A rel B")))
    )
    llm.add_extraction(
        TEXT, 2, _ext(_names("C"), _one(_t("B", "C", "B rel C")))
    )
    return llm^


def test_gleaning_folds_the_passes_into_one_extraction() raises:
    var llm = _two_pass_model()
    var got = run_gleaning(llm, TEXT, 1)
    assert_equal(len(got.entities), 3)
    assert_equal(got.entities[0].name, "A")
    assert_equal(got.entities[1].name, "B")
    assert_equal(got.entities[2].name, "C")
    assert_equal(len(got.triples), 2)
    assert_equal(got.triples[0].fact, "A rel B")
    assert_equal(got.triples[1].fact, "B rel C")


def test_zero_gleanings_ask_once() raises:
    var llm = _two_pass_model()
    var got = run_gleaning(llm, TEXT, 0)
    assert_equal(len(got.entities), 2)
    assert_equal(len(got.triples), 1)


def test_a_pass_that_adds_nothing_ends_the_loop_whatever_the_limit() raises:
    # Nothing is registered for the second pass: it answers empty. A loop that
    # went on would run the limit out (a million asks).
    var llm = StubLlmClient()
    llm.add_extraction(TEXT, 0, _ext(_names("A"), _none()))
    var got = run_gleaning(llm, TEXT, 1000000)
    assert_equal(len(got.entities), 1)
    assert_equal(len(got.triples), 0)


def test_a_repeated_mention_or_triple_is_not_added_or_counted_new() raises:
    # The same extraction on every pass, with the mention twice in the first.
    var llm = StubLlmClient()
    llm.add_extraction_any_context(
        TEXT,
        _ext(
            _names("A B A"),
            _two(_t("A", "B", "A rel B"), _t("A", "B", "A rel B")),
        ),
    )
    var got = run_gleaning(llm, TEXT, 3)
    assert_equal(len(got.entities), 2)
    assert_equal(len(got.triples), 1)


def test_triples_that_differ_in_any_field_are_distinct() raises:
    var base = _t("A", "B", "A rel B")
    var other_predicate = _t("A", "B", "A rel B")
    other_predicate.predicate = "other"
    var other_object = _t("A", "C", "A rel B")
    var other_subject = _t("C", "B", "A rel B")
    var other_fact = _t("A", "B", "different")
    var other_valid = _t("A", "B", "A rel B")
    other_valid.valid_at = Int64(2)
    var other_invalid = _t("A", "B", "A rel B")
    other_invalid.invalid_at = Int64(9)
    var _all = _one(base)
    _all.append(other_predicate.copy())
    _all.append(other_object.copy())
    _all.append(other_subject.copy())
    _all.append(other_fact.copy())
    _all.append(other_valid.copy())
    _all.append(other_invalid.copy())
    var llm = StubLlmClient()
    llm.add_extraction_any_context(
        TEXT,
        _ext(
            _names("A"),
            _all,
        ),
    )
    var got = run_gleaning(llm, TEXT, 0)
    assert_equal(len(got.triples), 7)


def test_the_seed_grounds_every_pass_and_is_not_in_the_result() raises:
    var llm = StubLlmClient()
    # Two seeded entities: the first pass sees two, the gleaning pass sees the
    # two and the one the first pass found.
    llm.add_extraction(TEXT, 2, _ext(_names("C"), _none()))
    llm.add_extraction(TEXT, 3, _ext(_names("D"), _none()))
    var seed = List[EntityMention]()
    seed.append(_m("S1"))
    seed.append(_m("S2"))
    var got = run_gleaning(llm, TEXT, 1, seed)
    assert_equal(len(got.entities), 2)
    assert_equal(got.entities[0].name, "C")
    assert_equal(got.entities[1].name, "D")


def test_a_seed_name_a_pass_repeats_is_not_counted_twice() raises:
    # The body mentions the seeded name again: known stays at the seed's size
    # plus the new ones, so the gleaning pass sees 2, not 3.
    var llm = StubLlmClient()
    llm.add_extraction(TEXT, 1, _ext(_names("S1 C"), _none()))
    llm.add_extraction(TEXT, 2, _ext(_names("D"), _none()))
    var seed = List[EntityMention]()
    seed.append(_m("S1"))
    var got = run_gleaning(llm, TEXT, 1, seed)
    assert_equal(len(got.entities), 3)
    assert_equal(got.entities[0].name, "S1")
    assert_equal(got.entities[2].name, "D")


def test_the_config_refuses_knobs_no_ingest_can_run_with() raises:
    IngestConfig.default().check()
    var cfg = IngestConfig.default()
    assert_equal(cfg.max_gleanings, 1)
    assert_equal(cfg.cosine_k, 8)
    assert_false(cfg.match_predicate)
    assert_false(cfg.cross_unit_context)
    cfg.max_gleanings = -1
    with assert_raises(contains="max_gleanings must be at least 0, got -1"):
        cfg.check()
    cfg.max_gleanings = 0
    cfg.check()
    cfg.cosine_k = 0
    with assert_raises(contains="cosine_k must be at least 1, got 0"):
        cfg.check()
    cfg.cosine_k = 1
    cfg.check()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
