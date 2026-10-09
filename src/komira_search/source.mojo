# =============================================================================
# komira_search/source.mojo
#   The read-side core: QueryIR + the fail-loud doc-store reader + SearchCore
#   (the PURE single-split read path -> HitBatch).
# =============================================================================
#
# Upstream contract: komira_search/{split,term_dict,analyzer,score,inverted}.mojo.
# The `komira.search.index` scan kind (its binding, split plan and split
# reader, implementing the komira_scan_resolver contract) lives in the HIGHER
# `komira_search_scan` package, which keeps komira_search on the light
# the core packages edge.
#
# -----------------------------------------------------------------------------
# WHAT THIS MODULE OWNS (PURE, S3-FREE, unit-testable on the core edge)
# -----------------------------------------------------------------------------
#   * QueryIR — the query config (a single `match` over ONE text
#     field). Copyable POD-ish (String + Int + AnalyzerConfig value) — a
#     per-split copy (merge.mojo) never deep-copies split bytes.
#   * _read_docstore_blob — the fail-loud, bounds-checked doc-store reader
#     (split.mojo has the DocStoreBuilder WRITER + the
#     SplitView.docstore_region() accessor; the reader lives here). Returns a
#     Span tied to the docstore_region's INNER-field origin.
#   * hit_schema — the cached HitBatch schema (_score Float64 / _id Int64 /
#     _source STRING), shared by SearchCore + the `komira.search.index` scan
#     kind (komira_search_scan).
#   * SearchCore — the Movable-only read core: owns a PRE-PARSED SplitView + a
#     deserialized TermDictionary (both built at CONSTRUCTION: SplitView.parse
#     and TermDictionary.deserialize each consume owned bytes, and search(self)
#     is an immutable-self READ — you cannot move bytes out of an immutable self).
#     search() runs the read path: tokenize -> dedup -> per-term lookup + IDF +
#     posting walk + dense accumulate (union + sum) -> bounded top-k -> _source
#     fetch -> assemble the HitBatch RecordBatch.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY (owner self-audit)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY public (or private) signature.
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * SearchCore is MOVE-ONLY (owns a SplitView + a TermDictionary, both
#     Movable-only). It is a stack value / OwnedPointer field, never a byte-slab
#     element. The accumulator is trivial POD (acc = List[Float64] dense +
#     touched = List[Int]); the bounded top-k heap is parallel POD Lists. QueryIR
#     is Copyable POD-ish — no heap-owning pointer field. Region reads are Spans
#     tied to the SplitView inner field (origin_of(self._bytes)) — the
#     established idiom; the doc-store reader returns a Span tied to the SAME
#     origin.
#   * _decode_posting_list + _read_docstore_blob stay INTRA-package (komira_search)
#     — no UnsafePointer crosses a module boundary.
#
# NOTE: the scan-resolver conformance (`SearchScanResolver`, `SearchSplitReader`)
# lives in the HIGHER package komira_search_scan, NOT here.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from std.memory import ArcPointer

from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from std.builtin.swap import swap
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_IN_LIST,
    BIN_AND,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
)
from komira_plan_expr.scalar_value import (
    ScalarValue,
    SCALAR_KIND_DATE32,
    SCALAR_KIND_TIMESTAMP,
)

from .analyzer import (
    AnalyzerConfig,
    analyze_text,
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_DATE,
)
from .fast_fields import (
    FastFieldReader,
    FieldnormResolver,
    KeywordFastFieldResolver,
    NumericFastFieldResolver,
    FloatFastFieldResolver,
    FF_ENC_FLOAT_FULL,
    FIELDNORM_NAME,
)
from .score import Bm25Params, bm25_idf, bm25_score_contribution
from .split import (
    SplitView,
    BlockMaxIndex,
    POSTING_BLOCK_DOCS,
    _decode_posting_list,
    _decode_posting_block,
    _decode_posting_block_dids_only,
    _read_uleb128_span,
    DOCSTORE_FLAG_UNCOMPRESSED,
    DOCSTORE_FLAG_LZ4,
)
from .term_dict import TermDictionary, TermInfo

from komira_compression.lz4 import lz4_decompress


# =============================================================================
# Hit schema constants (FROZEN — the HitBatch column contract).
# =============================================================================

comptime HIT_COL_SCORE: String = "_score"
"""HitBatch column 0: the BM25 score (Float64, descending top-k order)."""

comptime HIT_COL_ID: String = "_id"
"""HitBatch column 1: the doc_id (Int64; OpenSearch names it `_id`/`_doc`)."""

comptime HIT_COL_SOURCE: String = "_source"
"""HitBatch column 2: the projected `_source` blob (STRING; the whole blob)."""


def hit_schema() raises -> Schema:
    """The HitBatch schema: `_score Float64`, `_id Int64`, `_source STRING`.

    Eagerly built (cheap — three Fields). The `komira.search.index` scan kind
    (komira_search_scan) states it as its scan schema, and its
    `search_split_hits` checks each assembled column's arrow_type against it."""
    var sb = SchemaBuilder()
    sb.add_field(Field(HIT_COL_SCORE, ArrowType.FLOAT64, False))
    sb.add_field(Field(HIT_COL_ID, ArrowType.INT64, False))
    sb.add_field(Field(HIT_COL_SOURCE, ArrowType.STRING, False))
    return sb.build()


# =============================================================================
# SearchResult: the search() return.
# =============================================================================


struct SortKeyColumn(Movable, Deinitable):
    """The per-row TYPED sort-key surface for a cross-split merge.

    The 3-column HitBatch (`_score`/`_id`/`_source`) is INSUFFICIENT to merge a
    cross-split fast-field-sorted result — the merge needs each hit's sort KEY,
    not just its score. SearchCore populates ONE typed column (matching the sort
    mode) parallel to the HitBatch rows; `_score`/`_doc` modes leave it EMPTY (the
    merge uses the batch's score/doc_id directly). `mode` is the `SORT_MODE_*`
    discriminant; `missing` flags the null bucket per row (for the typed compare).

    A stack/plan value held BY VALUE on the Movable SearchResult,
    never a byte-slab element (String + List of PODs fine outside a slab)."""

    var mode: UInt8
    var key_i64: List[Int64]
    var key_f64: List[Float64]
    var key_str: List[String]
    var missing: List[Bool]

    def __init__(out self, mode: UInt8 = SORT_MODE_SCORE):
        self.mode = mode
        self.key_i64 = List[Int64]()
        self.key_f64 = List[Float64]()
        self.key_str = List[String]()
        self.missing = List[Bool]()

    @always_inline
    def is_typed(self) -> Bool:
        """True iff this carries a fast-field typed key (I64/F64/STR mode)."""
        return (
            self.mode == SORT_MODE_I64
            or self.mode == SORT_MODE_F64
            or self.mode == SORT_MODE_STR
        )

    @always_inline
    def count(self) -> Int:
        """The number of rows for which a typed key was populated (0 for
        SCORE/DOC mode)."""
        return len(self.missing)


struct SearchResult(Movable, Deinitable):
    """The single-split search result: the HitBatch page + the TRUE match total.

    `SearchCore.search` returns this struct (NOT a parallel `search_with_total`
    method — one entry point, no parallel APIs; the caller is the OpenSearch
    shim's dispatcher).

    `total_matches` is `len(touched)` — the count of docs that matched >=1
    query TERM AND passed the filter. It is the TRUE number of matching
    docs, of which `batch` carries at most `size` rows (the page); the shim
    envelope caps it at 10000 and flips `relation`. Filter-only totals are out
    of scope (the filter-only match path is unimplemented).

    Movable-only (it carries a Movable-only RecordBatch)."""

    var batch: RecordBatch
    var total_matches: Int
    var agg_results: AggResults
    """The computed leaf-agg results (EMPTY for a no-aggs query).
    Defaulted-trailing on __init__ so a 2-arg caller stays source-compatible."""
    var sort_keys: SortKeyColumn
    """The per-row typed sort-key surface (one column matching the
    sort mode; EMPTY for `_score`/`_doc` modes). Defaulted-trailing so
    a 2-/3-arg caller stays source-compatible. The cross-split merge
    reads it to re-rank a fast-field-sorted result by the typed key."""

    def __init__(
        out self,
        var batch: RecordBatch,
        total_matches: Int,
        var agg_results: AggResults = AggResults(),
        var sort_keys: SortKeyColumn = SortKeyColumn(),
    ):
        self.batch = batch^
        self.total_matches = total_matches
        self.agg_results = agg_results^
        self.sort_keys = sort_keys^

    def take_batch(mut self) -> RecordBatch:
        """Move the HitBatch out of `self`, leaving an empty RecordBatch in its
        place (the swap-then-move idiom — the safe replacement for a partial
        move out of the middle of a value). The caller may still read
        `self.total_matches` afterward; `self` stays destructor-safe."""
        var out = RecordBatch()
        swap(self.batch, out)
        return out^

    def take_aggs(mut self) -> AggResults:
        """Move the AggResults out of `self`, leaving an empty AggResults in its
        place (the swap-then-move idiom). `self` stays
        destructor-safe; `self.total_matches` is still readable afterward."""
        var out = AggResults()
        swap(self.agg_results, out)
        return out^

    def take_sort_keys(mut self) -> SortKeyColumn:
        """Move the SortKeyColumn out of `self` (swap-then-move idiom).
        `self` stays destructor-safe."""
        var out = SortKeyColumn()
        swap(self.sort_keys, out)
        return out^


# =============================================================================
# Sort / pagination constants.
# =============================================================================

comptime SORT_DESC: UInt8 = 0
"""OpenSearch `_score` default order (and the QueryIR default)."""

comptime SORT_ASC: UInt8 = 1
"""Ascending order (the OpenSearch default for any non-`_score` field)."""

comptime MISSING_LAST: UInt8 = 0
"""OpenSearch `missing` default: null/missing cells sort to the END."""

comptime MISSING_FIRST: UInt8 = 1
"""null/missing cells sort to the FRONT."""

comptime SORT_FIELD_SCORE: String = "_score"
"""The reserved `_score` sort key (explicit relevance sort)."""

comptime SORT_FIELD_DOC: String = "_doc"
"""The reserved `_doc` sort key (doc-id order)."""

# Heap comparison modes (the `_TopKHeap._mode` discriminant).
comptime SORT_MODE_SCORE: UInt8 = 0
"""BM25-score ordering — the default; BYTE-IDENTICAL to an unsorted query (zero-cost)."""

comptime SORT_MODE_DOC: UInt8 = 1
"""Doc-id ordering (`_doc`)."""

comptime SORT_MODE_I64: UInt8 = 2
"""Integer/date fast-field sort key."""

comptime SORT_MODE_F64: UInt8 = 3
"""Float fast-field sort key."""

comptime SORT_MODE_STR: UInt8 = 4
"""Keyword fast-field sort key."""


# =============================================================================
# Aggregations: the agg-spec carrier POD + the agg-results struct.
# =============================================================================
#
# v1 surface: leaf metric aggs (avg/min/max/sum/value_count/
# stats) over numeric/date fast-fields + `terms` over keyword/numeric/date
# fast-fields. Single-level only (NO nested sub-aggs). The carrier is a POD-flat
# `List[AggSpec]` (every field ImplicitlyCopyable — String/UInt8/Int) so QueryIR
# stays SYNTHESIZED-Copyable with ZERO new machinery (unlike the filter,
# there is no non-ImplicitlyCopyable Expr here, so NO ArcPointer is needed).
# No arity siblings: the metric/key arity is driven by `len(aggs)`
# (a count-driven List), NOT a per-arity struct family.

# Agg kind discriminants (AggSpec.kind).
comptime AGG_KIND_TERMS: UInt8 = 0
"""Bucket agg: `terms` over a keyword/numeric/date fast-field."""

comptime AGG_KIND_AVG: UInt8 = 1
"""Metric: mean of the non-null cells."""

comptime AGG_KIND_MIN: UInt8 = 2
"""Metric: minimum of the non-null cells."""

comptime AGG_KIND_MAX: UInt8 = 3
"""Metric: maximum of the non-null cells."""

comptime AGG_KIND_SUM: UInt8 = 4
"""Metric: sum of the non-null cells."""

comptime AGG_KIND_VALUE_COUNT: UInt8 = 5
"""Metric: count of the non-null cells."""

comptime AGG_KIND_STATS: UInt8 = 6
"""Metric: the five-value bundle (count/min/max/avg/sum) from one pass."""

# `terms` order codes (AggSpec.order_code). The post-walk bucket sort key.
comptime AGG_ORDER_COUNT_DESC: UInt8 = 0
"""OpenSearch default: by doc_count descending."""

comptime AGG_ORDER_COUNT_ASC: UInt8 = 1
"""By doc_count ascending."""

comptime AGG_ORDER_KEY_ASC: UInt8 = 2
"""By the bucket key ascending (string-byte order; numeric keys stringified)."""

comptime AGG_ORDER_KEY_DESC: UInt8 = 3
"""By the bucket key descending."""

comptime DEFAULT_TERMS_SIZE: Int = 10
"""The OpenSearch default `terms` `size` (top-N buckets)."""


struct AggSpec(Copyable, Movable, Deinitable):
    """One leaf aggregation descriptor (the POD-flat carrier element).

    ALL fields are ImplicitlyCopyable (String + UInt8 + Int) — this is
    load-bearing: any non-ImplicitlyCopyable field (an `Optional[Expr]`/owned
    tree) re-triggers the copy-synthesis hard-fail described on QueryIR and
    breaks QueryIR's synthesized Copyable. Do NOT add such a field; if nesting
    is ever admitted (OUT of v1), use `Optional[ArcPointer[...]]` (as QueryIR's
    filter does), not an inline owned tree.

    Trivial POD: a stack/plan value held BY VALUE on the Copyable QueryIR,
    never a byte-slab element. String + List fields are fine OUTSIDE a slab.

    Fields:
      name:          the user's agg name (the response key).
      kind:          AGG_KIND_TERMS / _AVG / _MIN / _MAX / _SUM / _VALUE_COUNT /
                     _STATS.
      field:         the fast-field name the agg reads.
      bucket_size:   `terms` `size` (top-N buckets, default 10); ignored for
                     metrics.
      order_code:    `terms` order (AGG_ORDER_*); ignored for metrics.
      min_doc_count: `terms` min_doc_count (default 1); ignored for metrics.
      missing:       `terms` missing substitute key ("" = drop null cells);
                     ignored for metrics."""

    var name: String
    var kind: UInt8
    var field: String
    var bucket_size: Int
    var order_code: UInt8
    var min_doc_count: Int
    var missing: String

    def __init__(
        out self,
        var name: String,
        kind: UInt8,
        var field: String,
        bucket_size: Int = DEFAULT_TERMS_SIZE,
        order_code: UInt8 = AGG_ORDER_COUNT_DESC,
        min_doc_count: Int = 1,
        var missing: String = String(""),
    ):
        self.name = name^
        self.kind = kind
        self.field = field^
        self.bucket_size = bucket_size
        self.order_code = order_code
        self.min_doc_count = min_doc_count
        self.missing = missing^

    @always_inline
    def is_metric(self) -> Bool:
        """True for any single/multi-value metric agg (NOT `terms`)."""
        return self.kind != AGG_KIND_TERMS


struct _TermBucket(Copyable, Movable, Deinitable):
    """One `terms` bucket: a key string + a doc_count. Trivial POD."""

    var key: String
    var doc_count: Int

    def __init__(out self, var key: String, doc_count: Int):
        self.key = key^
        self.doc_count = doc_count


struct AggResult(Copyable, Movable, Deinitable):
    """The computed result for ONE agg (metric values OR terms buckets), shaped
    so the shim renderer maps it 1:1 to the OpenSearch `aggregations` member.

    A metric agg fills (count/sum/min/max + has_value); `terms` fills `buckets` +
    `sum_other_doc_count` + `last_bucket_doc_count` (per-split error
    contribution) and `doc_count_error_upper_bound` (the merged/rendered bound:
    0 for a single split or key-order, the computed count-desc sum, or -1 for
    count-asc/sub-agg order — set by the merge reducer).
    Trivial POD (String + scalars + List[_TermBucket]; the two error
    fields are scalar Int — safe in the Slab[SearchResult] merge path).

    Empty-matched-set OpenSearch fidelity: when `count == 0`,
      * value_count -> 0, sum -> 0.0 (NEVER null),
      * avg/min/max -> null (signalled by `has_value == False`),
      * stats -> count 0, sum 0.0, min/max/avg null.
    `has_value` is True iff at least one non-null cell was folded."""

    var name: String
    var kind: UInt8
    # Metric accumulators (folded over non-null cells; widened to Float64).
    var count: Int
    var sum: Float64
    var min: Float64
    var max: Float64
    var has_value: Bool
    # `terms` results.
    var buckets: List[_TermBucket]
    var sum_other_doc_count: Int
    # multi-split error tracking. BOTH scalar Int —
    # safe (AggResult rides a Slab[SearchResult] in the merge path; a
    # heap-owning field here would be a byte-slab trap, a scalar Int is not).
    #   last_bucket_doc_count: per-split — the doc_count of the LAST (smallest)
    #     bucket this split RETURNED, but ONLY when this split DROPPED a bucket
    #     (kept count > requested size); else 0. The per-split error contribution
    #     the coordinator sums (the most a missing term could have had here).
    #   doc_count_error_upper_bound: the MERGED/rendered value (the renderer emits
    #     it). 0 on a single split (no other shard to miss terms from) and on
    #     key-order; the computed count-desc sum across dropped splits; -1 for
    #     count-asc / sub-agg order (indeterminate). Init 0.
    var last_bucket_doc_count: Int
    var doc_count_error_upper_bound: Int

    def __init__(out self, var name: String, kind: UInt8):
        self.name = name^
        self.kind = kind
        self.count = 0
        self.sum = 0.0
        self.min = 0.0
        self.max = 0.0
        self.has_value = False
        self.buckets = List[_TermBucket]()
        self.sum_other_doc_count = 0
        self.last_bucket_doc_count = 0
        self.doc_count_error_upper_bound = 0

    @always_inline
    def avg(self) -> Float64:
        """The mean (caller checks has_value first; 0 cells -> 0.0)."""
        if self.count == 0:
            return 0.0
        return self.sum / Float64(self.count)


struct AggResults(Movable, Deinitable):
    """The full per-search agg-results bundle carried on SearchResult.

    Movable-only (it rides the Movable SearchResult). Default-constructs to EMPTY
    (the no-aggs path), so the existing SearchResult callers + the no-aggs path
    pay no overhead. Trivial POD (a single List[AggResult])."""

    var results: List[AggResult]

    def __init__(out self):
        self.results = List[AggResult]()

    def __init__(out self, var results: List[AggResult]):
        self.results = results^

    @always_inline
    def count(self) -> Int:
        return len(self.results)


# =============================================================================
# QueryIR: the query config (Copyable).
# =============================================================================


struct QueryIR(Copyable, Movable, Deinitable):
    """The query: a single `match` over ONE text field.

    Copyable so a caller can take a per-split copy (merge.mojo rewrites
    top_k / shard_size on it) without sharing mutable state. All fields are
    Copyable (String + Int + AnalyzerConfig value + the `Optional[ArcPointer[Expr]]` filter carrier — see below).

    Contract: `analyzer_config` MUST satisfy `is_tokenized()` (FIELD_CLASS_TEXT)
    — `analyze_text` RAISES otherwise. The OpenSearch shim that builds the
    config must honor this; SearchCore passes the raw query_text + this config
    and tokenizes at execute (the symmetry guarantee).

    String + Int + AnalyzerConfig value + ArcPointer handle. Held BY VALUE
    on the Copyable spec; never a byte-slab element. The filter ArcPointer is a
    refcounted handle to an immutable, heap-resident predicate tree — fine
    OUTSIDE a byte-slab (the ban is on heap-owning fields of a Movable
    struct STORED IN a byte slab; QueryIR is not).

    Fields:
      field_name:      which text field the match targets.
      query_text:      the RAW query string (NOT pre-analyzed — the source owns
                       tokenization for the byte-identical query/index symmetry).
      top_k:           the `size` bound (number of ranked hits to return).
      analyzer_config: the field's analyzer (the symmetry carrier; must be TEXT).
      generation:      the metastore seam — the manifest generation
                       (SearchMetastore.generation(), which moves on every
                       publish, retire and reap) this query
                       reads. It is a SNAPSHOT, not identity: the
                       `komira.search.index` scan kind stamps the generation it
                       resolved for the execution (LIVE: re-read per execution;
                       or the caller's pin) -- the scan's plan identity folds a
                       pinned generation only. A defaulted trailing field (0) so
                       a QueryIR(field, text, top_k, cfg) caller is unaffected.
                       SearchCore.search does not read it.
      _filter:         the ACCEPTED fast-field pushed-down conjunction,
                       held as `Optional[ArcPointer[Expr]]` (None = no filter).
                       The single apply site (SearchCore.search) reads it via
                       `filter_ref()`; the fingerprint folds it; the gate accepts
                       per-conjunct. The direct path (the OpenSearch shim's
                       dispatcher) is the carrier (it calls SearchCore.search DIRECTLY — no
                       optimizer/ScanData).

    A SINGLE explicit defaulted __init__ (NO @fieldwise_init).
    Mojo rejects a struct-FIELD default initializer (`var x: T = 0`) AND
    collides @fieldwise_init with a same-arity defaulted __init__; so the
    `generation` and `filter` defaults are carried on a custom
    __init__ (the Bm25Params pattern). A 4-/5-arg
    `QueryIR(field, text, top_k, cfg[, generation])` caller works unchanged.

    Why the filter is an ArcPointer: `Expr` is
    `struct Expr(Movable, Writable)` — NOT Copyable (its variant data, e.g.
    `BinaryOpData(Movable)`, are non-ImplicitlyCopyable), so `Optional[Expr]` is
    itself non-ImplicitlyCopyable. A struct declared `Copyable` is field-wise
    SYNTHESIZED a `__copyinit__`, and that synthesis HARD-FAILS on a
    non-ImplicitlyCopyable field — EVEN with an explicit `__copyinit__`/`fn copy`
    present (the "cannot synthesize copy constructor" error persists and an
    explicit `__copyinit__` body fails with "'None' has no attributes"). So
    "declared Copyable with an explicit fn copy" is NOT achievable for an inline
    `Optional[Expr]`. The fix that keeps the struct genuinely
    trait-`Copyable`, synthesized — no explicit copy machinery: carry
    the filter as `Optional[ArcPointer[Expr]]`. `ArcPointer[T]` IS Copyable (a
    refcount bump — shared read-only ownership of the IMMUTABLE predicate tree,
    which is exactly the semantics when a per-split copy is taken). This is NOT
    the banned use of ArcPointer (to make a List / byte-slab ELEMENT Copyable);
    this is a single QueryIR field, never slab-stored.
    """

    var field_name: String
    var query_text: String
    var top_k: Int
    var analyzer_config: AnalyzerConfig
    var generation: Int64
    var _filter: Optional[ArcPointer[Expr]]
    # ---- sort / page fields (plain PODs) ----
    var sort_field: String
    """The sort target name. "" (default) = sort by `_score` (the default);
    `_score`/`_doc` are reserved; otherwise a fast-field name."""
    var sort_order: UInt8
    """SORT_ASC / SORT_DESC."""
    var missing_order: UInt8
    """MISSING_LAST (default) / MISSING_FIRST — the null bucket end."""
    var from_offset: Int
    """The OpenSearch `from` page offset (default 0)."""
    # ---- aggregations (POD-flat agg carrier) ----
    var _aggs: List[AggSpec]
    """The leaf agg specs (empty = no aggs). A `List[AggSpec]` of all-
    ImplicitlyCopyable PODs keeps QueryIR SYNTHESIZED-Copyable — like the
    sort PODs, NO explicit copy()."""
    # ---- the no-query scan ----
    var match_all: Bool
    """True = a query with NO search term matches EVERY live doc of the split
    (score 0.0), through the same no-term arm the match-all-for-aggs request
    uses. Set by a caller that reads a whole index with no query, whose rows
    are every live document. Default False: a `match` whose text analyzes to
    no terms (all stopwords, empty) still matches NOTHING, exactly as before
    -- OpenSearch semantics for `match`, which this flag must not change."""

    def __init__(
        out self,
        var field_name: String,
        var query_text: String,
        top_k: Int,
        var analyzer_config: AnalyzerConfig,
        generation: Int64 = 0,
        var filter: Optional[Expr] = None,
        var sort_field: String = String(""),
        sort_order: UInt8 = SORT_DESC,
        missing_order: UInt8 = MISSING_LAST,
        from_offset: Int = 0,
        var aggs: List[AggSpec] = List[AggSpec](),
        match_all: Bool = False,
    ):
        """Defaults: generation = 0 (no metastore wired into the in-memory
        SearchCore path), filter = None (no pushed-down predicate). The
        resolution caller (with a metastore) stamps generation = metastore.generation()
        for CSE-collision safety; the shim/optimizer attaches the accepted
        fast-field conjunction via `filter` (taken into the ArcPointer carrier).

        The ergonomic param is `Optional[Expr]` (the shim builds an Expr); it is
        wrapped into the `Optional[ArcPointer[Expr]]` carrier here.

        The four sort/page fields default to the unsorted behavior —
        sort_field="" (sort by `_score` desc), from_offset=0 (no skip). They are
        plain ImplicitlyCopyable PODs (String + UInt8 + UInt8 + Int), so they
        ride the SYNTHESIZED copy with ZERO new machinery (there is no
        explicit `copy()` on QueryIR; the filter rides `Optional[ArcPointer]`)."""
        self.field_name = field_name^
        self.query_text = query_text^
        self.top_k = top_k
        self.analyzer_config = analyzer_config^
        self.generation = generation
        if filter:
            self._filter = ArcPointer[Expr](filter.take())
        else:
            self._filter = None
        self.sort_field = sort_field^
        self.sort_order = sort_order
        self.missing_order = missing_order
        self.from_offset = from_offset
        self._aggs = aggs^
        self.match_all = match_all

    @always_inline
    def has_filter(self) -> Bool:
        """True iff a pushed-down predicate is attached."""
        return Bool(self._filter)

    def filter_ref(self) -> ref [origin_of(self._filter.value()[])] Expr:
        """A borrowed ref to the pushed-down predicate Expr. Caller MUST check
        `has_filter()` first. Returns a ref through the ArcPointer (no copy of the
        Expr tree)."""
        # The return origin is the ArcPointer DEREF's origin,
        # spelled `origin_of(self._filter.value()[])` — NOT the bare
        # `self._filter.value()` indirection-origin form (the compiler rejects
        # the latter).
        return self._filter.value()[]

    @always_inline
    def has_aggs(self) -> Bool:
        """True iff >=1 leaf agg is attached."""
        return len(self._aggs) > 0

    def aggs_ref(self) -> ref [self._aggs] List[AggSpec]:
        """A borrowed ref to the WHOLE agg-spec list (a LIST ref, not a
        single-element ref). The fingerprint fold + the agg pass iterate it.
        Non-raising (plain `ref` return)."""
        return self._aggs

    def rewrite_agg_field(mut self, idx: Int, var name: String) raises:
        """`.keyword` alias resolution: rewrite the `idx`-th agg's
        target field name in place. The OpenSearch `.keyword` sub-field alias is
        resolved to the bare keyword fast-field name by the agg gate BEFORE the
        engine reads the column, so a `{"terms":{"field":"status.keyword"}}`
        request reads the same `status` keyword column as the bare form. `_aggs`
        is PRIVATE with a read accessor + the bucket-size mutator; this is
        the second PUBLIC mutator (a by-value POD-list rewrite on the
        synthesized-Copyable QueryIR; it never touches the shared filter)."""
        if idx < 0 or idx >= len(self._aggs):
            raise Error(
                "QueryIR.rewrite_agg_field: index " + String(idx)
                + " out of range [0, " + String(len(self._aggs)) + ")"
            )
        self._aggs[idx].field = name^

    def replace_filter(mut self, var pred: Expr):
        """`.keyword` alias resolution: replace the pushed-down filter
        predicate with a rewritten tree (the gate resolves `.keyword` col-refs to
        their bare keyword fast-field names so the engine reads the right column).
        Wraps the fresh Expr into the `Optional[ArcPointer[Expr]]` carrier,
        exactly as __init__ does. Only the filter GATE calls this, on the
        per-query (non-shared) QueryIR before the leaf copy."""
        self._filter = ArcPointer[Expr](pred^)

    def rewrite_terms_bucket_sizes(mut self, shard_size: Int):
        """Multi-split over-fetch: set EVERY `terms` agg's `bucket_size` to
        `shard_size` on this (per-split copy of the) QueryIR, so each split returns
        MORE than `size` buckets and a globally-significant term below per-split
        `size` is not dropped before the coordinator merge sees it. Metric aggs are
        unaffected (`bucket_size` is ignored for them). `_aggs` is PRIVATE with only
        a read accessor, so this small PUBLIC mutator is the over-fetch
        seam (a by-value POD-list rewrite on the synthesized-Copyable QueryIR; it
        never touches the shared `Optional[ArcPointer[Expr]]` filter)."""
        for i in range(len(self._aggs)):
            if self._aggs[i].kind == AGG_KIND_TERMS:
                self._aggs[i].bucket_size = shard_size


# =============================================================================
# _read_docstore_blob: the fail-loud doc-store reader.
# =============================================================================
#
# The doc-store region format (DocStoreBuilder.serialize in split.mojo):
#   num_docs          : u64 LE
#   compressed_flag   : u8           (UNCOMPRESSED or LZ4; an unknown flag raises)
#   blob_offset[0..n] : each u64 LE  (n+1 entries, relative to blob area)
#   uncompressed_len[0..n)           (n entries, u64 LE)
#   blob_area         : concatenated UNCOMPRESSED blobs
#
# slot = doc_id - min_doc_id (the split writer's dense-ascending invariant). The blob
# for slot is blob_area[blob_offset[slot] .. blob_offset[slot+1]). EVERY offset
# is validated before any slice (the split is attacker-influenced at query time
# — fail-loud). Returns a Span tied to the docstore_region's
# inner-field origin.
# =============================================================================


@always_inline
def _read_u64_le_at(src: Span[UInt8, _], p: Int) -> Int:
    """Read a little-endian u64 from `src` starting at byte `p`. Caller MUST
    have bounds-checked `p + 8 <= len(src)` first."""
    var v = UInt64(0)
    for i in range(8):
        v = v | (UInt64(src[p + i]) << UInt64(8 * i))
    return Int(v)


def _docstore_num_docs(region: Span[UInt8, _]) raises -> Int:
    """Parse + validate the doc-store header's `num_docs`. Fail-loud: a
    region too short for even the header is corrupt; an UNKNOWN compressed_flag
    (not 0 = UNCOMPRESSED, not 1 = LZ4) is a future format this reader cannot
    decode."""
    # num_docs u64 (8) + compressed_flag u8 (1) = 9 byte minimum header.
    if len(region) < 9:
        raise Error(
            "_docstore_num_docs: region too short for header ("
            + String(len(region))
            + " < 9; corrupt)"
        )
    var num_docs = _read_u64_le_at(region, 0)
    if num_docs < 0:
        raise Error("_docstore_num_docs: negative num_docs (corrupt)")
    var flag = Int(region[8])
    if flag != Int(DOCSTORE_FLAG_UNCOMPRESSED) and flag != Int(
        DOCSTORE_FLAG_LZ4
    ):
        raise Error(
            "_docstore_num_docs: compressed_flag "
            + String(flag)
            + " unsupported (reader decodes UNCOMPRESSED=0 or LZ4=1 only)"
        )
    return num_docs


def _docstore_flag(region: Span[UInt8, _]) raises -> Int:
    """The doc-store `compressed_flag` byte (0 UNCOMPRESSED / 1 LZ4). Header is
    validated by `_docstore_num_docs` first."""
    if len(region) < 9:
        raise Error("_docstore_flag: region too short for header (corrupt)")
    return Int(region[8])


def _docstore_blob_extent[
    o: Origin[mut=False]
](region: Span[UInt8, o], slot: Int) raises -> Tuple[Int, Int, Int]:
    """Resolve doc-store `slot`'s STORED blob extent + its uncompressed length.
    Returns (blob_off, blob_len, uncompressed_len) where blob_off/blob_len locate
    the STORED bytes in `region` (verbatim when uncompressed; LZ4 when the flag
    is LZ4) and uncompressed_len is the ORIGINAL size. Fail-loud bounds-checked
    throughout (the split is attacker-influenced at query time).

    Layout (DocStoreBuilder.serialize): num_docs u64 + compressed_flag u8 +
    blob_offset[0..n] (n+1 u64) + uncompressed_len[0..n) (n u64) + blob_area.
    """
    var num_docs = _docstore_num_docs(region)
    if slot < 0 or slot >= num_docs:
        raise Error(
            "_docstore_blob_extent: slot "
            + String(slot)
            + " out of range [0, "
            + String(num_docs)
            + ")"
        )

    # Header is 9 bytes; then (num_docs + 1) blob offsets, then num_docs
    # uncompressed-lens, then the blob area.
    var off_table_start = 9
    var n_offsets = num_docs + 1
    var unc_table_start = off_table_start + n_offsets * 8
    var blob_area_start = unc_table_start + num_docs * 8
    # The full fixed-size prefix (header + both tables) must be present before we
    # read any offset (validate the whole index area first).
    if blob_area_start > len(region):
        raise Error(
            "_docstore_blob_extent: index area ["
            + String(off_table_start)
            + ", "
            + String(blob_area_start)
            + ") exceeds region length "
            + String(len(region))
            + " (corrupt)"
        )

    var start = _read_u64_le_at(region, off_table_start + slot * 8)
    var end = _read_u64_le_at(region, off_table_start + (slot + 1) * 8)
    if start < 0 or end < 0 or end < start:
        raise Error(
            "_docstore_blob_extent: bad blob offsets [start "
            + String(start)
            + ", end "
            + String(end)
            + ") for slot "
            + String(slot)
            + " (corrupt)"
        )
    var blob_len = end - start
    var blob_off = blob_area_start + start
    if blob_off + blob_len > len(region):
        raise Error(
            "_docstore_blob_extent: blob ["
            + String(blob_off)
            + ", "
            + String(blob_off + blob_len)
            + ") for slot "
            + String(slot)
            + " exceeds region length "
            + String(len(region))
            + " (corrupt)"
        )
    var uncompressed_len = _read_u64_le_at(region, unc_table_start + slot * 8)
    if uncompressed_len < 0:
        raise Error(
            "_docstore_blob_extent: negative uncompressed_len for slot "
            + String(slot)
            + " (corrupt)"
        )
    return (blob_off, blob_len, uncompressed_len)


def _read_docstore_blob[
    o: Origin[mut=False]
](region: Span[UInt8, o], slot: Int) raises -> Span[UInt8, o]:
    """Return the STORED blob bytes for doc-store `slot` as a borrowed Span tied
    to the SAME origin `o` as the passed `region`. For an UNCOMPRESSED doc-store
    this IS the verbatim `_source` blob; for an LZ4 doc-store this is the
    COMPRESSED bytes (callers wanting the decoded `_source` use
    `read_docstore_source`). Fail-loud bounds-checked."""
    var ext = _docstore_blob_extent(region, slot)
    return region[ext[0] : ext[0] + ext[1]]


def read_docstore_source[
    o: Origin[mut=False]
](region: Span[UInt8, o], slot: Int) raises -> String:
    """Return doc-store `slot`'s decoded `_source` blob as an OWNED String,
    decompressing per the compressed_flag (UNCOMPRESSED → verbatim; LZ4 →
    lz4_decompress using the stored uncompressed_len). Backward-compatible: a
    flag-0 (uncompressed) split reads verbatim. This is the canonical doc-store read
    surface for the searcher + the compaction merge — the flag is load-bearing
    so a pre-compression split round-trips unchanged.

    Fail-loud bounds-checked throughout via `_docstore_blob_extent` (the
    split is attacker-influenced at query time)."""
    var flag = _docstore_flag(region)
    var ext = _docstore_blob_extent(region, slot)
    var blob_off = ext[0]
    var blob_len = ext[1]
    var uncompressed_len = ext[2]
    # The STORED slot bytes as a borrowed Span tied to the SAME origin `o`.
    var stored = region[blob_off : blob_off + blob_len]
    if flag == Int(DOCSTORE_FLAG_LZ4):
        # An empty blob (uncompressed_len == 0) has an empty stored slot — skip
        # the FFI and return "" (mirrors the builder's empty-blob convention).
        if uncompressed_len == 0:
            return String("")
        var decoded = lz4_decompress(stored, uncompressed_len)
        # SAFETY: the docstore blob is the verbatim _source the builder wrote
        # from a String; lz4 returns exactly those bytes.
        return String(StringSlice(unsafe_from_utf8=Span(decoded)))
    # UNCOMPRESSED: the stored bytes ARE the verbatim _source.
    # SAFETY: as above, the builder wrote these bytes from a String.
    return String(StringSlice(unsafe_from_utf8=stored))


# =============================================================================
# Bounded top-k min-heap over (score, doc_id) (read path step 5).
# =============================================================================
#
# A capacity-k binary min-heap fed from `touched`. O(M log k) for M matching
# docs. Parallel POD Lists (trivial): `_score[i]` is the BM25 score of
# `_id[i]`. The MIN (smallest score) sits at the root, so a new candidate that
# beats the current minimum replaces the root. At drain, the heap holds the k
# highest-scoring docs; we sort them DESCENDING for the HitBatch.
#
# Tie-break: when scores are equal, the LOWER doc_id ranks higher (stable,
# deterministic — matches "earliest doc wins" and keeps the test vectors
# reproducible).
# =============================================================================


struct _TopKHeap(Movable, Deinitable):
    """A bounded capacity-k min-heap, sort-key-aware. Trivial:
    parallel POD Lists, no heap-owning element.

    The HEAP INVARIANT is min-at-root over the configured ranking key (`_mode`),
    so the root is always the WEAKEST surviving candidate and a stronger
    candidate evicts it. At drain we sort DESCENDING by the SAME ranking
    (strongest first) — that is the HitBatch row order.

    `_mode`:
      SORT_MODE_SCORE — the default: rank by BM25
        score, score-tie -> lower doc_id ranks higher. Zero-cost; `_key_*` /
        `_missing` unused.
      SORT_MODE_DOC   — rank by doc_id (`_doc`), honoring `_order`.
      SORT_MODE_I64/_F64/_STR — rank by the typed sort key, null-bucket FIRST
        (`_miss`), then the typed compare honoring `_order`, then ascending
        doc_id tiebreak.

    `push` and `_swap` BOTH participate in ranking — `push` has its own
    inlined root-evict comparison (routed through the mode-aware compare),
    and `_swap` swaps ALL parallel columns in lockstep (else key<->id alignment
    corrupts on every sift). Only ONE `_key_*` list is populated per query."""

    var _score: List[Float64]
    var _id: List[Int]
    var _key_i64: List[Int64]
    var _key_f64: List[Float64]
    var _key_str: List[String]
    var _missing: List[Bool]
    var _mode: UInt8
    var _order: UInt8
    var _miss: UInt8
    var _cap: Int

    def __init__(
        out self,
        capacity: Int,
        mode: UInt8 = SORT_MODE_SCORE,
        order: UInt8 = SORT_DESC,
        miss: UInt8 = MISSING_LAST,
    ):
        self._score = List[Float64]()
        self._id = List[Int]()
        self._key_i64 = List[Int64]()
        self._key_f64 = List[Float64]()
        self._key_str = List[String]()
        self._missing = List[Bool]()
        self._mode = mode
        self._order = order
        self._miss = miss
        self._cap = capacity if capacity > 0 else 1

    @always_inline
    def _typed_a_ranks_higher(self, a: Int, b: Int) -> Bool:
        """For a fast-field sort mode: True iff entry `a` ranks STRICTLY higher
        than `b` (closer to the top of the descending result). Applies the
        bucket-first rule: null bucket -> typed compare honoring _order ->
        ascending doc_id tiebreak. `a`/`b` are present unless flagged in
        `_missing`."""
        var ma = self._missing[a]
        var mb = self._missing[b]
        if ma != mb:
            # One is missing. With MISSING_LAST, the present entry ranks higher;
            # with MISSING_FIRST, the missing entry ranks higher. Independent of
            # _order (a fixed end, exactly like OpenSearch).
            if self._miss == MISSING_LAST:
                return mb  # a ranks higher iff b is the missing one.
            return ma  # MISSING_FIRST: a ranks higher iff a is the missing one.
        if not ma:  # both present: typed compare honoring _order.
            var a_smaller: Bool
            if self._mode == SORT_MODE_I64:
                if self._key_i64[a] != self._key_i64[b]:
                    a_smaller = self._key_i64[a] < self._key_i64[b]
                    return (a_smaller == (self._order == SORT_ASC))
            elif self._mode == SORT_MODE_F64:
                if self._key_f64[a] != self._key_f64[b]:
                    a_smaller = self._key_f64[a] < self._key_f64[b]
                    return (a_smaller == (self._order == SORT_ASC))
            else:  # SORT_MODE_STR
                if self._key_str[a] != self._key_str[b]:
                    a_smaller = self._key_str[a] < self._key_str[b]
                    return (a_smaller == (self._order == SORT_ASC))
        # both missing OR key tie: ascending doc_id ranks higher (deterministic).
        return self._id[a] < self._id[b]

    @always_inline
    def _a_ranks_higher(self, a: Int, b: Int) -> Bool:
        """True iff entry `a` ranks STRICTLY higher than `b` in the DESCENDING
        result order (used by the drain selection sort)."""
        if self._mode == SORT_MODE_SCORE:
            # The EXACT pre-sort "better": higher score, then lower doc_id.
            if self._score[a] != self._score[b]:
                return self._score[a] > self._score[b]
            return self._id[a] < self._id[b]
        if self._mode == SORT_MODE_DOC:
            if self._id[a] != self._id[b]:
                var a_smaller = self._id[a] < self._id[b]
                return (a_smaller == (self._order == SORT_ASC))
            return False
        return self._typed_a_ranks_higher(a, b)

    @always_inline
    def _less(self, a: Int, b: Int) -> Bool:
        """True iff heap entry `a` is "smaller" (weaker) than `b` for the
        MIN-heap ordering — i.e. `b` ranks higher than `a`. The min-at-root heap
        keeps the WEAKEST candidate at the root so a stronger candidate evicts
        it."""
        return self._a_ranks_higher(b, a)

    def _swap(mut self, a: Int, b: Int):
        var ts = self._score[a]
        self._score[a] = self._score[b]
        self._score[b] = ts
        var ti = self._id[a]
        self._id[a] = self._id[b]
        self._id[b] = ti
        # Swap ALL parallel key columns in lockstep (else key<->id alignment
        # corrupts on every sift). Each `_key_*` list is either empty (unused
        # mode) or fully populated, so guard on length.
        if len(self._key_i64) > 0:
            var tk = self._key_i64[a]
            self._key_i64[a] = self._key_i64[b]
            self._key_i64[b] = tk
        if len(self._key_f64) > 0:
            var tkf = self._key_f64[a]
            self._key_f64[a] = self._key_f64[b]
            self._key_f64[b] = tkf
        if len(self._key_str) > 0:
            var tks = self._key_str[a]
            self._key_str[a] = self._key_str[b]
            self._key_str[b] = tks^
        if len(self._missing) > 0:
            var tm = self._missing[a]
            self._missing[a] = self._missing[b]
            self._missing[b] = tm

    def _sift_up(mut self, start: Int):
        var i = start
        while i > 0:
            var parent = (i - 1) >> 1
            if self._less(i, parent):
                self._swap(i, parent)
                i = parent
            else:
                break

    def _sift_down(mut self, start: Int):
        var n = len(self._score)
        var i = start
        while True:
            var l = 2 * i + 1
            var r = 2 * i + 2
            var smallest = i
            if l < n and self._less(l, smallest):
                smallest = l
            if r < n and self._less(r, smallest):
                smallest = r
            if smallest == i:
                break
            self._swap(i, smallest)
            i = smallest

    def _append_entry(
        mut self,
        score: Float64,
        doc_id: Int,
        key_i64: Int64,
        key_f64: Float64,
        var key_str: String,
        missing: Bool,
    ):
        """Append a candidate to the parallel columns. Only the column matching
        `_mode` is populated (the others stay empty across the whole heap)."""
        self._score.append(score)
        self._id.append(doc_id)
        if self._mode == SORT_MODE_I64:
            self._key_i64.append(key_i64)
            self._missing.append(missing)
        elif self._mode == SORT_MODE_F64:
            self._key_f64.append(key_f64)
            self._missing.append(missing)
        elif self._mode == SORT_MODE_STR:
            self._key_str.append(key_str^)
            self._missing.append(missing)

    def _pop_tail(mut self):
        """Drop the last entry from EVERY populated column in lockstep."""
        _ = self._score.pop()
        _ = self._id.pop()
        if len(self._key_i64) > 0:
            _ = self._key_i64.pop()
        if len(self._key_f64) > 0:
            _ = self._key_f64.pop()
        if len(self._key_str) > 0:
            _ = self._key_str.pop()
        if len(self._missing) > 0:
            _ = self._missing.pop()

    def push(mut self, score: Float64, doc_id: Int):
        """SORT_MODE_SCORE / SORT_MODE_DOC fast path (no sort-key columns).

        PERF-CRITICAL: this MUST NOT route
        through `push_keyed`. Doing so (a) constructs+moves+drops a `String("")`
        on EVERY candidate — a per-posting heap-string ctor/dtor that the
        SCORE/DOC modes never store — and (b) on the heap-full path does an
        `_append_entry` + `_swap` + `_pop_tail` churn (two List grows + up to
        six List pops per offer) where an IN-PLACE root overwrite needs two
        scalar writes. On common-term queries the heap-full branch fires on
        nearly every posting, so that churn would dominate the score path
        (several times slower). This fast path
        is byte-identical in RANKING to `push_keyed` for SCORE/DOC (it reuses
        `_a_ranks_higher`) but touches only `_score`/`_id` and replaces the
        root in place. Do NOT 'simplify' it back into `push_keyed`.

        Only `_score`/`_id` are populated in SCORE/DOC mode (`_key_*` /
        `_missing` stay empty), so a dedicated 2-column path is sound — `_swap`
        / `_sift_*` / `_a_ranks_higher` all no-op the empty key columns."""
        if len(self._score) < self._cap:
            self._score.append(score)
            self._id.append(doc_id)
            self._sift_up(len(self._score) - 1)
            return
        # Heap full: rank the candidate against the root (the weakest survivor)
        # WITHOUT staging it at the tail. `_a_ranks_higher` over a virtual tail
        # entry would need the value present, so inline the SCORE/DOC compare
        # against the root's stored (score, id). Replace IN PLACE iff it wins.
        var wins: Bool
        if self._mode == SORT_MODE_SCORE:
            # The EXACT pre-sort "better": higher score, then lower doc_id.
            if score != self._score[0]:
                wins = score > self._score[0]
            else:
                wins = doc_id < self._id[0]
        else:  # SORT_MODE_DOC
            if doc_id != self._id[0]:
                var cand_smaller = doc_id < self._id[0]
                wins = (cand_smaller == (self._order == SORT_ASC))
            else:
                wins = False
        if wins:
            self._score[0] = score
            self._id[0] = doc_id
            self._sift_down(0)

    def push_keyed(
        mut self,
        score: Float64,
        doc_id: Int,
        key_i64: Int64,
        key_f64: Float64,
        var key_str: String,
        missing: Bool,
    ):
        """Offer a candidate to the bounded heap. If under capacity, insert + sift
        up. Else compare the candidate against the root (the weakest survivor):
        if the candidate ranks STRICTLY higher it evicts the root, else it is
        dropped.

        The root-evict comparison is the SAME mode-aware ranking as the heap
        sift (`_a_ranks_higher`). The candidate is STAGED at the tail (moving
        key_str in exactly ONCE), then ranked against the root. If stronger it is
        swapped into the root slot (all parallel columns move in lockstep via
        `_swap`) and the old root — now at the tail — is popped + the new root
        sifted down; otherwise the staged tail is popped off."""
        if len(self._score) < self._cap:
            self._append_entry(
                score, doc_id, key_i64, key_f64, key_str^, missing
            )
            self._sift_up(len(self._score) - 1)
            return
        # Heap full: stage the candidate at the tail, rank vs root.
        self._append_entry(score, doc_id, key_i64, key_f64, key_str^, missing)
        var cand = len(self._score) - 1
        if self._a_ranks_higher(cand, 0):
            # Candidate wins: move it into the root slot, drop the old root
            # (now at the tail), then restore the heap invariant.
            self._swap(0, cand)
            self._pop_tail()
            self._sift_down(0)
        else:
            # Candidate loses: discard the staged tail.
            self._pop_tail()

    def drain_descending(mut self) -> List[Int]:
        """Return the heap's entry-indices sorted by the configured ranking,
        STRONGEST first (the HitBatch row order). Selection sort over n entries
        (n <= from+size, small). After this call the heap content is consumed."""
        var n = len(self._score)
        var order = List[Int]()
        for i in range(n):
            order.append(i)
        for i in range(n):
            var best = i
            for j in range(i + 1, n):
                if self._a_ranks_higher(order[j], order[best]):
                    best = j
            var t = order[i]
            order[i] = order[best]
            order[best] = t
        return order^

    @always_inline
    def score_at(self, idx: Int) -> Float64:
        return self._score[idx]

    @always_inline
    def id_at(self, idx: Int) -> Int:
        return self._id[idx]

    # -------------------------------------------------------------------------
    # WAND: the running K-th-best-score reader the pivot loop's `θ` consumes. Read-ONLY —
    # NO ranking-logic change (push / _a_ranks_higher / tiebreak untouched). The
    # min-at-root invariant makes _score[0] the WEAKEST surviving candidate, i.e.
    # exactly the K-th best once the heap is full. The brute walk does not read
    # these (no skipping); the WAND walks do.
    # -------------------------------------------------------------------------
    @always_inline
    def is_full(self) -> Bool:
        """True once the heap holds its full capacity-K candidate set. Until then
        the WAND θ stays at its negative sentinel (no candidate can be skipped
        during warm-up)."""
        return len(self._score) >= self._cap

    @always_inline
    def root_score(self) -> Float64:
        """The score at the heap root — the WEAKEST surviving candidate (the
        min-at-root invariant). Valid as the WAND θ ONLY when `is_full()`; on an
        empty heap returns the most-negative finite sentinel so an unconditional
        read still degrades safely to 'skip nothing' (any real BM25 score, which
        is >= 0, exceeds it). NOTE: in SORT_MODE_SCORE the root is the K-th-best
        SCORE; in other sort modes the root ranks by the typed key, so θ-skipping
        is a SCORE-mode concept (the WAND eligibility gate restricts to
        SORT_MODE_SCORE)."""
        if len(self._score) == 0:
            return Float64.MIN_FINITE
        return self._score[0]

    # multi-split: typed sort-key accessors so the assembled page can surface the
    # per-row sort KEY (not just score/doc_id) for a cross-split fast-field-sorted
    # merge. Only the column matching `_mode` is populated; the merge reads the one
    # matching its sort mode. `missing_at` reports the null-bucket flag.
    @always_inline
    def key_i64_at(self, idx: Int) -> Int64:
        return self._key_i64[idx]

    @always_inline
    def key_f64_at(self, idx: Int) -> Float64:
        return self._key_f64[idx]

    def key_str_at(self, idx: Int) -> String:
        return self._key_str[idx]

    @always_inline
    def missing_at(self, idx: Int) -> Bool:
        return self._missing[idx] if len(self._missing) > 0 else False


# =============================================================================
# filter fast-field predicate eval (per-doc, intersected with the walk).
# =============================================================================
#
# The per-doc evaluator of the ACCEPTED pushed-down predicate (QueryIR.filter).
# The engine's vectorized Filter kernels operate on Arrow columns, not
# per-doc scalar fast-field reads. These helpers walk the SAME engine `Expr`
# vocabulary the gate (komira_search_scan's FastFieldPushdownGate) accepts, so
# the gate's accept-set == this eval-set.
#
# NULL handling (EXACT-only, load-bearing): a null cell (the scalar accessor
# returns None) FAILS the predicate (Arrow/OpenSearch three-valued logic) — so
# the pushdown is Exact (no false positives).
#
# PR2: for a DATE/TIMESTAMP fast-field the integer literal is read off date32_val
# (Int32) / ts_micros (Int64) per the literal's `_kind`, NOT int_val.
# =============================================================================


@always_inline
def _ff_literal_i64(v: ScalarValue) -> Int64:
    """The Int64 value of an integer-class literal, reading the discriminating
    field per its `_kind` (PR2). A DATE32 literal carries `date32_val` (Int32),
    a TIMESTAMP literal carries `ts_micros` (Int64); everything else uses the
    canonical `int_val`."""
    if v._kind == SCALAR_KIND_DATE32:
        return Int64(Int(v.date32_val))
    if v._kind == SCALAR_KIND_TIMESTAMP:
        return v.ts_micros
    return v.int_val


@always_inline
def _cmp_op_i64(op: UInt8, lhs: Int64, rhs: Int64) -> Bool:
    if op == BIN_EQ:
        return lhs == rhs
    elif op == BIN_NE:
        return lhs != rhs
    elif op == BIN_LT:
        return lhs < rhs
    elif op == BIN_LE:
        return lhs <= rhs
    elif op == BIN_GT:
        return lhs > rhs
    return lhs >= rhs  # BIN_GE


@always_inline
def _cmp_op_f64(op: UInt8, lhs: Float64, rhs: Float64) -> Bool:
    if op == BIN_EQ:
        return lhs == rhs
    elif op == BIN_NE:
        return lhs != rhs
    elif op == BIN_LT:
        return lhs < rhs
    elif op == BIN_LE:
        return lhs <= rhs
    elif op == BIN_GT:
        return lhs > rhs
    return lhs >= rhs  # BIN_GE


@always_inline
def _cmp_op_str(op: UInt8, lhs: String, rhs: String) -> Bool:
    # Only BIN_EQ / BIN_NE reach a keyword field (the gate rejects keyword range).
    if op == BIN_EQ:
        return lhs == rhs
    return lhs != rhs  # BIN_NE


def _resolve_colref_literal(
    pred: Expr,
) raises -> Tuple[String, ScalarValue, Bool]:
    """Resolve a comparison's (col-ref name, literal value, is_left_col) from a
    BINARY_OP whose two arms are one bare col-ref + one literal (either order —
    matching the order-insensitive gate). Returns (name, literal, _) — the third
    flag is unused by the eval but kept for clarity. Raises (fail-loud) if the
    shape is not col-op-literal (the gate should never let this through)."""
    ref l = pred.binary_left_ref()
    ref r = pred.binary_right_ref()
    if l.tag == EXPR_COL_REF and r.tag == EXPR_LITERAL:
        return (l.col_ref_name(), r.literal_value(), True)
    if r.tag == EXPR_COL_REF and l.tag == EXPR_LITERAL:
        return (r.col_ref_name(), l.literal_value(), False)
    raise Error(
        "SearchCore: pushed comparison is not col-op-literal (gate/apply"
        " mismatch)"
    )


# =============================================================================
# _FilterResolvers: the per-query FILTER field header-resolve registry.
#
# PERF-CRITICAL (FF-header pre-resolve): calling
# reader.fast_field_{keyword,i64,f64} for EVERY conjunct on EVERY candidate doc
# would re-parse the sub-region header per call (and the keyword accessor would
# re-allocate term_bounds + walk the whole dict, per doc).
# This registry walks the predicate ONCE up front, resolves each DISTINCT
# referenced field's header into a per-field resolver, and the eval then reads
# via the resolver in O(1). Byte-identical survivor set (same class dispatch,
# same null-fails-predicate three-valued logic, same eq/ne/lt comparisons).
# =============================================================================


struct _FilterResolvers(Movable, Deinitable):
    """One pre-resolved handle per DISTINCT fast-field referenced in the filter.
    Parallel-indexed lists keyed by `_names`. `_is_keyword` selects the keyword
    resolver; otherwise `_is_float` selects float vs i64. trivial (POD
    scalars + String names + the resolvers' own POD/term_bounds; a stack value,
    never a byte-slab element). Holds NO Span field."""

    var _names: List[String]
    var _is_keyword: List[Bool]
    var _is_float: List[Bool]
    var _kw: List[Optional[KeywordFastFieldResolver]]
    var _num: List[Optional[NumericFastFieldResolver]]
    var _flt: List[Optional[FloatFastFieldResolver]]

    def __init__(out self):
        self._names = List[String]()
        self._is_keyword = List[Bool]()
        self._is_float = List[Bool]()
        self._kw = List[Optional[KeywordFastFieldResolver]]()
        self._num = List[Optional[NumericFastFieldResolver]]()
        self._flt = List[Optional[FloatFastFieldResolver]]()

    def _index_of(self, name: String) -> Int:
        for i in range(len(self._names)):
            if self._names[i] == name:
                return i
        return -1

    def _ensure(
        mut self, reader: FastFieldReader, view: SplitView, name: String
    ) raises:
        """Resolve `name`'s sub-region header ONCE (idempotent — a no-op if it is
        already in the registry). Dispatch on the field class/encoding exactly as
        the per-doc accessor did (keyword -> keyword resolver; float field ->
        float resolver; int/date -> numeric resolver)."""
        if self._index_of(name) >= 0:
            return
        var fc = reader.field_class_of(name)
        if fc == FIELD_CLASS_KEYWORD:
            self._names.append(name.copy())
            self._is_keyword.append(True)
            self._is_float.append(False)
            self._kw.append(reader.keyword_resolver(view, name))
            self._num.append(None)
            self._flt.append(None)
        elif _ff_encoding_of(reader, name) == FF_ENC_FLOAT_FULL:
            self._names.append(name.copy())
            self._is_keyword.append(False)
            self._is_float.append(True)
            self._kw.append(None)
            self._num.append(None)
            self._flt.append(reader.float_resolver(view, name))
        else:
            self._names.append(name.copy())
            self._is_keyword.append(False)
            self._is_float.append(False)
            self._kw.append(None)
            self._num.append(reader.numeric_resolver(view, name))
            self._flt.append(None)


def _collect_filter_fields(
    mut acc: _FilterResolvers,
    reader: FastFieldReader,
    view: SplitView,
    pred: Expr,
) raises:
    """Walk the accepted pushed-down predicate ONCE and resolve every distinct
    referenced fast-field into `acc`. Mirrors the _eval_ff_predicate shape exactly
    (BIN_AND recurses both arms; a comparison resolves its col-ref; IN resolves
    its child col-ref)."""
    if pred.tag == EXPR_BINARY_OP:
        var op = pred.binary_op()
        if op == BIN_AND:
            _collect_filter_fields(acc, reader, view, pred.binary_left_ref())
            _collect_filter_fields(acc, reader, view, pred.binary_right_ref())
            return
        var rl = _resolve_colref_literal(pred)
        acc._ensure(reader, view, rl[0])
    elif pred.tag == EXPR_IN_LIST:
        ref child = pred.in_list_child_ref()
        if child.tag != EXPR_COL_REF:
            raise Error(
                "SearchCore: IN child is not a col-ref (gate/apply mismatch)"
            )
        acc._ensure(reader, view, child.col_ref_name())
    else:
        raise Error(
            "SearchCore: unsupported pushed predicate shape (gate/apply mismatch)"
        )


def _eval_ff_compare(
    res: _FilterResolvers, view: SplitView, pred: Expr, doc_id: Int
) raises -> Bool:
    """Evaluate one comparison conjunct via the PRE-RESOLVED field handle.
    Byte-identical to the per-doc-accessor path: KEYWORD -> keyword resolver
    (string eq/ne); float field -> f64 compare; int/date -> i64 compare. A null
    cell FAILS the predicate (three-valued logic, EXACT-only)."""
    var rl = _resolve_colref_literal(pred)
    var name = rl[0].copy()
    var lit = rl[1].copy()
    var op = pred.binary_op()
    var fi = res._index_of(name)
    if fi < 0:
        raise Error(
            "SearchCore: filter field '" + name + "' not pre-resolved"
            " (collect/eval mismatch)"
        )
    if res._is_keyword[fi]:
        var cell = res._kw[fi].value().keyword_at(view, doc_id)
        if not cell:
            return False  # null cell fails (three-valued logic).
        return _cmp_op_str(op, cell.value(), lit.string_val)
    if res._is_float[fi]:
        var fcell = res._flt[fi].value().f64_at(view, doc_id)
        if not fcell:
            return False
        return _cmp_op_f64(op, fcell.value(), lit.float_val)
    var icell = res._num[fi].value().i64_at(view, doc_id)
    if not icell:
        return False
    return _cmp_op_i64(op, icell.value(), _ff_literal_i64(lit))


def _eval_ff_in_list(
    res: _FilterResolvers, view: SplitView, pred: Expr, doc_id: Int
) raises -> Bool:
    """Evaluate `col IN (lit, ...)` via the pre-resolved field handle — eq-union.
    KEYWORD/NUMERIC/DATE only (the gate). A null cell fails."""
    ref child = pred.in_list_child_ref()
    if child.tag != EXPR_COL_REF:
        raise Error("SearchCore: IN child is not a col-ref (gate/apply mismatch)")
    var name = child.col_ref_name()
    var fi = res._index_of(name)
    if fi < 0:
        raise Error(
            "SearchCore: filter field '" + name + "' not pre-resolved"
            " (collect/eval mismatch)"
        )
    ref vals = pred.in_list_values_ref()
    if res._is_keyword[fi]:
        var cell = res._kw[fi].value().keyword_at(view, doc_id)
        if not cell:
            return False
        for i in range(len(vals)):
            if cell.value() == vals[i].string_val:
                return True
        return False
    # NUMERIC / DATE (IN reads via i64 — the gate admits only int/date/keyword IN).
    var icell = res._num[fi].value().i64_at(view, doc_id)
    if not icell:
        return False
    for i in range(len(vals)):
        if icell.value() == _ff_literal_i64(vals[i]):
            return True
    return False


def _eval_ff_predicate(
    res: _FilterResolvers, view: SplitView, pred: Expr, doc_id: Int
) raises -> Bool:
    """Recursively evaluate the accepted pushed-down predicate against one
    doc_id's fast-field cells via the PRE-RESOLVED registry. BIN_AND -> both sides
    (intersection). A comparison -> _eval_ff_compare. EXPR_IN_LIST ->
    _eval_ff_in_list. Any other shape is a gate/apply mismatch -> RAISE."""
    if pred.tag == EXPR_BINARY_OP:
        var op = pred.binary_op()
        if op == BIN_AND:
            return _eval_ff_predicate(
                res, view, pred.binary_left_ref(), doc_id
            ) and _eval_ff_predicate(
                res, view, pred.binary_right_ref(), doc_id
            )
        return _eval_ff_compare(res, view, pred, doc_id)
    elif pred.tag == EXPR_IN_LIST:
        return _eval_ff_in_list(res, view, pred, doc_id)
    raise Error("SearchCore: unsupported pushed predicate shape (gate/apply mismatch)")


# =============================================================================
# sort-key mode resolution.
# =============================================================================


def _ff_encoding_of(reader: FastFieldReader, name: String) raises -> UInt8:
    """The encoding byte for fast-field `name` (FF_ENC_FLOAT_FULL marks a float
    field), walking the public entry_meta_at accessor. RAISES if absent."""
    for i in range(reader.num_fields()):
        var m = reader.entry_meta_at(i)
        if m[0] == name:
            return m[2]
    raise Error("SearchCore: no fast-field named '" + name + "' (gate/apply mismatch)")


def _resolve_sort_mode(
    reader: FastFieldReader, sort_field: String
) raises -> UInt8:
    """Resolve the heap comparison mode for a fast-field sort target. KEYWORD ->
    STR; NUMERIC float -> F64; NUMERIC/DATE integer -> I64 (DATE flows through
    the i64 accessor). RAISES on a non-fast-field / wrong class — but the shim
    gate rejects those BEFORE search() runs, so a raise here is a
    gate/apply-mismatch invariant violation, not a user-facing path."""
    var fc = reader.field_class_of(sort_field)
    if fc == FIELD_CLASS_KEYWORD:
        return SORT_MODE_STR
    # NUMERIC / DATE: float vs int by the field's encoding.
    if _ff_encoding_of(reader, sort_field) == FF_ENC_FLOAT_FULL:
        return SORT_MODE_F64
    return SORT_MODE_I64


# =============================================================================
# The in-leaf aggregation pass (over the FULL `touched` matched set).
# =============================================================================
#
# The raise trap (the load-bearing decision): a metric agg's read accessor
# is dispatched by the field's ENCODING resolved ONCE before the touched loop
# (mirroring _resolve_sort_mode) — `fast_field_f64` for a float field,
# `fast_field_i64` for int/date. Calling the WRONG accessor RAISES by contract
# (FastFieldReader.fast_field_i64 / fast_field_f64), so the per-doc loop must already know which to
# call. A `terms` agg reads the field's CLASS once (keyword -> string key;
# numeric/date -> stringified numeric key).
#
# `terms` `missing` is a SUBSTITUTE key folded into the SAME bucket directory
# (a null cell reads AS the missing string), NOT a distinct null-bucket type.
# An empty `missing` ("") drops null cells.


@always_inline
def _is_float_metric_field(reader: FastFieldReader, name: String) raises -> Bool:
    """True iff the metric field is a float fast-field (dispatch f64), else int/
    date (dispatch i64). Resolved ONCE per metric agg."""
    return _ff_encoding_of(reader, name) == FF_ENC_FLOAT_FULL


def _bucket_index(buckets: List[_TermBucket], key: String) -> Int:
    """Linear find of `key` in the bucket directory (bounded by the dict size,
    small per-split). Returns -1 if absent."""
    for i in range(len(buckets)):
        if buckets[i].key == key:
            return i
    return -1


def _terms_key_resolved(
    kw_res: Optional[KeywordFastFieldResolver],
    num_res: Optional[NumericFastFieldResolver],
    view: SplitView,
    spec: AggSpec,
    doc_id: Int,
) raises -> Optional[String]:
    """Read the `terms` cell at `doc_id` via a PRE-RESOLVED per-field handle and
    stringify it to a bucket key. Byte-identical to the per-doc-accessor path:
    keyword cells ship the string verbatim; numeric/date cells ship the integer
    stringified. Returns None for a null cell AND an empty `missing` (drop the
    doc); a non-empty `missing` substitutes the key."""
    if kw_res:
        var cell = kw_res.value().keyword_at(view, doc_id)
        if cell:
            return Optional[String](cell.value())
    elif num_res:
        var celli = num_res.value().i64_at(view, doc_id)
        if celli:
            return Optional[String](String(celli.value()))
    # Null cell: substitute the `missing` key, or drop if `missing` is empty.
    if spec.missing.byte_length() > 0:
        return Optional[String](spec.missing)
    return Optional[String](None)


def _finalize_terms(mut res: AggResult, spec: AggSpec) raises:
    """Post-walk shaping for one terms result: filter by min_doc_count,
    sort by order_code, truncate to bucket_size, and compute the EXACT
    sum_other_doc_count from the dropped tail. Also records
    `last_bucket_doc_count` — the doc_count of the LAST (smallest) bucket this
    split RETURNED, but ONLY when this split DROPPED a bucket (kept > size); it
    is the per-split error contribution the coordinator sums for the count-desc
    `doc_count_error_upper_bound`. On a single split the
    rendered `doc_count_error_upper_bound` stays 0 (no other shard to miss terms
    from); the merge reducer computes the cross-split bound."""
    # min_doc_count filter (default 1 already excludes 0-count, which can't occur
    # here since a bucket exists only because >=1 doc landed in it).
    var kept = List[_TermBucket]()
    for i in range(len(res.buckets)):
        if res.buckets[i].doc_count >= spec.min_doc_count:
            kept.append(res.buckets[i].copy())

    # Sort by the order key (insertion sort — bucket cardinality is small/bounded
    # by the dict size). Stable on ties is not required (ES does not guarantee
    # tie order), but we keep a deterministic key tiebreak for reproducibility.
    for i in range(1, len(kept)):
        var cur = kept[i].copy()
        var j = i - 1
        while j >= 0 and _terms_bucket_less(cur, kept[j], spec.order_code):
            kept[j + 1] = kept[j].copy()
            j -= 1
        kept[j + 1] = cur^

    # Truncate to bucket_size; the dropped tail's doc_count sums into
    # sum_other_doc_count (EXACT — nothing approximated on a single split).
    var size = spec.bucket_size if spec.bucket_size >= 0 else 0
    var other = 0
    var top = List[_TermBucket]()
    for i in range(len(kept)):
        if i < size:
            top.append(kept[i].copy())
        else:
            other += kept[i].doc_count
    res.buckets = top^
    res.sum_other_doc_count = other
    # multi-split: record the per-split error contribution. This split DROPPED a
    # bucket iff more buckets survived the min_doc_count filter than the requested
    # `size` — then the LAST returned (smallest, post-sort-tail) bucket's
    # doc_count is the most a missing term could have had here without appearing.
    # NOTE this is the LAST RETURNED bucket regardless of order_code (the
    # smallest-count bucket the split surfaced); the order-dependent semantics
    # (count-desc sum vs key-order 0 vs count-asc -1) are applied by the merge
    # reducer, NOT here. Distinct from sum_other_doc_count (the dropped TAIL's
    # total) — the error bound is a SINGLE bucket's count, never the tail sum, so
    # they are not double-counted.
    if len(kept) > size and len(res.buckets) > 0:
        res.last_bucket_doc_count = res.buckets[len(res.buckets) - 1].doc_count
    else:
        res.last_bucket_doc_count = 0


def _terms_bucket_less(
    a: _TermBucket, b: _TermBucket, order_code: UInt8
) -> Bool:
    """`a` sorts BEFORE `b` under `order_code`. _count desc/asc with a `_key` asc
    tiebreak for determinism; `_key` asc/desc with a doc_count desc tiebreak."""
    if order_code == AGG_ORDER_COUNT_DESC:
        if a.doc_count != b.doc_count:
            return a.doc_count > b.doc_count
        return a.key < b.key
    if order_code == AGG_ORDER_COUNT_ASC:
        if a.doc_count != b.doc_count:
            return a.doc_count < b.doc_count
        return a.key < b.key
    if order_code == AGG_ORDER_KEY_ASC:
        if a.key != b.key:
            return a.key < b.key
        return a.doc_count > b.doc_count
    # AGG_ORDER_KEY_DESC
    if a.key != b.key:
        return a.key > b.key
    return a.doc_count > b.doc_count


def _run_aggs(
    specs: List[AggSpec],
    reader: FastFieldReader,
    view: SplitView,
    touched: List[Int],
) raises -> AggResults:
    """Compute every leaf agg over the FULL `touched` matched set (independent of
    from/size/top-k). Each metric agg is O(len(touched)) with O(1) state; each
    `terms` agg keeps a bounded bucket directory. The metric float/int
    dispatch is resolved ONCE per agg before the per-doc loop."""
    var out = List[AggResult]()
    # PERF-CRITICAL (FF-header pre-resolve): resolve each agg
    # field's sub-region header ONCE here (per agg-field, cached for this pass)
    # instead of re-parsing it inside the per-doc accessor. The keyword accessor
    # in particular would allocate a `term_bounds: List[Int]` + walk the whole
    # dict PER MATCHED DOC (a large share of a terms-agg query's time); the
    # resolver parses that header once and the per-doc read is a
    # single bitpack-window unpack — byte-identical buckets/metrics. The raise trap still
    # holds: the metric float/int dispatch is decided ONCE (here, by which
    # resolver we build), so the per-doc loop never calls a wrong accessor.
    var kw_res = List[Optional[KeywordFastFieldResolver]]()
    var num_res = List[Optional[NumericFastFieldResolver]]()
    var flt_res = List[Optional[FloatFastFieldResolver]]()
    for s in range(len(specs)):
        ref spec = specs[s]
        out.append(AggResult(spec.name.copy(), spec.kind))
        if spec.is_metric():
            # Metric: float field -> float resolver; int/date -> numeric resolver.
            if _is_float_metric_field(reader, spec.field):
                kw_res.append(None)
                num_res.append(None)
                flt_res.append(reader.float_resolver(view, spec.field))
            else:
                kw_res.append(None)
                num_res.append(reader.numeric_resolver(view, spec.field))
                flt_res.append(None)
        else:  # terms: keyword -> keyword resolver; numeric/date -> i64 resolver.
            flt_res.append(None)
            if reader.field_class_of(spec.field) == FIELD_CLASS_KEYWORD:
                kw_res.append(reader.keyword_resolver(view, spec.field))
                num_res.append(None)
            else:
                kw_res.append(None)
                num_res.append(reader.numeric_resolver(view, spec.field))

    # The single pass over the full matched set.
    for ti in range(len(touched)):
        var doc_id = touched[ti]
        for s in range(len(specs)):
            ref spec = specs[s]
            if spec.is_metric():
                # Read the cell (widen i64 -> Float64 for accumulation).
                var v: Float64 = 0.0
                var present = False
                if flt_res[s]:
                    var cf = flt_res[s].value().f64_at(view, doc_id)
                    if cf:
                        v = cf.value()
                        present = True
                else:
                    var ci = num_res[s].value().i64_at(view, doc_id)
                    if ci:
                        v = Float64(ci.value())
                        present = True
                if present:
                    ref r = out[s]
                    if not r.has_value:
                        r.min = v
                        r.max = v
                    else:
                        if v < r.min:
                            r.min = v
                        if v > r.max:
                            r.max = v
                    r.sum += v
                    r.count += 1
                    r.has_value = True
            else:  # terms
                var key_opt = _terms_key_resolved(
                    kw_res[s], num_res[s], view, spec, doc_id
                )
                if key_opt:
                    var key = key_opt.value()
                    ref r = out[s]
                    var bi = _bucket_index(r.buckets, key)
                    if bi < 0:
                        r.buckets.append(_TermBucket(key^, 1))
                    else:
                        r.buckets[bi].doc_count += 1

    # Post-walk shaping for terms aggs.
    for s in range(len(specs)):
        if not specs[s].is_metric():
            _finalize_terms(out[s], specs[s])

    return AggResults(out^)


# =============================================================================
# WAND Phase 1 (term-max top-K score-skipping).
# =============================================================================
#
# DAAT (doc-at-a-time) traversal that EXACTLY reproduces the brute-force top-K
# (byte-identical doc-ids, BIT-exact f64 scores, identical tiebreak +
# total_matches) while SKIPPING the expensive per-doc scoring of docs that
# provably cannot enter the top-K.
#
# THE BOUND (the part that must be exactly right). For one term `t`:
#
#   term_max_impact(t) = idf(t) * f(max_tf, min_dl)
#   f(tf, dl)          = tf / (tf + k1*(1 - b + b*dl/avgdl))   (modern, default)
#
# f is monotone-INCREASING in tf and monotone-DECREASING in dl (bm25_tf_component),
# so pairing the most-favorable tf (the WHOLE-list max_tf) with the
# most-favorable dl (the WHOLE-list min_dl) over-estimates EVERY real doc in the
# list: f(max_tf, min_dl) >= f(tf_d, dl_d) for all d. Multiplied by idf (>= 0,
# bm25_idf) the product is a TRUE UPPER bound on term `t`'s contribution to any
# doc. We compute it via the SAME bm25_score_contribution the scorer uses
# (max_tf, min_dl) so the bound tracks the live scorer's degrade rule EXACTLY
# (b!=0 + usable avgdl -> the dl/avgdl form; else norm=1.0). The
# `norm=1.0`-degrade safety (a doc with a missing/zero dl cell) is covered
# because dl=0 is the SMALLEST dl, and a smaller dl can only RAISE f -> the
# min_dl bound already rounds up over it (a missing cell reads dl=0 here too).
#
# THE SKIP (correctness-critical). A candidate doc's upper bound is the
# SUM of term_max_impact over the terms that match it. Skip the doc's full
# scoring ONLY when that sum is STRICTLY < theta (the running K-th-best score,
# _TopKHeap.root_score() once is_full()). A doc whose upper bound == theta is
# NOT skipped (it may tie the K-th best and win on the lower-doc-id tiebreak).
#
# THE FLOAT-ORDER PIN. The brute path sums acc[slot] += contribution in
# dedup-TERM order (the outer term loop, source.mojo accumulate). Float add is
# non-associative, so a scored doc's contributions MUST be summed in the SAME
# dedup-term order. We achieve this by accumulating into the SAME dense `acc`
# array in the SAME term-major order the brute path uses: WAND decides PER DOC
# whether to score it, but when it scores, it adds each term's contribution to
# acc[slot] in dedup-term order -> bit-identical sum.
#
# EXACTNESS of total_matches. WAND still VISITS every candidate doc (the DAAT
# merge touches every posting), so `touched` is the exact same set the brute
# path produces; only the per-doc BM25 contribution + fieldnorm read + the
# (losing) heap churn are skipped for sub-theta docs. total_matches is exact.
# =============================================================================


@always_inline
def _term_max_impact(
    idf: Float64,
    max_tf: Int,
    min_dl: Int,
    params: Bm25Params,
    avgdl: Float64,
) -> Float64:
    """A TRUE UPPER bound on term `t`'s BM25 contribution to ANY doc in its
    posting list: idf * f(max_tf, min_dl). Computed via the SAME
    bm25_score_contribution the scorer uses so the bound mirrors the live
    per-doc degrade rule (modern dl/avgdl form when b!=0 + avgdl>0; norm=1.0
    otherwise). min_dl is the most-favorable (smallest) doc length over the
    list (f decreases in dl); a missing/zero dl cell reads dl=0 here, which is
    <= any real dl, so the bound already rounds UP over the scorer's per-doc
    norm=1.0 degrade. idf >= 0 (bm25_idf) so the product stays a valid bound."""
    return bm25_score_contribution(
        idf, max_tf, params, doc_len=min_dl, avg_doc_len=avgdl
    )


comptime WAND_MODE_BRUTE: UInt8 = 0
"""_search_impl wand_mode: NO skipping — the exact term-major brute union walk
(the apples-to-apples baseline)."""

comptime WAND_MODE_PHASE1: UInt8 = 1
"""_search_impl wand_mode: Phase-1 term-max WAND (the PRODUCTION default — the
fastest scorer on log-search workloads)."""

comptime WAND_MODE_BMW: UInt8 = 2
"""_search_impl wand_mode: Phase-2 BMW block-max (forced, when eligible). Proven
byte-identical; available for long-posting workloads where its decode-skip
exceeds the per-block bookkeeping. Not the production default."""


comptime BMW_SKEW_FACTOR: Int = 8
"""WAND Phase 2 (BMW) idf-skew gate threshold. BMW engages only when the rarest
present query term's doc_freq * BMW_SKEW_FACTOR < the commonest's doc_freq (a
clearly-dominant rare term -> theta lifts above the common term's per-block
bounds -> blocks are decode-skippable). On a non-skewed all-common query the
block-cursor bookkeeping is pure overhead with no skip, so we fall back to the
byte-identical Phase-1 term-max WAND (no-regression on near-all-match). 8 cleanly
separates the rare+common (ratio >> 8) from the common+common (ratio ~1) regimes;
the result is byte-identical EITHER way — this only picks the faster path."""


@always_inline
def _bmw_block_count(doc_freq: Int, block: Int, nblocks: Int) -> Int:
    """WAND Phase 2: the number of docs in block `block` of a `doc_freq`-doc
    posting list (nblocks == ceil(doc_freq/128)). Every block but the last is a
    full POSTING_BLOCK_DOCS; the last is the remainder. Self-describing given
    doc_freq (matches the codec's block-slicing contract in split.mojo)."""
    if block < nblocks - 1:
        return POSTING_BLOCK_DOCS
    return doc_freq - block * POSTING_BLOCK_DOCS


def _bmw_read_doc_count(
    region: Span[UInt8, _], poff: Int, plen: Int
) raises -> Tuple[Int, Int]:
    """WAND Phase 2: read the leading doc_count ULEB of a term's posting region.
    Returns (doc_count, post_doc_count_rel) where post_doc_count_rel is the byte
    offset, RELATIVE to `poff`, of the first byte AFTER the doc_count ULEB — the
    base the BLOCKMAX `block_byte_offset` entries are relative to."""
    if poff < 0 or plen < 0 or poff + plen > len(region):
        raise Error("_bmw_read_doc_count: posting region out of bounds")
    var end = poff + plen
    var dc_res = _read_uleb128_span(region, poff, end)
    var doc_count = dc_res[0]
    if doc_count < 0:
        raise Error("_bmw_read_doc_count: negative doc_count (corrupt)")
    return (doc_count, dc_res[1] - poff)


# =============================================================================
# SearchCore: the Movable-only single-split read core.
# =============================================================================


struct SearchCore(Movable, Deinitable):
    """The read-side core: a PRE-PARSED SplitView + a deserialized
    TermDictionary, both built at CONSTRUCTION. `search(self)` is an
    IMMUTABLE-self READ over the owned SplitView + TermDictionary — you cannot
    move bytes out of an immutable self, so the parse/deserialize happen once at
    construction, NOT in search().

    Movable-only (owns a SplitView + a TermDictionary, both Movable-only). A
    stack value / OwnedPointer field, never a byte-slab element.

    Fields:
      _view: the parsed SplitView (owns the split bytes; region accessors return
             Spans tied to its inner field).
      _term_dict: the deserialized TermDictionary (owns a COPY of the term-dict
             region bytes — TermDictionary.deserialize consumes owned bytes).
    """

    var _view: SplitView
    var _term_dict: TermDictionary
    var _blockmax: Optional[BlockMaxIndex]
    """WAND Phase 2 (BMW): the parsed BLOCKMAX skip-list, deserialized ONCE at
    construction. None on a split written by an older writer / with no usable
    fieldnorm (the scorer falls back to Phase-1 term-max WAND / brute)."""

    def __init__(out self, var split_bytes: List[UInt8]) raises:
        """Parse the split footer-first + deserialize the term-dict ONCE, at
        construction. `SplitView.parse` consumes the owned `split_bytes`
        (fail-loud). The term-dict region is a borrowed Span
        over the parsed view, so it is COPIED into an owned List before
        `TermDictionary.deserialize` (which takes owned bytes).

        WAND Phase 2: if the split carries a BLOCKMAX region, deserialize it once
        here so search() has the per-block skip-list ready (parse-once, not
        per-query). An old split (has_blockmax() False) leaves _blockmax None and
        the scorer falls back to Phase-1 term-max WAND.

        Raises if the split carries an `l0_posting` region (see `from_view`)."""
        self = SearchCore.from_view(SplitView.parse(split_bytes^))

    @staticmethod
    def from_view(var view: SplitView) raises -> SearchCore:
        """Build a SearchCore from an ALREADY-PARSED SplitView (a caller that has
        already parsed the footer, such as komira_search_scan, hands the view in
        here and avoids a second footer parse). Identical to the bytes ctor
        minus the SplitView.parse. The term-dict region is COPIED into an owned
        List before TermDictionary.deserialize; the BLOCKMAX region (if
        present) is deserialized ONCE.

        Raises if the split carries an `l0_posting` region
        (`view.has_l0_posting()`). SearchCore reads postings only through the
        term dictionary and the postings region; it has no reader for the
        l0_posting region, so on such a split every query would return 0 hits.
        It refuses the split instead of answering from the wrong region."""
        if view.has_l0_posting():
            raise Error(
                "SearchCore: split carries an l0_posting region ("
                + String(view.l0_posting_len())
                + " bytes); SearchCore reads only the term dictionary and"
                " postings regions and has no l0_posting reader, so it"
                " refuses the split rather than return 0 hits"
            )
        var td_region = view.term_dict_region()
        var td_bytes = List[UInt8](capacity=len(td_region))
        for i in range(len(td_region)):
            td_bytes.append(td_region[i])
        var term_dict = TermDictionary.deserialize(td_bytes^)
        var blockmax: Optional[BlockMaxIndex] = None
        if view.has_blockmax():
            blockmax = BlockMaxIndex.deserialize(view.blockmax_region())
        return SearchCore(view^, term_dict^, blockmax^)

    def __init__(
        out self,
        var view: SplitView,
        var term_dict: TermDictionary,
        var blockmax: Optional[BlockMaxIndex],
    ):
        """The field-wise ctor (the from_view delegate). Takes the pre-parsed
        view + pre-deserialized term-dict + optional blockmax."""
        self._view = view^
        self._term_dict = term_dict^
        self._blockmax = blockmax^

    @always_inline
    def doc_count(self) -> Int:
        """The split's BM25 N (number of docs)."""
        return self._view.doc_count()

    @always_inline
    def min_doc_id(self) -> Int:
        """The doc-store slot base (slot = doc_id - min_doc_id)."""
        return self._view.min_doc_id()

    @always_inline
    def field_name(self) -> String:
        return self._view.field_name()

    def search(self, query: QueryIR) raises -> SearchResult:
        """The PRODUCTION single-split read path. WAND score-skipping is ENABLED
        (transparently byte-identical top-K). The scorer is the Phase-1 term-max
        DAAT (`_wand_accumulate`).

        Phase 2 (BMW) NOTE: the BLOCKMAX codec + the BMW block-max scorer
        (`_bmw_accumulate`) are PROVEN byte-identical (the equivalence test
        asserts search == search_bmw == brute), but BMW is NOT the production
        default BECAUSE it does NOT beat Phase-1 term-max WAND on log-search
        workloads: BMW's only decode-skip is the TF sub-block unpack (tiny on log
        data where tf is ~1-2), while the doc-id decode is UNAVOIDABLE for the
        exact total_matches union — so BMW's per-block bookkeeping costs more
        than it saves on short documents. The BMW path stays available + tested
        for long-posting / high-tf-variance workloads where the
        block-decode-skip exceeds the bookkeeping; `search_bmw` forces it."""
        return self._search_impl(query, WAND_MODE_PHASE1)

    def search_bmw(self, query: QueryIR) raises -> SearchResult:
        """Force the Phase-2 BMW block-max scorer (when the split carries BLOCKMAX
        + the idf-skew gate holds). Byte-identical to `search` / `search_no_wand`
        (proven by the equivalence gate). Used by the equivalence/perf harness to
        exercise + measure the BMW path directly."""
        return self._search_impl(query, WAND_MODE_BMW)

    def search_no_wand(self, query: QueryIR) raises -> SearchResult:
        """The brute-force baseline path (WAND DISABLED): the exact term-major
        union accumulate over EVERY matching doc, no skipping. Used by the
        equivalence/perf benches as the apples-to-apples baseline against the
        WAND path on the SAME query. Returns a byte-identical SearchResult to
        `search` (WAND only changes WHICH docs pay the full BM25 contribution,
        never the final top-K)."""
        return self._search_impl(query, WAND_MODE_BRUTE)

    def _search_impl(
        self, query: QueryIR, wand_mode: UInt8
    ) raises -> SearchResult:
        """The PURE single-split read path. Returns a SearchResult
        (the HitBatch RecordBatch — `_score Float64`, `_id Int64`,
        `_source STRING` — PLUS the true `total_matches`). An empty result (no
        query terms present in the split) returns a 0-row HitBatch (still
        schema-valid) with `total_matches == 0`.

        the ranking key, heap capacity, and page slice come off the
        QueryIR sort/page fields:
          * sort_field "" or "_score" -> SORT_MODE_SCORE (the EXACT pre-sort
            zero-cost BM25 path);
          * "_doc" -> SORT_MODE_DOC (doc-id order, honoring sort_order);
          * a fast-field name -> the typed sort key (read once per touched doc at
            heap-insert time via the SAME filter FastFieldReader);
        the heap capacity is `from_offset + top_k`, and the drain is sliced
        `[from_offset, min(len, from_offset+top_k))`. `total_matches` is
        `len(touched)` regardless of the page slice.

        IMMUTABLE self: reads over the pre-parsed SplitView + TermDictionary.
        No mutation, no move-out — safe to call from N concurrent workers through
        a shared borrow (the MorselSourceImpl immutable-borrow contract; the
        single-shot cursor lives on the higher-package reader).
        """
        var big_n = self._view.doc_count()
        var min_id = self._view.min_doc_id()
        var params = Bm25Params()  # modern BM25, Lucene/OpenSearch default b=0.75.

        # ---- sort: resolve the sort mode (branch, do NOT universally rewrite) --
        # sort_field "" / "_score" -> SORT_MODE_SCORE (zero-cost default); "_doc"
        # -> SORT_MODE_DOC; any other name -> a fast-field typed key.
        var sort_field = query.sort_field
        var fast_field_sort = (
            sort_field.byte_length() > 0
            and sort_field != SORT_FIELD_SCORE
            and sort_field != SORT_FIELD_DOC
        )

        # ---- filter/sort: build the fast-field reader ONCE iff a filter is pushed,
        # a fast-field sort is requested, aggs are requested, OR BM25
        # b>0 doc-length normalization needs the per-doc fieldnorm. The reader
        # holds NO Span field (clean, N-worker safe over the immutable
        # view); parses the THFF sub-dir once, O(num_fields).
        var need_fieldnorm = params.b != 0.0 and self._view.has_fastfields()
        var ff_opt: Optional[FastFieldReader] = None
        if (
            query.has_filter()
            or fast_field_sort
            or query.has_aggs()
            or need_fieldnorm
        ):
            ff_opt = FastFieldReader(self._view)

        # ---- fast-fields: resolve the per-split `avgdl` + the per-doc fieldnorm (`dl`)
        # source for the BM25 b>0 doc-length-normalization denominator.
        #
        # PERF-CRITICAL (query-latency-scales-with-match, not index): when the
        # split footer carries the per-split total token count (the O(1)-avgdl
        # writer), read `avgdl = total_token_count / doc_count` in O(1) and read
        # each matched doc's `dl` via the O(1) FieldnormResolver — so the cost is
        # O(matched), not O(doc_count). Summing the whole "__fieldnorm__" column
        # per query (the FALLBACK below) made warm match p50 scale with the index
        # size, and the cost multiplied across the splits of a multi-split search.
        # The avgdl value is IDENTICAL either way (sum/doc_count) — pure perf,
        # byte-identical scores.
        #
        # FALLBACK (split WITHOUT the footer total — written by an older writer):
        # the legacy fieldnorms() path decodes + sums the whole column once and
        # the accumulate loop indexes `fieldnorm_dls[slot]` O(1) per posting. A
        # split WITHOUT a "__fieldnorm__" field (a fieldnorm-less
        # split) leaves avgdl=0.0, and the scorer's avg_doc_len>0 guard degrades
        # that doc to b=0 behavior (norm=1.0) — no crash, no div-by-zero.
        var fieldnorm_dls = List[Int]()
        var fn_resolver: Optional[FieldnormResolver] = None
        var avgdl = 0.0
        if need_fieldnorm and ff_opt.value().has_field(FIELDNORM_NAME):
            if (
                self._view.has_total_token_count()
                and self._view.doc_count() > 0
            ):
                # O(1) avgdl from the footer + O(1)-per-matched-doc dl resolver.
                avgdl = Float64(self._view.total_token_count()) / Float64(
                    self._view.doc_count()
                )
                fn_resolver = ff_opt.value().fieldnorm_resolver()
            else:
                # FALLBACK: O(doc_count) whole-column decode + sum (older split).
                var fn_res = ff_opt.value().fieldnorms(self._view)
                fieldnorm_dls = fn_res[0].copy()
                avgdl = fn_res[1]

        # Heap comparison mode. SORT_MODE_SCORE is the default ranking.
        var sort_mode = SORT_MODE_SCORE
        if sort_field == SORT_FIELD_DOC:
            sort_mode = SORT_MODE_DOC
        elif fast_field_sort:
            sort_mode = _resolve_sort_mode(ff_opt.value(), sort_field)

        # ---- filter FF-header pre-resolve: resolve every distinct
        # fast-field referenced in the filter ONCE here, so the recursive per-doc
        # _eval_ff_predicate reads via an O(1) resolver (no per-doc header parse,
        # no per-doc term_bounds alloc on keyword conjuncts). Byte-identical
        # survivor set.
        var filter_res = _FilterResolvers()
        if query.has_filter():
            _collect_filter_fields(
                filter_res, ff_opt.value(), self._view, query.filter_ref()
            )

        # ---- Step 3: tokenize the query (symmetry) + DEDUP terms ----
        # analyze_text RAISES if not query.analyzer_config.is_tokenized().
        var af = analyze_text(query.query_text, query.analyzer_config)
        var terms = List[String]()
        for ti in range(len(af.tokens)):
            var t = af.tokens[ti].term
            var seen = False
            for ui in range(len(terms)):
                if terms[ui] == t:
                    seen = True
                    break
            if not seen:
                terms.append(t)

        # ---- Step 4: dense accumulator (trivial POD) ----
        # acc[doc_id - min_id] = summed BM25 score; touched = first-touched ids.
        #
        # WHY DENSE: a SPARSE accumulator (e.g. a `Dict[Int, Float64]`) would
        # drop the per-query `8*big_n`-byte zeroing, but it is SLOWER on log
        # search: the dominant log queries match NEAR-ALL docs, so a sparse map
        # pays a per-posting hash over ~big_n postings while the dense memset it
        # replaces is small. The alloc-zeroing win would materialize ONLY at
        # large big_n with SELECTIVE (few-match) queries. So the dense array
        # STAYS (direct O(1) indexing, no hashing). The byte-identical top-K
        # equivalence test is tests/test_search_wand_phase0_equivalence.
        var acc = List[Float64](length=big_n if big_n > 0 else 0, fill=0.0)
        var touched = List[Int]()

        # ---- Per-term decode + idf (shared by BOTH the brute walk AND the WAND
        # DAAT merge): decode each present term's posting list ONCE. Term-absent
        # terms are dropped (they contribute nothing). First gather each PRESENT
        # term's locator (ordinal/offset/len) + idf — WITHOUT decoding yet — so the
        # BMW branch can decide eligibility and then work block-by-block off the
        # postings region (skipping the TF decode of below-theta blocks) instead of
        # paying the full pre-decode the Phase-1 / brute paths need.
        var term_ord = List[Int]()
        var term_poff = List[Int]()
        var term_plen = List[Int]()
        var term_dfreq = List[Int]()
        var term_idf = List[Float64]()
        for tix in range(len(terms)):
            var ord_opt = self._term_dict.lookup(terms[tix].as_bytes())
            if not ord_opt:
                continue  # term absent in this split -> contributes nothing.
            var ordinal = ord_opt.value()
            var info = self._term_dict.term_info_at(ordinal)
            term_ord.append(ordinal)
            term_poff.append(info.posting_offset)
            term_plen.append(info.posting_len)
            term_dfreq.append(info.doc_freq)
            term_idf.append(bm25_idf(info.doc_freq, big_n))  # PRECOMPUTE once.
        var n_present = len(term_ord)

        # ---- WAND eligibility gate. WAND optimizes a SCORE ranking
        # by skipping the scoring (Phase 1) / DECODE (Phase 2 BMW) of docs/blocks
        # that provably cannot beat theta. It applies only when:
        #   1. sort_mode == SORT_MODE_SCORE (theta is a SCORE bound).
        #   2. no aggs (the agg pass needs the full matched set with scores).
        #   3. no filter (Phase 1/2 conservative; the filter narrows candidates
        #      more than WAND would — filtered WAND is not implemented).
        #   4. >= 2 present query terms — a single-term query has nothing to pivot
        #      on (its upper bound IS its score; no skip possible). The brute walk
        #      handles it byte-identically with less overhead.
        #   5. a bounded window (from+top_k > 0) so theta can engage; a size:0
        #      count-only request scores nothing, so there is no skip to be had.
        # On any miss we take the EXACT brute walk below (byte-identical). Result is byte-identical EITHER WAY — WAND only changes which
        # docs pay the full BM25 contribution / decode, never the final top-K.
        var wand_window = query.from_offset + query.top_k
        var wand_eligible = (
            wand_mode != WAND_MODE_BRUTE
            and sort_mode == SORT_MODE_SCORE
            and not query.has_aggs()
            and not query.has_filter()
            and n_present >= 2
            and wand_window > 0
        )

        # ---- Phase 2 (BMW) eligibility: WAND-eligible AND the split carries a
        # BLOCKMAX skip-list AND the fieldnorm `dl` source is the O(1) resolver
        # (the BMW per-doc dl read mirrors the live scorer). The BMW path SKIPS the
        # TF-unpack + per-doc scoring of whole blocks whose summed per-block
        # max-impact upper bound is < theta — the decode-skip win over Phase-1
        # term-max WAND. It produces the EXACT SAME acc/touched (doc-ids are still
        # decoded for the union -> total_matches stays exact; only the scoring
        # decode + work is skipped). Falls back to Phase 1 when no BLOCKMAX.
        #
        # IDF-SKEW GATE (the honest perf guard). BMW only ever WINS on a skewed-idf query (one RARE high-idf term
        # lifts theta above the common term's per-block bounds -> the common term's
        # blocks are decode-skippable). On an all-common near-all-match query NO
        # block is skippable and the block-cursor bookkeeping is pure overhead. So
        # even when BMW is FORCED (WAND_MODE_BMW), it engages only on the skewed
        # regime (rarest_df * BMW_SKEW_FACTOR < commonest_df) and otherwise falls to
        # Phase 1. The result is byte-identical EITHER path; this only picks the
        # faster one. (BMW is never the production default — `search` is Phase 1;
        # only `search_bmw` requests WAND_MODE_BMW. See `search`'s docstring for
        # why Phase 1 beats BMW on log-search workloads.)
        var min_df = -1
        var max_df = 0
        for tix in range(n_present):
            var df = term_dfreq[tix]
            if min_df < 0 or df < min_df:
                min_df = df
            if df > max_df:
                max_df = df
        var idf_skewed = min_df >= 0 and min_df * BMW_SKEW_FACTOR < max_df
        var bmw_eligible = (
            wand_mode == WAND_MODE_BMW
            and wand_eligible
            and self._blockmax
            and idf_skewed
        )

        if bmw_eligible:
            # ---- Phase 2 (BMW): block-max DAAT. Decodes doc-ids per block (the
            # union -> exact total_matches) but SKIPS the TF-unpack + per-doc
            # scoring of whole blocks whose summed per-block max-impact bound is
            # < theta. Byte-identical acc/touched to the brute walk. ----
            self._bmw_accumulate(
                term_ord,
                term_idf,
                term_poff,
                term_plen,
                params,
                avgdl,
                fn_resolver,
                fieldnorm_dls,
                min_id,
                big_n,
                wand_window,
                acc,
                touched,
            )
        else:
            # ---- Decode each present term's posting list ONCE (the Phase-1 /
            # brute substrate; the BMW branch above never reaches here). This is
            # the SAME decode the pre-WAND brute walk did, hoisted so the WAND
            # branch can merge across terms by doc-id without re-decoding.
            var term_dids = List[List[Int]]()
            var term_tfs = List[List[Int]]()
            for tix in range(n_present):
                var dids = List[Int]()
                var tfs = List[Int]()
                _decode_posting_list(
                    self._view.postings_region(),
                    term_poff[tix],
                    term_plen[tix],
                    dids,
                    tfs,
                )
                term_dids.append(dids^)
                term_tfs.append(tfs^)

            if wand_eligible:
                self._wand_accumulate(
                    term_dids,
                    term_tfs,
                    term_idf,
                    params,
                    avgdl,
                    fn_resolver,
                    fieldnorm_dls,
                    min_id,
                    big_n,
                    wand_window,
                    acc,
                    touched,
                )
            else:
                # ---- The EXACT brute walk: term-major union accumulate (the
                # pre-WAND path; byte-identical). For each present term, fold each
                # posting's BM25 contribution into acc[slot] in dedup-TERM order
                # (the float-order pin), restricting to the pushed filter survivors,
                # appending to `touched` on first touch.
                for tix in range(n_present):
                    ref dids = term_dids[tix]
                    ref tfs = term_tfs[tix]
                    var idf = term_idf[tix]
                    for i in range(len(dids)):
                        var slot = dids[i] - min_id
                        if slot < 0 or slot >= big_n:
                            raise Error(
                                "SearchCore.search: posting doc_id "
                                + String(dids[i])
                                + " maps to out-of-range slot "
                                + String(slot)
                                + " (split min_doc_id="
                                + String(min_id)
                                + ", doc_count="
                                + String(big_n)
                                + "; corrupt)"
                            )
                        # filter: restrict the candidate set during the walk. A doc
                        # that fails the pushed fast-field predicate `continue`s
                        # BEFORE the BM25 contribution — it never enters `touched`,
                        # never scores, never reaches top-k. The filter is UNSCORED
                        # (it only restricts WHICH docs accumulate; it NEVER adds to
                        # `acc`), so `_score` stays the pure BM25 of the matched
                        # terms over the survivors.
                        if query.has_filter():
                            if not _eval_ff_predicate(
                                filter_res,
                                self._view,
                                query.filter_ref(),
                                dids[i],
                            ):
                                continue
                        if acc[slot] == 0.0:
                            touched.append(dids[i])
                        # fast-fields: the per-doc fieldnorm `dl` (token count) for the b>0
                        # doc-length-normalization denominator. PREFERRED: the O(1)
                        # FieldnormResolver reads ONLY this matched doc's dl (cost
                        # O(matched)). FALLBACK: index the resolved-once
                        # `fieldnorm_dls` column (older split without the footer
                        # total). Both empty/None iff the split carries no
                        # "__fieldnorm__" (then dl=0 + avgdl=0.0 -> the scorer
                        # degrades that contribution to b=0, norm=1.0). `slot` is
                        # already bounds-validated above.
                        var dl = 0
                        if fn_resolver:
                            dl = fn_resolver.value().dl_at(self._view, dids[i])
                        elif len(fieldnorm_dls) > 0:
                            dl = fieldnorm_dls[slot]
                        acc[slot] += bm25_score_contribution(
                            idf, tfs[i], params, doc_len=dl, avg_doc_len=avgdl
                        )

        # ---- match-all-for-aggs: the headline `{"size":0,"aggs":{...}}` /
        # no-query / match_all aggs request. When there are NO query terms but
        # aggs ARE requested, populate `touched` with EVERY doc in the split so
        # the agg pass aggregates the WHOLE split (the default empty `touched`
        # would otherwise aggregate over ZERO docs — silently-wrong empty
        # buckets). These match-all docs carry no BM25 score (acc stays 0.0); the
        # canonical aggs-only request is size:0 (no hits fetched). If a filter is
        # ALSO present, the match-all set still respects it (the filter restricts
        # WHICH docs aggregate, exactly as for a term query). NOTE: this only fires
        # when the term walk produced no candidates AND no filter is restricting —
        # an aggs request WITH a `match` term aggregates over the matched (and
        # optionally filtered) survivors, unchanged.
        # The same arm serves the no-query scan (`query.match_all`): every
        # live doc (filter-respecting) becomes a 0.0-scored hit, and the
        # heap/page logic below emits it like any other.
        if (
            (query.has_aggs() or query.match_all)
            and len(terms) == 0
            and len(touched) == 0
        ):
            for slot in range(big_n):
                var did = slot + min_id
                if query.has_filter():
                    if not _eval_ff_predicate(
                        filter_res, self._view, query.filter_ref(), did
                    ):
                        continue
                touched.append(did)

        # ---- the true match total (count of docs that matched a TERM AND
        # passed the filter). Surfaced regardless of the page slice. For a
        # match-all-for-aggs request this is the whole-split (filtered) count. ----
        var total_matches = len(touched)

        # ---- aggregation: the in-leaf agg pass over the FULL `touched` matched
        # set (independent of from/size/top-k). It runs BEFORE the heap/page
        # logic, so a size:0 aggs-only request still aggregates everything while
        # the page slice below yields 0 rows. The FastFieldReader was built above
        # when has_aggs() (the extended gate). ----
        var agg_out = AggResults()
        if query.has_aggs():
            agg_out = _run_aggs(
                query.aggs_ref(), ff_opt.value(), self._view, touched
            )

        # ---- Step 5: bounded top-k over the touched docs ----
        # sort: the heap retains the top `from_offset + top_k` candidates
        # by the sort key, so the page `[from, from+size)` is materialized from
        # the descending drain. top_k <= 0 (e.g. size=0 count-only) clamps
        # capacity to 1 so the heap stays valid, but the slice below yields 0
        # rows; the count-only request returns an empty page + the true total.
        var window = query.from_offset + query.top_k
        var heap = _TopKHeap(
            window if window > 0 else 1,
            sort_mode,
            query.sort_order,
            query.missing_order,
        )
        # PERF-CRITICAL (FF-header pre-resolve): resolve the sort
        # field's sub-region header ONCE before the touched loop (the per-doc
        # accessor re-parsed it — and re-allocated term_bounds for a keyword sort
        # — per touched doc). Byte-identical typed keys.
        var sort_kw_res: Optional[KeywordFastFieldResolver] = None
        var sort_num_res: Optional[NumericFastFieldResolver] = None
        var sort_flt_res: Optional[FloatFastFieldResolver] = None
        if fast_field_sort:
            if sort_mode == SORT_MODE_I64:
                sort_num_res = ff_opt.value().numeric_resolver(
                    self._view, sort_field
                )
            elif sort_mode == SORT_MODE_F64:
                sort_flt_res = ff_opt.value().float_resolver(
                    self._view, sort_field
                )
            else:  # SORT_MODE_STR
                sort_kw_res = ff_opt.value().keyword_resolver(
                    self._view, sort_field
                )
        for i in range(len(touched)):
            var doc_id = touched[i]
            var sc = acc[doc_id - min_id]
            if sort_mode == SORT_MODE_SCORE or sort_mode == SORT_MODE_DOC:
                heap.push(sc, doc_id)
            else:
                # Read the sort key ONCE per touched doc (not per comparison).
                var ki = Int64(0)
                var kf = Float64(0.0)
                var ks = String("")
                var missing = False
                if sort_mode == SORT_MODE_I64:
                    var cell = sort_num_res.value().i64_at(self._view, doc_id)
                    if cell:
                        ki = cell.value()
                    else:
                        missing = True
                elif sort_mode == SORT_MODE_F64:
                    var cellf = sort_flt_res.value().f64_at(self._view, doc_id)
                    if cellf:
                        kf = cellf.value()
                    else:
                        missing = True
                else:  # SORT_MODE_STR
                    var cells = sort_kw_res.value().keyword_at(
                        self._view, doc_id
                    )
                    if cells:
                        ks = cells.value()
                    else:
                        missing = True
                heap.push_keyed(sc, doc_id, ki, kf, ks^, missing)
        var order = heap.drain_descending()  # entry-indices, strongest first

        # ---- sort: slice the page [from, min(len, from+size)) ----
        var page_start = query.from_offset
        var page_end = query.from_offset + query.top_k
        if page_end > len(order):
            page_end = len(order)
        if page_start < 0:
            page_start = 0
        # from >= total (or size <= 0): an empty 0-row page (still schema-valid).

        # ---- Steps 6 + 7: fetch _source per page doc + assemble HitBatch ----
        # multi-split: for a fast-field sort, surface the per-row TYPED sort key
        # (parallel to the page rows) on the SortKeyColumn so the cross-split merge
        # can re-rank by the key it cannot read off the 3-column HitBatch. SCORE/DOC
        # modes leave the column empty (the merge uses the batch score/doc_id).
        var docstore = self._view.docstore_region()
        var scores = List[Float64]()
        var ids = List[Int64]()
        var sources = List[String]()
        var sk = SortKeyColumn(sort_mode)
        var surface_keys = (
            sort_mode == SORT_MODE_I64
            or sort_mode == SORT_MODE_F64
            or sort_mode == SORT_MODE_STR
        )
        if page_start < page_end:
            for oi in range(page_start, page_end):
                var hidx = order[oi]
                var doc_id = heap.id_at(hidx)
                var sc = heap.score_at(hidx)
                var slot = doc_id - min_id
                # read_docstore_source decodes per the compressed_flag (verbatim
                # for an UNCOMPRESSED/OLD split, lz4_decompress for an LZ4 split).
                var src = read_docstore_source(docstore, slot)
                scores.append(sc)
                ids.append(Int64(doc_id))
                sources.append(src^)
                if surface_keys:
                    sk.missing.append(heap.missing_at(hidx))
                    if sort_mode == SORT_MODE_I64:
                        sk.key_i64.append(heap.key_i64_at(hidx))
                    elif sort_mode == SORT_MODE_F64:
                        sk.key_f64.append(heap.key_f64_at(hidx))
                    else:  # SORT_MODE_STR
                        sk.key_str.append(heap.key_str_at(hidx))

        return SearchResult(
            _assemble_hit_batch(scores^, ids^, sources^),
            total_matches,
            agg_out^,
            sk^,
        )

    def _wand_accumulate(
        self,
        term_dids: List[List[Int]],
        term_tfs: List[List[Int]],
        term_idf: List[Float64],
        params: Bm25Params,
        avgdl: Float64,
        fn_resolver: Optional[FieldnormResolver],
        fieldnorm_dls: List[Int],
        min_id: Int,
        big_n: Int,
        window: Int,
        mut acc: List[Float64],
        mut touched: List[Int],
    ) raises:
        """WAND Phase 1 term-max DAAT. Merges the present terms'
        already-decoded posting cursors by doc-id, and for each candidate doc
        SKIPS the full BM25 scoring of docs whose summed per-term max-impact
        UPPER bound is STRICTLY < theta (the running K-th-best score) — they
        cannot enter the top-K. Survivors are scored EXACTLY as the brute walk:
        per-doc contributions summed into acc[slot] in dedup-TERM order (the
        float pin) so the f64 result is BIT-identical. Every candidate doc is
        appended to `touched` exactly once (the DAAT merge visits each doc once)
        so total_matches is EXACT. Skipped docs leave acc[slot] == 0.0; the
        downstream heap pushes them with 0.0 (they lose to the K survivors whose
        true scores all exceed theta, so the final top-K is byte-identical to
        scoring everyone).

        EXACTNESS (the load-bearing argument): a doc is skipped only when the
        sum of its terms' TRUE UPPER bounds is < theta. Its real score <= that
        sum < theta = a real achieved K-th-best, so it provably cannot enter the
        top-K. theta only ever rises (the heap evicts its weakest), so no later
        doc that COULD beat it is lost either. Result: byte-identical top-K."""
        var nt = len(term_dids)

        # ---- Per-term max-impact UPPER bound: idf*f(max_tf,
        # min_dl). f INCREASES in tf and DECREASES in dl, so (max_tf, min_dl)
        # over-estimates every doc in the list.
        #
        # max_tf is the per-term whole-list max — free (a scan over the already-
        # decoded tfs, no fast-field read).
        #
        # min_dl is the COLUMN-GLOBAL minimum doc length, resolved ONCE for ALL
        # terms (NOT per-term, and CRUCIALLY not per-posting). The per-term min_dl
        # is always >= the column min, and f decreases in dl, so f(max_tf,
        # column_min_dl) >= f(max_tf, per_term_min_dl) >= the true per-doc max — a
        # valid (looser) UPPER bound. This is the load-bearing perf decision: a
        # per-posting dl_at to find the exact per-term min_dl would cost O(total
        # postings) fast-field reads UP FRONT (the same cost the skip is meant to
        # AVOID), turning WAND into a net regression. The O(1) column min keeps
        # the bound computation O(nt). Sources, in scorer-priority order:
        #   * fn_resolver -> the numeric frame-of-reference base (the column min,
        #     one O(1) header read);
        #   * fieldnorm_dls (older split) -> a single O(big_n) min scan, once;
        #   * neither -> dl=0 (no fieldnorm; the scorer degrades to norm=1.0).
        # A missing cell scores with norm=1.0, which is LESS favorable than the
        # column-min norm, so it is already covered (its f is smaller).
        var global_min_dl = 0
        if fn_resolver:
            global_min_dl = fn_resolver.value().min_dl(self._view)
        elif len(fieldnorm_dls) > 0:
            global_min_dl = fieldnorm_dls[0]
            for i in range(1, len(fieldnorm_dls)):
                if fieldnorm_dls[i] < global_min_dl:
                    global_min_dl = fieldnorm_dls[i]
            if global_min_dl < 0:
                global_min_dl = 0

        var term_max_impact = List[Float64](length=nt, fill=0.0)
        for t in range(nt):
            ref tfs = term_tfs[t]
            var max_tf = 0
            for i in range(len(tfs)):
                if tfs[i] > max_tf:
                    max_tf = tfs[i]
            term_max_impact[t] = _term_max_impact(
                term_idf[t], max_tf, global_min_dl, params, avgdl
            )

        # ---- DAAT cursors: one position per term into its ascending posting
        # list. The merge advances the cursors at the current minimum doc-id.
        var pos = List[Int](length=nt, fill=0)

        # ---- The theta tracker: a LOCAL capacity-`window` SCORE-mode min-heap
        # fed the REAL score of every doc WAND fully scores. theta = its
        # root_score() once is_full() (the K-th-best so far), else the negative
        # sentinel (warm-up: skip nothing). This mirrors the downstream
        # SORT_MODE_SCORE heap's ranking exactly, so the theta used for skipping
        # is a valid K-th-best bound. (The downstream heap re-derives the same
        # top-K from acc/touched; this local heap exists ONLY to drive theta.)
        var theta_heap = _TopKHeap(window, SORT_MODE_SCORE)
        var theta = Float64.MIN_FINITE

        while True:
            # 1. Find the minimum current doc-id across all live cursors.
            var pivot_doc = -1
            for t in range(nt):
                if pos[t] < len(term_dids[t]):
                    var d = term_dids[t][pos[t]]
                    if pivot_doc < 0 or d < pivot_doc:
                        pivot_doc = d
            if pivot_doc < 0:
                break  # all cursors exhausted.

            var slot = pivot_doc - min_id
            if slot < 0 or slot >= big_n:
                raise Error(
                    "SearchCore._wand_accumulate: posting doc_id "
                    + String(pivot_doc)
                    + " maps to out-of-range slot "
                    + String(slot)
                    + " (split min_doc_id="
                    + String(min_id)
                    + ", doc_count="
                    + String(big_n)
                    + "; corrupt)"
                )

            # 2. The candidate's UPPER bound: sum term_max_impact over the terms
            #    aligned at pivot_doc (those whose cursor sits on it). The set of
            #    aligned terms is identical to the terms that match this doc.
            var ub = 0.0
            for t in range(nt):
                if pos[t] < len(term_dids[t]) and (
                    term_dids[t][pos[t]] == pivot_doc
                ):
                    ub += term_max_impact[t]

            # 3. Every candidate is counted (total_matches is exact). The doc is
            #    visited exactly once (the merge dedups), so append directly — do
            #    NOT use the acc[slot]==0.0 first-touch test (a skipped doc keeps
            #    acc==0.0 and would be appended again by a later term).
            touched.append(pivot_doc)

            # 4. SKIP decision. Skip the full scoring ONLY when the
            #    upper bound is STRICTLY < theta (a doc whose ub == theta must
            #    still be scored — it may tie the K-th best and win on the lower-
            #    doc-id tiebreak). When skipped, acc[slot] stays 0.0.
            if ub >= theta:
                # SCORE: fold each aligned term's contribution into acc[slot] in
                # dedup-TERM order (the SAME order the brute walk uses). The
                # outer term index `t` IS the dedup-term order.
                var dl = 0
                if fn_resolver:
                    dl = fn_resolver.value().dl_at(self._view, pivot_doc)
                elif len(fieldnorm_dls) > 0:
                    dl = fieldnorm_dls[slot]
                var doc_score = 0.0
                for t in range(nt):
                    if pos[t] < len(term_dids[t]) and (
                        term_dids[t][pos[t]] == pivot_doc
                    ):
                        doc_score += bm25_score_contribution(
                            term_idf[t],
                            term_tfs[t][pos[t]],
                            params,
                            doc_len=dl,
                            avg_doc_len=avgdl,
                        )
                acc[slot] = doc_score
                # Feed the REAL score to the theta heap + refresh theta.
                theta_heap.push(doc_score, pivot_doc)
                if theta_heap.is_full():
                    theta = theta_heap.root_score()

            # 5. Advance every cursor sitting on pivot_doc.
            for t in range(nt):
                if pos[t] < len(term_dids[t]) and (
                    term_dids[t][pos[t]] == pivot_doc
                ):
                    pos[t] += 1

    def _bmw_accumulate(
        self,
        term_ord: List[Int],
        term_idf: List[Float64],
        term_poff: List[Int],
        term_plen: List[Int],
        params: Bm25Params,
        avgdl: Float64,
        fn_resolver: Optional[FieldnormResolver],
        fieldnorm_dls: List[Int],
        min_id: Int,
        big_n: Int,
        window: Int,
        mut acc: List[Float64],
        mut touched: List[Int],
    ) raises:
        """WAND Phase 2 (BMW) block-max DAAT. One
        block-cursor per present term, working DIRECTLY off the postings region +
        the parsed BLOCKMAX skip-list (NOT a pre-decoded posting list).

        EXACTNESS — produces the SAME acc/touched as the brute walk:
          * The DAAT merge decodes each block's DOC-IDS (a cheap delta-unpack) and
            visits every candidate doc exactly once -> `touched` is the EXACT union
            the brute walk produces -> total_matches is EXACT.
          * A doc is SCORED only when the sum of its terms' PER-BLOCK max-impact
            UPPER bounds is >= theta. The block bound is idf*f(block_max_tf,
            block_min_dl) computed via the SAME bm25_score_contribution the scorer
            uses — a TRUE upper bound on every doc in the block (f increases in tf,
            decreases in dl, so the (max_tf, min_dl) corner over-estimates every
            interior doc; idf >= 0 keeps the product a valid bound). A doc whose
            bound is < theta provably cannot enter the top-K (its real score <=
            block-bound-sum < theta = a real achieved K-th-best), so skipping its
            scoring (leaving acc[slot]=0.0) does not change the top-K.
          * Scored docs sum their aligned terms' contributions in dedup-TERM order
            (the float-order pin: the outer term index IS the dedup order), so the
            f64 result is BIT-identical to the brute walk.

        THE DECODE-SKIP WIN (over Phase-1 term-max WAND): each block is decoded
        EXACTLY ONCE. At block entry the cursor decides — from the block's own
        max-impact bound + the OTHER terms' whole-list max-impact (a TRUE upper
        bound on any doc in the block: a doc in block b of term t scores at most
        block_bound[t] + Σ_{u≠t} term_max_impact[u]) vs the current theta — whether
        the block CAN ever hold a scored doc:
          * CAN'T (bound < theta): decode DOC-IDS ONLY (cheap delta unpack; needed
            for the exact union) and SKIP the TF unpack entirely. The cursor lands
            on the next block via the BLOCKMAX byte-offset skip-list.
          * CAN (bound >= theta): decode the FULL block (doc-ids + tfs) once; the
            per-doc scoring reuses those tfs (NO second decode).
        Because the per-doc scoring bound (Σ aligned per-block bounds) is <= the
        block-entry bound (term_max_impact[u] >= any of u's per-block bounds), any
        block that EVER scores a doc was decoded full — so a doc-ids-only block is
        provably never scored, and there is never a re-decode. Phase 1 decoded
        EVERY term's full posting list (doc-ids AND tfs) up front; BMW skips the TF
        unpack of the below-theta blocks (the bulk on long common-term lists) while
        the doc-id union keeps total_matches exact.
        """
        var nt = len(term_ord)
        var region = self._view.postings_region()
        ref bm = self._blockmax.value()

        # ---- Per-term block-cursor state. ----
        var blk_idx = List[Int](length=nt, fill=0)
        var blk_base_rel = List[Int](length=nt, fill=0)
        var doc_freq = List[Int](length=nt, fill=0)
        var nblocks = List[Int](length=nt, fill=0)
        var blk_dids = List[List[Int]]()
        var blk_tfs = List[List[Int]]()
        var blk_pos = List[Int](length=nt, fill=0)
        var blk_have_tfs = List[Bool](length=nt, fill=False)
        var exhausted = List[Bool](length=nt, fill=False)
        # Whole-list max-impact per term (max over its blocks' bounds) — the
        # co-term bound for the block-entry decode decision. O(Σ nblocks), cheap.
        var term_max_impact = List[Float64](length=nt, fill=0.0)

        for t in range(nt):
            var ordinal = term_ord[t]
            var poff = term_poff[t]
            var plen = term_plen[t]
            var dc_res = _bmw_read_doc_count(region, poff, plen)
            doc_freq[t] = dc_res[0]
            blk_base_rel[t] = dc_res[1]  # post-doc_count rel offset.
            nblocks[t] = bm.num_blocks(ordinal)
            blk_dids.append(List[Int]())
            blk_tfs.append(List[Int]())
            if nblocks[t] <= 0 or doc_freq[t] <= 0:
                exhausted[t] = True
                continue
            var tmi = 0.0
            for b in range(nblocks[t]):
                var bnd = bm25_score_contribution(
                    term_idf[t],
                    bm.block_max_tf(ordinal, b),
                    params,
                    doc_len=bm.block_min_dl(ordinal, b),
                    avg_doc_len=avgdl,
                )
                if bnd > tmi:
                    tmi = bnd
            term_max_impact[t] = tmi

        # Σ of all terms' whole-list max-impact (for the per-block co-term bound:
        # block_could_score = blk_bound[t] + (sum_tmi - term_max_impact[t]) >= theta).
        var sum_tmi = 0.0
        for t in range(nt):
            sum_tmi += term_max_impact[t]

        # ---- The theta tracker (mirrors _wand_accumulate). ----
        var theta_heap = _TopKHeap(window, SORT_MODE_SCORE)
        var theta = Float64.MIN_FINITE

        # blk_bound[t] = the CURRENT block's per-block bound (the pivot scoring
        # decision input). Load block 0 of each term (decode-once decision below).
        var blk_bound = List[Float64](length=nt, fill=0.0)
        for t in range(nt):
            if not exhausted[t]:
                self._bmw_load_block(
                    region,
                    bm,
                    term_ord[t],
                    term_poff[t],
                    term_plen[t],
                    blk_base_rel[t],
                    blk_idx[t],
                    doc_freq[t],
                    nblocks[t],
                    term_idf[t],
                    params,
                    avgdl,
                    sum_tmi - term_max_impact[t],
                    theta,
                    blk_dids[t],
                    blk_tfs[t],
                    blk_have_tfs,
                    t,
                    blk_bound,
                )

        while True:
            # 1. The pivot doc = the minimum current doc-id across live cursors.
            var pivot_doc = -1
            for t in range(nt):
                if not exhausted[t]:
                    var d = blk_dids[t][blk_pos[t]]
                    if pivot_doc < 0 or d < pivot_doc:
                        pivot_doc = d
            if pivot_doc < 0:
                break  # all cursors exhausted.

            var slot = pivot_doc - min_id
            if slot < 0 or slot >= big_n:
                raise Error(
                    "SearchCore._bmw_accumulate: posting doc_id "
                    + String(pivot_doc)
                    + " maps to out-of-range slot "
                    + String(slot)
                    + " (split min_doc_id="
                    + String(min_id)
                    + ", doc_count="
                    + String(big_n)
                    + "; corrupt)"
                )

            # 2. The candidate's PER-BLOCK upper bound: sum the current-block bound
            #    over the terms aligned at pivot_doc (those whose cursor sits on it).
            var ub = 0.0
            for t in range(nt):
                if not exhausted[t] and blk_dids[t][blk_pos[t]] == pivot_doc:
                    ub += blk_bound[t]

            # 3. Count the candidate (total_matches exact — every distinct doc once).
            touched.append(pivot_doc)

            # 4. SKIP decision: skip the full scoring ONLY when the upper bound is
            #    STRICTLY < theta (ub == theta must still be scored — it may tie the
            #    K-th best and win the lower-doc-id tiebreak). When skipped,
            #    acc[slot] stays 0.0.
            if ub >= theta:
                var dl = 0
                if fn_resolver:
                    dl = fn_resolver.value().dl_at(self._view, pivot_doc)
                elif len(fieldnorm_dls) > 0:
                    dl = fieldnorm_dls[slot]  # cov: unreachable dls fill only without a footer total; BLOCKMAX needs one
                var doc_score = 0.0
                # dedup-TERM order (the float-order pin): the outer term index `t`.
                # A scored doc's block was decoded full (its block-entry bound >=
                # theta, since ub >= theta implies blk_bound[t] + co-term-bound >=
                # theta), so blk_tfs[t] is populated — no re-decode here.
                for t in range(nt):
                    if (
                        not exhausted[t]
                        and blk_dids[t][blk_pos[t]] == pivot_doc
                    ):
                        debug_assert(
                            blk_have_tfs[t],
                            "BMW: scored block was not full-decoded (bound bug)",
                        )
                        doc_score += bm25_score_contribution(
                            term_idf[t],
                            blk_tfs[t][blk_pos[t]],
                            params,
                            doc_len=dl,
                            avg_doc_len=avgdl,
                        )
                acc[slot] = doc_score
                theta_heap.push(doc_score, pivot_doc)
                if theta_heap.is_full():
                    theta = theta_heap.root_score()

            # 5. Advance every cursor sitting on pivot_doc — within the block, or to
            #    the next block (loaded via the decode-once decision against the
            #    LATEST theta). The advance lands on the next block via the BLOCKMAX
            #    byte-offset skip-list.
            for t in range(nt):
                if not exhausted[t] and blk_dids[t][blk_pos[t]] == pivot_doc:
                    blk_pos[t] += 1
                    if blk_pos[t] >= len(blk_dids[t]):
                        blk_idx[t] += 1
                        if blk_idx[t] >= nblocks[t]:
                            exhausted[t] = True
                        else:
                            blk_dids[t].clear()
                            blk_tfs[t].clear()
                            blk_have_tfs[t] = False
                            blk_pos[t] = 0
                            self._bmw_load_block(
                                region,
                                bm,
                                term_ord[t],
                                term_poff[t],
                                term_plen[t],
                                blk_base_rel[t],
                                blk_idx[t],
                                doc_freq[t],
                                nblocks[t],
                                term_idf[t],
                                params,
                                avgdl,
                                sum_tmi - term_max_impact[t],
                                theta,
                                blk_dids[t],
                                blk_tfs[t],
                                blk_have_tfs,
                                t,
                                blk_bound,
                            )

    @always_inline
    def _bmw_load_block(
        self,
        region: Span[UInt8, _],
        bm: BlockMaxIndex,
        ordinal: Int,
        poff: Int,
        plen: Int,
        base_rel: Int,
        block: Int,
        doc_freq: Int,
        nblocks: Int,
        idf: Float64,
        params: Bm25Params,
        avgdl: Float64,
        co_term_bound: Float64,
        theta: Float64,
        mut out_dids: List[Int],
        mut out_tfs: List[Int],
        mut blk_have_tfs: List[Bool],
        t: Int,
        mut blk_bound: List[Float64],
    ) raises:
        """Load ONE block for term-cursor `t`, deciding ONCE whether to decode the
        TF sub-block. Computes the block's per-block bound `blk_bound[t]` =
        idf*f(block_max_tf, block_min_dl). If `blk_bound[t] + co_term_bound >=
        theta` the block CAN hold a scored doc -> decode FULL (doc-ids + tfs,
        `blk_have_tfs[t]=True`); else it CANNOT -> decode DOC-IDS ONLY (skip the TF
        unpack). The decode lands on the block via the BLOCKMAX byte-offset
        skip-list. EXACT: the co_term_bound is the sum of the OTHER terms'
        whole-list max-impact, an upper bound on their contribution to ANY doc, so
        a doc that later scores (its tighter aligned-block-bound sum >= theta) is
        always in a full-decoded block."""
        var bc = _bmw_block_count(doc_freq, block, nblocks)
        var bnd = bm25_score_contribution(
            idf,
            bm.block_max_tf(ordinal, block),
            params,
            doc_len=bm.block_min_dl(ordinal, block),
            avg_doc_len=avgdl,
        )
        blk_bound[t] = bnd
        var off = bm.block_byte_offset(ordinal, block)
        if bnd + co_term_bound >= theta:
            # FULL decode (doc-ids + tfs) once.
            _decode_posting_block(
                region, poff, plen, base_rel, off, bc, out_dids, out_tfs
            )
            blk_have_tfs[t] = True
        else:
            # DOC-IDS ONLY — skip the TF unpack (the decode-skip win).
            _decode_posting_block_dids_only(
                region, poff, plen, base_rel, off, bc, out_dids
            )
            blk_have_tfs[t] = False


# =============================================================================
# HitBatch assembly (from_list / Column factories; NOT nested ctors).
# =============================================================================


def _assemble_hit_batch(
    var scores: List[Float64],
    var ids: List[Int64],
    var sources: List[String],
) raises -> RecordBatch:
    """Build the HitBatch RecordBatch from the parallel top-k result lists.
    PrimitiveArray.from_list + Column.from_primitive / from_string (the
    nested-PrimitiveArray constructor form does NOT work — use from_list).
    `_id` is Int64 (from_list[int64] needs List[Int64], converted at the call
    site)."""
    var score_arr = PrimitiveArray[DType.float64].from_list(scores)
    var id_arr = PrimitiveArray[DType.int64].from_list(ids)
    var src_arr = StringArray.from_strings(sources)

    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(Column.from_primitive[DType.float64](score_arr))
    rb.add_column(Column.from_primitive[DType.int64](id_arr))
    rb.add_column(Column.from_string(src_arr^))
    return rb.build(hit_schema())
