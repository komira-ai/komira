# =============================================================================
# komira_search_runtime/search_source.mojo
#   The split-reading half of the `komira.search.index` scan kind: the
#   fast-field pushdown classifier, the analyzer fingerprint, and the one call
#   that turns (SearchCore, QueryIR) into a hit batch.
# =============================================================================
#
# THE PACKAGE-DAG DECISION (keep komira_search light).
# -----------------------------------------------------------------------------
# `komira_search` depends only on komira_core + komira_eval (+ komira_lz4).
# The scan-kind contract (`ScanSourceResolver`) lives in komira_scan_resolver,
# which depends on komira_core alone. This package joins the two and adds
# nothing else: it does not depend on the morsel layer or on any engine, so a
# context that executes the kind links it without pulling the executor into
# the search build, and its tests construct no executor.
#
# -----------------------------------------------------------------------------
# THE PLAN-SIDE IDENTITY IS NOT HERE ANY MORE
# -----------------------------------------------------------------------------
# This module used to own `Searcher`, a Copyable plan SPEC carrying the
# SourceLike method surface (schema / estimate_rows / fingerprint /
# supports_filter_pushdown), and `SearchMorselSource`, a single-shot morsel
# reader over one split. `Searcher.fingerprint()` folded the index GENERATION
# into the scan's IDENTITY, so every publish changed the plan-cache key -- the
# opposite of what a LIVE scan wants -- and it was a second way to express the
# scan the `komira.search.index` kind now expresses (`search_scan_kind.mojo`).
# Both are RETIRED. What survives, because the kind needs it:
#   * `FastFieldPushdownGate` -- the per-conjunct fast-field classifier the
#     spec carried (same accept-set, same literal/class matrix). The kind uses
#     it to lower fast-field conjuncts into `QueryIR._filter`.
#   * `analyzer_config_fingerprint` -- the AnalyzerConfig fold, which is the
#     kind's `analyzer_fp` param.
#   * `search_split_hits` -- what the morsel reader did, minus the morsel: run
#     the query once over one split and check the batch against the hit
#     schema before handing it on.
# A scan's identity is now the kind's `ScanBinding` (params
# {index, field, query, analyzer_fp}; the generation is a LIVE snapshot token
# resolved per execution, or a PINNED one the caller states). Sort, page,
# filter and aggregation are PLAN operators above that scan, and the plan's
# structural hash is what separates two plans that differ by them.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY
# -----------------------------------------------------------------------------
#   * No UnsafePointer anywhere in this module.
#   * No wildcard origins / unsafe_from_address / take_pointee.
#   * FastFieldPushdownGate is a stack value holding a List of plain value
#     structs; it is never stored in a byte-backed slab.
# =============================================================================

from komira_core.arrow.record_batch import RecordBatch
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
    """Fold the AnalyzerConfig discriminating fields. Two scans with the same
    query text but a different AnalyzerConfig (stopwords on/off, fold on/off
    -> a DIFFERENT matched-term set) MUST get different values, else the plan
    cache / CSE structural hash silently self-joins them. Folds field_class
    (UInt8), lowercase / ascii_fold / remove_stopwords (Bool) and
    stopword_set (String)."""
    var h = _hash_combine(h_in, UInt64(cfg.field_class))
    h = _hash_combine(h, UInt64(1) if cfg.lowercase else UInt64(0))
    h = _hash_combine(h, UInt64(1) if cfg.ascii_fold else UInt64(0))
    h = _hash_combine(h, UInt64(1) if cfg.remove_stopwords else UInt64(0))
    h = _hash_combine(h, _hash_string(cfg.stopword_set))
    return h


def analyzer_config_fingerprint(cfg: AnalyzerConfig) -> UInt64:
    """The fold of an AnalyzerConfig's DISCRIMINATING fields, seeded at the
    FNV-1a offset basis. Two configs that analyze one text to different term
    sets (stopwords on/off, case/ascii folding on/off, another stopword set,
    another field class) get different values.

    This is the `komira.search.index` kind's `analyzer_fp` param: the plan
    carries it so a plan built against one analyzer is never executed against
    an index whose field now analyzes differently (the kind refuses by name)."""
    return _hash_analyzer_config(_fnv1a_offset_basis(), cfg)


# =============================================================================
# _FastFieldMeta: the per-conjunct gate cache element.
# =============================================================================


@fieldwise_init
struct _FastFieldMeta(Copyable, Movable, Deinitable):
    """One fast-field's (name, field_class, encoding) — the gate cache element.
    Trivial value type (String value + two UInt8). Held in a
    `List[_FastFieldMeta]` field on the Copyable FastFieldPushdownGate — never
    a byte-slab element.

    Built at FastFieldPushdownGate.__init__ by walking
    FastFieldReader.entry_meta_at over num_fields() (the reader's `_entries`
    are private; the public entry_meta_at accessor exposes exactly the
    (name, class, encoding) the gate needs without re-parsing the region per
    conjunct)."""

    var name: String
    var field_class: UInt8
    var encoding: UInt8
    """FF_ENC_FLOAT_FULL marks a float numeric field (a float literal is
    admitted only against a float field; an int literal only against a non-float
    numeric/date field)."""


# =============================================================================
# FastFieldPushdownGate: the per-conjunct fast-field classifier.
# =============================================================================


struct FastFieldPushdownGate(Copyable, Movable, Deinitable):
    """Which predicate conjuncts a split's fast-fields can evaluate.

    MIRRORS the Parquet source's pushdown gate, swapping the parquet-stats
    gate for the split's fast-field set + a field-class/literal-dtype match.
    Accepts only term(eq/ne) + range(lt/le/gt/ge) + IN + bool-AND over a
    fast-field of the RIGHT class (KEYWORD -> term only; NUMERIC/DATE -> term
    AND range), with the literal-dtype check. Anything else is rejected (kept
    as a plan Filter above the scan kind; rejected with a 400 by the HTTP
    layer on its direct path).

    Two-way contract: an accepted conjunct MUST be applied correctly by
    SearchCore, so the accept-set here == the apply-step's eval-set
    (komira_search's fast-field predicate eval).

    Built ONCE per split: the fast-field (name, class, encoding) set is parsed
    from a FastFieldReader at construction, so the per-conjunct call is pure
    and does no I/O.
    """

    var _fastfield_meta: List[_FastFieldMeta]

    def __init__(out self, view: SplitView) raises:
        """Read the split's fast-field set. A split with no fast-fields yields
        an empty set -> every conjunct is rejected."""
        self._fastfield_meta = List[_FastFieldMeta]()
        var reader = FastFieldReader(view)
        for i in range(reader.num_fields()):
            var m = reader.entry_meta_at(i)
            self._fastfield_meta.append(_FastFieldMeta(m[0], m[1], m[2]))

    @staticmethod
    def from_split_bytes(split_bytes: List[UInt8]) raises -> Self:
        """Parse a COPY of `split_bytes` (SplitView.parse consumes owned bytes)."""
        var view = SplitView.parse(split_bytes.copy())
        return Self(view)

    def num_fast_fields(self) -> Int:
        return len(self._fastfield_meta)

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """True iff SearchCore can evaluate `predicate` exactly over this
        split's fast-fields (see the struct doc for the accept-set)."""
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


# =============================================================================
# search_split_hits: one query over one split.
# =============================================================================


def search_split_hits(core: SearchCore, query: QueryIR) raises -> RecordBatch:
    """Run `query` over the split `core` holds and return its hit batch
    (`_score Float64`, `_id Int64`, `_source STRING`), ranked as
    `SearchCore.search` ranks it.

    The batch is checked column by column against `hit_schema()` before it is
    returned (a tag compare, O(columns)), so a column-type drift in the
    doc-store or score assembly is an error here and not a silently mistyped
    row downstream."""
    var result = core.search(query)
    var batch = result.take_batch()
    var want = hit_schema()
    var want_cols = want.num_columns()
    var got_cols = batch.num_columns()
    if want_cols != got_cols:
        raise Error(
            "search_split_hits: hit batch column count "
            + String(got_cols)
            + " != hit schema column count "
            + String(want_cols)
        )
    for ci in range(want_cols):
        ref col = batch.column_at(ci)
        if want.field_arrow_type(ci) != col.arrow_type:
            raise Error(
                "search_split_hits: hit batch column "
                + String(ci)
                + " arrow_type does not match the hit schema"
            )
    return batch^
