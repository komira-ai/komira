# =============================================================================
# dedup -- resolve one entity mention against candidate entities.
# =============================================================================
#
# `dedup_resolve` takes a mention's name and a list of candidates (existing
# entities the caller found by embedding similarity) and returns a decision:
# the mention IS a candidate, it is a NEW entity, or a candidate is close enough
# that someone must JUDGE. It reads no store, calls no model and reads no clock;
# the same inputs always give the same decision.
#
# The tiers, in order:
#   1 exact      the normalized names are equal: matched, no further test.
#   gate         a mention whose normalized name has less entropy than
#                `min_entropy` is too generic to merge on similarity ("Catalog"
#                must not fold into "Catalog Tier Change"): new.
#   2 fuzzy      a candidate (also past the entropy gate) whose signature shares
#                a band with the mention's and whose Jaccard estimate reaches
#                `jaccard_merge`: matched; the best estimate wins.
#   3 escalate   otherwise the best candidate at or above `jaccard_escalate`
#                (see `pair_decision`): needs judgment.
#   new          nothing qualified.
#
# Judgment is the caller's. `Resolution.needs_judgment` names the candidate to
# ask about. A caller may handle that itself, or pass a `SameEntityJudge` (a
# trait the caller implements with a model, a rule or a person) to
# `dedup_resolve_judged`, which asks it and folds the verdict into a matched or
# new decision. This package holds no model.
# =============================================================================

from .name_similarity import (
    PAIR_ESCALATE,
    PAIR_MERGE,
    jaccard_estimate,
    lsh_candidate,
    minhash_signature,
    normalize_name,
    pair_decision,
    shannon_entropy,
)


@fieldwise_init
struct DedupCandidate(Copyable, Movable):
    """An existing entity offered to the cascade.

    Fields:
        nid: The entity's dense id (what a match resolves to).
        name: Its surface name.
        summary: Its summary, for a judge to read.
    """

    var nid: Int64
    var name: String
    var summary: String


# The decision kinds a `Resolution` carries.
comptime RES_MATCHED: Int = 0
comptime RES_NEW: Int = 1
comptime RES_NEEDS_JUDGMENT: Int = 2


@fieldwise_init
struct Resolution(Copyable, Movable):
    """The cascade's decision for one mention.

    Fields:
        kind: `RES_MATCHED`, `RES_NEW` or `RES_NEEDS_JUDGMENT`.
        nid: The matched or candidate id; -1 for new.
        tier: 1 exact, 2 fuzzy, 3 judged or to be judged, 0 new.
        candidate_index: For `RES_NEEDS_JUDGMENT`, the index in the candidate
            list to ask about; -1 otherwise.
    """

    var kind: Int
    var nid: Int64
    var tier: Int
    var candidate_index: Int

    @staticmethod
    def matched(nid: Int64, tier: Int) -> Self:
        """The mention is the entity `nid`, decided at `tier`."""
        return Self(RES_MATCHED, nid, tier, -1)

    @staticmethod
    def new_entity() -> Self:
        """The mention is a new entity; the caller mints its id."""
        return Self(RES_NEW, Int64(-1), 0, -1)

    @staticmethod
    def needs_judgment(candidate_nid: Int64, candidate_index: Int) -> Self:
        """The candidate at `candidate_index` may be the mention; someone must
        judge. `nid` is that candidate's id, not yet trusted."""
        return Self(RES_NEEDS_JUDGMENT, candidate_nid, 3, candidate_index)

    def is_matched(self) -> Bool:
        return self.kind == RES_MATCHED

    def is_new(self) -> Bool:
        return self.kind == RES_NEW

    def is_needs_judgment(self) -> Bool:
        return self.kind == RES_NEEDS_JUDGMENT


def dedup_resolve(
    mention_name: String,
    candidates: List[DedupCandidate],
    jaccard_merge: Float64,
    jaccard_escalate: Float64,
    min_entropy: Float64,
) -> Resolution:
    """Run the cascade for one mention.

    On equal scores the lower candidate index wins, so the caller's ranking
    (best embedding match first) breaks ties. A mention, or a candidate, whose
    normalized name is empty (no letter or digit) is never matched by name: an
    empty name identifies nothing.

    Args:
        mention_name: The mention's surface name.
        candidates: Existing entities to test, best first.
        jaccard_merge: The auto-merge floor (for example 0.7).
        jaccard_escalate: The escalation floor (for example 0.25).
        min_entropy: The specificity floor, in bits, below which a name is not
            merged or escalated on similarity.

    Returns:
        Matched, new, or needs-judgment.
    """
    var mention_norm = normalize_name(mention_name)
    if len(mention_norm.as_bytes()) == 0:
        return Resolution.new_entity()

    for i in range(len(candidates)):
        if normalize_name(candidates[i].name) == mention_norm:
            return Resolution.matched(candidates[i].nid, 1)

    if shannon_entropy(mention_norm) < min_entropy:
        return Resolution.new_entity()

    var mention_sig = minhash_signature(mention_norm)
    var best_merge_jac = -1.0
    var best_merge_idx = -1
    var best_escalate_jac = -1.0
    var best_escalate_idx = -1

    for i in range(len(candidates)):
        var cand_norm = normalize_name(candidates[i].name)
        if shannon_entropy(cand_norm) < min_entropy:
            continue
        var cand_sig = minhash_signature(cand_norm)
        var jac = jaccard_estimate(mention_sig, cand_sig)
        var tier = pair_decision(
            jac,
            lsh_candidate(mention_sig, cand_sig),
            jaccard_merge,
            jaccard_escalate,
        )
        if tier == PAIR_MERGE:
            if jac > best_merge_jac:
                best_merge_jac = jac
                best_merge_idx = i
        elif tier == PAIR_ESCALATE:
            if jac > best_escalate_jac:
                best_escalate_jac = jac
                best_escalate_idx = i

    if best_merge_idx >= 0:
        return Resolution.matched(candidates[best_merge_idx].nid, 2)
    if best_escalate_idx >= 0:
        return Resolution.needs_judgment(
            candidates[best_escalate_idx].nid, best_escalate_idx
        )
    return Resolution.new_entity()


trait SameEntityJudge(Movable, Deinitable):
    """The caller's verdict on a borderline pair: is the mention this
    candidate? Implemented with a model, a rule or a person, outside this
    package."""

    def same_entity(
        mut self, mention_name: String, candidate: DedupCandidate
    ) raises -> Bool:
        """True when the mention names the same entity as `candidate`."""
        ...


def dedup_resolve_judged[
    J: SameEntityJudge
](
    mention_name: String,
    candidates: List[DedupCandidate],
    jaccard_merge: Float64,
    jaccard_escalate: Float64,
    min_entropy: Float64,
    mut judge: J,
) raises -> Resolution:
    """`dedup_resolve`, with a needs-judgment decision settled by `judge`.

    The judge is asked at most once, and only for a borderline candidate: an
    exact, fuzzy or new decision never reaches it. A yes gives
    `Resolution.matched(candidate.nid, 3)`, a no gives a new entity. An error
    the judge raises propagates; no decision is guessed.

    Args:
        mention_name: The mention's surface name.
        candidates: Existing entities to test, best first.
        jaccard_merge: The auto-merge floor.
        jaccard_escalate: The escalation floor.
        min_entropy: The specificity floor, in bits.
        judge: The caller's verdict function.

    Returns:
        Matched or new; never needs-judgment.
    """
    var res = dedup_resolve(
        mention_name, candidates, jaccard_merge, jaccard_escalate, min_entropy
    )
    if not res.is_needs_judgment():
        return res^
    if judge.same_entity(mention_name, candidates[res.candidate_index]):
        return Resolution.matched(res.nid, 3)
    return Resolution.new_entity()
