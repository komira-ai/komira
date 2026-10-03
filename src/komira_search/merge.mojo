# =============================================================================
# merge.mojo — the MULTI-SPLIT result-merge reducers.
# =============================================================================
#
# An orchestration layer ABOVE the single-split SearchCore. These are
# the PURE merge reducers — free functions over `List[SearchResult]` + the
# query's from/size/sort/aggs — that fold N per-split SearchResults into ONE
# global result before the single render call. They live in `komira_search`
# (the LIGHT core+eval edge: NO S3, NO Morsel dep) so they stay unit-testable as
# pure functions over in-memory split results (no S3, no Reactor).
#
# The four cross-split correctness traps:
#   (1) per-split over-fetch to (from+size) NOT size — the driver zeroes
#       from_offset and sets top_k=from+size on the per-split QueryIR copy, so the
#       leaf returns its top (from+size) candidates UN-sliced; THIS reducer does
#       the single global [from, from+size) skip.
#   (2) deterministic cross-split tiebreak (sort-key, doc_id, split-publish-order)
#       — internal doc_ids COLLIDE across splits (every split stamps min_doc_id=0),
#       so each hit carries its split's publish-order index and ties break on it.
#   (3) terms doc_count summed per key across splits, then re-finalize (re-sort by
#       the agg order, re-truncate to the base size, recompute sum_other_doc_count).
#   (4) metric fold: count/sum SUM, min MIN, max MAX, has_value OR; avg re-derived
#       from the MERGED sum/count (NEVER avg-of-averages); empty-set fidelity.
# =============================================================================

from komira_search.source import (
    SearchResult,
    SortKeyColumn,
    AggResults,
    AggResult,
    AggSpec,
    _TermBucket,
    _finalize_terms,
    _assemble_hit_batch,
    SORT_MODE_SCORE,
    SORT_MODE_DOC,
    SORT_MODE_I64,
    SORT_MODE_F64,
    SORT_MODE_STR,
    SORT_ASC,
    MISSING_LAST,
    AGG_KIND_TERMS,
    AGG_ORDER_COUNT_DESC,
    AGG_ORDER_KEY_ASC,
    AGG_ORDER_KEY_DESC,
)
from komira_core.collections.slab import Slab


# =============================================================================
# The reducer container is Slab, not List.
# =============================================================================
#
# The natural reducer signature would be
# `merge_search_results(results: List[SearchResult], ...)`. Mojo CANNOT
# express that: `List[T]` HARD-REQUIRES `T: Copyable`, and `SearchResult` is
# Movable-only (it carries a Movable-only `RecordBatch`). So the N per-split
# results ride a `Slab[SearchResult]` — the project's canonical Movable-only
# container, already used for the Movable-only `_SearchState` of the search
# runtime's source. Slab's `__getitem__` returns a TIGHT-origin
# `ref [self._bytes] T` — NOT a wildcard
# `MutExternalOrigin` cast — so this is NOT a byte-slab+wildcard trap (the
# heap-owning inner fields' liveness is tracked through the tight origin, exactly
# as `_SearchState`'s `SearchCore`/`QueryIR` heap fields are today). Intent is
# preserved: the reducers stay PURE functions over the N per-split results in the
# light `komira_search` core, unit-testable with in-memory splits (no S3).


# =============================================================================
# shard_size: the per-split terms over-fetch bound.
# =============================================================================


@always_inline
def shard_size_for(base_size: Int) -> Int:
    """The OpenSearch per-split terms `shard_size` over-fetch (default
    `size*1.5 + 10`): each split returns MORE than `size` buckets so a globally-
    significant term below per-split `size` is not dropped before the merge. The
    coordinator re-truncates to the ORIGINAL `base_size` after the union."""
    if base_size < 0:
        return 0
    return base_size * 3 // 2 + 10


# =============================================================================
# _MergeHit: one decoded per-split hit + its provenance.
# =============================================================================


struct _MergeHit(Copyable, Movable, Deinitable):
    """One hit pulled out of a per-split SearchResult, tagged with its split's
    publish-order index for the deterministic cross-split tiebreak.

    Carries every column the global comparator needs: `score`/`doc_id` (the
    `_score`/`_doc` keys) PLUS the typed sort key (`key_i64`/`key_f64`/`key_str` +
    `missing`) when the sort is by a fast-field. `source` is the rendered `_source`
    blob (carried so the merged page can be re-assembled). `split_index` is the
    stable publish-order position (the tiebreak)."""

    var score: Float64
    var doc_id: Int64
    var source: String
    var key_i64: Int64
    var key_f64: Float64
    var key_str: String
    var missing: Bool
    var split_index: Int

    def __init__(
        out self,
        score: Float64,
        doc_id: Int64,
        var source: String,
        split_index: Int,
        key_i64: Int64 = 0,
        key_f64: Float64 = 0.0,
        var key_str: String = String(""),
        missing: Bool = False,
    ):
        self.score = score
        self.doc_id = doc_id
        self.source = source^
        self.split_index = split_index
        self.key_i64 = key_i64
        self.key_f64 = key_f64
        self.key_str = key_str^
        self.missing = missing


# =============================================================================
# the global ranking comparator (mirror _a_ranks_higher / _typed).
# =============================================================================


@always_inline
def _typed_hit_ranks_higher(
    a: _MergeHit, b: _MergeHit, mode: UInt8, order: UInt8, miss: UInt8
) -> Bool:
    """Mirror `_TopKHeap._typed_a_ranks_higher` (source.mojo) EXACTLY for the
    cross-split merge: null-bucket-first per `missing_order` -> typed compare
    honoring `order` -> the (doc_id, split_index) composite tiebreak."""
    var ma = a.missing
    var mb = b.missing
    if ma != mb:
        if miss == MISSING_LAST:
            return mb  # a ranks higher iff b is the missing one.
        return ma  # MISSING_FIRST: a ranks higher iff a is the missing one.
    if not ma:  # both present: typed compare honoring `order`.
        var a_smaller: Bool
        if mode == SORT_MODE_I64:
            if a.key_i64 != b.key_i64:
                a_smaller = a.key_i64 < b.key_i64
                return a_smaller == (order == SORT_ASC)
        elif mode == SORT_MODE_F64:
            if a.key_f64 != b.key_f64:
                a_smaller = a.key_f64 < b.key_f64
                return a_smaller == (order == SORT_ASC)
        else:  # SORT_MODE_STR
            if a.key_str != b.key_str:
                a_smaller = a.key_str < b.key_str
                return a_smaller == (order == SORT_ASC)
    # both missing OR key tie: the cross-split composite tiebreak.
    return _composite_tiebreak(a, b)


@always_inline
def _composite_tiebreak(a: _MergeHit, b: _MergeHit) -> Bool:
    """On an otherwise-exact tie, order by (doc_id asc, then
    split-publish-order asc). doc_ids COLLIDE across splits (every split stamps
    min_doc_id=0), so a naive doc-id tiebreak is non-deterministic across splits;
    the split-publish-order index is the deterministic, stable secondary key."""
    if a.doc_id != b.doc_id:
        return a.doc_id < b.doc_id
    return a.split_index < b.split_index


@always_inline
def _hit_ranks_higher(
    a: _MergeHit, b: _MergeHit, mode: UInt8, order: UInt8, miss: UInt8
) -> Bool:
    """True iff hit `a` ranks STRICTLY higher than `b` in the global descending
    order. Mirrors `_TopKHeap._a_ranks_higher` branched on the sort mode, with the
    cross-split composite tiebreak replacing the leaf's lower-doc_id tiebreak
    (doc_ids collide cross-split)."""
    if mode == SORT_MODE_SCORE:
        # Higher score, then the (doc_id, split_index) composite.
        if a.score != b.score:
            return a.score > b.score
        return _composite_tiebreak(a, b)
    if mode == SORT_MODE_DOC:
        # doc_id honoring `order`, then split_index on a true doc_id tie.
        if a.doc_id != b.doc_id:
            var a_smaller = a.doc_id < b.doc_id
            return a_smaller == (order == SORT_ASC)
        return a.split_index < b.split_index
    return _typed_hit_ranks_higher(a, b, mode, order, miss)


def _order_hits_descending(
    hits: List[_MergeHit], mode: UInt8, order: UInt8, miss: UInt8
) -> List[Int]:
    """Return the hit indices sorted STRONGEST-first by the global comparator.
    Selection sort over an INDEX permutation (the leaf `drain_descending` shape —
    avoids moving the non-Copyable `_MergeHit` payloads; the union is
    N*(from+size) entries, small at per-query scale). Deterministic: every
    comparison resolves to a strict order via the composite tiebreak, so the
    permutation is stable across repeated merges."""
    var n = len(hits)
    var idx = List[Int]()
    for i in range(n):
        idx.append(i)
    for i in range(n):
        var best = i
        for j in range(i + 1, n):
            if _hit_ranks_higher(
                hits[idx[j]], hits[idx[best]], mode, order, miss
            ):
                best = j
        var t = idx[i]
        idx[i] = idx[best]
        idx[best] = t
    return idx^


# =============================================================================
# _sort_mode_for: map the sort_field/order to the SORT_MODE_* discriminant.
# =============================================================================
#
# The driver KNOWS each split's resolved sort mode (it built the leaf query). To
# keep the reducer pure + self-contained, the merge takes the sort mode directly
# (the driver passes the SortKeyColumn.mode it read off any non-empty split
# result, or SORT_MODE_SCORE / SORT_MODE_DOC for the score/doc paths).


def _resolve_merge_mode(
    results: Slab[SearchResult], default_mode: UInt8
) raises -> UInt8:
    """Resolve the cross-split sort mode. A fast-field-sorted result carries the
    typed mode on its SortKeyColumn; if ANY split surfaced a typed key, that mode
    governs the merge. Otherwise the caller's `default_mode` (SCORE/DOC) wins."""
    for i in range(len(results)):
        if results[i].sort_keys.is_typed():
            return results[i].sort_keys.mode
    return default_mode


# =============================================================================
# MergedSearch + merge_search_results: hits + total + max_score reducer.
# =============================================================================


struct MergedSearch(Movable, Deinitable):
    """The cross-split hits-merge output: the global SearchResult PLUS the per-row
    split-publish-order index (provenance). The driver uses `hit_split_index`
    to render the namespaced `<split-short-uuid>_<doc_id>` `_id` that disambiguates
    cross-split doc-id collisions — the merged 3-column HitBatch cannot
    carry that provenance, so it rides here parallel to the merged page rows."""

    var result: SearchResult
    var hit_split_index: List[Int]

    def __init__(out self, var result: SearchResult, var hit_split_index: List[Int]):
        self.result = result^
        self.hit_split_index = hit_split_index^


def merge_search_results(
    var results: Slab[SearchResult],
    base_from: Int,
    base_size: Int,
    sort_mode: UInt8,
    sort_order: UInt8,
    missing_order: UInt8,
) raises -> MergedSearch:
    """Fold N per-split SearchResults into ONE global SearchResult (hits + total +
    max_score; the agg merge is `merge_agg_results`, called separately by the
    driver and stitched in via the returned result's `agg_results`). Returns a
    MergedSearch carrying the merged SearchResult + the per-row split-publish-order
    index (provenance, for the namespaced `_id` render).

    Each per-split result MUST already be the split's top `(from+size)` rows
    UN-sliced (the driver's per-split over-fetch rewrite). This reducer:
      1. unions all per-split hits, tagging each with its split-publish-order index,
      2. sorts STRONGEST-first by the global comparator (+ composite tiebreak),
      3. takes the GLOBAL `[from, from+size)` slice (the single skip),
      4. total = SUM of per-split total_matches; max_score = the merged top row.

    `sort_mode` is the resolved mode (the driver passes it; for a fast-field sort
    it is reconciled with the SortKeyColumn the leaves surfaced)."""
    # Resolve the effective mode: a typed result's SortKeyColumn mode governs.
    var mode = _resolve_merge_mode(results, sort_mode)

    # ---- 1. Union the per-split hits, tagged with the split-publish-order index.
    var hits = List[_MergeHit]()
    var total = 0
    for si in range(len(results)):
        ref r = results[si]
        total += r.total_matches
        var nrows = r.batch.num_rows()
        ref sk = r.sort_keys
        var has_typed = sk.is_typed() and sk.count() == nrows
        for row in range(nrows):
            var score = Float64(
                r.batch.column_at(0).as_primitive[DType.float64]().get(row)
            )
            var doc_id = Int64(
                r.batch.column_at(1).as_primitive[DType.int64]().get(row)
            )
            var source = r.batch.column_at(2).as_string().get(row)
            if has_typed:
                var ki = Int64(0)
                var kf = Float64(0.0)
                var ks = String("")
                var miss = sk.missing[row]
                if mode == SORT_MODE_I64:
                    ki = sk.key_i64[row]
                elif mode == SORT_MODE_F64:
                    kf = sk.key_f64[row]
                elif mode == SORT_MODE_STR:
                    ks = sk.key_str[row]
                hits.append(
                    _MergeHit(
                        score, doc_id, source^, si, ki, kf, ks^, miss
                    )
                )
            else:
                hits.append(_MergeHit(score, doc_id, source^, si))

    # ---- 2. Order the union STRONGEST-first by the global comparator (index
    #         permutation — avoids moving the non-Copyable hit payloads).
    var order = _order_hits_descending(hits, mode, sort_order, missing_order)

    # ---- 3. The GLOBAL [from, from+size) slice (the single skip).
    var page_start = base_from if base_from > 0 else 0
    var page_end = base_from + base_size
    if page_end > len(order):
        page_end = len(order)
    if page_start > len(order):
        page_start = len(order)

    # ---- 4. Re-assemble the merged page (score/doc_id/source) + the merged
    #         SortKeyColumn (so downstream sees the global page's typed keys).
    var scores = List[Float64]()
    var ids = List[Int64]()
    var sources = List[String]()
    var split_idx = List[Int]()
    var out_keys = SortKeyColumn(mode)
    var surface = (
        mode == SORT_MODE_I64
        or mode == SORT_MODE_F64
        or mode == SORT_MODE_STR
    )
    for oi in range(page_start, page_end):
        ref h = hits[order[oi]]
        scores.append(h.score)
        ids.append(h.doc_id)
        sources.append(h.source.copy())
        split_idx.append(h.split_index)
        if surface:
            out_keys.missing.append(h.missing)
            if mode == SORT_MODE_I64:
                out_keys.key_i64.append(h.key_i64)
            elif mode == SORT_MODE_F64:
                out_keys.key_f64.append(h.key_f64)
            else:  # SORT_MODE_STR
                out_keys.key_str.append(h.key_str.copy())

    return MergedSearch(
        SearchResult(
            _assemble_hit_batch(scores^, ids^, sources^),
            total,
            AggResults(),
            out_keys^,
        ),
        split_idx^,
    )


# =============================================================================
# merge_agg_results: the metric-fold + terms-union/re-finalize reducer.
# =============================================================================


def _merge_one_metric(mut acc: AggResult, src: AggResult):
    """Fold one split's metric AggResult into the accumulator:
    count/sum SUM; min MIN; max MAX over splits that have_value; has_value OR.
    avg is NOT stored — it is re-derived from the merged sum/count by
    `AggResult.avg()` at render (NEVER avg-of-averages). Empty-set fidelity is
    preserved: if NO split has_value, the merged result stays has_value=False (so
    avg/min/max render null) while count->0 and sum->0.0 (the AggResult ctor
    defaults)."""
    acc.count += src.count
    acc.sum += src.sum
    if src.has_value:
        if not acc.has_value:
            acc.min = src.min
            acc.max = src.max
            acc.has_value = True
        else:
            if src.min < acc.min:
                acc.min = src.min
            if src.max > acc.max:
                acc.max = src.max


def _merge_one_terms(
    mut acc: AggResult, src: AggResult, base_residual: Int
) -> Int:
    """Union one split's terms buckets into the accumulator (step 1):
    SUM `doc_count` per key across splits. Carries the running
    `sum_other_doc_count` residual (each split's own `sum_other_doc_count` — the
    tail it already dropped). Returns the updated residual. The per-key union is a
    linear scan over the (small, bounded by shard_size) bucket directory."""
    for i in range(len(src.buckets)):
        ref b = src.buckets[i]
        var found = False
        for j in range(len(acc.buckets)):
            if acc.buckets[j].key == b.key:
                acc.buckets[j].doc_count += b.doc_count
                found = True
                break
        if not found:
            acc.buckets.append(_TermBucket(b.key.copy(), b.doc_count))
    return base_residual + src.sum_other_doc_count


def _compute_terms_error_bound(
    results: Slab[SearchResult], agg_index: Int, order_code: UInt8
) -> Int:
    """The OpenSearch `doc_count_error_upper_bound` for the merged terms agg at
    `agg_index`, ORDER-DEPENDENT:

      * count-desc (AGG_ORDER_COUNT_DESC): the COMPUTED upper bound = the sum,
        over every split that DROPPED a bucket past its requested size, of that
        split's last-returned (smallest) bucket's doc_count — the most a term
        missing from that split could have contributed without appearing. Each
        split surfaced this as `last_bucket_doc_count` in `_finalize_terms`
        (0 when the split did NOT drop a bucket).
      * key-asc / key-desc: exactly 0 — key order is globally exact, so no shard
        can hide a term that belongs in the top-N.
      * count-asc / sub-agg order: -1 — the bound is indeterminate (a term with a
        tiny count on one shard could be globally large; not boundable).

    Single-split fidelity: with ONE split the bound is exactly 0 by
    OpenSearch definition — a lone shard saw every doc, so there is no OTHER shard
    that could be hiding a globally-significant term. The driver's dispatch path
    folds even a single live split through this merge, so the `len(results) <= 1`
    guard is what keeps a single shard at 0 (for count-desc; key-order is 0 and
    count-asc is -1 regardless of split count, matching OpenSearch)."""
    if order_code == AGG_ORDER_KEY_ASC or order_code == AGG_ORDER_KEY_DESC:
        return 0
    if order_code != AGG_ORDER_COUNT_DESC:
        # count-asc / sub-agg order — indeterminate.
        return -1
    # Single split: 0 by definition (no other shard to miss terms from).
    if len(results) <= 1:
        return 0
    # count-desc: sum the per-split last-returned-bucket counts of dropped splits.
    var bound = 0
    for si in range(len(results)):
        ref ar = results[si].agg_results
        if agg_index < len(ar.results):
            bound += ar.results[agg_index].last_bucket_doc_count
    return bound


def merge_agg_results(
    results: Slab[SearchResult], specs: List[AggSpec]
) raises -> AggResults:
    """Combine N per-split AggResults into ONE merged AggResults. `specs` is
    the ORIGINAL `List[AggSpec]` from `base_query.aggs_ref()` (with the ORIGINAL
    `base_size` bucket sizes — NOT the per-split `shard_size`), used to re-trim the
    merged terms directories. The per-agg merge is positional: every split runs the
    SAME agg specs, so result index `k` is the same agg across all splits.

    Metric aggs: field-wise fold (count/sum SUM, min MIN, max MAX, has_value OR);
    avg re-derived post-merge (never avg-of-averages); empty-set fidelity.
    Terms aggs: union buckets by key SUMMING doc_count, then re-run `_finalize_terms`
    over the MERGED directory with the ORIGINAL spec (re-sort by order, re-truncate
    to base_size, recompute sum_other_doc_count = per-split-sum + coordinator-tail).

    doc_count_error_upper_bound is ORDER-DEPENDENT:
      * count-desc (default): the COMPUTED bound = sum over splits that DROPPED a
        bucket of that split's last-returned-bucket doc_count (the most a missing
        term could have had there) — `_compute_terms_error_bound`.
      * key-asc / key-desc: exactly 0 (key order is exact across shards).
      * count-asc / sub-agg order: -1 (indeterminate)."""
    var out = List[AggResult]()
    var nspecs = len(specs)
    for k in range(nspecs):
        ref spec = specs[k]
        var acc = AggResult(spec.name.copy(), spec.kind)
        if spec.kind == AGG_KIND_TERMS:
            # Union buckets by key (sum doc_count), accumulate per-split residual.
            var residual = 0
            for si in range(len(results)):
                ref ar = results[si].agg_results
                if k < len(ar.results):
                    residual = _merge_one_terms(acc, ar.results[k], residual)
            # Re-finalize over the merged directory with the ORIGINAL spec
            # (re-sort, re-truncate to base_size, exact coordinator-tail other).
            # _finalize_terms sets sum_other_doc_count to the coordinator-tail
            # ONLY; add back the per-split residual the leaves already dropped.
            _finalize_terms(acc, spec)
            acc.sum_other_doc_count += residual
            # The order-dependent error bound. Computed
            # from each split's last_bucket_doc_count (NOT from sum_other — the two
            # are distinct: sum_other is the dropped TAIL total, the error bound is
            # the SINGLE smallest-returned-bucket count per dropped split).
            acc.doc_count_error_upper_bound = _compute_terms_error_bound(
                results, k, spec.order_code
            )
        else:
            for si in range(len(results)):
                ref ar = results[si].agg_results
                if k < len(ar.results):
                    _merge_one_metric(acc, ar.results[k])
        out.append(acc^)
    return AggResults(out^)
