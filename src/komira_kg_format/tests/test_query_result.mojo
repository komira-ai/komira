# =============================================================================
# test_query_result.mojo -- building a KgQueryResult and reading it back.
# =============================================================================
#
#   builders    each add_* appends to its list in order; `answer` starts empty;
#               has_node finds a node id; the severity constants and the format
#               version have their stated values.
#   provenance  a second entry for a doc_id is dropped and the first is kept.
#   content     is_non_trivial needs a node or finding AND a score or provenance
#               entry, and is false for each half alone and for an empty result.
#   round trip  a full result (every collection, an answer, multi-byte UTF-8,
#               escapes, negative and large integers, fractional scores)
#               serializes and deserializes to the same values, and serializing
#               the decoded result gives the same text.
#   empty       an empty result round-trips and decodes with empty lists.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_kg_format import (
    KG_QUERY_RESULT_FORMAT_VERSION,
    KgQueryResult,
    Locus,
    ProvenanceEntry,
    ResultEdge,
    ResultFinding,
    ResultNode,
    SEV_ERROR,
    SEV_INFO,
    SEV_WARN,
    ScoreEntry,
)


def _full() -> KgQueryResult:
    var r = KgQueryResult("analyze", "which terms are undefined?")
    r.set_answer("Two terms: \"tort\" and 'estoppel'.\nSee §99.")
    r.add_node(ResultNode(7, "Ada Lovelace", "person", 0.875))
    r.add_node(ResultNode(-3, "naïve résumé 日本語", "term", 0.0))
    r.add_node(ResultNode(9223372036854775807, "big", "term", -1.5))
    r.add_edge(ResultEdge(7, -3, "wrote about", 1700000000000000, "d1"))
    r.add_edge(ResultEdge(-3, 7, "tab\there", -5, "d2"))
    r.add_finding(
        ResultFinding("§12.3", SEV_ERROR, "dangling_xref", "refers to §99\nwhich is absent")
    )
    r.add_finding(ResultFinding("term:tort", SEV_INFO, "undefined_term", "back\\slash"))
    r.add_provenance(ProvenanceEntry("d1", "notes.md"))
    r.add_provenance(ProvenanceEntry("d2", "episode \"two\""))
    r.add_locus(Locus("d1", "§12.3", 4096))
    r.add_locus(Locus("d2", "", -1))
    r.add_score(ScoreEntry("cosine", 7, 0.8750000000000001))
    r.add_score(ScoreEntry("rrf", -1, 1.0e-7))
    r.add_score(ScoreEntry("fulltext_tf", 9, 12345678.5))
    return r^


def test_constants() raises:
    assert_equal(SEV_INFO, 0)
    assert_equal(SEV_WARN, 1)
    assert_equal(SEV_ERROR, 2)
    assert_equal(KG_QUERY_RESULT_FORMAT_VERSION, 1)


def test_builders_append_in_order() raises:
    var r = _full()
    assert_equal(r.mode, "analyze")
    assert_equal(r.query_label, "which terms are undefined?")
    assert_equal(len(r.nodes), 3)
    assert_equal(r.nodes[0].label, "Ada Lovelace")
    assert_equal(r.nodes[2].id, Int64(9223372036854775807))
    assert_equal(len(r.edges), 2)
    assert_equal(r.edges[1].predicate, "tab\there")
    assert_equal(len(r.findings), 2)
    assert_equal(r.findings[0].severity, SEV_ERROR)
    assert_equal(len(r.provenance), 2)
    assert_equal(len(r.loci), 2)
    assert_equal(r.loci[1].offset, Int64(-1))
    assert_equal(len(r.scores), 3)
    assert_equal(r.scores[1].target_id, Int64(-1))


def test_answer_starts_empty() raises:
    var r = KgQueryResult("retain_and_query", "q")
    assert_equal(r.answer, "")
    r.set_answer("yes")
    assert_equal(r.answer, "yes")


def test_has_node() raises:
    var r = _full()
    assert_true(r.has_node(7))
    assert_true(r.has_node(-3))
    assert_false(r.has_node(8))


def test_provenance_keeps_the_first_entry_per_doc_id() raises:
    var r = KgQueryResult("analyze", "q")
    r.add_provenance(ProvenanceEntry("d1", "first"))
    r.add_provenance(ProvenanceEntry("d1", "second"))
    r.add_provenance(ProvenanceEntry("d2", "other"))
    assert_equal(len(r.provenance), 2)
    assert_equal(r.provenance[0].source, "first")
    assert_equal(r.provenance[1].doc_id, "d2")


def test_is_non_trivial() raises:
    var empty = KgQueryResult("analyze", "q")
    assert_false(empty.is_non_trivial())

    var nodes_only = KgQueryResult("analyze", "q")
    nodes_only.add_node(ResultNode(1, "a", "t", 0.0))
    assert_false(nodes_only.is_non_trivial())

    var score_only = KgQueryResult("analyze", "q")
    score_only.add_score(ScoreEntry("cosine", -1, 0.5))
    assert_false(score_only.is_non_trivial())

    var finding_and_provenance = KgQueryResult("analyze", "q")
    finding_and_provenance.add_finding(ResultFinding("l", SEV_WARN, "k", "r"))
    finding_and_provenance.add_provenance(ProvenanceEntry("d", "s"))
    assert_true(finding_and_provenance.is_non_trivial())

    var node_and_score = KgQueryResult("analyze", "q")
    node_and_score.add_node(ResultNode(1, "a", "t", 0.0))
    node_and_score.add_score(ScoreEntry("cosine", 1, 0.5))
    assert_true(node_and_score.is_non_trivial())


def test_full_result_round_trips() raises:
    var r = _full()
    var wire = r.serialize()
    var back = KgQueryResult.deserialize(wire)
    assert_equal(back.mode, r.mode)
    assert_equal(back.query_label, r.query_label)
    assert_equal(back.answer, r.answer)

    assert_equal(len(back.nodes), 3)
    for i in range(3):
        assert_equal(back.nodes[i].id, r.nodes[i].id)
        assert_equal(back.nodes[i].label, r.nodes[i].label)
        assert_equal(back.nodes[i].type, r.nodes[i].type)
        assert_equal(back.nodes[i].score, r.nodes[i].score)

    assert_equal(len(back.edges), 2)
    for i in range(2):
        assert_equal(back.edges[i].src, r.edges[i].src)
        assert_equal(back.edges[i].dst, r.edges[i].dst)
        assert_equal(back.edges[i].predicate, r.edges[i].predicate)
        assert_equal(back.edges[i].valid_at, r.edges[i].valid_at)
        assert_equal(back.edges[i].doc_id, r.edges[i].doc_id)

    assert_equal(len(back.findings), 2)
    for i in range(2):
        assert_equal(back.findings[i].locus, r.findings[i].locus)
        assert_equal(back.findings[i].severity, r.findings[i].severity)
        assert_equal(back.findings[i].kind, r.findings[i].kind)
        assert_equal(back.findings[i].rationale, r.findings[i].rationale)

    assert_equal(len(back.provenance), 2)
    assert_equal(back.provenance[1].source, "episode \"two\"")

    assert_equal(len(back.loci), 2)
    assert_equal(back.loci[0].section, "§12.3")
    assert_equal(back.loci[0].offset, Int64(4096))
    assert_equal(back.loci[1].offset, Int64(-1))

    assert_equal(len(back.scores), 3)
    for i in range(3):
        assert_equal(back.scores[i].name, r.scores[i].name)
        assert_equal(back.scores[i].target_id, r.scores[i].target_id)
        assert_equal(back.scores[i].value, r.scores[i].value)

    # Byte-stable: the decoded result serializes to the same text.
    assert_equal(back.serialize(), wire)


def test_empty_result_round_trips() raises:
    var r = KgQueryResult("retain_and_query", "")
    var back = KgQueryResult.deserialize(r.serialize())
    assert_equal(back.mode, "retain_and_query")
    assert_equal(back.query_label, "")
    assert_equal(back.answer, "")
    assert_equal(len(back.nodes), 0)
    assert_equal(len(back.edges), 0)
    assert_equal(len(back.findings), 0)
    assert_equal(len(back.provenance), 0)
    assert_equal(len(back.loci), 0)
    assert_equal(len(back.scores), 0)
    assert_false(back.is_non_trivial())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
