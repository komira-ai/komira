# =============================================================================
# test_extractor.mojo -- the Extractor seam and the table-driven StubExtractor.
# =============================================================================
#
#   trait       a function generic over Extractor instantiates with the stub, so
#               the stub satisfies the trait (a build error otherwise).
#   rows        a sized row answers exactly its (text, already_found length);
#               every field of the extraction comes back; a miss is empty.
#   gleaning    a first pass at length 0 and a delta at the first pass's count
#               answer in turn, and a loop that feeds each pass's findings back
#               ends on the empty answer after a bounded number of passes.
#   any-context an any-context row answers whatever already_found holds, and a
#               sized row for the same text wins over it.
#   storage     a row is copied in (the caller keeps its value), is not consumed
#               by a lookup, and a second registration of a key replaces it.
#   copy        copy_extraction is a deep copy.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_kg import Extractor, StubExtractor, copy_extraction
from komira_kg_format import EntityMention, Extraction, TS_OPEN_SENTINEL, Triple


def _drive_extract[
    X: Extractor
](x: X, text: String, found: List[EntityMention]) raises -> Int:
    var ex = x.extract(text, found)
    return ex.num_entities() + ex.num_triples()


def _first_pass() -> Extraction:
    var ents = List[EntityMention]()
    ents.append(EntityMention("Service A", "component", "serves requests"))
    ents.append(EntityMention("Queue B", "", ""))
    var trips = List[Triple]()
    trips.append(
        Triple(
            "Service A",
            "reads_from",
            "Queue B",
            "Service A reads from Queue B",
            Int64(100),
            TS_OPEN_SENTINEL,
        )
    )
    return Extraction(ents^, trips^)


def _delta() -> Extraction:
    var ents = List[EntityMention]()
    ents.append(EntityMention("Cache C", "component", ""))
    return Extraction(ents^, List[Triple]())


def test_the_stub_satisfies_the_extractor_trait() raises:
    var x = StubExtractor()
    x.add_extraction("text one", 0, _first_pass())
    assert_equal(_drive_extract(x, "text one", List[EntityMention]()), 3)
    assert_equal(_drive_extract(x, "other text", List[EntityMention]()), 0)


def test_a_sized_row_returns_every_field() raises:
    var x = StubExtractor()
    x.add_extraction("text one", 0, _first_pass())
    var ex = x.extract("text one", List[EntityMention]())
    assert_equal(ex.num_entities(), 2)
    assert_equal(ex.num_triples(), 1)
    assert_equal(ex.entities[0].name, "Service A")
    assert_equal(ex.entities[0].entity_type, "component")
    assert_equal(ex.entities[0].summary, "serves requests")
    assert_equal(ex.entities[1].name, "Queue B")
    assert_equal(ex.entities[1].entity_type, "")
    assert_equal(ex.triples[0].subject_name, "Service A")
    assert_equal(ex.triples[0].predicate, "reads_from")
    assert_equal(ex.triples[0].object_name, "Queue B")
    assert_equal(ex.triples[0].fact, "Service A reads from Queue B")
    assert_equal(ex.triples[0].valid_at, Int64(100))
    assert_true(ex.triples[0].invalid_at == TS_OPEN_SENTINEL)


def test_a_miss_is_an_empty_extraction() raises:
    var x = StubExtractor()
    x.add_extraction("text one", 0, _first_pass())
    var unknown = x.extract("unknown text", List[EntityMention]())
    assert_equal(unknown.num_entities(), 0)
    assert_equal(unknown.num_triples(), 0)
    # The text is registered, but not for an already_found of length 1.
    var one = List[EntityMention]()
    one.append(EntityMention("Service A", "", ""))
    var wrong_pass = x.extract("text one", one)
    assert_equal(wrong_pass.num_entities(), 0)
    assert_equal(wrong_pass.num_triples(), 0)


def test_a_gleaning_delta_is_keyed_by_the_first_pass_count() raises:
    var x = StubExtractor()
    x.add_extraction("text one", 0, _first_pass())
    x.add_extraction("text one", 2, _delta())
    var p1 = x.extract("text one", List[EntityMention]())
    assert_equal(p1.num_entities(), 2)
    var found = List[EntityMention]()
    found.append(p1.entities[0].copy())
    found.append(p1.entities[1].copy())
    var p2 = x.extract("text one", found)
    assert_equal(p2.num_entities(), 1)
    assert_equal(p2.entities[0].name, "Cache C")
    assert_equal(p2.num_triples(), 0)


def test_a_gleaning_loop_over_the_stub_ends_on_the_empty_answer() raises:
    var x = StubExtractor()
    x.add_extraction("text one", 0, _first_pass())
    x.add_extraction("text one", 2, _delta())
    var found = List[EntityMention]()
    var passes = 0
    while passes < 10:
        var ex = x.extract("text one", found)
        passes += 1
        if ex.num_entities() == 0 and ex.num_triples() == 0:
            break
        for i in range(len(ex.entities)):
            found.append(ex.entities[i].copy())
    # Pass 1 finds two, pass 2 finds one, pass 3 (found length 3) finds nothing.
    assert_equal(passes, 3)
    assert_equal(len(found), 3)


def test_an_any_context_row_answers_whatever_is_already_found() raises:
    var x = StubExtractor()
    x.add_extraction_any_context("text two", _delta())
    var seeded = List[EntityMention]()
    seeded.append(EntityMention("Seed", "", ""))
    seeded.append(EntityMention("Seed 2", "", ""))
    seeded.append(EntityMention("Seed 3", "", ""))
    assert_equal(x.extract("text two", List[EntityMention]()).num_entities(), 1)
    assert_equal(x.extract("text two", seeded).num_entities(), 1)
    assert_equal(x.extract("text three", seeded).num_entities(), 0)


def test_a_sized_row_wins_over_an_any_context_row() raises:
    var x = StubExtractor()
    x.add_extraction_any_context("text one", _delta())
    x.add_extraction("text one", 0, _first_pass())
    assert_equal(x.extract("text one", List[EntityMention]()).num_entities(), 2)
    var one = List[EntityMention]()
    one.append(EntityMention("Seed", "", ""))
    assert_equal(x.extract("text one", one).num_entities(), 1)


def test_a_lookup_does_not_consume_the_row_or_the_callers_value() raises:
    var x = StubExtractor()
    var mine = _first_pass()
    x.add_extraction("text one", 0, mine)
    assert_equal(mine.num_entities(), 2)
    for _ in range(3):
        assert_equal(
            x.extract("text one", List[EntityMention]()).num_entities(), 2
        )


def test_registering_a_key_again_replaces_its_row() raises:
    var x = StubExtractor()
    x.add_extraction("text one", 0, _first_pass())
    x.add_extraction("text one", 0, _delta())
    var ex = x.extract("text one", List[EntityMention]())
    assert_equal(ex.num_entities(), 1)
    assert_equal(ex.entities[0].name, "Cache C")
    x.add_extraction_any_context("text two", _first_pass())
    x.add_extraction_any_context("text two", _delta())
    assert_equal(x.extract("text two", List[EntityMention]()).num_entities(), 1)


def test_copy_extraction_is_independent_of_the_source() raises:
    var source = _first_pass()
    var copy = copy_extraction(source)
    assert_equal(copy.num_entities(), 2)
    assert_equal(copy.num_triples(), 1)
    assert_equal(copy.triples[0].fact, "Service A reads from Queue B")
    copy.entities[0].name = "changed"
    copy.triples[0].fact = "changed"
    assert_equal(source.entities[0].name, "Service A")
    assert_equal(source.triples[0].fact, "Service A reads from Queue B")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
