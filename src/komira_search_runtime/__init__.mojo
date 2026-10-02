# =============================================================================
# komira_search_runtime — the search SOURCE EDGE.
# =============================================================================
#
# THE PACKAGE-DAG DECISION. `komira_search` depends only on komira_core +
# komira_eval, kept LIGHT so its fast storage-free unit suite and non-source
# search consumers stay on that edge. `Morsel` + `MorselSourceImpl` live in
# `komira_morsel`, which is NOT on that edge. So this package holds the source
# EDGE (the Morsel-dependent spec + reader) ABOVE komira_search, the same
# layering the message broker uses for its consumer spec and morsel source:
#
#   * Searcher — the Copyable SourceLike plan-SPEC (the read-side identity for a
#     resolved single split + a QueryIR). Conforms SourceLike (schema /
#     estimate_rows / fingerprint / supports_filter_pushdown). The fingerprint
#     folds the AnalyzerConfig discriminating fields, so two queries that differ
#     only by analyzer settings never collide in the plan cache.
#   * SearchMorselSource — the Movable MorselSourceImpl execute READER. Owns a
#     live SearchCore + a single-shot Atomic cursor (mirror BatchMorselSource):
#     first next_morsel returns the one HitBatch Morsel, then None (single-pass
#     EOF). Built from a Searcher spec via `from_spec`.
#
# The pure read CORE (SearchCore + QueryIR + the fail-loud doc-store reader)
# stays in komira_search (the light edge); this package re-exports QueryIR /
# SearchCore for ergonomics.
#
# Build DAG (cycle-free; komira_morsel has ZERO search deps):
#   komira_search_runtime -> komira_search   (SearchCore / QueryIR / hit_schema)
#   komira_search_runtime -> komira_morsel   (Morsel / MorselSourceImpl)
#   komira_search_runtime -> komira_core     (Schema / RecordBatch / Slab / Expr)
# =============================================================================

from .search_source import (
    Searcher,
    SearchMorselSource,
)

# Re-export the pure-core surface for ergonomics (a single import home).
from komira_search.source import (
    QueryIR,
    SearchCore,
    hit_schema,
)
