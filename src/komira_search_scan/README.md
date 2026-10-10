# komira_search_scan

A search index read as a scan: the `komira.search.index` scan kind. A scan over
`{index, field, query, analyzer_fp}` returns one row per matching document of
every split of that field live at the resolved generation, in the hit schema of
`komira_search` (`_score` Float64, `_id` Int64, `_source` string); filtering,
sorting, paging and aggregation are ordinary plan operators above it.

- `search_scan_binding(index, field, query, analyzer_fp, generation=None)`
  builds the plan-side binding. Without a `generation` the scan is live: the
  generation is resolved again at every execution. With one, the scan is pinned
  to it. An empty query reads every document, each scored 0.0.
- `SearchIndexCatalog` is what the kind asks of a store: the current
  generation, the analyzer of a field, the splits live at a generation, and
  the field each split indexes (`split_field_at`).
  `InMemorySearchIndexCatalog` implements it in memory: `create_index`,
  `add_field`, and `publish`, which appends a split, records its field (one of
  the index's, `SEARCH_INDEX_UNKNOWN` otherwise) and returns the new
  generation.
- `SearchScanResolver[C]`, and `search_scan_resolver(catalog^)` which erases it
  for registration, implement the `komira_scan_resolver` contract: one split per
  live split object that indexes the binding's field, keyed `search_split_key(index, ordinal)`, read by
  `SearchSplitReader`. A binding whose analyzer fingerprint
  (`analyzer_config_fingerprint`) differs from the catalog's is refused with
  `SEARCH_ANALYZER_MISMATCH`, an unknown index with `SEARCH_INDEX_UNKNOWN`, and
  a field left out of a binding is taken from the catalog only when the index
  has exactly one field (`SEARCH_FIELD_AMBIGUOUS` otherwise).
- `FastFieldPushdownGate` decides which filter conjuncts a split's fast fields
  can answer.

`_id` is split-local: two splits can return the same `_id`. The catalog over an
object store is `komira_search_catalog`'s; this package ships only the
in-memory one.

## Examples

Two splits published to an in-memory catalog, then one live scan for "error"
drained the way an engine reads it: one batch per split, in publish order:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_scan_resolver.drain_scan import drain_scan
from komira_scan_resolver.scan_source_resolver import ScanRequest
from komira_scan_source.scan_resolver import resolve_for_execution
from komira_search import AnalyzerConfig, DocStoreBuilder, InvertedIndexBuilder, TermDictBuilder
from komira_search import analyze_text, serialize_split
from komira_search_scan import InMemorySearchIndexCatalog, analyzer_config_fingerprint
from komira_search_scan import search_scan_binding, search_scan_resolver, search_split_key


def build_split(texts: List[String], seed: UInt8) raises -> List[UInt8]:
    var config = AnalyzerConfig.text("body")
    var index = InvertedIndexBuilder.create("body")
    var sources = DocStoreBuilder()
    for i in range(len(texts)):
        index.add_document(i, analyze_text(texts[i], config))
        sources.append(texts[i].as_bytes())
    var finalized = index.finalize()
    var terms = TermDictBuilder.build_from_finalized(finalized)
    var n = len(texts)
    return serialize_split(
        finalized, terms^, sources, "body", Array[UInt8, 16](fill=seed), 0, n - 1, n
    )


var catalog = InMemorySearchIndexCatalog()
catalog.create_index("logs", "body", AnalyzerConfig.text("body"))
var first: List[String] = ["error disk full", "all good"]
var second: List[String] = ["disk error again"]
assert_equal(catalog.publish("logs", build_split(first, 1)), 1)
assert_equal(catalog.publish("logs", build_split(second, 2)), 2)
var resolver = search_scan_resolver(catalog^)

var fp = analyzer_config_fingerprint(AnalyzerConfig.text("body"))
var plan = search_scan_binding("logs", "body", "error", fp)
var run = resolve_for_execution(resolver, plan)
assert_equal(run.snapshot_token, UInt64(2))  # the live generation, read now

var opened = drain_scan(resolver, ScanRequest(run^))
assert_equal(opened.num_batches(), 2)
assert_equal(opened.num_rows(), 2)
ref batches = opened.batches[]
assert_equal(String(batches[0].column_at(2).as_string().get(0)), "error disk full")
assert_equal(String(batches[1].column_at(2).as_string().get(0)), "disk error again")
assert_equal(search_split_key("logs", 1), "logs/1")
```

A plan built against a different analyzer is refused by name rather than
returning hits tokenized another way:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_scan_resolver.drain_scan import drain_scan
from komira_scan_resolver.scan_source_resolver import ScanRequest
from komira_scan_source.scan_resolver import resolve_for_execution
from komira_search import AnalyzerConfig
from komira_search_scan import InMemorySearchIndexCatalog, analyzer_config_fingerprint
from komira_search_scan import search_scan_binding, search_scan_resolver

var catalog = InMemorySearchIndexCatalog()
catalog.create_index("logs", "body", AnalyzerConfig.text("body"))
var other = AnalyzerConfig.keyword("body")
var resolver = search_scan_resolver(catalog^)
var plan = search_scan_binding("logs", "body", "error", analyzer_config_fingerprint(other))

var refused = False
try:
    _ = drain_scan(resolver, ScanRequest(resolve_for_execution(resolver, plan)))
except e:
    refused = String(e).find("SEARCH_ANALYZER_MISMATCH") >= 0
assert_true(refused)
```
