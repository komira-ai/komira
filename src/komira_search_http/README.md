# komira_search_http

The wire translators of an OpenSearch/Elasticsearch compatible search shim.
They convert the JSON and NDJSON a client sends into the Arrow-native types of
`komira_search` and convert the results back, so the engine sees no wire byte
and has no HTTP or JSON dependency. They are pure functions over bytes and
values: no I/O, no store, no handler.

- `ndjson_bulk_to_docbatch(body, text_field)` (`bulk`) parses a `_bulk` body of
  alternating action and source lines (the `index` action only) into a
  `BulkParse`: a `RecordBatch` of the good documents, one `BulkItem` per pair in
  wire order (status 201 or 400 with an error `type` and `reason`), the count of
  committed documents and an `any_error` flag. Every field other than the text
  field is mapped dynamically to a nullable typed column: a string is a keyword
  (STRING), an integer is INT64 and a fractional or exponent number is FLOAT64.
  The first occurrence fixes a field's type, an integer meeting a FLOAT64 field
  widens, and any other disagreement fails that document. A document fails on
  its own (a non-index action, malformed JSON, a missing or non-string text
  field, a nested object or array, a reserved key, a field named twice, a number
  out of range, too many fields) and the rest still index. Only an odd number of
  non-blank lines (a dangling action line) raises.
- `search_json_to_queryir(body, generation)` (`search_query`) parses a `_search`
  body into a `QueryIR`: a `match` query, or a `bool` with `must`/`filter` arms
  holding one `match` and any number of `term` and `range` clauses (folded into
  the QueryIR filter), `sort` (one key), `from`/`size` (bounded by the
  10000-document result window), `track_total_hits` (`parse_track_total_hits`)
  and `aggs`/`aggregations` (avg, min, max, sum, value_count, stats and a
  single-field `terms`; a request with only aggregations or `match_all` takes
  the whole-split aggregation path). `should`, `must_not`, a nested bool, a
  filter-only query, `search_after`, multi-key sort and nested aggregations are
  refused.
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
the term and range clauses of a bool query, `MAX_RESULT_WINDOW` (10000) on
`from` and `size` taken one at a time and then summed, and `MAX_DYNAMIC_FIELDS`
(1000) on the fields a document carries and on the union of fields across the
batch. A body that is not valid UTF-8 is refused by the parser from its bytes.

## Not here

The request handler that routes `_bulk` and `_search` to a store and the
configuration it needs are not part of this package.
