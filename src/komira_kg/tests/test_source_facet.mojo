# =============================================================================
# test_source_facet.mojo -- the facet an entity carries and the tombstone set.
# =============================================================================
#
#   attrs        the facet and its source write to the exact attrs JSON, read
#                back unchanged for any text (quotes, backslashes, control
#                characters, other scripts), and read from an attrs object that
#                has other members.
#   absent       an empty facet writes "{}"; an empty source leaves out the
#                source member; empty, "{}", malformed, non-object and
#                non-string attrs all read as no facet and no source.
#   tombstone    a pair excludes exactly that source and facet: another facet of
#                the same source and the same facet of another source stay in;
#                a wildcard (source "") excludes the facet for every source and
#                no other facet; a disable repeated adds no entry; an empty set
#                excludes nothing; a pair is not matched by an unattributed row.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_kg import (
    FACET_ATTR_KEY,
    FACET_SOURCE_ATTR_KEY,
    FacetTombstoneSet,
    facet_attrs_json,
    facet_from_attrs,
    facet_source_from_attrs,
)


def test_attrs_json_has_the_documented_shape() raises:
    assert_equal(FACET_ATTR_KEY, "facet")
    assert_equal(FACET_SOURCE_ATTR_KEY, "facet_source")
    assert_equal(
        facet_attrs_json("kind-a", "src-1"),
        '{"facet":"kind-a","facet_source":"src-1"}',
    )


def test_an_empty_source_leaves_out_the_source_member() raises:
    assert_equal(facet_attrs_json("kind-a", ""), '{"facet":"kind-a"}')
    var attrs = facet_attrs_json("kind-a", "")
    assert_equal(facet_from_attrs(attrs), "kind-a")
    assert_equal(facet_source_from_attrs(attrs), "")


def test_an_empty_facet_writes_no_facet() raises:
    assert_equal(facet_attrs_json("", ""), "{}")
    assert_equal(facet_attrs_json("", "src-1"), "{}")
    assert_equal(facet_from_attrs(facet_attrs_json("", "src-1")), "")
    assert_equal(facet_source_from_attrs(facet_attrs_json("", "src-1")), "")


def test_any_text_round_trips() raises:
    var texts = List[String]()
    texts.append("plain")
    texts.append('has "quotes"')
    texts.append("back\\slash")
    texts.append("line\nbreak\tand tab")
    texts.append(String("ctl") + chr(1) + "char")
    texts.append("東京 · Zoë")
    texts.append('{"nested":"json"}')
    for i in range(len(texts)):
        for j in range(len(texts)):
            var attrs = facet_attrs_json(texts[i], texts[j])
            assert_equal(facet_from_attrs(attrs), texts[i])
            assert_equal(facet_source_from_attrs(attrs), texts[j])


def test_the_facet_reads_from_attrs_with_other_members() raises:
    var attrs = '{"x":1,"facet":"kind-b","note":["a"],"facet_source":"src-9"}'
    assert_equal(facet_from_attrs(attrs), "kind-b")
    assert_equal(facet_source_from_attrs(attrs), "src-9")


def test_attrs_without_a_usable_facet_read_as_none() raises:
    var cases = List[String]()
    cases.append("")
    cases.append("{}")
    cases.append("{")
    cases.append("not json")
    cases.append("[]")
    cases.append('"facet"')
    cases.append('{"facet":5,"facet_source":true}')
    cases.append('{"facet":null,"facet_source":{"a":1}}')
    cases.append('{"other":"x"}')
    for i in range(len(cases)):
        assert_equal(facet_from_attrs(cases[i]), "")
        assert_equal(facet_source_from_attrs(cases[i]), "")


def test_an_empty_set_excludes_nothing() raises:
    var t = FacetTombstoneSet()
    assert_true(t.is_empty())
    assert_equal(t.num_entries(), 0)
    assert_false(t.is_disabled("src-1", "kind-a"))
    assert_false(t.is_disabled("", ""))


def test_a_pair_excludes_that_source_and_facet_only() raises:
    var t = FacetTombstoneSet()
    t.disable("src-1", "kind-a")
    assert_false(t.is_empty())
    assert_true(t.is_disabled("src-1", "kind-a"))
    # Another facet of the same source stays in.
    assert_false(t.is_disabled("src-1", "kind-b"))
    # The same facet of another source stays in.
    assert_false(t.is_disabled("src-2", "kind-a"))
    # An unattributed row is not excluded by a pair for a named source.
    assert_false(t.is_disabled("", "kind-a"))


def test_a_wildcard_excludes_one_facet_for_every_source() raises:
    var t = FacetTombstoneSet()
    t.disable("", "kind-a")
    assert_true(t.is_disabled("src-1", "kind-a"))
    assert_true(t.is_disabled("src-2", "kind-a"))
    assert_true(t.is_disabled("", "kind-a"))
    assert_false(t.is_disabled("src-1", "kind-b"))
    assert_false(t.is_disabled("", "kind-b"))


def test_pairs_accumulate_and_a_repeat_adds_nothing() raises:
    var t = FacetTombstoneSet()
    t.disable("src-1", "kind-a")
    t.disable("src-1", "kind-a")
    assert_equal(t.num_entries(), 1)
    t.disable("src-1", "kind-b")
    t.disable("src-2", "kind-a")
    assert_equal(t.num_entries(), 3)
    assert_true(t.is_disabled("src-1", "kind-b"))
    assert_true(t.is_disabled("src-2", "kind-a"))
    assert_false(t.is_disabled("src-2", "kind-b"))


def test_a_copy_is_independent() raises:
    var t = FacetTombstoneSet()
    t.disable("src-1", "kind-a")
    var c = t.copy()
    c.disable("src-2", "kind-a")
    assert_true(c.is_disabled("src-2", "kind-a"))
    assert_false(t.is_disabled("src-2", "kind-a"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
