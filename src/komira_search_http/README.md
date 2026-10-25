# komira_search_http

The wire translators of an OpenSearch/Elasticsearch compatible search shim.
They convert the JSON and NDJSON a client sends into the Arrow-native types of
`komira_search` and convert the results back, so the engine sees no wire byte
and has no HTTP or JSON dependency. They are pure functions over bytes and
values: no I/O, no store, no handler.

- `ndjson_bulk_to_docbatch(body, text_field)` (`bulk`) parses a `_bulk` body of
  action lines, each followed by a source line (a `delete` action has none),
  into a `BulkParse`: a `RecordBatch` of the good documents, one `BulkItem` per
  action in wire order (status 201 or 400 with an error `type` and `reason`, and
  the action `verb` the response item is keyed by), the count of committed
  documents and an `any_error` flag. Records end at every raw newline, so a
  malformed line costs its own item and no more. Every field other than the text
  field is mapped dynamically to a nullable typed column: a string is a keyword
  (STRING), an integer is INT64 and a fractional or exponent number is FLOAT64.
  The first occurrence fixes a field's type, an integer meeting a FLOAT64 field
  widens, and any other disagreement fails that document. A document fails on
  its own (a non-index action, malformed JSON, a missing or non-string text
  field, a nested object or array, a reserved key, a field named twice, a number
  out of range, too many fields, a batch past the cell budget) and the rest
  still index. Only a final action line that needs a source line and has none
  raises.
- `search_json_to_queryir(body, generation, text_field)` (`search_query`) parses
  a `_search` body into a `QueryIR`: a `match` query, or a `bool` with
  `must`/`filter` arms holding one `match` and any number of `term` and `range`
  clauses (folded into the QueryIR filter), `sort` (one key), `from`/`size`
  (bounded by the 10000-document result window), `track_total_hits`
  (`parse_track_total_hits`) and `aggs`/`aggregations` (avg, min, max, sum,
  value_count, stats and a single-field `terms`; a request with only
  aggregations or `match_all` takes the whole-split aggregation path).
  `text_field` is the index's text field and has no default: a request with
  aggregations and no `match` names no field of its own, and the engine refuses
  a QueryIR whose field is not the split's text field, so the caller of the
  QueryIR passes the real name (a caller that only inspects the parse passes
  `""`). `should`, `must_not`, a nested bool, a filter-only query (with or
  without `aggs`), `search_after`, multi-key sort, nested aggregations, an
  object that names two clauses where the DSL takes one, a key named twice,
  and the options that change the result set (`min_score`, `post_filter`,
  `collapse`, `rescore`, `terminate_after`, `slice`, `knn`, `pit`, and a
  `match` option other than `query`, `boost` and `operator: or`) are refused.
- `gate_filter_against_fastfields`, `gate_sort_against_fastfields` and
  `gate_aggs_against_fastfields` (`search_gates`) check a parsed request against
  one split's `FastFieldReader`: a filter, sort or aggregation field must be a
  fast field of a class that supports it, and a literal must match the field's
  type. They also resolve the `<field>.keyword` alias of a string field to its
  bare keyword fast field. A violation raises, so the caller can answer 400.
- `hitbatch_to_hits_envelope`, `empty_hits_envelope`, `bulk_response_envelope`,
  `bulk_response_envelope_items`, `error_envelope` and
  `agg_results_to_aggregations_object` (`envelopes`) build the response JSON
  through a `komira_json` tree, so a `_source` blob round-trips. A non-finite
  score or aggregate renders as `null`.
- `json_response` and `ok_json` (`response`) wrap a serialized body in an
  `HttpResponse` with `content-type: application/json` and an exact
  `content-length`.

## Untrusted input

Both parsers read client bodies. The JSON parser refuses nesting deeper than 128
levels, and the translators add their own bounds: `MAX_BOOL_CLAUSES` (1024) on
the `must` plus `filter` clauses of a bool query, `MAX_AGGS` (100) on the
aggregations of a request, `MAX_TERMS_SIZE` (10000) on a `terms` size,
`MAX_RESULT_WINDOW` (10000) on `from` and `size` taken one at a time and then
summed, `MAX_DYNAMIC_FIELDS` (1000) on the fields a document carries and on the
union of fields across the batch, and `MAX_BATCH_CELLS` (1048576) on committed
documents times mapped fields (every committed document pads every mapped field
with a cell, so the field cap alone does not bound memory). A body that is not
valid UTF-8 is refused by the parser from its bytes. The caller still bounds the
body size; with the cell budget a `_bulk` body costs memory in proportion to its
size.

## Differences from OpenSearch

The shim answers a request it cannot honour with a 400 where it can, and
otherwise differs as follows.

- `_bulk` indexes with the `index` action only. `create`, `update` and `delete`
  fail their item with `action_not_supported`, keyed by their own verb. The
  action `_id` is echoed in the item and is not stored: a hit carries the engine
  document id, a repeated `_id` is a new document and every success reads
  `201 created`, `_version` 1. A non-string action `_id` is replaced by the
  ordinal. A document's scalar arrays, objects, booleans and nulls are not
  mapped (an array or object fails the item; a boolean or null is kept in
  `_source` only), and a string field other than the text field is a keyword.
- `track_total_hits` as an integer is read as the default (exact up to 10000,
  `gte` above); `true` and `false` are honoured.
- For a relevance sort `max_score` is the score of the first returned row, so
  with `from` above 0 it is the top of that page and not the maximum over all
  matches; under a field sort it is `null`, and a hit keeps its match score and
  carries no `sort` array.
- Options the translator does not read and that only shape the response or the
  aggregation (`_source`, `timeout`, `terms.include`, `avg.script`, ...) are
  ignored without an error.
- A `term` or `range` literal must match the field's type: an integer literal
  on a float field, a number on a keyword field and a date string on a date
  field fail with a 400.
- `terms` bucket keys are JSON strings, also for numeric fields.
- A `terms` or metric aggregation over an empty index renders whatever
  `AggResults` the caller passes to `empty_hits_envelope`; the caller builds
  the zeroed skeleton from the requested aggregations.
- An unknown index answers like an empty one (200), not 404.
- A bool query with only `filter` arms is refused even with `aggs`: the
  whole-split path carries no filter.
- A bool arm must be an array, `term` takes the bare-value form only, and a
  `terms` query clause is not parsed.
- Response shaping that clients may require (`typed_keys`, the
  `X-Elastic-Product` header, `root_cause` in an error body) is not produced.

## Not here

The request handler that routes `_bulk` and `_search` to a store and the
configuration it needs are not part of this package.
