# =============================================================================
# komira_search_runtime/search_scan_kind.mojo -- the `komira.search.index`
# scan kind.
# =============================================================================
#
# A search index is an ACCESS PATH over a relation: a scan of kind
# `komira.search.index` over `{index, field, query, analyzer_fp}` returns one
# hit row per matching live document (`_score Float64`, `_id Int64`,
# `_source STRING` -- `komira_search.source.hit_schema`). Filter, sort, page
# and aggregation are ordinary PLAN operators above the scan.
#
# WHAT THIS FILE OWNS
#   * the kind's NAME (`komira.search.index`), its
#     descriptor, its binding builder and its identity corpus;
#   * `SearchIndexCatalog` -- the trait a store implements so the kind can ask
#     "which generation is live" and "which splits were live at generation g";
#     `InMemorySearchIndexCatalog` is the in-process conformer;
#   * `SearchScanRuntime[C]` -- the tier-2 `ScanMorselResolver` the engine
#     executes, and `search_scan_runtime(catalog^)`, which erases it.
#
# THE SNAPSHOT. The generation is a LIVE snapshot by default: the plan carries
# token 0, identity excludes it (so the plan cache hits across a publish), and
# `resolve_snapshot` re-reads the catalog's current generation at every
# execution. A caller that wants a PINNED read states the generation as the
# `generation` param. It is a PARAM, not `SNAPSHOT_PINNED`, on purpose:
# `ScanKindRegistry.validate` holds every binding of a kind to the descriptor's
# ONE snapshot policy, so a second policy for the same kind would be refused at
# bind. As a param it is folded into identity (two pins are two plans) and
# `resolve_snapshot` returns it verbatim, so the per-execution token IS the
# pinned generation.
#
# `field` IS OPTIONAL. A binding built without it gets the field from the
# catalog at bind time (`build_binding`), and only when the index has EXACTLY
# ONE analyzed text field. Otherwise the build is refused by name
# (`SEARCH_FIELD_AMBIGUOUS`, listing the candidate fields); the kind never
# guesses. The derived field is WRITTEN INTO the binding, so a scan of `logs`
# with no field and the same scan with `field=body` over a one-field index are
# the SAME plan: same params, same fingerprint. The identity corpus's
# `field_derived` entry pins that.
#
# A SCAN WITH NO QUERY IS SUPPORTED. `query == ""` scans every live
# document of the index at the resolved generation through the existing
# no-term arm of `SearchCore` (`QueryIR.match_all`), each row scored 0.0. It
# is not refused: an index read as a relation, then filtered, needs it. A
# NON-empty query that analyzes to no terms (all stopwords) still matches
# nothing -- `match` semantics are unchanged.
#
# SCOPE, STATED SO NOBODY OVERREADS IT
#   * `open_scan` DRAINS every live split into resident batches; it does not
#     stream morsels into the walker.
#   * `_id` is SPLIT-LOCAL (a split's doc-id space), exactly as `SearchCore`
#     returns it; two splits can carry the same `_id`.
#   * Fast-field conjuncts in `ScanRequest.predicate` are LOWERED into
#     `QueryIR._filter` (`FastFieldPushdownGate`), but the hit schema carries no
#     fast-field COLUMN, so a plan Filter cannot name one yet; the lowering is
#     reachable through a direct `ScanRequest`. A `match(...)` predicate is
#     not lowered here.
#   * The product catalog over the S3 `SearchMetastore` is not here; the
#     in-memory catalog is what in-process registration and the tests use.
#
# ENCAPSULATION: no UnsafePointer anywhere in this file; the erasure is
# `ErasedScanMorselResolver.erase[R]` (komira_scan_resolver), which owns its
# SAFETY.
# =============================================================================

from std.memory import ArcPointer

from komira_core.arrow.record_batch import RecordBatch
from komira_core.collections.slab import Slab
from komira_core.plan.expr import Expr, BIN_AND
from komira_core.plan.expr_helpers import flatten_and_conjuncts
from komira_core.source.pushdown_gate import PushdownGate
from komira_core.source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_EPOCH_NONE,
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_LIVE,
)
from komira_core.source.scan_identity_audit import ScanIdentityCorpus
from komira_core.source.scan_kind_registry import ScanKindDescriptor
from komira_core.source.scan_params import (
    ScanParams,
    param_hash_combine,
    param_hash_string,
)

from komira_scan_resolver.scan_morsel_resolver import (
    ErasedScanMorselResolver,
    ScanMorselResolver,
    ScanOpened,
    ScanRequest,
)

from komira_search.analyzer import AnalyzerConfig
from komira_search.source import QueryIR, SearchCore, hit_schema
from komira_search.split import SplitView

from .search_source import (
    FastFieldPushdownGate,
    analyzer_config_fingerprint,
    search_split_hits,
)


# =============================================================================
# names
# =============================================================================

comptime SEARCH_SCAN_KIND_NAME: String = "komira.search.index"
"""Reverse-DNS kind name. `kind_id` is its FNV-1a/32 hash -- no central
table allocates it."""

comptime SEARCH_PARAM_INDEX: String = "index"
comptime SEARCH_PARAM_FIELD: String = "field"
"""OPTIONAL at build: absent = derived from the catalog when the index has
exactly one analyzed text field (`SEARCH_FIELD_AMBIGUOUS` otherwise). Every
binding the kind BUILDS carries it."""
comptime SEARCH_PARAM_QUERY: String = "query"
"""The raw query text, analyzed at execution with the index's analyzer. ""
is the no-query scan: every live document."""
comptime SEARCH_PARAM_ANALYZER_FP: String = "analyzer_fp"
"""`analyzer_config_fingerprint` of the analyzer the plan was built against.
`build_binding` fills it from the catalog when the caller omits it."""
comptime SEARCH_PARAM_GENERATION: String = "generation"
"""OPTIONAL. Present = a PINNED read at that generation; absent = LIVE."""

comptime SEARCH_RESOLVED_GENERATION: String = "generation"
"""The `ScanOpened.resolved` key: the generation this execution read."""

comptime SEARCH_INDEX_UNKNOWN: StaticString = "SEARCH_INDEX_UNKNOWN"
"""NAMED ERROR -- the catalog holds no index of that name (or no such field)."""

comptime SEARCH_FIELD_AMBIGUOUS: StaticString = "SEARCH_FIELD_AMBIGUOUS"
"""NAMED ERROR -- no `field` was stated and the index does not have exactly
one analyzed text field, so there is nothing to derive without guessing. The
message lists the candidate fields."""

comptime SEARCH_ANALYZER_MISMATCH: StaticString = "SEARCH_ANALYZER_MISMATCH"
"""NAMED ERROR -- the plan's `analyzer_fp` is not the analyzer the index's
field uses now. Executing anyway would analyze the query with an analyzer the
plan never saw, so a different term set would match with nothing going red."""

comptime SEARCH_GENERATION_NOT_AVAILABLE: StaticString = (
    "SEARCH_GENERATION_NOT_AVAILABLE"
)
"""NAMED ERROR -- a pinned generation the catalog cannot serve (beyond the
current one, or negative)."""


def search_scan_kind_id() -> UInt32:
    return scan_kind_id(String(SEARCH_SCAN_KIND_NAME))


def _search_gate() -> PushdownGate:
    """The conjunctive-comparison family, no column statistics required: the
    same bit the broker kind declares. What the kind can actually evaluate is
    decided per split by `FastFieldPushdownGate`; a conjunct it cannot evaluate
    is simply not lowered, and the engine keeps the whole filter above the
    scan either way."""
    return PushdownGate.conjunctive_comparison(require_stat_friendly_col=False)


def search_scan_descriptor() -> ScanKindDescriptor:
    var req = List[String]()
    # `field` is NOT required: `build_binding` derives it (header).
    req.append(String(SEARCH_PARAM_INDEX))
    return ScanKindDescriptor(
        kind_name=String(SEARCH_SCAN_KIND_NAME),
        gate=_search_gate(),
        orientation=SCAN_ORIENTATION_COLUMNAR,
        snapshot_policy=SNAPSHOT_LIVE,
        required_params=req^,
    )


def _identity_of(params: ScanParams) -> UInt64:
    """A CONTENT-derived identity, stable across processes: the kind id folded
    with every param. It is a function of exactly what core's own
    `identity_hash()` folds (params), so it is never finer than core (audit
    R2), and it carries no construction counter (audit R9)."""
    return params.hash_into(
        param_hash_string(
            String(SEARCH_SCAN_KIND_NAME), UInt64(search_scan_kind_id())
        )
    )


def search_scan_binding(
    var index: String,
    var field: String,
    var query: String,
    analyzer_fp: UInt64,
    generation: Optional[Int64] = None,
) raises -> ScanBinding:
    """The plan-side identity token for a `komira.search.index` scan.

    Carries no split bytes, no SearchCore and no store handle, so it is
    Copyable and serializable. `generation` None = LIVE (token 0 in the plan,
    re-resolved per execution); a value = PINNED at that generation."""
    var params = ScanParams()
    params.put_str(String(SEARCH_PARAM_INDEX), String(index))
    params.put_str(String(SEARCH_PARAM_FIELD), field^)
    params.put_str(String(SEARCH_PARAM_QUERY), query^)
    params.put_u64(String(SEARCH_PARAM_ANALYZER_FP), analyzer_fp)
    if generation:
        var g = generation.value()
        if g < Int64(0):
            raise Error(
                String(SEARCH_GENERATION_NOT_AVAILABLE)
                + String(": a pinned generation cannot be negative (got ")
                + String(g)
                + String(")")
            )
        params.put_i64(String(SEARCH_PARAM_GENERATION), g)
    var fp = _identity_of(params)
    return ScanBinding(
        kind_id=search_scan_kind_id(),
        kind_name=String(SEARCH_SCAN_KIND_NAME),
        name=index^,
        params=params^,
        schema=hit_schema(),
        fingerprint=fp,
        structural_id=fp,
        gate=_search_gate(),
        snapshot_policy=SNAPSHOT_LIVE,
        # ZERO, always, in a plan: a LIVE token is written only to the
        # per-execution copy (`resolve_for_execution`).
        snapshot_token=UInt64(0),
        orientation=SCAN_ORIENTATION_COLUMNAR,
    )


def search_scan_identity_corpus() raises -> ScanIdentityCorpus:
    """This kind's statement of what makes two of its scans different: every
    param it folds, varied one at a time against a baseline, plus a pinned
    generation (two pins of one query are two plans)."""
    var cfg = AnalyzerConfig.text(String("body"))
    var afp = analyzer_config_fingerprint(cfg)
    var other = AnalyzerConfig.text(String("body"))
    other.remove_stopwords = not other.remove_stopwords
    var afp2 = analyzer_config_fingerprint(other)
    var c = ScanIdentityCorpus(search_scan_descriptor())
    c.add(
        String("baseline"),
        search_scan_binding(
            String("logs"), String("body"), String("error"), afp
        ),
    )
    c.add(
        String("index"),
        search_scan_binding(
            String("audit"), String("body"), String("error"), afp
        ),
    )
    c.add(
        String("field"),
        search_scan_binding(
            String("logs"), String("title"), String("error"), afp
        ),
    )
    c.add(
        String("query"),
        search_scan_binding(
            String("logs"), String("body"), String("timeout"), afp
        ),
    )
    # `field` OMITTED, derived by the kind from a one-field catalog. It must
    # fingerprint EXACTLY as `baseline` (the same scan, spelled without the
    # field); `test_a_derived_field_is_the_explicit_fields_identity` asserts
    # that equality by label.
    var one_field = InMemorySearchIndexCatalog()
    one_field.create_index(String("logs"), String("body"), cfg.copy())
    var derived_params = ScanParams()
    derived_params.put_str(String(SEARCH_PARAM_INDEX), String("logs"))
    derived_params.put_str(String(SEARCH_PARAM_QUERY), String("error"))
    c.add(
        String("field_derived"),
        SearchScanRuntime[InMemorySearchIndexCatalog](
            one_field^
        ).build_binding(derived_params),
    )
    c.add(
        String("no_query"),
        search_scan_binding(String("logs"), String("body"), String(""), afp),
    )
    c.add(
        String("analyzer_fp"),
        search_scan_binding(
            String("logs"), String("body"), String("error"), afp2
        ),
    )
    c.add(
        String("generation_pinned"),
        search_scan_binding(
            String("logs"),
            String("body"),
            String("error"),
            afp,
            Optional[Int64](Int64(3)),
        ),
    )
    c.add(
        String("generation_pinned_other"),
        search_scan_binding(
            String("logs"),
            String("body"),
            String("error"),
            afp,
            Optional[Int64](Int64(4)),
        ),
    )
    return c^


# =============================================================================
# the catalog seam
# =============================================================================


trait SearchIndexCatalog(Movable, Deinitable):
    """What the kind needs from an index store, and nothing else.

    `generation(index)` is the CURRENT generation: it must CHANGE whenever the
    live split set changes (a publish), because it is the LIVE snapshot token.
    `splits_at(index, g)` returns the bytes of every split live AT generation
    `g`, in publish order; `g` above the current generation is refused by name
    (`SEARCH_GENERATION_NOT_AVAILABLE`)."""

    def generation(self, index: String) raises -> Int64:
        ...

    def analyzer(self, index: String, field: String) raises -> AnalyzerConfig:
        ...

    def fields(self, index: String) raises -> List[String]:
        """Every analyzed text field of `index`, in declaration order. Raises
        `SEARCH_INDEX_UNKNOWN` for an index the catalog does not hold. The
        kind derives an omitted `field` from this list ONLY when it has
        exactly one entry."""
        ...

    def splits_at(
        self, index: String, generation: Int64
    ) raises -> List[List[UInt8]]:
        ...


@fieldwise_init
struct _CatalogIndex(Copyable, Movable, Deinitable):
    """One index of the in-memory catalog. Split `i` was published at
    generation `i + 1`, so generation `g` sees splits `[0, g)`. `fields[i]`
    analyzes with `analyzers[i]` (parallel Lists: an index has a handful of
    fields). A List element, never a byte-slab element."""

    var name: String
    var fields: List[String]
    var analyzers: List[AnalyzerConfig]
    var splits: List[List[UInt8]]


struct InMemorySearchIndexCatalog(SearchIndexCatalog, Movable, Deinitable):
    """The in-process catalog: an index is created with one analyzed text
    field and may gain more (`add_field`); splits are appended by `publish`.
    It keeps every published split, so every
    generation it ever reported can be read back exactly (no compaction)."""

    var _indexes: List[_CatalogIndex]

    def __init__(out self):
        self._indexes = List[_CatalogIndex]()

    def _find(self, index: String) -> Int:
        for i in range(len(self._indexes)):
            if self._indexes[i].name == index:
                return i
        return -1

    def _find_or_raise(self, index: String) raises -> Int:
        var at = self._find(index)
        if at < 0:
            raise Error(
                String(SEARCH_INDEX_UNKNOWN)
                + String(": no search index '")
                + index
                + String("' in this catalog")
            )
        return at

    def create_index(
        mut self, var name: String, var field: String, var analyzer: AnalyzerConfig
    ) raises:
        if self._find(name) >= 0:
            raise Error(
                String("InMemorySearchIndexCatalog: index '")
                + name
                + String("' already exists")
            )
        var fields = List[String]()
        fields.append(field^)
        var analyzers = List[AnalyzerConfig]()
        analyzers.append(analyzer^)
        self._indexes.append(
            _CatalogIndex(name^, fields^, analyzers^, List[List[UInt8]]())
        )

    def add_field(
        mut self, index: String, var field: String, var analyzer: AnalyzerConfig
    ) raises:
        """Declare one more analyzed text field on `index`. An index with two
        or more fields cannot have its field derived: a scan over it must
        state `field` (`SEARCH_FIELD_AMBIGUOUS` otherwise)."""
        var at = self._find_or_raise(index)
        for i in range(len(self._indexes[at].fields)):
            if self._indexes[at].fields[i] == field:
                raise Error(
                    String("InMemorySearchIndexCatalog: index '")
                    + index
                    + String("' already has field '")
                    + field
                    + String("'")
                )
        self._indexes[at].fields.append(field^)
        self._indexes[at].analyzers.append(analyzer^)

    def publish(mut self, index: String, var split_bytes: List[UInt8]) raises -> Int64:
        """Append one split; returns the NEW generation."""
        var at = self._find_or_raise(index)
        self._indexes[at].splits.append(split_bytes^)
        return Int64(len(self._indexes[at].splits))

    def generation(self, index: String) raises -> Int64:
        var at = self._find_or_raise(index)
        return Int64(len(self._indexes[at].splits))

    def analyzer(self, index: String, field: String) raises -> AnalyzerConfig:
        var at = self._find_or_raise(index)
        ref ix = self._indexes[at]
        for i in range(len(ix.fields)):
            if ix.fields[i] == field:
                return ix.analyzers[i].copy()
        raise Error(
            String(SEARCH_INDEX_UNKNOWN)
            + String(": index '")
            + index
            + String("' has no analyzed field '")
            + field
            + String("' (its fields: ")
            + _render_fields(ix.fields)
            + String(")")
        )

    def fields(self, index: String) raises -> List[String]:
        var at = self._find_or_raise(index)
        return self._indexes[at].fields.copy()

    def splits_at(
        self, index: String, generation: Int64
    ) raises -> List[List[UInt8]]:
        var at = self._find_or_raise(index)
        var n = Int64(len(self._indexes[at].splits))
        if generation < Int64(0) or generation > n:
            raise Error(
                String(SEARCH_GENERATION_NOT_AVAILABLE)
                + String(": index '")
                + index
                + String("' is at generation ")
                + String(n)
                + String("; generation ")
                + String(generation)
                + String(" cannot be read")
            )
        var out = List[List[UInt8]]()
        for i in range(Int(generation)):
            out.append(self._indexes[at].splits[i].copy())
        return out^


# =============================================================================
# the tier-2 resolver
# =============================================================================


def _lower_fast_field_conjuncts(
    predicate: Expr, gate: FastFieldPushdownGate
) -> Optional[Expr]:
    """The AND of every top-level conjunct of `predicate` the split's
    fast-fields can evaluate, or None. Partial lowering is correct: the engine
    keeps the WHOLE filter above the re-rooted scan (`ScanRequest` contract),
    so an unlowered conjunct is still applied there."""
    var parts = flatten_and_conjuncts(predicate)
    var acc: Optional[Expr] = None
    for i in range(len(parts)):
        if not gate.supports_filter_pushdown(parts[i]):
            continue
        if acc:
            acc = Optional(Expr.binary(BIN_AND, acc.take(), parts[i].copy()))
        else:
            acc = Optional(parts[i].copy())
    return acc^


struct SearchScanRuntime[C: SearchIndexCatalog](
    ScanMorselResolver, Movable, Deinitable
):
    """`komira.search.index`, executable. Owns its catalog.

    Tier-2 bindings are UNBOUND (no registry slot), so `epoch` answers
    `SCAN_EPOCH_NONE` and `is_bound` False."""

    var _catalog: Self.C

    def __init__(out self, var catalog: Self.C):
        self._catalog = catalog^

    def catalog(self) -> ref [self._catalog] Self.C:
        return self._catalog

    def catalog_mut(mut self) -> ref [self._catalog] Self.C:
        return self._catalog

    def _refuse_foreign(self, binding: ScanBinding, verb: String) raises:
        if binding.kind_id != search_scan_kind_id():
            raise Error(
                String("SearchScanRuntime.")
                + verb
                + String(": refusing foreign kind '")
                + binding.kind_name
                + String("'")
            )

    def epoch(self) -> UInt64:
        return SCAN_EPOCH_NONE

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return False

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        """The generation this execution reads: the stated pin, or the
        catalog's CURRENT generation (re-read every call -- never cached)."""
        self._refuse_foreign(binding, String("resolve_snapshot"))
        if binding.params.has(String(SEARCH_PARAM_GENERATION)):
            return UInt64(
                binding.params.get_i64(String(SEARCH_PARAM_GENERATION))
            )
        var index = binding.params.get_str(String(SEARCH_PARAM_INDEX))
        return UInt64(self._catalog.generation(index))

    def descriptor(self) -> ScanKindDescriptor:
        return search_scan_descriptor()

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        """Params: `index` (required), `field` (default: DERIVED -- the
        index's one analyzed text field, `SEARCH_FIELD_AMBIGUOUS` when it has
        none or several), `query` (default "" = the no-query scan),
        `analyzer_fp` (default: the catalog's; if stated it must match),
        `generation` (optional pin). The binding always carries the field, so
        a derived field and the same field stated are one identity."""
        var index = params.get_str(String(SEARCH_PARAM_INDEX))
        var field: String
        if params.has(String(SEARCH_PARAM_FIELD)):
            field = params.get_str(String(SEARCH_PARAM_FIELD))
        else:
            field = derive_search_field(index, self._catalog.fields(index))
        var live_fp = analyzer_config_fingerprint(
            self._catalog.analyzer(index, field)
        )
        var afp = live_fp
        if params.has(String(SEARCH_PARAM_ANALYZER_FP)):
            afp = params.get_u64(String(SEARCH_PARAM_ANALYZER_FP))
            _check_analyzer(index, field, afp, live_fp)
        var gen: Optional[Int64] = None
        if params.has(String(SEARCH_PARAM_GENERATION)):
            gen = Optional(params.get_i64(String(SEARCH_PARAM_GENERATION)))
        return search_scan_binding(
            index^,
            field^,
            params.get_str(String(SEARCH_PARAM_QUERY)),
            afp,
            gen,
        )

    def open_scan(self, req: ScanRequest) raises -> ScanOpened:
        """Drain every split live at the binding's generation. Each split is
        read by `search_split_hits` over `QueryIR(field, query,
        top_k=<the split's doc count>)`, so every matching doc of the split is
        returned, ranked -- the same rows `SearchCore.search` returns for that
        QueryIR. `req.limit`, when set, caps the rows returned."""
        ref binding = req.binding
        self._refuse_foreign(binding, String("open_scan"))
        var index = binding.params.get_str(String(SEARCH_PARAM_INDEX))
        var field = binding.params.get_str(String(SEARCH_PARAM_FIELD))
        var text = binding.params.get_str(String(SEARCH_PARAM_QUERY))
        var cfg = self._catalog.analyzer(index, field)
        _check_analyzer(
            index,
            field,
            binding.params.get_u64(String(SEARCH_PARAM_ANALYZER_FP)),
            analyzer_config_fingerprint(cfg),
        )
        # The token IS the generation: resolved LIVE by `resolve_for_execution`
        # or the stated pin. It is never re-resolved here, so the rows and the
        # reported snapshot cannot disagree.
        var generation = Int64(binding.snapshot_token)
        if binding.params.has(String(SEARCH_PARAM_GENERATION)):
            generation = binding.params.get_i64(String(SEARCH_PARAM_GENERATION))
        var splits = self._catalog.splits_at(index, generation)
        var out = Slab[RecordBatch]()
        var remaining = Int(req.limit)
        for si in range(len(splits)):
            if req.has_limit() and remaining <= 0:
                break
            var view = SplitView.parse(splits[si].copy())
            var lowered: Optional[Expr] = None
            if req.predicate:
                lowered = _lower_fast_field_conjuncts(
                    req.predicate.value(), FastFieldPushdownGate(view)
                )
            var core = SearchCore.from_view(view^)
            var top_k = core.doc_count()
            if req.has_limit() and remaining < top_k:
                top_k = remaining
            var q = QueryIR(
                field.copy(),
                text.copy(),
                top_k,
                cfg.copy(),
                generation,
                lowered^,
                match_all=(text == ""),
            )
            var batch = search_split_hits(core, q)
            remaining -= batch.num_rows()
            out.append(batch^)
        var resolved = ScanParams()
        resolved.put_i64(String(SEARCH_RESOLVED_GENERATION), generation)
        return ScanOpened(ArcPointer(out^), resolved^)


def _render_fields(fields: List[String]) -> String:
    var out = String("[")
    for i in range(len(fields)):
        if i > 0:
            out += String(", ")
        out += String("'") + fields[i] + String("'")
    return out + String("]")


def derive_search_field(index: String, fields: List[String]) raises -> String:
    """The field a scan that states none reads: the ONLY analyzed text field
    of `index`. Zero or several candidates is `SEARCH_FIELD_AMBIGUOUS`,
    naming them -- never a guess."""
    if len(fields) == 1:
        return fields[0]
    raise Error(
        String(SEARCH_FIELD_AMBIGUOUS)
        + String(": index '")
        + index
        + String("' has ")
        + String(len(fields))
        + String(" analyzed text fields ")
        + _render_fields(fields)
        + String("; state `field` to choose one")
    )


def _check_analyzer(
    index: String, field: String, plan_fp: UInt64, live_fp: UInt64
) raises:
    if plan_fp != live_fp:
        raise Error(
            String(SEARCH_ANALYZER_MISMATCH)
            + String(": index '")
            + index
            + String("' field '")
            + field
            + String("' analyzes with fingerprint ")
            + String(live_fp)
            + String(" but the plan was built against ")
            + String(plan_fp)
        )


def search_scan_runtime[
    C: SearchIndexCatalog
](var catalog: C) -> ErasedScanMorselResolver:
    """The registrable form: `ctx.register_scan_kind(search_scan_runtime(c^))`."""
    return ErasedScanMorselResolver.erase(SearchScanRuntime[C](catalog^))
