# =============================================================================
# test_query_result_wire.mojo -- the JSON text of a KgQueryResult.
# =============================================================================
#
#   layout      a result serializes to exactly the stated text: the version
#               stamp first, then mode, query_label, answer and the six
#               collections (nodes, edges, annotations, provenance, loci,
#               scores) in order, each record with its fields in order.
#   escapes     the short escapes for quote, backslash, newline, return, tab, backspace and
#               form feed; every other byte below 0x20 as \u00XX; multi-byte UTF-8 raw. Each
#               control character survives a round trip (a raw one would make
#               the text unreadable).
#   non-finite  a NaN or infinite score or value is written as 0.0, so the text
#               stays valid JSON and reads back.
#   version     a version above the reader's, the previous one, zero and a
#               negative one are refused; a missing version reads as current;
#               the version-1 key names are not read.
#   tolerance   a missing collection reads as empty, a missing answer as "", and
#               a repeated provenance source_id keeps the first.
#   wrong kind  a known key holding the wrong kind of value (a collection that
#               is not an array, an answer that is not a string, a version that
#               is not a number) and a repeated object key are refused.
#   refusals    malformed JSON, a root that is not an object, a missing mode or
#               query_label, and a record missing a field, each raise.
# No test reads a clock or the environment.
# =============================================================================

from std.math import inf, nan
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_kg_format import (
    KgQueryResult,
    Locus,
    ProvenanceEntry,
    ResultEdge,
    ResultAnnotation,
    ResultNode,
    ScoreEntry,
)


def test_exact_text_of_a_small_result() raises:
    var r = KgQueryResult("mode-a", "q1")
    r.set_answer("a")
    r.add_node(ResultNode(7, "One", "kind-x", 0.5))
    r.add_edge(ResultEdge(7, 8, "knows", 100, "d1"))
    r.add_annotation(ResultAnnotation("s1", 2, "kind-a", "why"))
    r.add_provenance(ProvenanceEntry("d1", "notes"))
    r.add_locus(Locus("d1", "s1", -1))
    r.add_score(ScoreEntry("cosine", 7, 0.25))
    var want = String(
        '{"v":2,"mode":"mode-a","query_label":"q1","answer":"a",'
        '"nodes":[{"id":7,"label":"One","type":"kind-x","score":0.5}],'
        '"edges":[{"src":7,"dst":8,"predicate":"knows","valid_at":100,'
        '"source_id":"d1"}],'
        '"annotations":[{"locus":"s1","severity":2,"kind":"kind-a",'
        '"rationale":"why"}],'
        '"provenance":[{"source_id":"d1","source":"notes"}],'
        '"loci":[{"source_id":"d1","anchor":"s1","offset":-1}],'
        '"scores":[{"name":"cosine","target_id":7,"value":0.25}]}'
    )
    assert_equal(r.serialize(), want)


def test_empty_result_text() raises:
    var r = KgQueryResult("m", "l")
    assert_equal(
        r.serialize(),
        String(
            '{"v":2,"mode":"m","query_label":"l","answer":"",'
            '"nodes":[],"edges":[],"annotations":[],"provenance":[],'
            '"loci":[],"scores":[]}'
        ),
    )


def test_short_escapes_and_raw_utf8() raises:
    var r = KgQueryResult("m", 'q"\\\n\r\t§日')
    var text = r.serialize()
    assert_true(text.find(String('"query_label":"q\\"\\\\\\n\\r\\t§日"')) >= 0)
    assert_equal(KgQueryResult.deserialize(text).query_label, r.query_label)


def test_control_characters_are_escaped_and_survive() raises:
    # Every byte 0x01..0x1F (0x00 cannot sit in a String's text) round-trips.
    var bytes = List[UInt8]()
    for b in range(1, 0x20):
        bytes.append(UInt8(b))
    var label = String(unsafe_from_utf8=bytes)
    var r = KgQueryResult("m", label)
    var text = r.serialize()
    for i in range(len(text.as_bytes())):
        assert_true(
            text.as_bytes()[i] >= UInt8(0x20), "no raw control byte in the text"
        )
    assert_true(text.find(String("\\u0001")) >= 0)
    assert_true(text.find(String("\\u001f")) >= 0)
    assert_true(text.find(String("\\b")) >= 0)
    assert_true(text.find(String("\\f")) >= 0)
    var back = KgQueryResult.deserialize(text)
    assert_equal(back.query_label, label)
    assert_equal(back.serialize(), text)


def test_non_finite_scores_are_written_as_zero() raises:
    var r = KgQueryResult("m", "l")
    r.add_node(ResultNode(1, "a", "t", nan[DType.float64]()))
    r.add_node(ResultNode(2, "b", "t", inf[DType.float64]()))
    r.add_score(ScoreEntry("s", -1, -inf[DType.float64]()))
    var text = r.serialize()
    var back = KgQueryResult.deserialize(text)
    assert_equal(back.nodes[0].score, 0.0)
    assert_equal(back.nodes[1].score, 0.0)
    assert_equal(back.scores[0].value, 0.0)


def test_version_gate() raises:
    var tail = ',"mode":"m","query_label":"l"}'
    with assert_raises(contains="version 3 > reader-supported 2"):
        _ = KgQueryResult.deserialize('{"v":3' + tail)
    with assert_raises(contains="version 1 < 2"):
        _ = KgQueryResult.deserialize('{"v":1' + tail)
    with assert_raises(contains="version 0 < 2"):
        _ = KgQueryResult.deserialize('{"v":0' + tail)
    with assert_raises(contains="version -1 < 2"):
        _ = KgQueryResult.deserialize('{"v":-1' + tail)
    # A missing version reads as the current one; the current one reads.
    assert_equal(KgQueryResult.deserialize('{"mode":"m","query_label":"l"}').mode, "m")
    assert_equal(KgQueryResult.deserialize('{"v":2' + tail).query_label, "l")


def test_old_key_names_are_not_read() raises:
    # The version-1 layout named these keys differently; a version 2 reader
    # does not take them for the current ones.
    with assert_raises(contains="no key 'source_id'"):
        _ = KgQueryResult.deserialize(
            '{"v":2,"mode":"m","query_label":"l","edges":['
            '{"src":1,"dst":2,"predicate":"p","valid_at":0,"doc_id":"d"}]}'
        )


def test_missing_collections_and_answer_read_as_empty() raises:
    var r = KgQueryResult.deserialize('{"v":2,"mode":"m","query_label":"l"}')
    assert_equal(r.answer, "")
    assert_equal(len(r.nodes), 0)
    assert_equal(len(r.scores), 0)


def test_repeated_provenance_source_id_keeps_the_first() raises:
    var r = KgQueryResult.deserialize(
        '{"v":2,"mode":"m","query_label":"l","provenance":['
        '{"source_id":"d","source":"one"},{"source_id":"d","source":"two"}]}'
    )
    assert_equal(len(r.provenance), 1)
    assert_equal(r.provenance[0].source, "one")


def test_a_wrong_kind_of_value_for_a_known_key_is_refused() raises:
    var head = '{"v":2,"mode":"m","query_label":"l",'
    for key in ["nodes", "edges", "annotations", "provenance", "loci", "scores"]:
        for bad in ["5", "null", "{}", '"x"']:
            with assert_raises(contains="'" + key + "' is not an array"):
                _ = KgQueryResult.deserialize(head + '"' + key + '":' + bad + "}")
        # An empty array is the right kind and reads as empty.
        _ = KgQueryResult.deserialize(head + '"' + key + '":[]}')
    for bad in ["5", "null", "[]", "{}", "true"]:
        with assert_raises(contains="'answer' is not a string"):
            _ = KgQueryResult.deserialize(head + '"answer":' + bad + "}")
    with assert_raises(contains="'v' is not a number"):
        _ = KgQueryResult.deserialize('{"v":"2","mode":"m","query_label":"l"}')
    with assert_raises(contains="'v' is not a number"):
        _ = KgQueryResult.deserialize('{"v":null,"mode":"m","query_label":"l"}')


def test_a_repeated_key_is_refused() raises:
    with assert_raises(contains="duplicate object key 'mode'"):
        _ = KgQueryResult.deserialize(
            '{"v":2,"mode":"m","mode":"n","query_label":"l"}'
        )
    with assert_raises(contains="duplicate object key 'id'"):
        _ = KgQueryResult.deserialize(
            '{"v":2,"mode":"m","query_label":"l","nodes":[{"id":1,"id":2,'
            '"label":"a","type":"t","score":0}]}'
        )


def test_refusals() raises:
    with assert_raises():
        _ = KgQueryResult.deserialize("")
    with assert_raises():
        _ = KgQueryResult.deserialize('{"v":2,')
    with assert_raises(contains="root is not a JSON object"):
        _ = KgQueryResult.deserialize("[1,2]")
    with assert_raises(contains="no key 'mode'"):
        _ = KgQueryResult.deserialize('{"v":2,"query_label":"l"}')
    with assert_raises(contains="no key 'query_label'"):
        _ = KgQueryResult.deserialize('{"v":2,"mode":"m"}')
    with assert_raises(contains="no key 'label'"):
        _ = KgQueryResult.deserialize(
            '{"mode":"m","query_label":"l","nodes":[{"id":1,"type":"t","score":0}]}'
        )
    with assert_raises(contains="expected a number"):
        _ = KgQueryResult.deserialize(
            '{"mode":"m","query_label":"l","scores":[{"name":"n","target_id":1,"value":"x"}]}'
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
