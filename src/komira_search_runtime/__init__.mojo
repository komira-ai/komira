# =============================================================================
# komira_search_runtime — the `komira.search.index` scan kind.
# =============================================================================
#
# A search index read as a relation: a scan of kind `komira.search.index`
# returns one hit row (`_score`, `_id`, `_source`) per matching live document,
# and filter, sort, page and aggregation are ordinary plan operators above it.
#
#   * search_scan_kind.mojo -- the kind: its name, descriptor, binding builder
#     and identity corpus (a `ScanBinding` over {index, field, query,
#     analyzer_fp}, generation LIVE or pinned); `SearchIndexCatalog`, the
#     store seam, with the in-process `InMemorySearchIndexCatalog`; and
#     `SearchScanRuntime`, the tier-2 `ScanMorselResolver` an engine executes.
#   * search_source.mojo -- what the kind reads a split with:
#     `search_split_hits` (one query over one split, checked against the hit
#     schema), `FastFieldPushdownGate` (which predicate conjuncts the split's
#     fast-fields can evaluate) and `analyzer_config_fingerprint`.
#
# `Searcher` (a SourceLike plan spec that folded the generation into the
# scan's identity) and its single-shot morsel reader are RETIRED: the scan
# kind is the one way to express a search scan.
#
# The pure read CORE (SearchCore + QueryIR + the fail-loud doc-store reader)
# stays in komira_search (the light edge); this package re-exports QueryIR /
# SearchCore for ergonomics.
#
# Build DAG (cycle-free, no engine):
#   komira_search_runtime -> komira_search         (SearchCore / QueryIR / hit_schema)
#   komira_search_runtime -> komira_scan_resolver  (ScanMorselResolver / ScanRequest)
#   komira_search_runtime -> komira_core           (ScanBinding / RecordBatch / Expr)
# =============================================================================

from .search_source import (
    FastFieldPushdownGate,
    analyzer_config_fingerprint,
    search_split_hits,
)
from .search_scan_kind import (
    InMemorySearchIndexCatalog,
    SEARCH_SCAN_KIND_NAME,
    SearchIndexCatalog,
    SearchScanRuntime,
    search_scan_binding,
    search_scan_descriptor,
    search_scan_identity_corpus,
    search_scan_kind_id,
    search_scan_runtime,
)

# Re-export the pure-core surface for ergonomics (a single import home).
from komira_search.source import (
    QueryIR,
    SearchCore,
    hit_schema,
)
