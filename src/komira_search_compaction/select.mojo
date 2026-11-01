# =============================================================================
# komira_search_compaction/select.mojo — which splits to merge.
# =============================================================================
#
# The selection policy of a single-level merge: merge at least `MERGE_FACTOR`
# small splits at a time, smallest first, up to a byte cap. A pure function
# over `List[MergeCandidate]`: no store, no readers, testable in isolation.
# The constants follow the stable-log merge policy of Quickwit and Lucene's
# tiered merge policy.
#
# Candidate and plan are plain value records (strings, integers, lists); no
# pointer appears in any signature.
# =============================================================================

from komira_search_catalog.split_summary import SplitSummary


# =============================================================================
# Pinned policy constants.
# =============================================================================

comptime SPLIT_DOC_TARGET: Int64 = 10_000_000
"""A split at or above this document count is mature: it is never re-read. The
document-count eligibility ceiling."""

comptime SPLIT_BYTE_TARGET: Int64 = 100_000_000
"""The byte-size eligibility ceiling (about 100 MB). A split below EITHER
target is a merge candidate; at or above BOTH it is mature."""

comptime MERGE_FACTOR: Int = 10
"""Fire a merge only once at least this many eligible small splits have
accumulated. Below it a merge is a wasted rewrite that hurts freshness."""

comptime MAX_MERGE_FACTOR: Int = 12
"""Never take more than this many inputs in one merge (bounds the work of one
merge)."""

comptime MAX_MERGED_BYTES: Int64 = 5_000_000_000
"""The write-amplification cap (about 5 GB). The greedy selection stops adding
inputs once the summed `byte_size` would exceed it."""


# =============================================================================
# The candidate and the plan.
# =============================================================================


@fieldwise_init
struct MergeCandidate(Copyable, Movable, Deinitable):
    """One live split with the shard lineage and the manifest `chunk_seq` it
    lives at.

    The candidate set is the union of all of an index's lineages. Each
    candidate carries the `shard_id` it was published in (the empty string tags
    the unsharded lineage `<index>/meta`) so `compact_once` can route the
    `retire` of each input to the lineage that holds it. `select_merge` is
    policy over the union: the shard id is carried through unchanged, and the
    smallest splits are merged whichever writer produced them."""

    var shard_id: String
    var chunk_seq: Int64
    var summary: SplitSummary


@fieldwise_init
struct MergePlan(Movable, Deinitable):
    """The selected merge set, in greedy smallest-first order. `should_merge()`
    is False when the trigger threshold was not met; the caller then does
    nothing. When it is True the set holds between `MERGE_FACTOR` and
    `MAX_MERGE_FACTOR` candidates."""

    var selected: List[MergeCandidate]

    @always_inline
    def should_merge(self) -> Bool:
        return len(self.selected) >= MERGE_FACTOR

    @always_inline
    def num_selected(self) -> Int:
        return len(self.selected)


# =============================================================================
# select_merge: the pure policy.
# =============================================================================


def _is_eligible(s: SplitSummary) -> Bool:
    """A candidate iff `doc_count < SPLIT_DOC_TARGET` or `byte_size <
    SPLIT_BYTE_TARGET`. A split at or above both targets is mature."""
    return s.doc_count < SPLIT_DOC_TARGET or s.byte_size < SPLIT_BYTE_TARGET


def _maturity_ok(s: SplitSummary) -> Bool:
    """A split that is already merged (`merge_ops > 0`) is not fed into a new
    merge: only splits written by ingest (`merge_ops == 0`) are eligible
    inputs. This keeps a low-volume index whose merged result stays under the
    target from re-merging forever, which would re-tokenize the same documents
    again and again.

    The trigger therefore needs `MERGE_FACTOR` new small splits to justify a
    merge. A time-based maturation of merged splits is not implemented."""
    return s.merge_ops == Int64(0)


def select_merge(
    candidates: List[MergeCandidate],
) -> MergePlan:
    """The single-level policy:

      1. Eligibility: keep the candidates that are small (document count or
         byte size under its target) and were written by ingest.
      2. Trigger: with fewer than `MERGE_FACTOR` eligible candidates, return an
         empty plan (`should_merge()` is False).
      3. Selection: sort the eligible candidates by `byte_size` ascending and
         greedily take the smallest ones, at most `MAX_MERGE_FACTOR`, while the
         summed `byte_size` stays within `MAX_MERGED_BYTES`.

    A selection that the byte cap clips below `MERGE_FACTOR` is returned as it
    is; `should_merge()` is then False, because a merge below the factor is a
    wasted rewrite. The function does no I/O: the caller feeds it the live
    splits and merges and retires exactly the plan's set."""
    # 1. Eligibility and maturity filter.
    var eligible = List[MergeCandidate]()
    for i in range(len(candidates)):
        ref c = candidates[i]
        if _is_eligible(c.summary) and _maturity_ok(c.summary):
            eligible.append(c.copy())

    # 2. Trigger gate.
    if len(eligible) < MERGE_FACTOR:
        return MergePlan(List[MergeCandidate]())

    # 3a. Sort by byte_size ascending (insertion sort: manifests are small).
    for i in range(1, len(eligible)):
        var v = eligible[i].copy()
        var j = i - 1
        while j >= 0 and eligible[j].summary.byte_size > v.summary.byte_size:
            eligible[j + 1] = eligible[j].copy()
            j -= 1
        eligible[j + 1] = v^

    # 3b. Greedy smallest-first under the byte cap, bounded by MAX_MERGE_FACTOR.
    var selected = List[MergeCandidate]()
    var summed = Int64(0)
    for i in range(len(eligible)):
        if len(selected) >= MAX_MERGE_FACTOR:
            break
        var bs = eligible[i].summary.byte_size
        if len(selected) > 0 and summed + bs > MAX_MERGED_BYTES:
            # Adding this one would exceed the write-amplification cap: stop.
            # The smaller inputs already selected form the merge.
            break
        selected.append(eligible[i].copy())
        summed += bs

    return MergePlan(selected^)
