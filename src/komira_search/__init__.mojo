# =============================================================================
# komira_search — the full-text search engine core
# =============================================================================
#
# The pieces, from the write side to the read side:
#
# TOKENIZER / ANALYZER
#   * AnalyzerConfig — per-field analyzer configuration (field class + which
#     transforms + the stopword-set choice). A Copyable value, persisted with
#     the index mapping so the indexer (build) and searcher (query) build the
#     IDENTICAL analyzer (query-time symmetry).
#   * Token — one emitted term (term string + a reserved position slot;
#     positions are not recorded yet).
#   * AnalyzedField — the per-document tokenize result: a TF-countable
#     multiset of Tokens (the inverted index needs term frequencies).
#   * analyze_text / analyze_text_column — the analyze entry points
#     (whitespace + lowercase + ASCII-fold + stopwords, per-field). BOTH
#     funnel into ONE internal byte-span normalizer so index-time and
#     query-time tokenization are byte-identical (symmetry by construction).
#
# INVERTED INDEX
#   * InvertedIndexBuilder — the in-memory, single-text-field inverted index
#     builder: term -> ascending doc-ids + parallel per-doc term-frequencies,
#     accumulated over a FLAT shared Slab arena (POD substrate with no owning
#     pointer fields + salt-packed open-addressing term directory).
#     add_document / add_text_column / finalize.
#   * FinalizedIndex — the frozen, drainable read surface the term dictionary
#     and the split writer consume: ordinal-indexed (lexicographic) random
#     access to term bytes, doc-freq, and borrowed posting doc-id / TF Spans.
#   * TermEntry — the per-term POD build-phase record (exposed for completeness;
#     callers use the builder + finalize surface).
#
# TERM DICTIONARY (two-stage)
#   * TermDictBuilder — builds a TermDictionary from a FinalizedIndex by a
#     single ascending-ordinal walk (NO re-sort: the ordinal IS the lex
#     position). build_from_finalized.
#   * TermDictionary — the container: stage (a) string->ordinal +
#     stage (b) ordinal->TermInfo + the field name. serialize / deserialize /
#     lookup / term_info_at / lookup_info / set_posting_location.
#   * SortedBlockTermMap — stage (a): sorted-block + front-coding + sparse
#     offset index. A swappable black box (lookup/serialize/deserialize only),
#     so an FST can replace it later.
#   * TermInfoStore — stage (b): flat fixed-width (24-byte) ordinal->TermInfo
#     store. Its format does not change if stage (a) is swapped.
#   * TermInfo — the pure-POD store record {posting_offset, posting_len,
#     doc_freq}. The dictionary build fills doc_freq; the split writer patches
#     the posting location.
#
# BM25 SCORER (pure-math leaf)
#   * Bm25Params — the POD tuning config {k1=1.2, b=0.75, avgdl=0.0,
#     legacy=False}. The DEFAULT is the MODERN BM25 form (no (k1+1) numerator,
#     Lucene 8.0+/OpenSearch 3.0+) with the Lucene/OpenSearch-default b=0.75
#     doc-length normalization; legacy=True opts in to the pre-8.0 (k1+1)
#     numerator; b=0.0 opts out of length normalization. Pure POD.
#   * bm25_idf / bm25_tf_component / bm25_score_contribution — the stateless
#     pure-math relevance kernel SearchCore calls per (term, doc). idf once per
#     term; contribution per matching doc; multi-term = SUM (the accumulator,
#     union and top-k stay in SearchCore).
#
# SEARCH SOURCE (the read side; the engine-facing source edge lives in
# komira_search_scan)
#   * QueryIR — the query config (a `match` over ONE text field): field_name +
#     query_text + top_k + analyzer_config. Copyable POD-ish so it rides on a
#     Copyable searcher plan-spec.
#   * SearchCore — the Movable-only read core: a PRE-PARSED SplitView + a
#     deserialized TermDictionary (both at construction); search(self) is an
#     immutable READ that runs tokenize -> dedup -> per-term lookup + IDF +
#     posting walk + dense accumulate (union + sum) -> bounded top-k -> _source
#     fetch -> HitBatch RecordBatch (_score Float64 / _id Int64 / _source STRING).
#   * hit_schema + a fail-loud, bounds-checked doc-store reader. Both stay
#     intra-package.
#
# The metastore, the OpenSearch JSON surface and multi-split fan-out live in
# other packages and do not change this module's surface.
#
# Dependencies (cycle-free):
#   komira_search -> the core packages   (StringColumnView / StringArray / Schema)
#   komira_search -> komira_hash   (the FNV-1a-64 byte kernel for the posting build)
#   komira_search -> komira_compression (the `_source` LZ4 block codec)
# =============================================================================

from .analyzer import (
    AnalyzerConfig,
    Token,
    AnalyzedField,
    analyze_text,
    analyze_text_column,
    analyze_text_column_resolved,
    resolve_stopwords_for,
    FIELD_CLASS_TEXT,
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_DATE,
    DEFAULT_ENGLISH_STOPWORDS,
)
from .inverted import (
    InvertedIndexBuilder,
    FinalizedIndex,
    TermEntry,
)
from .term_dict import (
    TermDictBuilder,
    TermDictionary,
    SortedBlockTermMap,
    TermInfoStore,
    TermInfo,
    BLOCK_TERMS,
    POSTING_LOC_UNSET,
    MAX_TERM_LEN,
)
from .split import (
    serialize_split,
    SplitView,
    DocStoreBuilder,
    SPLIT_MAGIC_LEN,
    SPLIT_VERSION,
    FOOTER_MAGIC_LEN,
    FOOTER_VERSION,
    POSTING_BLOCK_DOCS,
)
from .sink import (
    IndexCore,
    SearchSink,
)
from .fast_fields import (
    FastFieldSpec,
    NumericFastFieldBuilder,
    KeywordFastFieldBuilder,
    serialize_fastfields_region,
    FastFieldEntry,
    FastFieldReader,
    FF_VERSION,
    FF_ENC_FOR_BITPACK,
    FF_ENC_KEYWORD_DICT,
    FF_ENC_FLOAT_FULL,
    FIELDNORM_NAME,
)
from .score import (
    Bm25Params,
    bm25_idf,
    bm25_tf_component,
    bm25_score_contribution,
    BM25_DEFAULT_K1,
    BM25_DEFAULT_B,
)
from .source import (
    QueryIR,
    SearchCore,
    SearchResult,
    AggSpec,
    AggResult,
    AggResults,
    hit_schema,
    HIT_COL_SCORE,
    HIT_COL_ID,
    HIT_COL_SOURCE,
    SORT_DESC,
    SORT_ASC,
    MISSING_LAST,
    MISSING_FIRST,
    SORT_FIELD_SCORE,
    SORT_FIELD_DOC,
    SEARCH_QUERY_FIELD_MISMATCH,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    AGG_KIND_MIN,
    AGG_KIND_MAX,
    AGG_KIND_SUM,
    AGG_KIND_VALUE_COUNT,
    AGG_KIND_STATS,
    AGG_ORDER_COUNT_DESC,
    AGG_ORDER_COUNT_ASC,
    AGG_ORDER_KEY_ASC,
    AGG_ORDER_KEY_DESC,
    DEFAULT_TERMS_SIZE,
)
