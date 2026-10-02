# =============================================================================
# komira_search_runtime/search_source.mojo
#   The search source EDGE: Searcher (SourceLike plan-spec) +
#   SearchMorselSource (MorselSourceImpl execute reader).
# =============================================================================
#
# THE PACKAGE-DAG DECISION (keep komira_search light).
# -----------------------------------------------------------------------------
# `komira_search` depends only on komira_core + komira_eval. `Morsel` +
# `MorselSourceImpl` live in `komira_morsel`, which is NOT on that edge
# (komira_morsel has ZERO search deps, so komira_search_runtime ->
# {komira_search, komira_morsel} is acyclic). Placing a `MorselSourceImpl`
# conformer inside komira_search would invert the DAG (komira_search ->
# komira_morsel) and bloat the light unit edge. So the Searcher SPEC + the
# SearchMorselSource READER sit in this higher package (deps: komira_search +
# komira_morsel), the same layering the message broker uses for its consumer
# spec and morsel source. The pure read core (SearchCore + QueryIR + the
# doc-store reader) stays in komira_search.
#
# This package does NOT wire the DataFrame entry point (`ctx.read` /
# `to_dataframe`). The Searcher conforms the SourceLike METHOD surface
# (schema/estimate_rows/fingerprint/supports_filter_pushdown) for plan-cache
# discrimination; a `to_dataframe(var self) -> DataFrame` method would pull the
# DataFrame SDK into this package and into the conformance test's edge. When
# the in-pipeline wiring lands, only that small method moves to an SDK-side
# home, as the broker's does.
#
# -----------------------------------------------------------------------------
# WHAT THIS MODULE OWNS
# -----------------------------------------------------------------------------
#   * Searcher — the Copyable SourceLike plan-SPEC. Holds the split IDENTITY
#     (the split bytes by value for a single resolved split + a split_uuid for
#     the fingerprint) + the QueryIR + index name + a cached hit Schema — NOT a
#     deep-copied SplitView. Conforms SourceLike (schema / estimate_rows /
#     fingerprint / supports_filter_pushdown). fingerprint() folds the
#     AnalyzerConfig discriminating fields so two queries that differ only by
#     analyzer settings never collide in the plan cache.
#   * SearchMorselSource — the Movable MorselSourceImpl execute READER. Owns a
#     live SearchCore + a single-shot Atomic cursor on a heap Slab (Atomic is
#     non-Movable; mirror BatchMorselSource). The FIRST next_morsel claim runs
#     SearchCore.search and returns the one HitBatch Morsel; every subsequent
#     claim sees c >= 1 and returns None (single-pass EOF). Re-uses the
#     BatchMorselSource schema-tag guard before returning.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY public signature.
#   * ZERO wildcard origins / unsafe_from_address / take_pointee in this module.
#   * The Atomic single-shot cursor lives on a `Slab[_SearchState]` heap slot
#     (Atomic is non-Movable) — mirror BatchMorselSource EXACTLY. The
#     _SearchState slab element holds a SearchCore (Movable-only, owns the
#     SplitView + TermDictionary) + a QueryIR + a cached Schema + the Atomic
#     cursors — every field either POD, Movable-owned, or Atomic; no
#     heap-owning wildcard-origin pointer field, so no stale-pointer hazard
#     across destroy and recreate. `Slab.get_mut_interior` returns a ref
#     through borrowed self (the SAME pattern BatchMorselSource uses for its
#     immutable-borrow next_morsel).
#
# The SourceLike / MorselSourceImpl conformer methods are `def`, as the traits
# declare them.
# =============================================================================

from std.memory import UnsafePointer, bitcast
from komira_atomic_alias import AtomicI64

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema, SchemaBuilder
from komira_core.collections.slab import Slab
from komira_core.plan.expr import (
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
    COL_SIDE_NONE,
)
from komira_core.plan.scalar_value import ScalarValue

from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl
from komira_core.traits.source_capabilities import SourceCapabilities

from komira_search.analyzer import (
    AnalyzerConfig,
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_DATE,
)
from komira_search.fast_fields import FastFieldReader, FF_ENC_FLOAT_FULL
from komira_search.source import QueryIR, SearchCore, hit_schema
from komira_search.split import SplitView


# =============================================================================
# FNV-1a hash helpers (the same scheme the broker and Parquet sources use).
# =============================================================================


@always_inline
def _fnv1a_offset_basis() -> UInt64:
    return UInt64(14695981039346656037)


@always_inline
def _fnv1a_prime() -> UInt64:
    return UInt64(1099511628211)


def _hash_string(s: String) -> UInt64:
    var h: UInt64 = _fnv1a_offset_basis()
    var prime: UInt64 = _fnv1a_prime()
    var b = s.as_bytes()
    for i in range(len(b)):
        h = (h ^ UInt64(b[i])) * prime
    return h


def _hash_combine(a: UInt64, b: UInt64) -> UInt64:
    return (a ^ b) * _fnv1a_prime()


def _hash_analyzer_config(h_in: UInt64, cfg: AnalyzerConfig) -> UInt64:
    """Fold the AnalyzerConfig discriminating fields into the fingerprint
    ALONGSIDE the query coordinates. Two Searchers with the same query_text but
    different AnalyzerConfig (stopwords on/off, fold on/off -> a DIFFERENT
    matched-term set) MUST produce DIFFERENT fingerprints, else the plan cache /
    CSE structural hash silently self-joins them (the silent-wrong-result class
    the SourceLike trait documents). Folds field_class (UInt8),
    lowercase / ascii_fold / remove_stopwords (Bool) and stopword_set (String)."""
    var h = _hash_combine(h_in, UInt64(cfg.field_class))
    h = _hash_combine(h, UInt64(1) if cfg.lowercase else UInt64(0))
    h = _hash_combine(h, UInt64(1) if cfg.ascii_fold else UInt64(0))
    h = _hash_combine(h, UInt64(1) if cfg.remove_stopwords else UInt64(0))
    h = _hash_combine(h, _hash_string(cfg.stopword_set))
    return h


def _hash_expr_predicate(h_in: UInt64, e: Expr) -> UInt64:
    """Fold the accepted pushed-down predicate into the fingerprint (the
    plan-cache collision guard). Two `_search` requests differing ONLY by a
    filter MUST produce different fingerprints, else the plan cache self-joins
    them -> wrong cached results (the silent-wrong-result class).

    This helper is NON-raising, with its body (which calls the raising Expr
    accessors binary_op / col_ref_name / literal_value / in_list_*) wrapped in
    `try/except`. `Searcher.fingerprint` conforms to the SourceLike.fingerprint
    trait slot, which is NON-raising ("cannot call function that may raise in a
    context that cannot raise"), so the fold helper must itself be non-raising.
    The accessors never actually raise here (every access is tag-checked
    first), so the except-arm is unreachable (returns the partial hash
    defensively).

    Order-canonical: the optimizer emits a right-leaning BIN_AND chain and the
    HTTP layer builds the same shape, so two structurally-equal predicate sets
    hash equal. A literal folds its DType tag (String(dtype) — DType is
    Writable; a string literal folds the DType.invalid sentinel, harmless
    because string_val is also folded unconditionally) + int_val + the Float64
    bit pattern (via `bitcast`, the same idiom komira_search's sink uses — NOT
    .to_bits()) + string_val.
    """
    var h = h_in
    try:
        if e.tag == EXPR_BINARY_OP:
            h = _hash_combine(h, UInt64(e.binary_op()))
            h = _hash_expr_predicate(h, e.binary_left_ref())
            h = _hash_expr_predicate(h, e.binary_right_ref())
        elif e.tag == EXPR_COL_REF:
            h = _hash_combine(h, _hash_string(e.col_ref_name()))
        elif e.tag == EXPR_LITERAL:
            var v = e.literal_value()
            h = _hash_combine(h, _hash_string(String(v.dtype)))
            h = _hash_combine(h, UInt64(v.int_val))
            h = _hash_combine(h, bitcast[DType.uint64](v.float_val))
            h = _hash_combine(h, _hash_string(v.string_val))
        elif e.tag == EXPR_IN_LIST:
            h = _hash_expr_predicate(h, e.in_list_child_ref())
            ref vals = e.in_list_values_ref()
            for i in range(len(vals)):
                h = _hash_combine(h, UInt64(vals[i].int_val))
                h = _hash_combine(h, _hash_string(vals[i].string_val))
    except:
        # Unreachable: every accessor is tag-guarded above. The except-arm only
        # satisfies the non-raising signature.
        pass
    return h


def _hash_agg_specs(h_in: UInt64, query: QueryIR) -> UInt64:
    """Fold EVERY discriminating AggSpec field (the plan-cache collision guard).
    Two `_search` requests differing ONLY by aggregations return different
    responses and MUST hash differently, else the plan cache / CSE structural
    hash silently self-joins them. Load-bearing: fold name/kind/field AND the
    terms knobs (bucket_size/order_code/min_doc_count/missing) — two terms aggs
    differing only by order/min_doc_count/missing would otherwise hash
    identically (wrong cached ordering, the silent-wrong-result class).

    NON-raising: `fingerprint` CONFORMS to the SourceLike.fingerprint trait
    slot, which is non-raising, so this helper must itself be non-raising.
    `aggs_ref()` is a plain `ref` return
    and `_hash_string`/`_hash_combine` never raise — no `try/except` is needed
    (unlike _hash_expr_predicate, whose Expr accessors are raising `def`s). The
    default empty aggs list folds nothing (backward-compatible)."""
    var h = h_in
    ref aggs = query.aggs_ref()
    for i in range(len(aggs)):
        ref a = aggs[i]
        h = _hash_combine(h, _hash_string(a.name))
        h = _hash_combine(h, UInt64(a.kind))
        h = _hash_combine(h, _hash_string(a.field))
        h = _hash_combine(h, UInt64(a.bucket_size))
        h = _hash_combine(h, UInt64(a.order_code))
        h = _hash_combine(h, UInt64(a.min_doc_count))
        h = _hash_combine(h, _hash_string(a.missing))
    return h


# =============================================================================
# _FastFieldMeta: the per-conjunct gate cache.
# =============================================================================


@fieldwise_init
struct _FastFieldMeta(Copyable, Movable, Deinitable):
    """One fast-field's (name, field_class, encoding) — the gate cache element.
    Trivial value type (String value + two UInt8). Held in a
    `List[_FastFieldMeta]` field on the Copyable Searcher — never a byte-slab
    element.

    Built at Searcher.__init__ by walking FastFieldReader.entry_meta_at over
    num_fields() (the reader's `_entries` are private; the public
    entry_meta_at accessor exposes exactly the (name, class, encoding) the gate
    needs without re-parsing the region per conjunct)."""

    var name: String
    var field_class: UInt8
    var encoding: UInt8
    """FF_ENC_FLOAT_FULL marks a float numeric field (a float literal is
    admitted only against a float field; an int literal only against a non-float
    numeric/date field)."""


# =============================================================================
# Searcher: the Copyable SourceLike plan-SPEC.
# =============================================================================


struct Searcher(Copyable, Movable, Deinitable):
    """The Copyable search plan-SPEC — the read-side `SourceLike` conformer.

    Holds the split IDENTITY + bytes + the QueryIR + index name + a cached
    hit Schema — NOT a deep-copied SplitView (the SplitView lives ONLY on the
    Movable SearchMorselSource execute reader, built from these bytes at execute).
    For a single resolved split (no metastore) the "identity" is the split
    bytes themselves (carried by value) + a split_uuid String used in the
    fingerprint. Carrying the bytes on a Copyable spec means a CSE / plan copy
    copies the bytes — acceptable for a single split; a multi-split fan-out
    would carry a list of small split handles instead.

    All fields are Copyable (String / Int / AnalyzerConfig value / List[UInt8] /
    Schema), so this is a GENUINE trait-`Copyable` conformer (synthesized copy()).
    Schema IS Copyable — the cached hit Schema rides freely.

    A stack value / plan-node value, never a byte-slab element. List[UInt8]
    + String fields are fine OUTSIDE a byte-slab; the ban is List/String fields on
    a Movable struct STORED IN a byte-backed slab. Searcher is never slab-stored.

    Fields:
      _split_bytes: the resolved split bytes (the single-split input seam).
      _split_uuid:  a short identity tag for the fingerprint (e.g. a hex uuid).
      _index_name:  the logical index name (folded into the fingerprint).
      _query:       the QueryIR (field_name + query_text + top_k + analyzer_config).
      _hit_schema:  the cached HitBatch schema (eager at construction).
      _fastfield_meta: the filter-pushdown gate cache — the split's fast-field
                    (name, field_class, encoding) set, parsed ONCE at construction
                    from a FastFieldReader over the split bytes. The gate
                    (supports_filter_pushdown) is called per-conjunct in a loop
                    and the SourceLike contract says it is pure/cheap with no I/O,
                    so the field set is resolved at __init__, NOT per call.

    `Expr` is NOT Copyable, so an inline `Optional[Expr]` filter would make
    QueryIR — and hence Searcher — non-synthesizable as `Copyable` (the
    synthesis HARD-FAILS on a non-ImplicitlyCopyable field even with an
    explicit `__copyinit__`/`copy`). So QueryIR (komira_search) carries the
    filter as `Optional[ArcPointer[Expr]]` (ArcPointer IS Copyable — a refcount
    bump over the immutable predicate tree), QueryIR stays genuinely
    trait-`Copyable` (synthesized), and Searcher stays a genuine Copyable
    SourceLike conformer with NO hand-written copy machinery.
    """

    var _split_bytes: List[UInt8]
    var _split_uuid: String
    var _index_name: String
    var _query: QueryIR
    var _hit_schema: Schema
    var _fastfield_meta: List[_FastFieldMeta]

    def __init__(
        out self,
        var split_bytes: List[UInt8],
        var split_uuid: String,
        var index_name: String,
        var query: QueryIR,
    ) raises:
        """Construct a Searcher plan-spec over a resolved split. The hit schema is
        eagerly cached at construction (a pure copy of cached state thereafter —
        the SourceLike `schema()` contract). The fast-field meta cache is
        extracted ONCE here by parsing a FastFieldReader over the split bytes."""
        self._split_bytes = split_bytes^
        self._split_uuid = split_uuid^
        self._index_name = index_name^
        self._query = query^
        self._hit_schema = hit_schema()
        # Extract the fast-field (name, class, encoding) set ONCE. A split with
        # no fast-fields (has_fastfields() False) yields an empty reader -> an
        # empty cache (every conjunct gates False -> kept/raised by the caller).
        self._fastfield_meta = List[_FastFieldMeta]()
        var view = SplitView.parse(self._split_bytes.copy())
        var reader = FastFieldReader(view)
        for i in range(reader.num_fields()):
            var m = reader.entry_meta_at(i)
            self._fastfield_meta.append(
                _FastFieldMeta(m[0], m[1], m[2])
            )

    # NO explicit copy machinery needed. QueryIR carries its filter as
    # `Optional[ArcPointer[Expr]]` (ArcPointer IS Copyable — a refcount bump),
    # so QueryIR is genuinely trait-`Copyable` (synthesized) and `_query` is
    # ImplicitlyCopyable. Every Searcher field is therefore ImplicitlyCopyable
    # (List[UInt8] / String / QueryIR / Schema / List[_FastFieldMeta]), so the
    # synthesized `__copyinit__`/`copy()` works — Searcher stays a genuine
    # Copyable SourceLike conformer with no hand-written copy.

    # =========================================================================
    # SourceLike trait conformance (the trait methods are `def`).
    # =========================================================================

    def schema(self) -> Schema:
        """The HitBatch schema (`_score Float64`, `_id Int64`, `_source STRING`).
        Eager: a pure copy of cached state, no I/O."""
        return self._hit_schema.copy()

    def estimate_rows(self) -> Int:
        """Row-count hint: the page-window bound. A search retains at most
        `from_offset + top_k` candidates (the top-k heap capacity) and returns
        at most `top_k` rows on the page. The estimate is the whole window so a
        paged query's estimate reflects the candidates the leaf must hold."""
        return self._query.from_offset + self._query.top_k

    def fingerprint(self) -> UInt64:
        """Stable identity hash. Plan-cache collision class (see the SourceLike
        trait): MUST be unique per (index, field, query_text, top_k, split_uuid,
        analyzer config) so the plan cache / CSE structural hash never silently
        self-joins two different queries. STABLE across `copy()` / `value^`
        moves.

        Load-bearing: the AnalyzerConfig discriminating fields ARE folded
        (via `_hash_analyzer_config`). Two Searchers with the same query_text but
        different configs (stopwords/fold -> different matched terms) produce
        DIFFERENT fingerprints.

        The metastore seam: the QueryIR.generation (= the search metastore's
        generation, the manifest chunk count the resolution caller stamps) is
        folded at a fixed slot. A re-query AFTER a new publish carries a
        DIFFERENT generation, so it produces a DIFFERENT fingerprint than the
        pre-publish query — the plan cache / CSE structural hash never silently
        self-joins a stale cached plan against the freshened split set. The
        in-memory path (no metastore) leaves generation 0, so the term is a
        no-op until the resolution caller sets query.generation from the
        metastore."""
        var h = _hash_string(self._index_name)
        h = _hash_combine(h, _hash_string(self._query.field_name))
        h = _hash_combine(h, _hash_string(self._query.query_text))
        h = _hash_combine(h, UInt64(self._query.top_k))
        h = _hash_combine(h, _hash_string(self._split_uuid))
        h = _hash_analyzer_config(h, self._query.analyzer_config)
        h = _hash_combine(h, UInt64(self._query.generation))
        # Fold the accepted pushed-down predicate AFTER the generation term. A
        # None filter folds nothing (a match-only query's fingerprint does not
        # depend on the filter fold at all).
        if self._query.has_filter():
            h = _hash_expr_predicate(h, self._query.filter_ref())
        # Fold the sort + page knobs AFTER the filter fold. Two
        # `_search` requests differing ONLY by sort field/order/missing or page
        # offset return DIFFERENT orderings/pages and MUST hash differently, else
        # the plan cache / CSE structural hash silently self-joins them (the
        # silent-wrong-result class). fingerprint is a NON-raising `def`, so
        # this uses ONLY the non-raising helpers; UInt64(from_offset) is safe
        # because the HTTP layer rejects from<0. The default (sort_field=""/
        # SORT_DESC/MISSING_LAST/from_offset=0) folds a fixed suffix — harmless
        # (every match-only query shifts identically; fingerprints compare for
        # equality).
        h = _hash_combine(h, _hash_string(self._query.sort_field))
        h = _hash_combine(h, UInt64(self._query.sort_order))
        h = _hash_combine(h, UInt64(self._query.missing_order))
        h = _hash_combine(h, UInt64(self._query.from_offset))
        # Fold the agg spec AFTER the page knobs. An empty aggs list folds
        # nothing (a match/filter/sort query's fingerprint is unaffected); two
        # queries differing only by aggs hash differently.
        h = _hash_agg_specs(h, self._query)
        return h

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Per-conjunct fast-field classifier — MIRRORS the Parquet source's
        pushdown gate, swapping the parquet-stats gate for
        FastFieldReader.has_field + a field-class/literal-dtype match. Returns
        True only for term(eq/ne) + range(lt/le/gt/ge) + IN + bool-AND over a
        fast-field of the RIGHT class (KEYWORD -> term only; NUMERIC/DATE ->
        term AND range), with the literal-dtype check. False otherwise (kept as
        a downstream Filter on the optimizer path; rejected with a 400 by the
        HTTP layer on the direct path).

        Two-way contract (the SourceLike trait): if this returns True,
        SearchCore MUST apply it correctly — so the accept-set here == the
        apply-step's eval-set (komira_search's fast-field predicate eval)."""
        return self._pushdown_supported(predicate)

    def _pushdown_supported(self, predicate: Expr) -> Bool:
        """Recursive predicate-shape classifier (mirrors parquet's shape).
        Pure (no I/O) — reads only the cached `_fastfield_meta`."""
        if predicate.tag == EXPR_BINARY_OP:
            var op = predicate.binary_op()
            if op == BIN_AND:
                # bool-AND decomposes for free: pushable iff BOTH sides are.
                return self._pushdown_supported(
                    predicate.binary_left_ref()
                ) and self._pushdown_supported(predicate.binary_right_ref())
            elif (
                op == BIN_EQ
                or op == BIN_NE
                or op == BIN_LT
                or op == BIN_LE
                or op == BIN_GT
                or op == BIN_GE
            ):
                # Comparison: one bare col-ref + one literal (order-insensitive).
                # The literal Expr is passed in so the gate can check the
                # literal's dtype against the resolved fast-field class.
                return self._is_ff_colop_literal(
                    predicate.binary_left_ref(), predicate.binary_right_ref(), op
                ) or self._is_ff_colop_literal(
                    predicate.binary_right_ref(), predicate.binary_left_ref(), op
                )
            else:
                # OR / arithmetic -> not pushable.
                return False
        elif predicate.tag == EXPR_IN_LIST:
            # `col IN (lit, ...)` -> eq-union. Pushable iff the child is a bare
            # fast-field col-ref (KEYWORD/NUMERIC/DATE) AND every value's dtype
            # matches the field class.
            ref child = predicate.in_list_child_ref()
            if not self._is_ff_colref(child, BIN_EQ):
                return False
            return self._in_list_values_match_class(child, predicate)
        # bare col-ref / literal / cast / string-op / between / etc.
        return False

    def _is_ff_colop_literal(self, lhs: Expr, rhs: Expr, op: UInt8) -> Bool:
        """True if `lhs` is a bare fast-field col-ref of the right class for `op`
        AND `rhs` is a literal whose dtype matches the field class."""
        if rhs.tag != EXPR_LITERAL:
            return False
        if not self._is_ff_colref(lhs, op):
            return False
        # The literal's effective dtype MUST match the resolved field class.
        var name = lhs.col_ref_name()
        return self._literal_matches_class(name, rhs.literal_value())

    def _is_ff_colref(self, e: Expr, op: UInt8) -> Bool:
        """True if `e` is a bare (COL_SIDE_NONE) col-ref whose name has a
        fast-field of the right class for `op`: KEYWORD -> term(eq/ne) only (range
        rejected); NUMERIC/DATE -> term AND range."""
        if e.tag != EXPR_COL_REF:
            return False
        if e.col_ref_side() != COL_SIDE_NONE:
            return False
        var name = e.col_ref_name()
        for i in range(len(self._fastfield_meta)):
            ref m = self._fastfield_meta[i]
            if m.name == name:
                var is_range = (
                    op == BIN_LT or op == BIN_LE or op == BIN_GT or op == BIN_GE
                )
                if m.field_class == FIELD_CLASS_KEYWORD:
                    return not is_range  # KEYWORD: term only.
                elif (
                    m.field_class == FIELD_CLASS_NUMERIC
                    or m.field_class == FIELD_CLASS_DATE
                ):
                    return True  # NUMERIC/DATE: term AND range.
                return False
        return False  # not a fast-field -> not pushed.

    def _meta_index(self, name: String) -> Int:
        """The `_fastfield_meta` index for `name`, or -1 if absent."""
        for i in range(len(self._fastfield_meta)):
            if self._fastfield_meta[i].name == name:
                return i
        return -1

    def _literal_matches_class(self, name: String, lit: ScalarValue) -> Bool:
        """Reject a conjunct whose literal dtype does not match the resolved
        fast-field class. Matrix: KEYWORD field <- string-sentinel literal;
        NUMERIC-int / DATE field <- int (or date/timestamp) literal; NUMERIC-float
        field <- float literal. A STRING literal is the DType.invalid + non-empty
        string_val SENTINEL (see ScalarValue), NOT a real dtype."""
        var mi = self._meta_index(name)
        if mi < 0:
            return False
        ref m = self._fastfield_meta[mi]
        if m.field_class == FIELD_CLASS_KEYWORD:
            return lit.is_string()
        # NUMERIC or DATE.
        if m.encoding == FF_ENC_FLOAT_FULL:
            # float numeric field: only a float literal.
            return lit.is_float()
        # int numeric / date field: an int literal, OR a date32 / timestamp
        # literal (DATE field). Reject string + float + bool + null.
        return (
            lit.is_int()
            or lit.is_date32()
            or lit.is_timestamp()
        )

    def _in_list_values_match_class(self, child: Expr, pred: Expr) -> Bool:
        """The literal-dtype check for IN: every value's dtype must match the
        field class."""
        var name = child.col_ref_name()
        ref vals = pred.in_list_values_ref()
        if len(vals) == 0:
            return False
        for i in range(len(vals)):
            if not self._literal_matches_class(name, vals[i]):
                return False
        return True

    # =========================================================================
    # Accessors for the execute reader.
    # =========================================================================

    def query(self) -> QueryIR:
        return self._query.copy()

    def split_uuid(self) -> String:
        return self._split_uuid

    def index_name(self) -> String:
        return self._index_name

    def split_bytes_copy(self) -> List[UInt8]:
        """An owned COPY of the split bytes (the execute reader consumes owned
        bytes to build the SearchCore — SplitView.parse consumes them)."""
        return self._split_bytes.copy()


# =============================================================================
# _SearchState: the heap slab element (Atomic cursor + live core + cache).
# =============================================================================
#
# Not Movable / Copyable — it lives exactly once on the heap (allocated by
# SearchMorselSource.__init__, destroyed by its auto-synth Slab destructor).
# Atomic fields are assigned in place. Mirrors BatchMorselSource._State.
# =============================================================================


struct _SearchState:
    """Heap slab element for SearchMorselSource. Audited: a Movable-owned
    SearchCore + a Copyable QueryIR + a cached Schema + two Atomic cursors. No
    heap-owning wildcard field; the only pointer access is via
    Slab.get_mut_interior (the established immutable-borrow idiom).

    The HitBatch is NOT cached: `RecordBatch` is Movable-only (no copy), so
    caching one would force a per-claim copy that the type does not support.
    Instead the FIRST next_morsel claim runs `core.search(query)` (an
    immutable-self READ over the heap-resident SearchCore — reachable via the
    state pointer) and MOVES the fresh RecordBatch straight into the returned
    Morsel. The single-shot Atomic cursor guarantees `search` runs exactly once.
    `total_rows` is resolved at construction by a one-shot search-count peek so
    `row_count_hint()` (an immutable read with no move) has a value to return.

    Fields:
      core           — the live SearchCore (owns the SplitView + TermDictionary).
      query          — the QueryIR to execute (Copyable; re-read per search call).
      schema         — the HitBatch schema (for output_schema + the tag guard).
      cursor         — single-shot claim cursor (fetch_add 0 -> 1 yields the one
                       morsel; subsequent claims see c >= 1 -> EOF).
      morsel_counter — monotonic morsel_id stamp.
      total_rows     — cached hit row count (peeked at construction) for
                       row_count_hint.
    """

    var core: SearchCore
    var query: QueryIR
    var schema: Schema
    var cursor: AtomicI64
    var morsel_counter: AtomicI64
    var total_rows: Int


# =============================================================================
# SearchMorselSource: the Movable MorselSourceImpl execute READER.
# =============================================================================


struct SearchMorselSource(MorselSourceImpl):
    """The Movable `MorselSourceImpl` execute reader over a single split. Built
    FROM a `Searcher` spec at execute time (`from_spec`); owns the live
    SearchCore + a single-shot Atomic cursor.

    Single-pass contract: the FIRST `next_morsel` claim (cursor fetch_add
    0 -> 1) returns the one HitBatch Morsel; every subsequent claim sees c >= 1
    (n == 1) and returns `None` (the single-pass EOF, as in BatchMorselSource).
    Shared mutable state (the cursor) lives behind `Atomic` per the immutable-
    borrow rule (see the MorselSourceImpl trait).

    Construction peeks the hit count once (for `row_count_hint`); the HitBatch
    itself is produced by the first `next_morsel` claim and moved into the
    returned Morsel. A multi-split fan-out would claim split i behind the same
    Atomic cursor inside SearchCore — that does not change the conformance.
    """

    # Single-element heap slab holding the Movable-incompatible _SearchState (it
    # has Atomic fields). Slab[_SearchState].create_prefilled(1) zero-fills so
    # direct assignment to Atomic fields does not run destructors on
    # uninitialized memory; Movable fields are init via init_pointee_move. The
    # auto-synth Slab destructor destroys the slot + frees the buffer.
    var _state: Slab[_SearchState]

    def __init__(out self, var core: SearchCore, var query: QueryIR) raises:
        """Build the reader: peek the hit row count ONCE (for row_count_hint),
        cache the hit schema, store the live core + query, and heap-allocate the
        single-shot state slab. The ACTUAL HitBatch is produced lazily by the
        first `next_morsel` claim (RecordBatch is Movable-only / non-copyable, so
        it cannot be cached and handed out per claim — it is moved straight into
        the one returned Morsel). `core` is the live SearchCore (already parsed);
        `query` is the QueryIR to execute."""
        # One-shot peek at construction: run the search to learn the hit count +
        # schema. `core` is a local `var` here so the immutable-self borrow is
        # fine; the result batch is discarded (only its row count + schema are
        # kept). The real search re-runs once on the first next_morsel claim.
        # `query.copy()` keeps `query` intact for the init_pointee_move below
        # (QueryIR is Copyable, not ImplicitlyCopyable).
        var peek = core.search(query.copy())
        var sch = peek.batch.schema.copy()
        var rows = peek.batch.num_rows()
        _ = peek^

        self._state = Slab[_SearchState].create_prefilled(1)
        # SAFETY: slot 0 is the only slot, zero-filled by create_prefilled; we
        # init each field exactly once before any field-destroying mutation. The
        # state slab outlives every next_morsel call (it is a self field).
        var state_ptr = UnsafePointer(to=self._state.get_mut_interior(0))
        UnsafePointer(to=state_ptr[].core).unsafe_write(core^)
        UnsafePointer(to=state_ptr[].query).unsafe_write(query^)
        UnsafePointer(to=state_ptr[].schema).unsafe_write(sch^)
        state_ptr[].cursor = AtomicI64(0)
        state_ptr[].morsel_counter = AtomicI64(0)
        state_ptr[].total_rows = rows

    @staticmethod
    def from_spec(spec: Searcher) raises -> Self:
        """Build the live execute reader FROM the Copyable plan spec — the
        spec->reader construction seam. Parses the spec's split bytes into a
        SearchCore (consuming an owned copy) and runs the spec's QueryIR."""
        var core = SearchCore(spec.split_bytes_copy())
        return Self(core^, spec.query())

    # NOTE: No __del__. Slab runs its auto-synth destructor on drop.

    # =========================================================================
    # MorselSourceImpl trait conformance (the trait methods are `def`).
    # =========================================================================

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        """Single-shot claim. The FIRST caller (cursor fetch_add 0 -> 1) runs
        `core.search(query)` and gets the one HitBatch Morsel; every subsequent
        caller sees c >= 1 (n == 1) and returns `None` (the single-pass EOF
        contract).

        IMMUTABLE self: the only mutation of `self` is the Atomic fetch_add on
        the cursor + morsel_counter (race-free). `core.search` is an
        immutable-self READ over the heap-resident SearchCore (reached via the
        state pointer); the fresh RecordBatch it returns is MOVED into the Morsel
        — no field of `self` is moved out, so the immutable borrow holds. The
        single-shot cursor guarantees the search runs exactly once.

        Re-uses the BatchMorselSource schema-tag guard: assert each assembled
        column's arrow_type matches the cached schema before returning, so a
        silent column-type drift in the doc-store / score assembly is LOUD."""
        # SAFETY: state_ptr lifetime is tied to self._state which outlives this
        # call; slot 0 is initialized in __init__.
        var state_ptr = UnsafePointer(to=self._state.get_mut_interior(0))
        var c = Int(state_ptr[].cursor.fetch_add(Int64(1)))
        if c >= 1:
            return None  # single-shot EOF.

        var mid = Int(state_ptr[].morsel_counter.fetch_add(Int64(1)))
        # Run the search now (the one-and-only claim). `core.search` is an
        # immutable-self read; the result is a fresh owned SearchResult. The
        # QueryIR is explicitly copied (it is Copyable, not ImplicitlyCopyable).
        # The SourceLike reader path returns ONLY the RecordBatch per the trait
        # (total_matches is an HTTP response-envelope concern).
        var result = state_ptr[].core.search(state_ptr[].query.copy())
        var batch = result.take_batch()

        # Schema-tag guard (as in BatchMorselSource): tag-compare only, O(cols).
        var cached_cols = state_ptr[].schema.num_columns()
        var batch_cols = batch.num_columns()
        if cached_cols != batch_cols:
            raise Error(
                "SearchMorselSource: HitBatch column count "
                + String(batch_cols)
                + " != cached schema column count "
                + String(cached_cols)
            )
        for ci in range(cached_cols):
            var schema_tag = state_ptr[].schema.field_arrow_type(ci)
            ref col = batch.column_at(ci)
            if schema_tag != col.arrow_type:
                raise Error(
                    "SearchMorselSource: HitBatch column "
                    + String(ci)
                    + " arrow_type mismatch with cached schema"
                )
        return Morsel(batch^, mid, 0)

    def output_schema(self) -> Schema:
        """Return a copy of the cached HitBatch schema (Schema IS Copyable)."""
        return self._state.get_mut_interior(0).schema.copy()

    def partition_hint(self) -> Int:
        """A single split is one logical partition."""
        return 1

    def row_count_hint(self) -> Int:
        return self._state.get_mut_interior(0).total_rows

    def capabilities(self) -> SourceCapabilities:
        """No hooks advertised. The search result is produced whole by the
        first claim; projection / decode-filter / pushdown are fast-field
        concerns of SearchCore, not source hooks here."""
        return SourceCapabilities(
            supports_projection=False,
            supports_decode_filter=False,
            supports_dict_preservation=False,
            supports_dynamic_filter=False,
            supports_row_group_pruning=False,
            supports_bypass_columns=False,
            supports_as_source=False,
        )
