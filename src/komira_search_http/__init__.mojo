# =============================================================================
# komira_search_http — the wire translators of an OpenSearch/Elasticsearch
# compatible search shim
# =============================================================================
#
# Part 1 is the wire translators; part 2 is the dispatcher and its config.
#
# These modules translate the JSON / NDJSON wire to and from the Arrow-native
# search engine (`komira_search`): a `_bulk` body becomes a DocBatch
# (RecordBatch), a `_search` body becomes a QueryIR, and a HitBatch becomes the
# response envelope. The engine has no HTTP or JSON dependency; these
# translators are the only code that sees a wire byte.
#
#   * bulk.mojo          `ndjson_bulk_to_docbatch`: `_bulk` NDJSON -> DocBatch
#                        with dynamic field mapping and per-item outcomes.
#   * bulk_fields.mojo   the dynamic-mapping accumulators and the typed
#                        RecordBatch builder `bulk` drives.
#   * search_query.mojo  `search_json_to_queryir`: `_search` match / filter /
#                        sort / pagination / aggregation JSON -> QueryIR, plus
#                        `parse_track_total_hits` and `sort_is_by_score`.
#                        `search_json_to_queryir` takes the index's text field
#                        (`text_field`, no default): a request with `aggs` and
#                        no `match` targets it, and the engine refuses a
#                        QueryIR whose field is not the split's text field.
#   * search_gates.mojo  `gate_filter_against_fastfields`,
#                        `gate_sort_against_fastfields`,
#                        `gate_aggs_against_fastfields`: the checks against a
#                        resolved split's fast-field meta, and the
#                        `<field>.keyword` alias rewrite.
#   * envelopes.mojo     the hits, `_bulk` and error response envelopes.
#   * response.mojo      `json_response` / `ok_json`: a JSON HttpResponse from a
#                        serialized body.
#   * config.mojo        `SearchHttpConfig`: the dispatcher's plain value
#                        config (key prefixes, text field, node id, limits).
#   * request_path.mojo  the pure helpers that read an untrusted request
#                        target: `strip_query`, `split_path`,
#                        `is_valid_index_name`, `body_too_large`.
#   * split_ids.mojo     `make_split_uuid`: the split uuid (worker, install
#                        epoch, sequence).
#   * dispatch.mojo      `SearchHttpDispatcher[Storage]`: the `RequestDispatcher`
#                        for `POST /<index>/_bulk` and `POST /<index>/_search`
#                        over a `CloneableConditionalWriteStore`.
# =============================================================================

from .bulk import (
    BulkParse,
    BulkItem,
    ndjson_bulk_to_docbatch,
    MAX_DYNAMIC_FIELDS,
    MAX_BATCH_CELLS,
)
from .search_query import (
    search_json_to_queryir,
    parse_track_total_hits,
    sort_is_by_score,
    DEFAULT_SIZE,
    MAX_RESULT_WINDOW,
    MAX_BOOL_CLAUSES,
    MAX_AGGS,
    MAX_TERMS_SIZE,
)
from .search_gates import (
    gate_filter_against_fastfields,
    gate_sort_against_fastfields,
    gate_aggs_against_fastfields,
)
from .envelopes import (
    hitbatch_to_hits_envelope,
    empty_hits_envelope,
    bulk_response_envelope,
    bulk_response_envelope_items,
    error_envelope,
    agg_results_to_aggregations_object,
    TRACK_TOTAL_DEFAULT,
    TRACK_TOTAL_TRUE,
    TRACK_TOTAL_FALSE,
)
from .response import json_response, ok_json
from .config import (
    SearchHttpConfig,
    DEFAULT_TEXT_FIELD,
    SOURCE_FIELD,
    DEFAULT_MAX_BODY_BYTES,
    DEFAULT_MAX_SPLITS_PER_SEARCH,
)
from .request_path import (
    strip_query,
    split_path,
    is_valid_index_name,
    body_too_large,
    MAX_PATH_BYTES,
    MAX_PATH_SEGMENTS,
    MAX_INDEX_NAME_BYTES,
)
from .split_ids import make_split_uuid
from .dispatch import SearchHttpDispatcher
