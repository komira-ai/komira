# =============================================================================
# komira_log_index.l0_read: the per-split L0 posting-probe reader.
# =============================================================================
#
# This module owns the read path for an L0 (cheap drain) split: the branch a
# per-split read fan-out takes when `SplitView.has_l0_posting()` is True.
#
# WHY HERE (and not in komira_search): the L0 posting codec and its deserializer
# (`L0PostingIndex`, l0_index.mojo) live in komira_log_index, which depends on
# komira_search, not the other way round. The L0 read path needs both
# `L0PostingIndex` and the komira_search read surface (SearchResult,
# read_docstore_source, the filter, aggregation and sort machinery, and
# _assemble_hit_batch), so it lives in the one package that can name both. A
# read fan-out calls `search_l0_split` per split when the split is an L0 split
# and stays on the SearchCore BM25 path otherwise.
#
# WHAT IT DOES: analyze the match query text, hash each distinct term, probe the
# L0 posting in O(1), union the matching doc-ids, and accumulate the per-doc
# term frequency as the basic rank score (no BM25: that needs the precompute
# L0 omits). Everything downstream is the same as the optimized path: the
# filter (the L0 split's fast-field region is byte-identical to the optimized
# writer's, so the same FastFieldReader and predicate evaluation apply), the
# aggregation pass, the typed sort key, the bounded top-K heap, the page slice,
# the `_source` fetch and the 3-column hit batch. An L0 split therefore honors
# every QueryIR knob (filter, sort, aggregations); only `_score` differs
# (term-frequency rank, not BM25). That is what lets a mixed set of L0 and
# optimized splits merge with no lost or duplicated documents.
#
# This module has no UnsafePointer in any signature. It reuses the komira_search
# read primitives verbatim (FastFieldReader holds no Span field; the borrowed
# region Spans are tied to the parsed SplitView's inner bytes origin). All
# scratch is plain List storage.
# =============================================================================

from komira_hash import fnv1a_64

from komira_search.analyzer import analyze_text
from komira_search.fast_fields import (
    FastFieldReader,
    NumericFastFieldResolver,
    FloatFastFieldResolver,
    KeywordFastFieldResolver,
)
from komira_search.split import SplitView

# The komira_search read surface this module composes. read_docstore_source is
# a module-level public; _assemble_hit_batch, the filter, aggregation and sort
# helpers and _TopKHeap are module-private (an underscore-prefixed cross-module
# import works in Mojo). They are the same primitives SearchCore's _search_impl
# uses, composed identically so the L0 path is shaped like the optimized path
# downstream of the term decode.
from komira_search.source import (
    QueryIR,
    SearchResult,
    SortKeyColumn,
    AggResults,
    SORT_MODE_SCORE,
    SORT_MODE_DOC,
    SORT_MODE_I64,
    SORT_MODE_F64,
    SORT_MODE_STR,
    SORT_FIELD_SCORE,
    SORT_FIELD_DOC,
    read_docstore_source,
    _assemble_hit_batch,
    _TopKHeap,
    _FilterResolvers,
    _collect_filter_fields,
    _eval_ff_predicate,
    _resolve_sort_mode,
    _run_aggs,
)

from komira_log_index.l0_index import L0PostingIndex
from komira_log_index.transpose import LOG_INDEX_TEXT_FIELD


# =============================================================================
# search_l0_split — the per-split L0 read path. Mirrors SearchCore._search_impl
# EXACTLY downstream of the term decode; the ONLY difference is the term
# substrate (the L0 posting probe + TF score instead of the optimized posting
# decode + BM25 score). The result is a SearchResult byte-SHAPE-identical to the
# optimized path (the 3-column HitBatch + total_matches + agg_results + the typed
# SortKeyColumn) so the cross-split merge folds L0 + optimized results uniformly.
# =============================================================================


def search_l0_split(view: SplitView, query: QueryIR) raises -> SearchResult:
    """Read an L0 (cheap drain) split for a MATCH query. PRECONDITION:
    `view.has_l0_posting()` is True (the caller routed here on the format
    discriminator). The schema (THFF fast-fields) is byte-identical to the
    optimized writer's, so a pushed FILTER / fast-field SORT / AGGS apply via the
    SAME FastFieldReader the optimized path uses — only `_score` is TF-rank (not
    BM25). Returns a SearchResult with the same 3-column HitBatch + true
    total_matches + the typed SortKeyColumn (for the cross-split merge).

    IMMUTABLE `view` borrow: reads over the parsed SplitView's owned bytes; no
    mutation, no move-out — safe to call from N concurrent readers over a shared
    borrow (the SearchCore.search immutable-borrow contract).
    """
    var big_n = view.doc_count()
    var min_id = view.min_doc_id()

    # ---- The L0 posting (the term substrate). Deserialized ONCE per query from
    # the borrowed l0_posting region (plain List storage). ----
    var posting = L0PostingIndex.deserialize(view.l0_posting_region())

    # ---- Sort mode resolution (identical to the optimized path). sort_field ""
    # / "_score" -> SORT_MODE_SCORE; "_doc" -> SORT_MODE_DOC; else a fast-field
    # typed key. ----
    var sort_field = query.sort_field
    var fast_field_sort = (
        sort_field.byte_length() > 0
        and sort_field != SORT_FIELD_SCORE
        and sort_field != SORT_FIELD_DOC
    )

    # ---- Build the FastFieldReader ONCE iff a filter is pushed, a fast-field
    # sort is requested, or aggs are requested. The L0 split's THFF is
    # byte-identical to the optimized writer's, so the reader works unchanged.
    # (No fieldnorm/BM25 path: L0 scores by TF, not BM25, so the per-doc
    # fieldnorm dl is never read.) ----
    var ff_opt: Optional[FastFieldReader] = None
    if query.has_filter() or fast_field_sort or query.has_aggs():
        ff_opt = FastFieldReader(view)

    var sort_mode = SORT_MODE_SCORE
    if sort_field == SORT_FIELD_DOC:
        sort_mode = SORT_MODE_DOC
    elif fast_field_sort:
        sort_mode = _resolve_sort_mode(ff_opt.value(), sort_field)

    # ---- Pre-resolve every distinct fast-field referenced in the filter ONCE
    # (the O(1)-per-doc registry — the SAME _FilterResolvers the optimized path
    # uses). ----
    var filter_res = _FilterResolvers()
    if query.has_filter():
        _collect_filter_fields(
            filter_res, ff_opt.value(), view, query.filter_ref()
        )

    # ---- Tokenize the query (symmetry) + DEDUP terms. analyze_text RAISES if
    # the analyzer is not tokenized — same contract as the optimized path. -
    var af = analyze_text(query.query_text, query.analyzer_config)
    var terms = List[String]()
    for ti in range(len(af.tokens)):
        var t = af.tokens[ti].term
        var seen = False
        for ui in range(len(terms)):
            if terms[ui] == t:
                seen = True
                break
        if not seen:
            terms.append(t)

    # ---- Dense accumulator (plain List storage), parallel to the optimized path:
    # acc[doc_id - min_id] = summed per-doc TF (the basic L0 rank). touched =
    # first-touched ids (the UNION over present terms). ----
    var acc = List[Float64](length=big_n if big_n > 0 else 0, fill=0.0)
    var touched = List[Int]()

    # ---- The L0 term walk: for each distinct present query term, probe the L0
    # posting for its ascending doc-ids + per-doc TFs, UNION them into touched
    # (restricting to the pushed filter survivors, exactly as the optimized
    # brute walk), and accumulate TF into acc[slot] as the rank score. ----
    for tix in range(len(terms)):
        var h = fnv1a_64(terms[tix].as_bytes())
        var dids = posting.doc_ids_for_hash(h)
        var tfs = posting.tfs_for_hash(h)
        for i in range(len(dids)):
            var doc_id = dids[i]
            var slot = doc_id - min_id
            if slot < 0 or slot >= big_n:
                raise Error(
                    "search_l0_split: posting doc_id "
                    + String(doc_id)
                    + " maps to out-of-range slot "
                    + String(slot)
                    + " (split min_doc_id="
                    + String(min_id)
                    + ", doc_count="
                    + String(big_n)
                    + "; corrupt)"
                )
            # The pushed fast-field filter restricts WHICH docs match (it is
            # UNSCORED — it only narrows the candidate set, never adds to acc).
            if query.has_filter():
                if not _eval_ff_predicate(
                    filter_res, view, query.filter_ref(), doc_id
                ):
                    continue
            if acc[slot] == 0.0:
                touched.append(doc_id)
            # Basic L0 rank: sum the carried per-doc TF across the matched
            # terms (no BM25).
            acc[slot] += Float64(tfs[i])

    # ---- match-all-for-aggs (identical to the optimized path): a
    # `{"size":0,"aggs":{...}}` / no-query aggs request with no term candidates
    # aggregates over the WHOLE (filtered) split, not zero docs. ----
    if query.has_aggs() and len(terms) == 0 and len(touched) == 0:
        for slot in range(big_n):
            var did = slot + min_id
            if query.has_filter():
                if not _eval_ff_predicate(
                    filter_res, view, query.filter_ref(), did
                ):
                    continue
            touched.append(did)

    # ---- The true match total: count of docs that matched a TERM AND
    # passed the filter. Surfaced regardless of the page slice. ----
    var total_matches = len(touched)

    # ---- The in-leaf agg pass over the FULL touched set (the SAME _run_aggs the
    # optimized path uses; the THFF is byte-identical). ----
    var agg_out = AggResults()
    if query.has_aggs():
        agg_out = _run_aggs(query.aggs_ref(), ff_opt.value(), view, touched)

    # ---- Bounded top-K over the touched docs (the SAME _TopKHeap + the SAME
    # per-touched-doc typed sort-key read the optimized path uses). ----
    var window = query.from_offset + query.top_k
    var heap = _TopKHeap(
        window if window > 0 else 1,
        sort_mode,
        query.sort_order,
        query.missing_order,
    )
    # Resolve the sort field's sub-region header ONCE before the touched loop
    # (the FF-header pre-resolve — byte-identical typed keys).
    var sort_num_res: Optional[NumericFastFieldResolver] = None
    var sort_flt_res: Optional[FloatFastFieldResolver] = None
    var sort_kw_res: Optional[KeywordFastFieldResolver] = None
    if fast_field_sort:
        if sort_mode == SORT_MODE_I64:
            sort_num_res = ff_opt.value().numeric_resolver(view, sort_field)
        elif sort_mode == SORT_MODE_F64:
            sort_flt_res = ff_opt.value().float_resolver(view, sort_field)
        else:  # SORT_MODE_STR
            sort_kw_res = ff_opt.value().keyword_resolver(view, sort_field)
    for i in range(len(touched)):
        var doc_id = touched[i]
        var sc = acc[doc_id - min_id]
        if sort_mode == SORT_MODE_SCORE or sort_mode == SORT_MODE_DOC:
            heap.push(sc, doc_id)
        else:
            var ki = Int64(0)
            var kf = Float64(0.0)
            var ks = String("")
            var missing = False
            if sort_mode == SORT_MODE_I64:
                var cell = sort_num_res.value().i64_at(view, doc_id)
                if cell:
                    ki = cell.value()
                else:
                    missing = True
            elif sort_mode == SORT_MODE_F64:
                var cellf = sort_flt_res.value().f64_at(view, doc_id)
                if cellf:
                    kf = cellf.value()
                else:
                    missing = True
            else:  # SORT_MODE_STR
                var cells = sort_kw_res.value().keyword_at(view, doc_id)
                if cells:
                    ks = cells.value()
                else:
                    missing = True
            heap.push_keyed(sc, doc_id, ki, kf, ks^, missing)
    var order = heap.drain_descending()

    # ---- Slice the page [from, min(len, from+size)) ----
    var page_start = query.from_offset
    var page_end = query.from_offset + query.top_k
    if page_end > len(order):
        page_end = len(order)
    if page_start < 0:
        page_start = 0

    # ---- Fetch _source per page doc (the SAME read_docstore_source the
    # optimized path uses — the docstore region is byte-identical) + assemble the
    # 3-column HitBatch + the parallel typed SortKeyColumn for the merge. ----
    var docstore = view.docstore_region()
    var scores = List[Float64]()
    var ids = List[Int64]()
    var sources = List[String]()
    var sk = SortKeyColumn(sort_mode)
    var surface_keys = (
        sort_mode == SORT_MODE_I64
        or sort_mode == SORT_MODE_F64
        or sort_mode == SORT_MODE_STR
    )
    if page_start < page_end:
        for oi in range(page_start, page_end):
            var hidx = order[oi]
            var doc_id = heap.id_at(hidx)
            var sc = heap.score_at(hidx)
            var slot = doc_id - min_id
            var src = read_docstore_source(docstore, slot)
            scores.append(sc)
            ids.append(Int64(doc_id))
            sources.append(src^)
            if surface_keys:
                sk.missing.append(heap.missing_at(hidx))
                if sort_mode == SORT_MODE_I64:
                    sk.key_i64.append(heap.key_i64_at(hidx))
                elif sort_mode == SORT_MODE_F64:
                    sk.key_f64.append(heap.key_f64_at(hidx))
                else:  # SORT_MODE_STR
                    sk.key_str.append(heap.key_str_at(hidx))

    return SearchResult(
        _assemble_hit_batch(scores^, ids^, sources^),
        total_matches,
        agg_out^,
        sk^,
    )
