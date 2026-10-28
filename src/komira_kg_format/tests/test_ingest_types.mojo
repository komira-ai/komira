# =============================================================================
# test_ingest_types.mojo -- the extraction values.
# =============================================================================
#
#   values       Triple and EntityMention keep every field they are given, and a
#                copy is independent of the original.
#   extraction   an empty Extraction has no entities and no triples; one built
#                from lists reports their counts and holds their elements in
#                order; moving it keeps the contents (it is Movable only).
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_kg_format import EntityMention, Extraction, Triple


def _triple(subject: String, object: String) -> Triple:
    return Triple(
        subject, String("uses"), object, subject + " uses " + object, 10, 99
    )


def test_triple_keeps_every_field() raises:
    var t = _triple("a", "b")
    assert_equal(t.subject_name, "a")
    assert_equal(t.predicate, "uses")
    assert_equal(t.object_name, "b")
    assert_equal(t.fact, "a uses b")
    assert_equal(t.valid_at, 10)
    assert_equal(t.invalid_at, 99)


def test_triple_copy_is_independent() raises:
    var t = _triple("a", "b")
    var c = t.copy()
    c.subject_name = String("z")
    c.invalid_at = 5
    assert_equal(t.subject_name, "a")
    assert_equal(t.invalid_at, 99)
    assert_equal(c.subject_name, "z")


def test_entity_mention_untyped_is_empty_strings() raises:
    var m = EntityMention(String("Ada"), String(""), String(""))
    assert_equal(m.name, "Ada")
    assert_equal(m.entity_type, "")
    assert_equal(m.summary, "")
    var typed = EntityMention(String("Ada"), String("person"), String("a"))
    assert_equal(typed.entity_type, "person")
    assert_equal(typed.summary, "a")


def test_empty_extraction_has_nothing() raises:
    var e = Extraction()
    assert_equal(e.num_entities(), 0)
    assert_equal(e.num_triples(), 0)


def test_extraction_from_lists_counts_and_orders() raises:
    var entities = List[EntityMention]()
    entities.append(EntityMention(String("a"), String("t"), String("")))
    entities.append(EntityMention(String("b"), String(""), String("s")))
    var triples = List[Triple]()
    triples.append(_triple("a", "b"))
    var e = Extraction(entities^, triples^)
    assert_equal(e.num_entities(), 2)
    assert_equal(e.num_triples(), 1)
    assert_equal(e.entities[0].name, "a")
    assert_equal(e.entities[1].name, "b")
    assert_equal(e.triples[0].fact, "a uses b")


def test_extraction_moves_with_its_contents() raises:
    var entities = List[EntityMention]()
    entities.append(EntityMention(String("a"), String(""), String("")))
    var e = Extraction(entities^, List[Triple]())
    var moved = e^
    assert_equal(moved.num_entities(), 1)
    assert_equal(moved.entities[0].name, "a")
    moved.triples.append(_triple("a", "a"))
    assert_equal(moved.num_triples(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
