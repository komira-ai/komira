# =============================================================================
# test_llm_client.mojo -- the LlmClient seam and the table-driven StubLlmClient.
# =============================================================================
#
#   trait         a function generic over LlmClient instantiates with the stub.
#   extract       the stub extracts from its tables like StubExtractor: a sized
#                 row, an any-context row, a miss that is empty.
#   contradiction a registered verdict comes back, in either polarity; the key
#                 is ordered (new, old); a miss is False; a repeat replaces.
#   same entity   likewise keyed by (name_a, name_b), summaries not in the key.
#   synthesis     a client with nothing registered has no synthesis and raises
#                 if asked; one registered answer turns it on, answers exactly
#                 its prompt pair (the prompts are passed through unchanged) and
#                 raises for any other pair; a repeat replaces.
#   bridge        a caller settles dedup's borderline candidates with an
#                 LlmClient through its own SameEntityJudge adapter.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg import (
    DedupCandidate,
    LlmClient,
    SameEntityJudge,
    StubLlmClient,
    dedup_resolve_judged,
)
from komira_kg_format import EntityMention, Extraction, Triple


def _drive_extract[
    L: LlmClient
](l: L, text: String, found: List[EntityMention]) raises -> Int:
    return l.extract(text, found).num_entities()


def _drive_contradiction[
    L: LlmClient
](l: L, new_fact: String, old_fact: String) raises -> Bool:
    return l.judge_contradiction(new_fact, old_fact)


def _drive_synthesis[L: LlmClient](l: L) -> Bool:
    return l.has_synthesis()


def _one_entity(name: String) -> Extraction:
    var ents = List[EntityMention]()
    ents.append(EntityMention(name, "", ""))
    return Extraction(ents^, List[Triple]())


def test_the_stub_satisfies_the_llm_client_trait() raises:
    var l = StubLlmClient()
    l.add_extraction("text", 0, _one_entity("Service A"))
    l.add_contradiction("new", "old", True)
    assert_equal(_drive_extract(l, "text", List[EntityMention]()), 1)
    assert_true(_drive_contradiction(l, "new", "old"))
    assert_false(_drive_synthesis(l))


def test_extraction_rows_behave_like_the_stub_extractor() raises:
    var l = StubLlmClient()
    l.add_extraction("text", 0, _one_entity("Service A"))
    l.add_extraction("text", 1, _one_entity("Queue B"))
    l.add_extraction_any_context("other", _one_entity("Cache C"))
    var none = List[EntityMention]()
    assert_equal(l.extract("text", none).entities[0].name, "Service A")
    var one = List[EntityMention]()
    one.append(EntityMention("Service A", "", ""))
    assert_equal(l.extract("text", one).entities[0].name, "Queue B")
    assert_equal(l.extract("other", one).entities[0].name, "Cache C")
    assert_equal(l.extract("unknown", none).num_entities(), 0)
    assert_equal(l.extract("text", one).num_triples(), 0)


def test_a_contradiction_verdict_is_returned_with_its_polarity() raises:
    var l = StubLlmClient()
    l.add_contradiction("method B", "method A", True)
    l.add_contradiction("runs in region X", "runs in region Y", False)
    assert_true(l.judge_contradiction("method B", "method A"))
    assert_false(l.judge_contradiction("runs in region X", "runs in region Y"))


def test_a_contradiction_key_is_ordered_and_a_miss_is_false() raises:
    var l = StubLlmClient()
    l.add_contradiction("method B", "method A", True)
    assert_false(l.judge_contradiction("method A", "method B"))
    assert_false(l.judge_contradiction("unknown", "unknown too"))


def test_a_contradiction_registered_again_replaces_the_verdict() raises:
    var l = StubLlmClient()
    l.add_contradiction("method B", "method A", True)
    l.add_contradiction("method B", "method A", False)
    assert_false(l.judge_contradiction("method B", "method A"))
    l.add_contradiction("method B", "method A", True)
    assert_true(l.judge_contradiction("method B", "method A"))


def test_a_same_entity_verdict_ignores_summaries_and_has_an_ordered_key() raises:
    var l = StubLlmClient()
    l.add_same_entity("Alpha Corp", "Alpha Corporation", True)
    l.add_same_entity("Alpha Corp", "Beta Inc", False)
    assert_true(
        l.judge_same_entity("Alpha Corp", "", "Alpha Corporation", "a vendor")
    )
    assert_true(
        l.judge_same_entity(
            "Alpha Corp", "different", "Alpha Corporation", "summaries"
        )
    )
    assert_false(l.judge_same_entity("Alpha Corp", "", "Beta Inc", ""))
    assert_false(
        l.judge_same_entity("Alpha Corporation", "", "Alpha Corp", "")
    )
    assert_false(l.judge_same_entity("Foo", "", "Bar", ""))


def test_a_same_entity_registered_again_replaces_the_verdict() raises:
    var l = StubLlmClient()
    l.add_same_entity("A", "B", False)
    l.add_same_entity("A", "B", True)
    assert_true(l.judge_same_entity("A", "", "B", ""))


def test_with_nothing_registered_there_is_no_synthesis() raises:
    var l = StubLlmClient()
    assert_false(l.has_synthesis())
    with assert_raises(contains="no answer registered"):
        _ = l.synthesize("system", "user")


def test_a_registered_answer_turns_synthesis_on_for_its_prompts() raises:
    var l = StubLlmClient()
    l.add_synthesis("answer from the evidence", "evidence: E1. question: Q?", "A1")
    assert_true(l.has_synthesis())
    assert_equal(
        l.synthesize("answer from the evidence", "evidence: E1. question: Q?"),
        "A1",
    )
    # Either prompt differing is a different key.
    with assert_raises(contains="no answer registered"):
        _ = l.synthesize("another system text", "evidence: E1. question: Q?")
    with assert_raises(contains="no answer registered"):
        _ = l.synthesize("answer from the evidence", "evidence: E2. question: Q?")


def test_a_synthesis_answer_registered_again_is_replaced() raises:
    var l = StubLlmClient()
    l.add_synthesis("s", "u", "first")
    l.add_synthesis("s", "u", "second")
    assert_equal(l.synthesize("s", "u"), "second")


struct _LlmJudge[L: LlmClient](SameEntityJudge):
    """The adapter a caller writes to settle dedup's borderline candidates with
    an LlmClient."""

    var llm: Self.L
    var asked: Int

    def __init__(out self, var llm: Self.L):
        self.llm = llm^
        self.asked = 0

    def same_entity(
        mut self, mention_name: String, candidate: DedupCandidate
    ) raises -> Bool:
        self.asked += 1
        return self.llm.judge_same_entity(
            mention_name, "", candidate.name, candidate.summary
        )


def test_a_caller_bridges_the_client_to_the_dedup_judge() raises:
    var llm = StubLlmClient()
    llm.add_same_entity("Acme Incorporated", "Acme Inc", True)
    var judge = _LlmJudge[StubLlmClient](llm^)
    var near = List[DedupCandidate]()
    near.append(DedupCandidate(13, "Acme Inc", "a company"))
    var res = dedup_resolve_judged("Acme Incorporated", near, 0.7, 0.25, 2.6, judge)
    assert_true(res.is_matched())
    assert_equal(res.nid, 13)
    assert_equal(judge.asked, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
