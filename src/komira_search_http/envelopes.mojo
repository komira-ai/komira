# =============================================================================
# envelopes.mojo — the OpenSearch JSON response builders
# =============================================================================
#
# The response-envelope renderers: the `_search` hits envelope, the `_bulk`
# response and the error envelope. All of them build a komira_json JsonValue
# tree and serialize it, so escaping is correct and a `_source` blob containing
# `\n`, `\"` or `\uXXXX` round-trips losslessly. JSON is never concatenated by
# hand.
#
# The hits envelope carries a top-level
# `"_shards":{"total":N,"successful":N,"skipped":0,"failed":N}` (real-client and
# opensearch-dsl compatibility). The per-item `_shards` of `_bulk` is omitted:
# opensearch-py bulk reads only `item.status`.
#
# Pure value functions over a RecordBatch (HitBatch) / Lists -> a String. No
# pointers.
# =============================================================================

from komira_arrow.record_batch import RecordBatch

from komira_search.source import (
    AggResults,
    AggResult,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    AGG_KIND_MIN,
    AGG_KIND_MAX,
    AGG_KIND_SUM,
    AGG_KIND_VALUE_COUNT,
    AGG_KIND_STATS,
)

from std.math import isfinite

from komira_json import JsonValue, parse_json_value

from .bulk import BulkItem


# track_total_hits render modes (P1.3 §4.4 / A5). A pure rendering knob — the
# leaf always computes the exact total; this only changes how it is rendered.
comptime TRACK_TOTAL_DEFAULT: UInt8 = 0  # exact up to cap, relation gte above.
comptime TRACK_TOTAL_TRUE: UInt8 = 1     # exact value, relation always eq.
comptime TRACK_TOTAL_FALSE: UInt8 = 2    # omit the total object entirely.

# The OpenSearch default cap on the rendered total (P1.3 §5).
comptime TOTAL_CAP: Int = 10000


def _num(var raw: String) -> JsonValue:
    """A JSON Number value carrying the already-formatted text `raw`."""
    return JsonValue.from_number(raw^)


def _int(v: Int) -> JsonValue:
    return _num(String(v))


def _shards_object(
    total: Int = 1, successful: Int = 1, failed: Int = 0
) -> JsonValue:
    """The `_shards` object. P1.5 (§6.2): parameterized by the real per-query
    shard counts — `total` = the number of live splits fanned out over,
    `successful` = splits that searched without error, `failed` = splits that
    raised. `skipped` is 0 for v1 (can-match pruning deferred). Defaults keep the
    pre-P1.5 single-shard literal `{1,1,0,0}` for any caller that does not thread
    counts (the empty-index path)."""
    var sh = JsonValue.empty_object()
    try:
        sh.set_member(String("total"), _int(total))
        sh.set_member(String("successful"), _int(successful))
        sh.set_member(String("skipped"), _int(0))
        sh.set_member(String("failed"), _int(failed))
    except:
        pass  # set_member only raises on a non-object; `sh` IS an object.
    return sh^


def _embed_source(source_blob: String) -> JsonValue:
    """Embed the stored `_source` blob as a JSON VALUE (it IS a JSON object, so
    inline it as parsed JSON, NOT a quoted string). Fail-SOFT (08 §2.3): if the
    blob is not well-formed JSON (a corrupt split), quote it as a string
    fallback so the envelope still renders syntactically valid JSON (NOT a
    500)."""
    try:
        return parse_json_value(source_blob)
    except:
        return JsonValue.from_string(source_blob)


# Float64 score formatting: render with enough precision to be stable across a
# round-trip without trailing-zero noise. Mojo's String(Float64) gives a
# round-trippable shortest form, which is JSON-number-valid.
def _score_json(score: Float64) -> JsonValue:
    return _float_json(score)


def _float_json(x: Float64) -> JsonValue:
    """A Float64 as a JSON Number; NaN and +/-Inf have no JSON number form and
    render as null (as komira_json's `from_f64` does), so the envelope stays
    valid JSON."""
    if not isfinite(x):
        return JsonValue.null()
    return _num(String(x))


# =============================================================================
# P1.4 — the `aggregations` response renderer (§7.2).
# =============================================================================


def _metric_value_member(ar: AggResult) raises -> JsonValue:
    """Render ONE single-value metric -> {"value": <num|null>}. m3 (empty-set
    fidelity): sum -> 0.0, value_count -> 0 (NEVER null); avg/min/max -> null."""
    var obj = JsonValue.empty_object()
    if ar.kind == AGG_KIND_VALUE_COUNT:
        obj.set_member(String("value"), _int(ar.count))
    elif ar.kind == AGG_KIND_SUM:
        obj.set_member(String("value"), _float_json(ar.sum))
    else:
        # avg / min / max -> null over an empty matched set.
        if not ar.has_value:
            obj.set_member(String("value"), JsonValue.null())
        elif ar.kind == AGG_KIND_AVG:
            obj.set_member(String("value"), _float_json(ar.avg()))
        elif ar.kind == AGG_KIND_MIN:
            obj.set_member(String("value"), _float_json(ar.min))
        else:  # AGG_KIND_MAX
            obj.set_member(String("value"), _float_json(ar.max))
    return obj^


def _stats_member(ar: AggResult) raises -> JsonValue:
    """Render a `stats` agg -> {count, min, max, avg, sum}. m3: count -> exact,
    sum -> 0.0 over an empty set, min/max/avg -> null over an empty set."""
    var obj = JsonValue.empty_object()
    obj.set_member(String("count"), _int(ar.count))
    if ar.has_value:
        obj.set_member(String("min"), _float_json(ar.min))
        obj.set_member(String("max"), _float_json(ar.max))
        obj.set_member(String("avg"), _float_json(ar.avg()))
    else:
        obj.set_member(String("min"), JsonValue.null())
        obj.set_member(String("max"), JsonValue.null())
        obj.set_member(String("avg"), JsonValue.null())
    obj.set_member(String("sum"), _float_json(ar.sum))
    return obj^


def _terms_member(ar: AggResult) raises -> JsonValue:
    """Render a `terms` agg -> {doc_count_error_upper_bound, sum_other_doc_count,
    buckets:[{key,doc_count}]}. doc_count_error_upper_bound is order-aware (§5.2 +
    amendment E): 0 for a single split or key-order, the computed count-desc sum
    across splits that dropped a bucket, or -1 for count-asc/sub-agg order. The
    merge reducer (merge_agg_results) sets `ar.doc_count_error_upper_bound`; a
    single-split direct render leaves it 0 (the AggResult ctor default)."""
    var obj = JsonValue.empty_object()
    obj.set_member(
        String("doc_count_error_upper_bound"),
        _int(ar.doc_count_error_upper_bound),
    )
    obj.set_member(
        String("sum_other_doc_count"), _int(ar.sum_other_doc_count)
    )
    var buckets = JsonValue.empty_array()
    for i in range(len(ar.buckets)):
        var b = JsonValue.empty_object()
        b.set_member(
            String("key"), JsonValue.from_string(ar.buckets[i].key)
        )
        b.set_member(String("doc_count"), _int(ar.buckets[i].doc_count))
        buckets.push(b^)
    obj.set_member(String("buckets"), buckets^)
    return obj^


def agg_results_to_aggregations_object(agg: AggResults) raises -> JsonValue:
    """Render the full AggResults -> the OpenSearch `aggregations` object (keyed
    by each agg's NAME). An empty AggResults -> an empty object `{}` (the caller
    only adds the member when aggs were requested)."""
    var root = JsonValue.empty_object()
    for i in range(len(agg.results)):
        ref ar = agg.results[i]
        var member: JsonValue
        if ar.kind == AGG_KIND_TERMS:
            member = _terms_member(ar)
        elif ar.kind == AGG_KIND_STATS:
            member = _stats_member(ar)
        else:
            member = _metric_value_member(ar)
        root.set_member(ar.name, member^)
    return root^


def hitbatch_to_hits_envelope(
    hits: RecordBatch,
    index_name: String,
    client_ids: List[String],
    total_matches: Int,
    track_total: UInt8 = TRACK_TOTAL_DEFAULT,
    sorted_by_score: Bool = True,
    var agg_results: AggResults = AggResults(),
    has_aggs: Bool = False,
    shards_total: Int = 1,
    shards_successful: Int = 1,
    shards_failed: Int = 0,
) raises -> String:
    """Render the HitBatch page as the OpenSearch hits-envelope JSON string
    (08 §2.3 + P1.3 §5).

    P1.5 (§6.2): `shards_*` carry the real per-query shard counts (the driver
    threads `len(splits)` / successful / failed); they default to the pre-P1.5
    single-shard literal so the existing callers are source-compatible.

    The HitBatch columns: column_at(0) = _score Float64, column_at(1) = _id
    Int64 (the engine doc_id), column_at(2) = _source STRING. Each `_source`
    blob is embedded verbatim as a JSON value. `_id` is rendered as the engine
    doc_id stringified (08 §4.3 — the P0 _id contract; `client_ids` is accepted
    for the P1 client-_id round-trip seam but unused in P0). The leaf already
    returns the correctly-ordered + sliced page, so the rows render as-is.

    H5: the top-level `_shards` single-shard object is included.

    P1.3 §5 (the total/relation/max_score correctness fix):
      * `total.value` is the TRUE match total (`total_matches`, from
        SearchResult.total_matches — NOT `num_rows()`, which is the PAGE size and
        was the pre-P1.3 bug for any paginated query). track_total (A5):
          - TRACK_TOTAL_TRUE   -> exact value, relation always "eq".
          - TRACK_TOTAL_DEFAULT-> min(total, 10000), relation flips "eq"->"gte"
            above the cap.
          - TRACK_TOTAL_FALSE  -> the `total` object is OMITTED entirely.
      * `max_score` is null under a field sort (A7 — matches observed ES
        behavior; track_scores defaults false and is out of P1.3.0); for a
        `_score` sort it keeps the top hit's score.
    """
    var n = hits.num_rows()

    var root = JsonValue.empty_object()
    root.set_member(String("took"), _int(0))
    root.set_member(String("timed_out"), JsonValue.from_bool(False))
    root.set_member(
        String("_shards"),
        _shards_object(shards_total, shards_successful, shards_failed),
    )

    var hits_obj = JsonValue.empty_object()

    # P1.3 §5 / A5: render the true total per the track_total mode.
    if track_total != TRACK_TOTAL_FALSE:
        var total = JsonValue.empty_object()
        var value: Int
        var relation: String
        if track_total == TRACK_TOTAL_TRUE:
            value = total_matches
            relation = String("eq")
        else:  # TRACK_TOTAL_DEFAULT
            if total_matches > TOTAL_CAP:
                value = TOTAL_CAP
                relation = String("gte")
            else:
                value = total_matches
                relation = String("eq")
        total.set_member(String("value"), _int(value))
        total.set_member(
            String("relation"), JsonValue.from_string(relation)
        )
        hits_obj.set_member(String("total"), total^)
    # TRACK_TOTAL_FALSE: the `total` object is OMITTED (not value:0).

    # max_score = the top hit's score for a _score sort (HitBatch is descending);
    # null under a field sort (A7) or an empty page.
    if n > 0 and sorted_by_score:
        var top_score = Float64(hits.column_at(0).as_primitive[DType.float64]().get(0))
        hits_obj.set_member(String("max_score"), _score_json(top_score))
    else:
        hits_obj.set_member(String("max_score"), JsonValue.null())

    var hits_arr = JsonValue.empty_array()
    for row in range(n):
        var score = Float64(hits.column_at(0).as_primitive[DType.float64]().get(row))
        var doc_id = Int64(hits.column_at(1).as_primitive[DType.int64]().get(row))
        var source_blob = hits.column_at(2).as_string().get(row)

        var hit = JsonValue.empty_object()
        hit.set_member(String("_index"), JsonValue.from_string(index_name))
        # _id: P0 single-split renders the engine doc_id stringified (08 §4.3).
        # P1.5 (§4.3/§6.2): in a MULTI-SPLIT response the engine doc_id is
        # per-split-local and COLLIDES across splits (every split stamps
        # min_doc_id=0), so two hits from different splits would both render
        # _id:"0". When `client_ids` carries one entry per page row (the driver
        # passes a namespaced `<split-short-uuid>_<doc_id>` per merged hit), it is
        # the unambiguous cross-split _id; else fall back to the doc_id.
        if len(client_ids) == n:
            hit.set_member(
                String("_id"), JsonValue.from_string(client_ids[row])
            )
        else:
            hit.set_member(
                String("_id"), JsonValue.from_string(String(doc_id))
            )
        hit.set_member(String("_score"), _score_json(score))
        hit.set_member(String("_source"), _embed_source(source_blob))
        hits_arr.push(hit^)

    hits_obj.set_member(String("hits"), hits_arr^)
    root.set_member(String("hits"), hits_obj^)

    # P1.4 (§7.2): the `aggregations` object is a SIBLING of `hits` at the
    # response root. Rendered iff aggs were requested (an empty AggResults still
    # renders the `{}` shell for an aggs-requested query — e.g. an empty matched
    # set yields zeroed/null metric members, not an absent block).
    if has_aggs:
        root.set_member(
            String("aggregations"),
            agg_results_to_aggregations_object(agg_results),
        )
    return root.serialize()


def empty_hits_envelope(
    index_name: String,
    var agg_results: AggResults = AggResults(),
    has_aggs: Bool = False,
) raises -> String:
    """The empty hits envelope (no live splits / unknown index): total.value 0,
    max_score null, hits [] (08 §4.1 step 5 — NOT a 500/404). H5 _shards
    included.

    P1.4 (§7.2): when aggs were requested but there are no live splits,
    OpenSearch still returns the `aggregations` skeleton (empty buckets / zeroed
    or null metric values). `agg_results` is the (empty) AggResults rendered when
    `has_aggs` is set."""
    var root = JsonValue.empty_object()
    root.set_member(String("took"), _int(0))
    root.set_member(String("timed_out"), JsonValue.from_bool(False))
    root.set_member(String("_shards"), _shards_object())

    var hits_obj = JsonValue.empty_object()
    var total = JsonValue.empty_object()
    total.set_member(String("value"), _int(0))
    total.set_member(String("relation"), JsonValue.from_string(String("eq")))
    hits_obj.set_member(String("total"), total^)
    hits_obj.set_member(String("max_score"), JsonValue.null())
    hits_obj.set_member(String("hits"), JsonValue.empty_array())
    root.set_member(String("hits"), hits_obj^)

    if has_aggs:
        root.set_member(
            String("aggregations"),
            agg_results_to_aggregations_object(agg_results),
        )
    return root.serialize()


def bulk_response_envelope(
    index_name: String, client_ids: List[String]
) raises -> String:
    """The all-SUCCESS `_bulk` response (08 §3.4). One `items[]` entry per source
    doc, keyed by the action verb (`index`): {_index, _id, _version:1,
    result:"created", status:201}. The wire field is `status` (NOT `_status`).
    `errors` is always false.

    Used by the empty-body short-circuit and as the all-created convenience for
    callers that have only client ids (no per-item failures). The per-item
    partial-success path (P1.7) uses `bulk_response_envelope_items`.

    Empty (count 0) -> {"took":0,"errors":false,"items":[]}."""
    var items = List[BulkItem]()
    for i in range(len(client_ids)):
        items.append(BulkItem.created(client_ids[i].copy()))
    return bulk_response_envelope_items(index_name, items, False)


def _bulk_index_item(index_name: String, item: BulkItem) raises -> JsonValue:
    """Render ONE `_bulk` `items[]` entry, keyed by the action verb `index`.
    A SUCCESS item -> {_index, _id, _version:1, result:"created", status:201};
    a FAILED item -> {_index, _id, status:400, error:{type,reason}} (08 §3.4 /
    P1.7 — the OpenSearch per-item shape `helpers.bulk` inspects)."""
    var index_action = JsonValue.empty_object()
    index_action.set_member(
        String("_index"), JsonValue.from_string(index_name)
    )
    index_action.set_member(
        String("_id"), JsonValue.from_string(item.client_id)
    )
    if item.ok:
        index_action.set_member(String("_version"), _int(1))
        index_action.set_member(
            String("result"), JsonValue.from_string(item.result)
        )
        index_action.set_member(String("status"), _int(item.status))
    else:
        index_action.set_member(String("status"), _int(item.status))
        var err = JsonValue.empty_object()
        err.set_member(
            String("type"), JsonValue.from_string(item.error_type)
        )
        err.set_member(
            String("reason"), JsonValue.from_string(item.error_reason)
        )
        index_action.set_member(String("error"), err^)

    var entry = JsonValue.empty_object()
    entry.set_member(String("index"), index_action^)
    return entry^


def bulk_response_envelope_items(
    index_name: String, items: List[BulkItem], errors: Bool
) raises -> String:
    """The per-item `_bulk` response (P1.7 partial-success; 08 §3.4 + doc 18 A6).
    HTTP 200 with `{"took":0,"errors":<bool>,"items":[...]}`; each `items[]`
    entry is keyed by the `index` action and is either a 201/created success or a
    400/error failure, IN NDJSON ORDER. `errors` is the request-level flag
    (any item failed). This is the shape `opensearch-py` `helpers.bulk`
    inspects: it reads `response['errors']` then walks `items[]` for per-doc
    status.

    Empty (no items) -> {"took":0,"errors":false,"items":[]}."""
    var root = JsonValue.empty_object()
    root.set_member(String("took"), _int(0))
    root.set_member(String("errors"), JsonValue.from_bool(errors))

    var items_arr = JsonValue.empty_array()
    for i in range(len(items)):
        items_arr.push(_bulk_index_item(index_name, items[i]))

    root.set_member(String("items"), items_arr^)
    return root.serialize()


def error_envelope(error_type: String, reason: String, status: Int) raises -> String:
    """The OpenSearch error envelope (08 §7):
    {"error":{"type":"<type>","reason":"<msg>"},"status":<4xx>}. The reason is
    escaped via the JsonValue serializer (no hand-concatenation)."""
    var err = JsonValue.empty_object()
    err.set_member(String("type"), JsonValue.from_string(error_type))
    err.set_member(String("reason"), JsonValue.from_string(reason))

    var root = JsonValue.empty_object()
    root.set_member(String("error"), err^)
    root.set_member(String("status"), _int(status))
    return root.serialize()
