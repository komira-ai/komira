# =============================================================================
# komira_kg -- the mutable data-graph store and its ingest (parts 1 to 3:
#   bi-temporal edges, entity resolution, the source facet, the model seams, the
#   rule-driven extractor and the source cursor store).
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
#   * embedder         -- the `Embedder` trait (text to a vector of a reported
#                         dimension) and `StubEmbedder`.
#   * extractor        -- the `Extractor` trait (text to an `Extraction`
#                         without inference), `StubExtractor`, `copy_extraction`.
#   * llm_client       -- the `LlmClient` trait (extraction, two judgments,
#                         optional synthesis) and `StubLlmClient`.
#   * rule             -- `Rule`: one extraction rule (a type label and a
#                         matcher), all of it host data.
#   * rule_pattern     -- `Pattern`: a whole-token byte pattern.
#   * rule_scan        -- `scan_rule`, `tokens_of`: what a rule finds in a text.
#   * rule_extractor   -- `RuleExtractor`: an `Extractor` driven by a rule set.
#   * cursor_store     -- `SurfaceCursor` and `CursorStore`: where an incremental
#                         read of a source stopped, kept with compare-and-set on
#                         a conditional-write store.
#
# Depends on `komira_kg_format`, `komira_json` and `komira_objectstore` and their
# closure. Reads no
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
from .embedder import STUB_CHAR_CLASSES, Embedder, StubEmbedder
from .extractor import Extractor, StubExtractor, copy_extraction
from .llm_client import LlmClient, StubLlmClient
from .rule import (
    RULE_DELIMITED,
    RULE_EMAIL,
    RULE_MAX_SPAN_BYTES,
    RULE_TOKEN_PATTERN,
    RULE_URL,
    RULE_VERB_PREFIX,
    RULE_WORD_LIST,
    Rule,
)
from .rule_pattern import PATTERN_MAX_BYTES, Pattern
from .rule_scan import scan_rule, tokens_of
from .rule_extractor import RuleExtractor
from .cursor_store import (
    CURSOR_FORMAT_VERSION,
    CURSOR_MAX_FIELD_BYTES,
    CursorRead,
    CursorStore,
    SurfaceCursor,
    decode_cursor,
    encode_cursor,
)
