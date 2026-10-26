# =============================================================================
# test_dedup.mojo -- resolve a mention against candidate entities.
# =============================================================================
#
#   exact       equal normalized names match at tier 1 and the first such
#               candidate wins; an exact match beats a better-ranked fuzzy one.
#   fuzzy       a near-duplicate that shares a band and reaches the merge floor
#               matches at tier 2; the best estimate wins over earlier, weaker
#               matches; a tie goes to the lower index.
#   specificity a generic mention is new, not merged into a more specific name;
#               a generic candidate is skipped for a specific mention.
#   judgment    a borderline candidate asks for judgment and names which one, the
#               best near-miss wins; a pair that reaches the merge floor without
#               a band collision is judged, not dropped; floors are arguments.
#   new         no candidates, or only unrelated ones, gives new.
#   empty       a mention with no letter or digit is new and matches nothing,
#               and neither does a candidate with none.
#   scripts     names in a script other than Latin match only themselves.
#   judge       dedup_resolve_judged asks the caller's judge only for a
#               borderline candidate and only once, passes it the mention and the
#               candidate, folds yes into a tier-3 match and no into new, and
#               passes a judge's error on.
# No test calls a model, reads a clock or reads the environment.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_kg import (
    DedupCandidate,
    RES_MATCHED,
    RES_NEEDS_JUDGMENT,
    RES_NEW,
    Resolution,
    SameEntityJudge,
    dedup_resolve,
    dedup_resolve_judged,
)

comptime _MERGE: Float64 = 0.7
comptime _ESCALATE: Float64 = 0.25
comptime _MIN_ENTROPY: Float64 = 2.6


def _resolve(mention: String, cands: List[DedupCandidate]) -> Resolution:
    return dedup_resolve(mention, cands, _MERGE, _ESCALATE, _MIN_ENTROPY)


def _cand(nid: Int64, name: String) -> DedupCandidate:
    return DedupCandidate(nid, name, "summary of " + name)


def test_exact_normalized_match_is_tier_one() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(42, "acme inc "))
    var res = _resolve("Acme Inc", cands)
    assert_equal(res.kind, RES_MATCHED)
    assert_true(res.is_matched())
    assert_equal(res.tier, 1)
    assert_equal(res.nid, Int64(42))
    assert_equal(res.candidate_index, -1)


def test_first_exact_candidate_wins() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(8, "Other Name"))
    cands.append(_cand(11, "ACME, INC."))
    cands.append(_cand(12, "acme inc"))
    assert_equal(_resolve("Acme Inc", cands).nid, Int64(11))


def test_exact_beats_a_better_ranked_fuzzy_candidate() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(1, "Acme Catalog Models"))
    cands.append(_cand(2, "Acme Catalog Model"))
    var res = _resolve("acme catalog model", cands)
    assert_equal(res.tier, 1)
    assert_equal(res.nid, Int64(2))


def test_near_duplicate_is_a_tier_two_match() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(7, "Acme Catalog Model"))
    var res = _resolve("Acme Catalog Models", cands)
    assert_equal(res.kind, RES_MATCHED)
    assert_equal(res.tier, 2)
    assert_equal(res.nid, Int64(7))


def test_best_fuzzy_estimate_wins_over_earlier_matches() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(1, "Acme Catalog Modelz"))
    cands.append(_cand(2, "Acme Catalog Model"))
    cands.append(_cand(3, "Acmes Catalog Models"))
    var res = _resolve("Acme Catalog Models", cands)
    assert_equal(res.tier, 2)
    assert_equal(res.nid, Int64(3))


def test_equal_fuzzy_estimates_go_to_the_lower_index() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(5, "Acme Catalog Model"))
    cands.append(_cand(6, "acme catalog model!"))
    # Both names normalize alike, so the two estimates are equal.
    assert_equal(_resolve("Acme Catalog Models", cands).nid, Int64(5))


def test_generic_mention_is_new_not_merged_into_a_specific_name() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(99, "Catalog Tier Change"))
    var res = _resolve("Catalog", cands)
    assert_equal(res.kind, RES_NEW)
    assert_true(res.is_new())
    assert_equal(res.tier, 0)
    assert_equal(res.nid, Int64(-1))
    assert_equal(res.candidate_index, -1)


def test_generic_candidate_is_skipped_for_a_specific_mention() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(99, "Catalog"))
    assert_true(_resolve("Catalog Tier Change", cands).is_new())


def test_a_generic_mention_still_matches_exactly() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(4, "CATALOG"))
    var res = _resolve("catalog", cands)
    assert_equal(res.tier, 1)
    assert_equal(res.nid, Int64(4))


def test_borderline_candidate_asks_for_judgment() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(7, "Acme Catalog Model"))
    cands.append(_cand(13, "Acme Inc"))
    var res = _resolve("Acme Incorporated", cands)
    assert_equal(res.kind, RES_NEEDS_JUDGMENT)
    assert_true(res.is_needs_judgment())
    assert_equal(res.tier, 3)
    assert_equal(res.candidate_index, 1)
    assert_equal(res.nid, Int64(13))


def test_equal_borderline_candidates_go_to_the_lower_index() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(13, "Acme Inc"))
    cands.append(_cand(14, "ACME INC"))
    # These two normalize alike, so the second is not a better near-miss.
    var res = _resolve("Acme Incorporated", cands)
    assert_true(res.is_needs_judgment())
    assert_equal(res.candidate_index, 0)
    assert_equal(res.nid, Int64(13))


def test_a_pair_at_the_merge_floor_without_a_band_is_judged() raises:
    # Estimate 0.75 (above the merge floor) but no shared band: not strong
    # enough to merge on its own, too close to call it new.
    var cands = List[DedupCandidate]()
    cands.append(_cand(21, "harbor aypha meadow"))
    var res = _resolve("Harbor Alpha Meadow", cands)
    assert_true(res.is_needs_judgment())
    assert_equal(res.candidate_index, 0)
    assert_equal(res.nid, Int64(21))


def test_floors_are_arguments() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(13, "Acme Inc"))
    # Estimate 0.28: judged at the default escalation floor, new above it.
    assert_true(_resolve("Acme Incorporated", cands).is_needs_judgment())
    var strict = dedup_resolve("Acme Incorporated", cands, 0.95, 0.9, _MIN_ENTROPY)
    assert_true(strict.is_new())
    # A higher entropy floor makes even the specific mention too generic.
    var gated = dedup_resolve("Acme Incorporated", cands, _MERGE, _ESCALATE, 6.0)
    assert_true(gated.is_new())


def test_no_candidate_or_only_unrelated_ones_is_new() raises:
    var none = List[DedupCandidate]()
    assert_true(_resolve("Acme Incorporated", none).is_new())
    var far = List[DedupCandidate]()
    far.append(_cand(3, "Globex Ltd"))
    assert_true(_resolve("Acme Catalog Models", far).is_new())


def test_a_name_with_no_letter_or_digit_matches_nothing() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(1, "???"))
    cands.append(_cand(2, ""))
    assert_true(_resolve("!!!", cands).is_new())
    assert_true(_resolve("", cands).is_new())
    # And such a candidate is not matched by a real mention.
    assert_true(_resolve("Acme Inc", cands).is_new())


def test_names_in_other_scripts_match_only_themselves() raises:
    var cands = List[DedupCandidate]()
    cands.append(_cand(1, "大阪"))
    cands.append(_cand(2, "東京"))
    var res = _resolve("東京", cands)
    assert_equal(res.tier, 1)
    assert_equal(res.nid, Int64(2))
    assert_true(_resolve("京都", cands).is_new())


struct _Judge(SameEntityJudge):
    """A scripted judge: answers `verdict`, or raises when `fail`, and records
    what it was asked."""

    var verdict: Bool
    var fail: Bool
    var calls: Int
    var asked_mention: String
    var asked_nid: Int64
    var asked_summary: String

    def __init__(out self, verdict: Bool, fail: Bool = False):
        self.verdict = verdict
        self.fail = fail
        self.calls = 0
        self.asked_mention = String("")
        self.asked_nid = -1
        self.asked_summary = String("")

    def same_entity(
        mut self, mention_name: String, candidate: DedupCandidate
    ) raises -> Bool:
        self.calls += 1
        self.asked_mention = mention_name
        self.asked_nid = candidate.nid
        self.asked_summary = candidate.summary
        if self.fail:
            raise Error("judge unavailable")
        return self.verdict


def _borderline_cands() -> List[DedupCandidate]:
    var cands = List[DedupCandidate]()
    cands.append(_cand(7, "Acme Catalog Model"))
    cands.append(_cand(13, "Acme Inc"))
    return cands^


def test_judge_yes_becomes_a_tier_three_match() raises:
    var judge = _Judge(True)
    var res = dedup_resolve_judged(
        "Acme Incorporated", _borderline_cands(), _MERGE, _ESCALATE, _MIN_ENTROPY, judge
    )
    assert_equal(res.kind, RES_MATCHED)
    assert_equal(res.tier, 3)
    assert_equal(res.nid, Int64(13))
    assert_equal(judge.calls, 1)
    assert_equal(judge.asked_mention, "Acme Incorporated")
    assert_equal(judge.asked_nid, Int64(13))
    assert_equal(judge.asked_summary, "summary of Acme Inc")


def test_judge_no_becomes_new() raises:
    var judge = _Judge(False)
    var res = dedup_resolve_judged(
        "Acme Incorporated", _borderline_cands(), _MERGE, _ESCALATE, _MIN_ENTROPY, judge
    )
    assert_equal(res.kind, RES_NEW)
    assert_equal(res.nid, Int64(-1))
    assert_equal(judge.calls, 1)


def test_judge_is_not_asked_when_the_cascade_decides() raises:
    var judge = _Judge(False)
    var exact = List[DedupCandidate]()
    exact.append(_cand(42, "acme inc"))
    var r1 = dedup_resolve_judged("Acme Inc", exact, _MERGE, _ESCALATE, _MIN_ENTROPY, judge)
    assert_equal(r1.tier, 1)

    var fuzzy = List[DedupCandidate]()
    fuzzy.append(_cand(7, "Acme Catalog Model"))
    var r2 = dedup_resolve_judged(
        "Acme Catalog Models", fuzzy, _MERGE, _ESCALATE, _MIN_ENTROPY, judge
    )
    assert_equal(r2.tier, 2)

    var none = List[DedupCandidate]()
    var r3 = dedup_resolve_judged("Acme Inc", none, _MERGE, _ESCALATE, _MIN_ENTROPY, judge)
    assert_true(r3.is_new())
    assert_equal(judge.calls, 0)


def test_judge_error_is_passed_on() raises:
    var judge = _Judge(True, fail=True)
    with assert_raises(contains="judge unavailable"):
        _ = dedup_resolve_judged(
            "Acme Incorporated", _borderline_cands(), _MERGE, _ESCALATE, _MIN_ENTROPY, judge
        )
    assert_equal(judge.calls, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
