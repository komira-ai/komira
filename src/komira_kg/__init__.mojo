# =============================================================================
# komira_kg -- the mutable data-graph store and its ingest (part 1: bi-temporal
#   edges, entity resolution and the source facet).
# =============================================================================
#
#   * bitemporal       -- `WorkingEdge`, `open_edge`,
#                         `overlapping_contradiction_candidates`,
#                         `apply_invalidation`: a replaced fact is closed, not
#                         erased.
#   * name_similarity  -- `normalize_name`, `shannon_entropy`,
#                         `minhash_signature`, `jaccard_estimate`,
#                         `lsh_candidate`, `pair_decision`.
#   * dedup            -- `DedupCandidate`, `Resolution`, `dedup_resolve`, and
#                         `SameEntityJudge` with `dedup_resolve_judged`.
#   * alias_map        -- `AliasMap`, a directed union-find over node ids.
#   * source_facet     -- the facet an entity carries in its `attrs`, and
#                         `FacetTombstoneSet`, keyed by source and facet.
#
# Depends on `komira_kg_format` and `komira_json` and their closure. Reads no
# clock and no environment; a time is always an argument.
# =============================================================================

from .alias_map import AliasMap
from .bitemporal import (
    WorkingEdge,
    apply_invalidation,
    open_edge,
    overlapping_contradiction_candidates,
)
from .dedup import (
    DedupCandidate,
    RES_MATCHED,
    RES_NEEDS_JUDGMENT,
    RES_NEW,
    Resolution,
    SameEntityJudge,
    dedup_resolve,
    dedup_resolve_judged,
)
from .name_similarity import (
    LSH_NUM_BANDS,
    MINHASH_NUM_PERM,
    PAIR_ESCALATE,
    PAIR_MERGE,
    PAIR_NONE,
    SHINGLE_K,
    jaccard_estimate,
    lsh_candidate,
    minhash_signature,
    normalize_name,
    pair_decision,
    shannon_entropy,
)
from .source_facet import (
    FACET_ATTR_KEY,
    FACET_SOURCE_ATTR_KEY,
    FacetTombstoneSet,
    facet_attrs_json,
    facet_from_attrs,
    facet_source_from_attrs,
)
