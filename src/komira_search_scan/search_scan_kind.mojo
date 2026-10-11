# =============================================================================
# komira_search_scan/search_scan_kind.mojo -- the `komira.search.index`
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
#   * `SearchScanResolver[C]` -- the tier-2 `ScanSourceResolver` the engine
#     executes, and `search_scan_resolver(catalog^)`, which erases it. Its
#     splits are read by `SearchSplitReader` (`search_split_reader.mojo`).
#
# THE SPLITS. A scan reads one split per split object live at the resolved
# generation that indexes the binding's field (`split_field_at`; an index
# with several fields holds splits of each), in publish order, keyed `<index>/<ordinal>` (the ordinal is the
# split's place in publish order, stable for every generation that has it).
# Each runs from rank 0 to the end of its hits, so every split is bounded and
# the plan is complete: the kind is BOUNDED, and `discover_splits` is refused
# by name. `plan_splits` is the execution's one read of the catalog (the
# analyzer check, the split count and each split's field); the plan's `resolved` is
# `{generation}`. The row `limit` is not the kind's: `drain_scan` applies it
# across splits, and a reader honours what is left of it per poll.
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
#   * the bounded read is `drain_scan` (komira_scan_resolver), which reads
#     every split into resident batches; nothing here streams into a walker.
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
# `ErasedScanSourceResolver` (komira_scan_resolver), which owns its SAFETY.
# =============================================================================

from komira_plan_expr.expr import Expr, BIN_AND
from komira_plan_expr.expr_helpers import flatten_and_conjuncts
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_EPOCH_NONE,
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_LIVE,
)
from komira_scan_source.scan_identity_audit import ScanIdentityCorpus
from komira_scan_source.scan_kind_registry import ScanKindDescriptor
from komira_scan_source.scan_params import (
    ScanParams,
    param_hash_combine,
    param_hash_string,
)

from komira_scan_resolver.scan_source_resolver import (
    ErasedScanSourceResolver,
    ScanRequest,
    ScanSourceResolver,
    refuse_discover_splits,
)
from komira_scan_resolver.scan_split import (
    ScanSplit,
    ScanSplitPlan,
    SplitDelta,
)

from komira_search.analyzer import AnalyzerConfig
from komira_search.source import QueryIR, SearchCore, hit_schema
from komira_search.split import SplitView

from .search_source import (
    FastFieldPushdownGate,
    analyzer_config_fingerprint,
)
from .search_split_reader import (
    SEARCH_SPLIT_POSITION_INVALID,
    SEARCH_SPLIT_POSITION_VERSION,
    SearchSplitReader,
    decode_search_split_position,
    search_split_position,
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
"""The `ScanSplitPlan.resolved` (and so `ScanOpened.resolved`) key: the
generation this execution read."""

comptime SEARCH_SPLIT_KEY_INVALID: StaticString = "SEARCH_SPLIT_KEY_INVALID"
"""NAMED ERROR -- a split handed to `open_split` whose key is not
`<index>/<ordinal>` for the scan's index, whose ordinal is not a split of
the resolved generation, or whose split indexes another field than the
scan's."""

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
        SearchScanResolver[InMemorySearchIndexCatalog](
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

    def split_count_at(self, index: String, generation: Int64) raises -> Int:
        """How many splits were live at `generation`, refused as `splits_at`
        refuses. What `plan_splits` reads. The default copies every split; a
        catalog that can count without copying overrides it."""
        return len(self.splits_at(index, generation))

    def split_at(
        self, index: String, generation: Int64, ordinal: Int
    ) raises -> List[UInt8]:
        """The bytes of the `ordinal`-th split live at `generation` (publish
        order). What `open_split` reads. Refused as `splits_at` refuses, and
        `SEARCH_SPLIT_KEY_INVALID` for an ordinal out of range. The default
        copies every split; a catalog that can fetch one overrides it."""
        var every = self.splits_at(index, generation)
        _check_ordinal(index, generation, ordinal, len(every))
        return every[ordinal].copy()

    def split_field_at(
        self, index: String, generation: Int64, ordinal: Int
    ) raises -> String:
        """The text field the `ordinal`-th split live at `generation` indexes
        (`SplitView.field_name`), refused as `split_at` refuses. What
        `plan_splits` routes on: a scan reads only its field's splits. The
        default fetches and parses the split; a catalog that records each
        split's field overrides it."""
        return SplitView.parse(
            self.split_at(index, generation, ordinal)
        ).field_name()


def _check_ordinal(index: String, generation: Int64, ordinal: Int, n: Int) raises:
    if ordinal < 0 or ordinal >= n:
        raise Error(
            String(SEARCH_SPLIT_KEY_INVALID)
            + String(": index '")
            + index
            + String("' has ")
            + String(n)
            + String(" splits at generation ")
            + String(generation)
            + String("; split ")
            + String(ordinal)
            + String(" is not one of them")
        )


@fieldwise_init
struct _CatalogIndex(Copyable, Movable, Deinitable):
    """One index of the in-memory catalog. Split `i` was published at
    generation `i + 1`, so generation `g` sees splits `[0, g)`. `fields[i]`
    analyzes with `analyzers[i]` (parallel Lists: an index has a handful of
    fields). `split_fields[i]` is the field split `i` indexes. A List
    element, never a byte-slab element."""

    var name: String
    var fields: List[String]
    var analyzers: List[AnalyzerConfig]
    var splits: List[List[UInt8]]
    var split_fields: List[String]


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
            _CatalogIndex(
                name^,
                fields^,
                analyzers^,
                List[List[UInt8]](),
                List[String](),
            )
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
        """Append one split; returns the NEW generation. The split's field
        (`SplitView.field_name`) is recorded with it and must be one of the
        index's fields (`SEARCH_INDEX_UNKNOWN` otherwise, nothing published)."""
        var at = self._find_or_raise(index)
        var field = SplitView.parse(split_bytes.copy()).field_name()
        _ = self.analyzer(index, field)  # refuses a field the index lacks.
        self._indexes[at].splits.append(split_bytes^)
        self._indexes[at].split_fields.append(field^)
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
        var at = self._generation_or_raise(index, generation)
        var out = List[List[UInt8]]()
        for i in range(Int(generation)):
            out.append(self._indexes[at].splits[i].copy())
        return out^

    def _generation_or_raise(self, index: String, generation: Int64) raises -> Int:
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
        return at

    def split_count_at(self, index: String, generation: Int64) raises -> Int:
        """Generation `g` sees splits `[0, g)`: `g` of them."""
        _ = self._generation_or_raise(index, generation)
        return Int(generation)

    def split_at(
        self, index: String, generation: Int64, ordinal: Int
    ) raises -> List[UInt8]:
        var at = self._generation_or_raise(index, generation)
        _check_ordinal(index, generation, ordinal, Int(generation))
        return self._indexes[at].splits[ordinal].copy()

    def split_field_at(
        self, index: String, generation: Int64, ordinal: Int
    ) raises -> String:
        """The field recorded for the split at `publish`; no copy, no parse."""
        var at = self._generation_or_raise(index, generation)
        _check_ordinal(index, generation, ordinal, Int(generation))
        return self._indexes[at].split_fields[ordinal]


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


struct SearchScanResolver[C: SearchIndexCatalog](
    ScanSourceResolver, Movable, Deinitable
):
    """`komira.search.index`, executable. Owns its catalog.

    Tier-2 bindings are UNBOUND (no registry slot), so `epoch` answers
    `SCAN_EPOCH_NONE` and `is_bound` False."""

    comptime Reader = SearchSplitReader

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
                String("SearchScanResolver.")
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

    def position_version(self) -> UInt8:
        return SEARCH_SPLIT_POSITION_VERSION

    def _generation_of(self, binding: ScanBinding) -> Int64:
        """The generation an execution of `binding` reads. The token IS the
        generation: resolved LIVE by `resolve_for_execution`, or the stated
        pin. It is never re-resolved here, so the rows and the reported
        snapshot cannot disagree."""
        if binding.params.has(String(SEARCH_PARAM_GENERATION)):
            return binding.params.get_i64(String(SEARCH_PARAM_GENERATION))
        return Int64(binding.snapshot_token)

    def _checked_analyzer(self, binding: ScanBinding) raises -> AnalyzerConfig:
        """The index field's analyzer, refused by name when it is not the one
        the plan was built against (`SEARCH_ANALYZER_MISMATCH`)."""
        var index = binding.params.get_str(String(SEARCH_PARAM_INDEX))
        var field = binding.params.get_str(String(SEARCH_PARAM_FIELD))
        var cfg = self._catalog.analyzer(index, field)
        _check_analyzer(
            index,
            field,
            binding.params.get_u64(String(SEARCH_PARAM_ANALYZER_FP)),
            analyzer_config_fingerprint(cfg),
        )
        return cfg^

    def plan_splits(self, req: ScanRequest) raises -> ScanSplitPlan:
        """One split per split live at the binding's generation that indexes
        the binding's field (`split_field_at`), in publish order, each from
        rank 0 to its end; a split of another field of the index is not
        planned. Refuses a foreign binding, analyzer drift and a generation
        the catalog cannot serve, each by name."""
        ref binding = req.binding
        self._refuse_foreign(binding, String("plan_splits"))
        _ = self._checked_analyzer(binding)
        var index = binding.params.get_str(String(SEARCH_PARAM_INDEX))
        var generation = self._generation_of(binding)
        var field = binding.params.get_str(String(SEARCH_PARAM_FIELD))
        var n = self._catalog.split_count_at(index, generation)
        var kind_id = search_scan_kind_id()
        var splits = List[ScanSplit](capacity=n)
        for i in range(n):
            if self._catalog.split_field_at(index, generation, i) != field:
                continue
            splits.append(
                ScanSplit(
                    search_split_key(index, i),
                    search_split_position(kind_id, False, 0),
                    Optional(search_split_position(kind_id, True, 0)),
                )
            )
        var resolved = ScanParams()
        resolved.put_i64(String(SEARCH_RESOLVED_GENERATION), generation)
        return ScanSplitPlan(splits^, True, resolved^)

    def discover_splits(
        self, req: ScanRequest, known: List[String]
    ) raises -> SplitDelta:
        """A scan reads the splits of ONE generation; there is nothing to
        discover (`SCAN_READ_MODE_NOT_SUPPORTED`)."""
        return refuse_discover_splits(String(SEARCH_SCAN_KIND_NAME))

    def open_split(
        self, req: ScanRequest, split: ScanSplit
    ) raises -> SearchSplitReader:
        """A reader over `split`: its bytes at the binding's generation, the
        query analyzed with the index's analyzer, and the request predicate's
        fast-field conjuncts lowered into the search (`ScanRequest`: a hint;
        the engine keeps the whole filter). Each split's hits are the rows
        `SearchCore.search` returns for `QueryIR(field, query, top_k=<the
        split's doc count>)`, ranked. Refuses a foreign binding, analyzer
        drift, a split key that is not one of this scan's (including a split
        of another field), and a position that is foreign, mis-versioned or
        malformed, each by name."""
        ref binding = req.binding
        self._refuse_foreign(binding, String("open_split"))
        var kind_id = search_scan_kind_id()
        var kind_name = String(SEARCH_SCAN_KIND_NAME)
        split.start.require_kind(
            kind_id,
            SEARCH_SPLIT_POSITION_VERSION,
            kind_name,
            String("start of '") + split.split_key + String("'"),
        )
        var start = decode_search_split_position(
            split.start, String("start of '") + split.split_key + String("'")
        )
        if split.stop:
            ref stop = split.stop.value()
            stop.require_kind(
                kind_id,
                SEARCH_SPLIT_POSITION_VERSION,
                kind_name,
                String("stop of '") + split.split_key + String("'"),
            )
            var at = decode_search_split_position(
                stop, String("stop of '") + split.split_key + String("'")
            )
            if not at.done:
                raise Error(
                    String(SEARCH_SPLIT_POSITION_INVALID)
                    + String(": split '")
                    + split.split_key
                    + String("' stops at a rank; a search split is read to")
                    + String(" its end")
                )
        var cfg = self._checked_analyzer(binding)
        var index = binding.params.get_str(String(SEARCH_PARAM_INDEX))
        var generation = self._generation_of(binding)
        var ordinal = _split_ordinal(index, split.split_key)
        var bytes = self._catalog.split_at(index, generation, ordinal)
        var n_bytes = len(bytes)
        var view = SplitView.parse(bytes^)
        var field = binding.params.get_str(String(SEARCH_PARAM_FIELD))
        if view.field_name() != field:
            raise Error(
                String(SEARCH_SPLIT_KEY_INVALID)
                + String(": split '")
                + split.split_key
                + String("' indexes field '")
                + view.field_name()
                + String("', not the scan's field '")
                + field
                + String("'")
            )
        var lowered: Optional[Expr] = None
        if req.predicate:
            lowered = _lower_fast_field_conjuncts(
                req.predicate.value(), FastFieldPushdownGate(view)
            )
        var core = SearchCore.from_view(view^)
        return SearchSplitReader(
            core^,
            kind_id,
            field^,
            binding.params.get_str(String(SEARCH_PARAM_QUERY)),
            cfg^,
            generation,
            lowered^,
            start,
            n_bytes,
        )


def search_split_key(index: String, ordinal: Int) -> String:
    """The key of the `ordinal`-th split (publish order) of `index`."""
    return index + String("/") + String(ordinal)


def _split_ordinal(index: String, key: String) raises -> Int:
    """The ordinal `search_split_key(index, ordinal)` wrote into `key`;
    `SEARCH_SPLIT_KEY_INVALID` for any other key."""
    var prefix = index + String("/")
    var kb = key.as_bytes()
    var pb = prefix.as_bytes()
    var ok = len(kb) > len(pb)
    if ok:
        for i in range(len(pb)):
            if kb[i] != pb[i]:
                ok = False
                break
    var ordinal = 0
    if ok:
        for i in range(len(pb), len(kb)):
            var c = Int(kb[i])
            if c < 48 or c > 57 or (i - len(pb)) > 15:
                ok = False
                break
            ordinal = ordinal * 10 + (c - 48)
    if not ok:
        raise Error(
            String(SEARCH_SPLIT_KEY_INVALID)
            + String(": '")
            + key
            + String("' is not a split key of index '")
            + index
            + String("' (want '")
            + prefix
            + String("<ordinal>')")
        )
    return ordinal


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


def search_scan_resolver[
    C: SearchIndexCatalog
](var catalog: C) -> ErasedScanSourceResolver:
    """The registrable form: `ctx.register_scan_kind(search_scan_resolver(c^))`."""
    return ErasedScanSourceResolver(SearchScanResolver[C](catalog^))
