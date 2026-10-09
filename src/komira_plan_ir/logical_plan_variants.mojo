# =============================================================================
# logical_plan_variants — the per-node-type *Data payload structs
# =============================================================================
#
# Kept separate from `logical_plan.mojo` to keep that file a manageable
# size. Each `*Data` struct lives here whole (fields, `__init__`, `.copy()`,
# other methods).
#
# Module layout:
#   - `logical_plan.mojo`            keeps the `LogicalPlan` top struct, the
#                                    tag constants (`PLAN_*`, `SOURCE_*`,
#                                    `JOIN_*`, `ASOF_*`, `CORR_KIND_*`), the
#                                    `AsofTolerance` struct, the `ExprArray` /
#                                    `AggExprArray` aliases, the factory
#                                    methods, the tag-dispatch methods
#                                    (`copy` / `structural_hash` / `write_to`),
#                                    and the `_infer_*` helpers — and
#                                    re-exports every `*Data` type from here
#                                    (facade) so no consumer import path
#                                    changes.
#   - `logical_plan_variants.mojo`   (this file) holds the `*Data` structs.
#
# Import cycle: `logical_plan_variants.mojo` imports `LogicalPlan` /
# `ExprArray` / `AggExprArray` / `AsofTolerance` / `SOURCE_*` from
# `.logical_plan`; `logical_plan.mojo` imports the `*Data` structs from
# here. Mojo resolves this bidirectional module import fine —
# none of the *Data structs participates in a struct-recursion cycle that
# would trip the recursive-type check (the recursive cross-edges go
# through `OwnedPointer[LogicalPlan]`, which is the POD 8-byte handle, and
# `Optional[OwnedPointer[*Data]]` on the LogicalPlan side, neither of
# which inlines a recursive layout).
# =============================================================================

from std.memory import OwnedPointer

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_PARQUET,
    SOURCE_VARIANT_IN_MEMORY,
)
# A binding-backed arm is recognised by `source.is_binding_backed()` and
# describes itself with DECLARED data, so this file names no binding-backed
# source TYPE (ORC, AVRO, JSON, arrow) at all. A new kind adds nothing to this
# import list.
from komira_scan_source.scan_binding import SCAN_LEGACY_SOURCE_TYPE_NONE
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.in_memory_source import InMemorySource
from komira_plan_expr.expr import Expr
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_stats.table_stats import TableStats
from komira_plan_expr.payload_narrow import PayloadNarrowSpec
from komira_plan_expr.null_order_policy import derived_nulls_first
# The Filter/Project/Aggregate variants carry the typed-UDF carrier as a thin
# `Optional[OwnedPointer[UdfData]]` field. The IR payload itself (UdfData) is
# the type-erased snapshot — `F` is recovered at operator-build time by the
# comptime UDF pack threaded down from the SDK call site (matched via
# `operator_factory_id` / `call_site_salt`).
from komira_plan_expr.udf_data import UdfData
# FACADE re-export: `CorrelatedSubqueryData` is DECLARED in
# `corr_subquery_data.mojo`, so that `expr.mojo` can name the payload without
# reaching anything that names `LogicalPlan`. Consumers may import it from
# here. See the note further down.
from komira_plan_expr.corr_subquery_data import CorrelatedSubqueryData
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    SOURCE_PARQUET,
    # SOURCE_CSV / SOURCE_NDJSON are DELIBERATELY NOT IMPORTED: nothing in
    # this file names either constant, and an import kept "in case" is how a
    # deleted mechanism grows back.
    SOURCE_IN_MEMORY,
    SOURCE_BINDING,
    # ⛔ SOURCE_KIND_COLUMNAR / SOURCE_KIND_ROW ARE A RE-EXPORT, NOT A USE.
    # Nothing in THIS module names either constant in code —
    # `derive_source_layout` is the one authority and returns one of the two —
    # but `from komira_plan_ir.logical_plan_variants import
    # SOURCE_KIND_COLUMNAR` is how several tests spell it, so this line is
    # part of the module's SURFACE.
    SOURCE_KIND_COLUMNAR,
    SOURCE_KIND_ROW,
    # `SOURCE_KIND_UNSET` is a real USE — it is the ctor parameter's
    # default, i.e. how a caller says NOTHING.
    SOURCE_KIND_UNSET,
    derive_source_layout,
    JOIN_ALGO_AUTO,
    JOIN_ALGO_SORT_MERGE,
)


# =============================================================================
# Variant data structs for each LogicalPlan node type
# =============================================================================

struct ScanData(Movable):
    """Scan node payload.

    Source identity is carried as a single `source: SourceVariant` field. The
    `source_path: String` + `source_type: UInt8` fields are DERIVED,
    read-only caches for the call sites that read them as fields (optimizer
    rules, plan_compiler, plan_display, cardinality_estimator, etc.). Both
    caches are populated at construction time from the SourceVariant and
    never mutated thereafter; the `source` field is the single source of
    truth.

    For SOURCE_IN_MEMORY scans the RecordBatch payload lives inside the
    `InMemorySource` arm of the `SourceVariant` (refcount-share semantics —
    InMemorySource holds an `ArcPointer[Slab[RecordBatch]]` and `.copy()` is
    a refcount-bump). Build one with
    `InMemorySource.from_record_batch(rb, name)` (schema derived from
    `rb.schema`) and wrap it in `SourceVariant(in_mem)`.

    Fields:
        source: canonical SourceVariant. One of the concrete arms (parquet /
            in_memory / ...) or a `ScanBinding` — arrow, ORC, AVRO, CSV and
            JSON are binding-backed, as is any kind an upper package declares
            (the open `SOURCE_VARIANT_BINDING` arm). Identity, schema,
            fingerprint and row-count estimate all flow through this field.
        source_path: DERIVED. The concrete arm's path, the in-memory registry
            name, or — for a binding-backed source — `binding_ref().name`.
            Cached at __init__ from `source`.
        source_type: DERIVED, and for a binding-backed source it is DECLARED
            DATA (`ScanBinding.legacy_source_type`), not a tag-keyed branch —
            see the `is_binding_backed()` arm of __init__ for why that is what
            makes the next kind cost ZERO core lines. One of the numeric
            `SOURCE_*` constants, or `SOURCE_BINDING` meaning
            "consult `binding_ref().kind_id`" for a kind core has never heard
            of. Cached at __init__.
        schema: Optional explicit schema. None means infer from source.
        projection: Optional column names to read. None means all columns.
        filter: Optional predicate for pushdown. None means no filter.
        row_count: Optional exact row count from source metadata
            (e.g. Parquet footer). Used by the cost model for
            cardinality-aware join build-side selection. None means
            unknown -- the cost model falls back to heuristic defaults.
        table_stats: Optional per-column statistics (NDV / null_count /
            min / max). Populated by `precompute_scan_stats` when the
            source is Parquet and the writer emitted distinct_count.
            Consumed by the join-reorder cost model to compute the
            FK-PK join cardinality formula `(L*R)/max(NDV(lk), NDV(rk))`.
            None means stats unavailable -- cost model falls back to
            `max(L, R)`.
        source_kind: One of `SOURCE_KIND_COLUMNAR` / `SOURCE_KIND_ROW` —
            the SOURCE FILE'S PHYSICAL LAYOUT, which picks the READER (there
            is one executor); see the banner over the constants in
            `logical_plan.mojo`. A WRONG value is a real defect: a ROW-layout
            file decoded as though it were columnar reads the wrong bytes.
            That is why the value is DERIVED from the source rather than
            accepted from a caller.

            ⚠ FOR A BINDING-BACKED SOURCE THE CTOR ARGUMENT IS NOT READ
            AT ALL. The kind DECLARES its `orientation` and that
            declaration DECIDES, enforced by construction at the end of
            `__init__`. A caller cannot overrule a kind about its own
            physical shape (not "should not" — cannot);
            `LogicalPlan.scan_from_source` REFUSES a contradicting argument
            so the caller learns. `komira.avro` declares ROW.

            The parameter's default is `SOURCE_KIND_UNSET` (255), NOT
            `SOURCE_KIND_COLUMNAR` — the sentinel is load-bearing, not
            cosmetic: without it "stated COLUMNAR" and "stated nothing"
            are one byte and the rule above cannot be expressed. For a
            non-binding-backed arm (parquet, in_memory) an explicit value is
            honored verbatim and an unstated one is COLUMNAR.
    """
    var source: SourceVariant
    var source_path: String
    var source_type: UInt8
    var schema: Optional[Schema]
    var projection: Optional[List[String]]
    var filter: Optional[Expr]
    var row_count: Optional[Int]
    var table_stats: Optional[TableStats]
    var source_kind: UInt8
    # --- The per-column integral-narrowing
    #     instructions the compressed-materialization rule
    #     (`komira_optimizer.optimizer_payload_narrow`) proved from
    #     `table_stats`' folded [min,max].
    #
    #     ⛔ IT IS NOT A CTOR ARGUMENT, DELIBERATELY. Every construction site in
    #     the tree — and every REBUILD site (`optimizer_helpers`,
    #     `attach_hive_predicate`, `partition_prune_scans`) — must start EMPTY,
    #     because a rebuild that silently carried a stale narrowing forward past
    #     the pass that proved it would be applying an unproven cast. The rule
    #     stamps it by direct field assignment, LAST in the pipeline, after every
    #     pass that rebuilds a ScanData has run. `copy()` DOES carry it: a deep
    #     clone of an already-stamped plan is the same plan.
    var payload_narrow: List[PayloadNarrowSpec]

    def __init__(
        out self,
        var source: SourceVariant,
        var schema: Optional[Schema],
        var projection: Optional[List[String]],
        var filter: Optional[Expr],
        var row_count: Optional[Int] = None,
        var table_stats: Optional[TableStats] = None,
        source_kind: UInt8 = SOURCE_KIND_UNSET,
    ):
        """Primary ctor: takes a SourceVariant directly.

        Populates the derived `source_path` + `source_type` caches from
        the variant tag.

        ⚠ `source_kind` IS NOT AN INPUT FOR A BINDING-BACKED SOURCE. The kind
        DECLARES its `orientation` and that declaration decides — this ctor does
        not read the argument at all (the rule is stated at the end of this
        ctor). The caller-facing factory `LogicalPlan.scan_from_source` REFUSES
        an argument that disagrees, so a caller does learn; this ctor cannot
        report it because it must stay NON-RAISING — `copy()` reaches it, and a
        deep clone cannot fail.

        For a non-binding-backed arm there is no declaration: an explicit value
        is honored verbatim, an unstated one (`SOURCE_KIND_UNSET`, the default)
        is COLUMNAR — correct for the arms that remain, parquet and in_memory —
        so construction sites (`LogicalPlan.scan`, `optimizer_helpers`,
        `partition_prune_scans`) wire correctly without per-site edits.

        ⚠ AN UNSTATED `source_kind` OVER A ROW-DECLARING KIND (AVRO, CSV)
        DERIVES ROW. A ladder keyed on the caller's value would come out
        COLUMNAR there. Falsifiers `test_scan_binding_avro_arm.mojo
        :test_an_unstated_source_kind_over_avro_derives_row` and
        `test_scan_binding_csv_arm.mojo
        :test_an_unstated_source_kind_over_csv_derives_row`.
        """
        # Derive legacy caches FIRST (read-only after construction).
        var derived_path: String
        var derived_type: UInt8
        if source.tag == SOURCE_VARIANT_PARQUET:
            derived_path = String(source._parquet.value().path)
            derived_type = SOURCE_PARQUET
        elif source.tag == SOURCE_VARIANT_IN_MEMORY:
            # IN_MEMORY: name (Optional[String]) carries the registry handle
            # callers use. If name is unset, fall back to a stable
            # synthetic label "__in_memory__" (parity with `__inline__`).
            if source._in_memory.value().name:
                derived_path = String(source._in_memory.value().name.value())
            else:
                derived_path = String("__in_memory__")
            derived_type = SOURCE_IN_MEMORY
        elif source.is_binding_backed():
            # ONE branch for every binding-backed
            # arm and for every kind core has never heard of — the derivation
            # reads DATA off the binding instead of naming a source type, which
            # is precisely why an upper package can add a kind without editing
            # this ladder.
            #
            # The legacy type is DECLARED on the binding
            # (`ScanBinding.legacy_source_type`), exactly as `orientation`
            # is. A tag test here ("is the tag one of the arrow tags? then
            # SOURCE_ARROW, else SOURCE_BINDING") would cost +2 core lines for
            # every arm that becomes binding-backed, forever — a ladder inside
            # the branch whose job is to delete the ladder. With the
            # declaration, the next kind costs ZERO lines here.
            #
            # It also keeps a non-parquet scan from wearing a Parquet label:
            # an arm falling into the `else` below would come out as
            # `SOURCE_PARQUET` with an EMPTY path, which is what optimizer
            # sites key on. Falsifier: `test_scan_binding_arrow_arm.mojo
            # :test_arrow_scan_is_not_labelled_parquet`.
            ref b = source.binding_ref()
            derived_path = String(b.name)
            if b.legacy_source_type == SCAN_LEGACY_SOURCE_TYPE_NONE:
                # No legacy numeric type exists for an open kind, and inventing
                # one per kind would rebuild the closed enum. `SOURCE_BINDING`
                # means "consult `binding_ref().kind_id`".
                derived_type = SOURCE_BINDING
            else:
                # A binding-backed arm with a legacy tag answers its
                # `SOURCE_*` value (arrow -> SOURCE_ARROW, orc -> SOURCE_ORC),
                # so callers that read `source_type` see a stable value.
                derived_type = b.legacy_source_type
        else:
            # ⚠ THIS BRANCH HAS ZERO OCCUPANTS. Every tag is covered above:
            # 0/1/2 by their own arms and 3-9 by `is_binding_backed()`. Kept
            # because Mojo requires `derived_path` / `derived_type` to be
            # definitely-initialized on every path, not because anything
            # reaches it.
            #
            # A fall-through that answers `SOURCE_PARQUET` with an EMPTY path
            # does not fail — it produces a scan wearing another format's
            # label, and many `source_type == SOURCE_PARQUET` sites key on it.
            # `optimizer_scan_dedup` is the sharpest: it groups scans by path,
            # and EVERY arm that landed here would carry the SAME empty path,
            # so two unrelated scans would look like one file. Falsifiers
            # `test_scan_binding_arrow_arm.mojo
            # :test_arrow_scan_is_not_labelled_parquet` and
            # `test_scan_binding_csv_arm.mojo
            # :test_csv_scan_is_not_labelled_parquet`.
            derived_path = String("")
            derived_type = SOURCE_PARQUET
        self.source = source^
        self.source_path = derived_path^
        self.source_type = derived_type
        self.schema = schema^
        self.projection = projection^
        self.filter = filter^
        self.row_count = row_count^
        self.table_stats = table_stats^
        # Payload narrowing: always EMPTY at construction. See the field comment.
        self.payload_narrow = List[PayloadNarrowSpec]()
        # =====================================================================
        # ORIENTATION — the binding's DECLARATION DECIDES.
        # =====================================================================
        #
        # THE RULE: for a binding-backed source the kind's declared
        # `orientation` is the answer and `source_kind` IS NOT READ. The caller
        # cannot overrule a kind about its own physical shape — not "should
        # not", CANNOT. `LogicalPlan.scan_from_source` refuses an argument that
        # disagrees (`_require_orientation_agreement`) so the caller LEARNS;
        # this ctor is where the rule is ENFORCED.
        #
        # WHY A RULE AT ALL. Applying the declaration only when the caller's
        # value happens to be COLUMNAR — with the parameter's default ALSO
        # COLUMNAR — makes "the caller said nothing" and "the caller said
        # COLUMNAR" one byte, and the behaviour incoherent in both directions:
        #   * a caller stating ROW over a kind that declares COLUMNAR would
        #     silently overrule the kind — `orientation` documented as
        #     DECLARED and behaving as a DEFAULT;
        #   * a caller stating COLUMNAR over a kind that declares ROW would be
        #     silently overruled BY the kind — the caller's argument vanishing.
        #
        # WHY THE DECLARATION AND NOT THE CALLER. `orientation` is one of the
        # two values a kind DECLARES about itself, and the registry ALREADY
        # treats a disagreement about it as a named error:
        # `ScanKindRegistry.validate` raises when a binding's orientation
        # differs from its descriptor's. It is also what lets a kind carry ROW
        # (CSV, NDJSON, AVRO) with no per-type ladder here — sound only if
        # nothing else can decide it.
        #
        # ⚠ WHY THE DIAGNOSTIC IS AT THE FACTORY AND NOT HERE — A MEASURED
        # TRADE, NOT AN OVERSIGHT. Raising from this ctor forces `raises` onto
        # `copy()` — a `def` does NOT carry an implicit `raises` ("'raise'
        # requires a surrounding 'try' block or the enclosing function to
        # declare 'raises'") — on a deep clone that is called from everywhere
        # and cannot fail. From there it propagates TRANSITIVELY through the
        # test tree (dozens of helper signatures across dozens of files). The
        # correctness property is identical either way (the declaration
        # decides, always); only the diagnostic moves. So it lives at
        # `scan_from_source`, where it costs ONE `raises`.
        #
        # The legacy `LogicalPlan.scan` factory CAN build a binding-backed
        # variant (its NDJSON arm builds a `JsonSource`, a kind that DECLARES
        # ROW). It cannot contradict a declaration BY CONSTRUCTION:
        # `legacy_scan_factory_source_kind` states `SOURCE_KIND_UNSET` for
        # every arm but CSV.
        #
        # This costs no in-tree caller anything: the sites that state a kind
        # all state ROW over a NON-binding-backed source, and every rebuild
        # site (`optimizer_helpers`, `attach_hive_predicate`,
        # `partition_prune_scans`) states nothing.
        if source_kind == SOURCE_KIND_UNSET or self.source.is_binding_backed():
            # ⭐ ONE CALL: `if is_binding_backed(): declaration / elif UNSET:
            # COLUMNAR` is ONE question asked of the SOURCE — asked once, by
            # name, at `logical_plan.derive_source_layout`. Binding-backed with
            # ANY argument -> the declaration (the derivation checks that
            # first, so a STATED value cannot overrule a kind); not
            # binding-backed + UNSET -> COLUMNAR; not binding-backed + STATED
            # -> the `else` below.
            self.source_kind = derive_source_layout(self.source)
        # ⚠ THERE IS NO CSV / NDJSON AUTO-PROMOTION LADDER HERE, BY DESIGN.
        # A CSV kind is binding-backed with `orientation = ROW` DECLARED on
        # the kind, so a CSV scan takes the derivation branch above; NDJSON
        # routes through `JsonSource` and derives SOURCE_JSON (the columnar
        # materializer), and nothing derives SOURCE_NDJSON. The question
        # "what layout does this SOURCE have?" lives in one piece, in
        # `logical_plan.derive_source_layout`.
        else:
            # ⚠ THE ONE ARM A CALLER CAN STILL REACH, AND IT IS NOT CEREMONY.
            # Exactly one in-tree caller states a layout: the PLAN WIRE DECODER,
            # re-stating `WireScanNode.source_kind`. Over a NON-binding-backed
            # leaf (parquet, in-memory) this `else` KEEPS that value, so the
            # decoded slot is READ rather than derived away — pinned by
            # `test_a_forged_source_kind_is_refused_by_name_not_silently_
            # re_derived`, whose control half asserts the decoded plan CHANGES.
            self.source_kind = source_kind

    def copy(self) -> Self:
        """Deep-clone the ScanData.

        `SourceVariant.copy()` dispatches per-arm: ParquetSource is a
        shallow String+Schema clone; InMemorySource refcount-bumps the
        ArcPointer[Slab[RecordBatch]] (no buffer byte-copy — a ~1μs clone).
        All other fields
        delegate to their per-type `.copy()`.

        Re-passes `self.source_kind`, which for a binding-backed source IS the
        kind's declaration — so the primary ctor's enforcement is a no-op here
        and the clone is byte-identical.
        """
        var schema_copy: Optional[Schema] = None
        if self.schema:
            schema_copy = Optional(self.schema.value().copy())
        var proj_copy: Optional[List[String]] = None
        if self.projection:
            proj_copy = Optional(self.projection.value().copy())
        var filter_copy: Optional[Expr] = None
        if self.filter:
            filter_copy = Optional(self.filter.value().copy())
        var rc_copy: Optional[Int] = None
        if self.row_count:
            rc_copy = Optional(self.row_count.value())
        var ts_copy: Optional[TableStats] = None
        if self.table_stats:
            ts_copy = Optional(self.table_stats.value().copy())
        var out = Self(
            self.source.copy(),
            schema_copy^,
            proj_copy^,
            filter_copy^,
            rc_copy^,
            ts_copy^,
            self.source_kind,
        )
        # Payload narrowing: carried across the clone. The ctor cannot take it (see
        # the field comment), so it is assigned after construction.
        var pn = List[PayloadNarrowSpec]()
        for i in range(len(self.payload_narrow)):
            pn.append(self.payload_narrow[i].copy())
        out.payload_narrow = pn^
        return out^

    def fingerprint(self) -> UInt64:
        """Stable identity hash for plan-cache discrimination.

        Combines `source.fingerprint()` (path+mtime for PARQUET, arc-addr+
        construction-ns for IN_MEMORY) with the projection / filter / limit
        identity so two scans on the same source but different shape
        narrowings are not mistaken for cache hits.

        IMPORTANT: `dyn_filter_arc` is EXCLUDED. The
        dyn-filter-hoist optimizer rule rewrites the join probe to
        push a dynamic filter onto the SCAN; the SCAN must remain
        cache-key-equivalent to the un-rewritten form. ScanData carries
        no `dyn_filter_arc` field today — the dyn-filter Arc lives in the
        engine-side join probe — but the contract still holds in
        spirit: scan-cache identity must NOT depend on any post-plan
        runtime narrowing artifact.
        """
        # FNV-1a prime for hash mixing (matches parquet_source._fnv1a_prime).
        comptime FNV1A_PRIME: UInt64 = 1099511628211
        var h = self.source.fingerprint()
        # Mix in projection identity (column-name count + cumulative hash).
        if self.projection:
            ref proj = self.projection.value()
            var proj_h: UInt64 = UInt64(len(proj))
            for i in range(len(proj)):
                ref nm = proj[i]
                var bs = nm.as_bytes()
                for j in range(len(bs)):
                    proj_h = proj_h ^ UInt64(bs[j])
                    proj_h = proj_h * FNV1A_PRIME
            h = (h ^ proj_h) * FNV1A_PRIME
        # Mix in filter identity via String representation (filter is rare;
        # cost is amortized over plan-cache-hit lookups).
        if self.filter:
            var s = String("")
            s.write(self.filter.value())
            var bs = s.as_bytes()
            var f_h: UInt64 = UInt64(0)
            for i in range(len(bs)):
                f_h = f_h ^ UInt64(bs[i])
                f_h = f_h * FNV1A_PRIME
            h = (h ^ f_h) * FNV1A_PRIME
        # Mix in row_count (limit-like narrowing axis).
        if self.row_count:
            h = (h ^ UInt64(self.row_count.value())) * FNV1A_PRIME
        return h

struct FilterData(Movable):
    """Filter node payload. Child is heap-allocated via OwnedPointer.

    Carries the typed-UDF `udf` field. It is `None` for the
    ordinary `df.filter(expr)` / `.filter[E: ExprBool](expr)` path; populated
    by `df.filter_udf[F: FilterFn](f)` with a type-erased UdfData snapshot
    (built by `udf_plan_builder.build_filter_udf_data[F]`). `F` is
    NOT carried on this field — it is recovered at operator-build time by
    matching `udf.operator_factory_id` + `udf.call_site_salt` against the
    comptime UDF pack threaded down from the SDK call site through
    `lower_untyped_udf_segment[F]`.

    For the typed `.filter_udf[F]` path, the `predicate` field holds a
    synthetic `lit(true)` placeholder (per the operator-build-driver
    contract: when `udf.is_filter()` is True, the operator routes through
    the UDF dispatch and ignores `predicate`).
    """
    var predicate: Expr
    var child: OwnedPointer[LogicalPlan]
    var udf: Optional[OwnedPointer[UdfData]]

    def __init__(
        out self,
        var predicate: Expr,
        var child: LogicalPlan,
        var udf: Optional[OwnedPointer[UdfData]] = None,
    ):
        self.predicate = predicate^
        self.child = OwnedPointer(child^)
        self.udf = udf^

    def copy(self) -> Self:
        """Deep-clone the FilterData (recurses into the child plan)."""
        var udf_copy: Optional[OwnedPointer[UdfData]] = None
        if self.udf:
            udf_copy = Optional(OwnedPointer(self.udf.value()[].copy()))
        return Self(self.predicate.copy(), self.child[].copy(), udf_copy^)

    @always_inline
    def has_udf(self) -> Bool:
        """True iff this Filter node was emitted by
        `df.filter_udf[F: FilterFn]` (carries a typed-UDF UdfData)."""
        return Bool(self.udf)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct ProjectData(Movable):
    """Project node payload.

    Uses ExprArray instead of List[Expr] because Expr is Movable-only.

    Carries the typed-UDF `udf` field. `None` for `df.select` / `.project` /
    `.with_column(expr)`; populated by `df.map_udf[M: MapFn](m)` with a
    type-erased UdfData snapshot (built by
    `udf_plan_builder.build_map_udf_data[M]`). `M` is recovered at
    operator-build time via `udf.operator_factory_id` + `udf.call_site_salt`.
    For the typed `.map_udf[M]` path, `exprs` may carry placeholder col_refs
    matching `M.OutputSchema` for downstream plan-schema validation; the
    operator-build driver routes execution through the UDF.

    `is_cse_introduced`
    marks Project nodes that the CSE rule (eliminate_common_subexpressions)
    inserted as CSE materializers (axis 2 outer/inner Project sandwich
    around a Filter; axis 3 synthetic Project below an Aggregate). The
    flag is read by `optimizer_filter.push_predicates_down` so a
    predicate referencing a `_cse_*` synthetic column is NOT pushed
    below the Project that materializes it (would break the col-ref
    target). Default `False`; set `True` only by the CSE rewrite.
    """
    var exprs: ExprArray
    var child: OwnedPointer[LogicalPlan]
    var is_cse_introduced: Bool
    var udf: Optional[OwnedPointer[UdfData]]

    def __init__(
        out self,
        var exprs: ExprArray,
        var child: LogicalPlan,
        is_cse_introduced: Bool = False,
        var udf: Optional[OwnedPointer[UdfData]] = None,
    ):
        self.exprs = exprs^
        self.child = OwnedPointer(child^)
        self.is_cse_introduced = is_cse_introduced
        self.udf = udf^

    def copy(self) -> Self:
        """Deep-clone the ProjectData (recurses into the child plan)."""
        var exprs_copy = ExprArray()
        for i in range(len(self.exprs)):
            exprs_copy.append(self.exprs[i].copy())
        var udf_copy: Optional[OwnedPointer[UdfData]] = None
        if self.udf:
            udf_copy = Optional(OwnedPointer(self.udf.value()[].copy()))
        return Self(exprs_copy^, self.child[].copy(), self.is_cse_introduced, udf_copy^)

    @always_inline
    def has_udf(self) -> Bool:
        """True iff this Project node was emitted by
        `df.map_udf[M: MapFn]` (carries a typed-UDF UdfData)."""
        return Bool(self.udf)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct AggGroupTopK(Movable):
    """The BOUNDED-TOP-K hint a `PLAN_TOPN` root stamps onto the
    `PLAN_AGGREGATE` it sits directly above.

    ⭐ WHY THIS IS A PLAN FIELD AND NOT A PARAMETER. The TopN root and the
    aggregate are executed by two different execs joined by the breaker walker,
    whose thunk signature is fixed (`materialize_subplan` -> `_dispatch_thunk`).
    Threading a parameter would have to widen every walker arm; an ANNOTATION on
    the node the walker already carries reaches the aggregate with no signature
    change anywhere, exactly like `estimated_groups` does for the cardinality
    estimate.

    ⛔ IT IS AN ANNOTATION, NEVER A SEMANTIC. Dropping it must change only
    COST — the drain that honours it emits the same K rows the full drain plus
    the caller's TopN would have emitted, so a consumer that ignores it is
    still correct. That is what lets an un-updated pass, a wire round-trip, or
    a node rebuild lose it safely.

    Fields:
        order_cols: the TopN's ORDER BY key column names, resolved against the
            AGGREGATE's own output schema. Always non-empty when present.
        descending: per-key direction, same length as `order_cols`.
        k: the LIMIT. Always > 0 when present.
    """
    var order_cols: List[String]
    var descending: List[Bool]
    var k: Int

    def __init__(
        out self,
        var order_cols: List[String],
        var descending: List[Bool],
        k: Int,
    ):
        self.order_cols = order_cols^
        self.descending = descending^
        self.k = k

    def copy(self) -> Self:
        return Self(self.order_cols.copy(), self.descending.copy(), self.k)


struct AggregateData(Movable):
    """Aggregate node payload.

    Uses ExprArray for group_by keys and AggExprArray for aggregations
    because both Expr and AggExpr are Movable-only.

    Carries the typed-UDF `udf` field. `None` for the ordinary
    `df.group_by(keys).agg(*aggs)` path; populated by
    `df.group_by(keys).agg_udf[A: AggFn](a)` with a type-erased UdfData
    snapshot (built by `udf_plan_builder.build_agg_udf_data[A]`).
    `A` is recovered at operator-build time via `udf.operator_factory_id` +
    `udf.call_site_salt`. For the typed `.agg_udf[A]` path, `agg_exprs` may
    be empty (the UDF produces all aggregations); the operator-build driver
    routes execution through the UDF's update/merge/finalize.

    Fields:
        group_by: GROUP BY key expressions.
        agg_exprs: aggregate function expressions.
        child: heap-allocated child plan.
        estimated_groups: pre-computed plan-time estimate of distinct
            group count. When None, plan_compiler falls back
            to its `_estimate_cardinality` heuristic. Populated by
            `engine.cardinality_estimator.precompute_aggregate_estimates`,
            which runs OUTSIDE plan_compile's dispatch tree (the
            FileHandle reach inside dispatch hangs Mojo's AOT linker).
        udf: optional typed-UDF carrier (the `.agg_udf[A]` path).
    """
    var group_by: ExprArray
    var agg_exprs: AggExprArray
    var child: OwnedPointer[LogicalPlan]
    var estimated_groups: Optional[Int]
    var udf: Optional[OwnedPointer[UdfData]]
    var group_topk: Optional[AggGroupTopK]

    def __init__(
        out self,
        var group_by: ExprArray,
        var agg_exprs: AggExprArray,
        var child: LogicalPlan,
        var estimated_groups: Optional[Int] = None,
        var udf: Optional[OwnedPointer[UdfData]] = None,
        var group_topk: Optional[AggGroupTopK] = None,
    ):
        self.group_by = group_by^
        self.agg_exprs = agg_exprs^
        self.child = OwnedPointer(child^)
        self.estimated_groups = estimated_groups^
        self.udf = udf^
        self.group_topk = group_topk^

    def copy(self) -> Self:
        """Deep-clone the AggregateData (recurses into the child plan)."""
        var gb_copy = ExprArray()
        for i in range(len(self.group_by)):
            gb_copy.append(self.group_by[i].copy())
        var agg_copy = AggExprArray()
        for i in range(len(self.agg_exprs)):
            agg_copy.append(self.agg_exprs[i].copy())
        var eg_copy: Optional[Int] = None
        if self.estimated_groups:
            eg_copy = Optional(self.estimated_groups.value())
        var udf_copy: Optional[OwnedPointer[UdfData]] = None
        if self.udf:
            udf_copy = Optional(OwnedPointer(self.udf.value()[].copy()))
        # The top-K annotation survives a `.copy()` because the SORT/TOPN
        # exec stamps it onto a COPY of its child before handing that copy to
        # the walker — a `copy()` that dropped it would silently un-stamp the
        # very plan the stamp was made for.
        var tk_copy: Optional[AggGroupTopK] = None
        if self.group_topk:
            tk_copy = Optional(self.group_topk.value().copy())
        return Self(
            gb_copy^, agg_copy^, self.child[].copy(), eg_copy^, udf_copy^,
            tk_copy^,
        )

    @always_inline
    def has_udf(self) -> Bool:
        """True iff this Aggregate node was emitted by
        `.agg_udf[A: AggFn]` (carries a typed-UDF UdfData)."""
        return Bool(self.udf)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct JoinData(Movable):
    """Join node payload. Both children heap-allocated via OwnedPointer.

    Fields:
        left, right: Child plans.
        left_on, right_on: Equi-join key column names per side.
        join_type: Semantic join (INNER/LEFT/RIGHT/FULL/SEMI/ANTI/CROSS).
        algo_hint: Physical-algorithm request. JOIN_ALGO_AUTO leaves the
            choice to the optimizer (auto-select rule).
            JOIN_ALGO_HASH / JOIN_ALGO_SORT_MERGE force a specific kernel.
            Separate from `join_type`.
        residual: the non-EQ / complex part of a join
            `predicate=` expression that does NOT lift into the
            `left_on` / `right_on` equi-key fast path (NEQ, range
            comparisons, EQ-on-non-bare-colrefs, arbitrary boolean
            sub-expressions). After `join_predicate_decompose`, the
            qualifiers are rewritten to plain (COL_SIDE_NONE) column
            references resolvable against the joined-row schema (left
            columns at indices [0..L), right columns at [L..L+R)). The
            engine residual-eval gates a
            matched pair on this Expr. `None` for the common pure-EQ
            join.
    """
    var left: OwnedPointer[LogicalPlan]
    var right: OwnedPointer[LogicalPlan]
    var left_on: List[String]
    var right_on: List[String]
    var join_type: UInt8
    var algo_hint: UInt8
    var residual: Optional[OwnedPointer[Expr]]

    def __init__(
        out self,
        var left: LogicalPlan,
        var right: LogicalPlan,
        var left_on: List[String],
        var right_on: List[String],
        join_type: UInt8,
        algo_hint: UInt8 = JOIN_ALGO_AUTO,
        var residual: Optional[OwnedPointer[Expr]] = None,
    ):
        self.left = OwnedPointer(left^)
        self.right = OwnedPointer(right^)
        self.left_on = left_on^
        self.right_on = right_on^
        self.join_type = join_type
        self.algo_hint = algo_hint
        self.residual = residual^

    @always_inline
    def has_algo_hint(self) -> Bool:
        """True when the caller has expressed a concrete algorithm preference."""
        return self.algo_hint != JOIN_ALGO_AUTO

    @always_inline
    def algo_hint_is_smj(self) -> Bool:
        """True when the caller has requested the sort-merge kernel."""
        return self.algo_hint == JOIN_ALGO_SORT_MERGE

    @always_inline
    def has_residual(self) -> Bool:
        """True when a non-EQ / complex residual predicate
        is attached to this join."""
        return Bool(self.residual)

    def copy(self) -> Self:
        """Deep-clone the JoinData (recurses into both children + residual)."""
        var residual_copy: Optional[OwnedPointer[Expr]] = None
        if self.residual:
            residual_copy = OwnedPointer(self.residual.value()[].copy())
        return Self(
            self.left[].copy(),
            self.right[].copy(),
            self.left_on.copy(),
            self.right_on.copy(),
            self.join_type,
            self.algo_hint,
            residual_copy^,
        )

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


def _resolve_nulls_first(descending: List[Bool], var provided: Optional[List[Bool]]) -> List[Bool]:
    """Resolve the per-key NULL placement.

    When `provided` is None, fill in the engine's DERIVED default per key —
    `null_order_policy.derived_nulls_first`, which is NULLS LAST in BOTH
    directions and matches DuckDB v1.5.3's `default_null_order`. When `provided`
    is Some, it is an explicit per-key override (SQL `NULLS FIRST/LAST`) and is
    used VERBATIM.

    ⭐ THE POLICY IS NOT WRITTEN HERE, AND THAT IS THE POINT. A rule spelled
    inline here and at other sites — some inside specialised kernels that take
    no placement argument — could not change in one edit without making the
    same query answer differently depending on row count and worker count.
    The policy has exactly one definition; read `null_order_policy.mojo`'s
    header for the DuckDB/pyarrow measurement.

    ⚠ THE THIRD STATE IS STILL HERE AND STILL LOAD-BEARING. `provided == None`
    means "nobody asked" and is what lets an explicit request EQUAL to the
    derived default collapse back to no request at all — the thing that keeps
    the specialised routes' decline gates from firing on the whole corpus.
    """
    if provided:
        return provided.value().copy()
    var nf = List[Bool]()
    for i in range(len(descending)):
        nf.append(derived_nulls_first(descending[i]))
    return nf^


struct SortData(Movable):
    """Sort node payload."""
    var keys: List[String]
    var descending: List[Bool]
    # Per-key NULL placement. `nulls_first[i]==True`
    # sorts NULLs before all valid values for key `i`; False sorts them
    # after.  Same arity as `keys`/`descending`.  The default (ctor
    # `nulls_first` arg None) is `null_order_policy.derived_nulls_first`, which
    # is NULLS LAST in both directions.
    var nulls_first: List[Bool]
    var child: OwnedPointer[LogicalPlan]

    def __init__(out self, var keys: List[String], var descending: List[Bool], var child: LogicalPlan, var nulls_first: Optional[List[Bool]] = None):
        self.nulls_first = _resolve_nulls_first(descending, nulls_first^)
        self.keys = keys^
        self.descending = descending^
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        """Deep-clone the SortData (recurses into the child plan)."""
        return Self(self.keys.copy(), self.descending.copy(), self.child[].copy(), Optional(self.nulls_first.copy()))

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct LimitData(Movable):
    """Limit node payload — the engine RANGE primitive.

    Semantics: emit rows ``[offset, offset + n)`` of the child's output
    order. ``offset == 0`` (the default) is the plain first-``n`` LIMIT — a
    PLAN_LIMIT consumer that only reads ``n`` / ``child`` is correct for it,
    which is why the range primitive is this node rather than a parallel
    RangeData node.

    Fields:
        n: the row COUNT to emit (the LIMIT). Always >= 0.
        offset: rows to SKIP from the child before emitting (the OFFSET).
            0 == no skip. rows [offset, offset + n) of child order.
        child: heap-allocated child plan.
    """
    var n: Int
    var offset: Int
    var child: OwnedPointer[LogicalPlan]

    def __init__(out self, n: Int, var child: LogicalPlan, offset: Int = 0):
        self.n = n
        self.offset = offset
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        """Deep-clone the LimitData (recurses into the child plan)."""
        return Self(self.n, self.child[].copy(), offset=self.offset)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct DistinctData(Movable):
    """Distinct node payload.

    Fields:
        columns: explicit DISTINCT key columns; None means "DISTINCT *"
            (dedup over the child schema's full column list).
        child: heap-allocated child plan.
        estimated_groups: pre-computed plan-time estimate of distinct
            row count. Same semantics as
            `AggregateData.estimated_groups`. Populated by
            `engine.cardinality_estimator.precompute_aggregate_estimates`.
    """
    var columns: Optional[List[String]]
    var child: OwnedPointer[LogicalPlan]
    var estimated_groups: Optional[Int]

    def __init__(
        out self,
        var columns: Optional[List[String]],
        var child: LogicalPlan,
        var estimated_groups: Optional[Int] = None,
    ):
        self.columns = columns^
        self.child = OwnedPointer(child^)
        self.estimated_groups = estimated_groups^

    def copy(self) -> Self:
        """Deep-clone the DistinctData (recurses into the child plan)."""
        var cols_copy: Optional[List[String]] = None
        if self.columns:
            cols_copy = Optional(self.columns.value().copy())
        var eg_copy: Optional[Int] = None
        if self.estimated_groups:
            eg_copy = Optional(self.estimated_groups.value())
        return Self(cols_copy^, self.child[].copy(), eg_copy^)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct TopNData(Movable):
    """TopN node payload — fused Sort + Limit.

    Uses a K-element heap instead of full O(N log N) sort.
    Created by the optimizer when it detects Sort followed by Limit(K).
    """
    var keys: List[String]
    var descending: List[Bool]
    # Per-key NULL placement — same semantics as
    # SortData.nulls_first. Default (ctor arg None) is
    # `null_order_policy.derived_nulls_first` (NULLS LAST, both directions).
    var nulls_first: List[Bool]
    var n: Int
    var child: OwnedPointer[LogicalPlan]

    def __init__(out self, var keys: List[String], var descending: List[Bool], n: Int, var child: LogicalPlan, var nulls_first: Optional[List[Bool]] = None):
        self.nulls_first = _resolve_nulls_first(descending, nulls_first^)
        self.keys = keys^
        self.descending = descending^
        self.n = n
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        """Deep-clone the TopNData (recurses into the child plan)."""
        return Self(self.keys.copy(), self.descending.copy(), self.n, self.child[].copy(), Optional(self.nulls_first.copy()))

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct PartitionByData(Movable):
    """PartitionBy (window function) node payload.

    Enriches each input row with computed partition function values.
    The output row count equals the input row count; the output schema
    is the child schema plus one column per PartitionExpr.

    Fields:
        partition_keys: Column names to partition by. Empty = single partition.
        order_keys: Column names defining intra-partition order.
        descending: Per-order-key sort direction (same length as order_keys).
        partition_exprs: Window function expressions to evaluate.
        child: Heap-allocated child plan.
    """
    var partition_keys: List[String]
    var order_keys: List[String]
    var descending: List[Bool]
    var partition_exprs: List[PartitionExpr]
    var child: OwnedPointer[LogicalPlan]

    def __init__(
        out self,
        var partition_keys: List[String],
        var order_keys: List[String],
        var descending: List[Bool],
        var partition_exprs: List[PartitionExpr],
        var child: LogicalPlan,
    ):
        self.partition_keys = partition_keys^
        self.order_keys = order_keys^
        self.descending = descending^
        self.partition_exprs = partition_exprs^
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        """Deep-clone the PartitionByData (recurses into the child plan)."""
        return Self(
            self.partition_keys.copy(),
            self.order_keys.copy(),
            self.descending.copy(),
            self.partition_exprs.copy(),
            self.child[].copy(),
        )

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct PartitionTopNData(Movable):
    """PartitionTopN node payload — per-partition Top-K (window-style).

    Computes the K rows with the smallest/largest sort_keys values within
    each partition group. Equivalent to (depending on `func`):

        ROW_NUMBER variant:
          SELECT * FROM (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...) AS rn
            FROM child
          ) WHERE rn <= K

        RANK variant:
          SELECT * FROM (
            SELECT *, RANK() OVER (PARTITION BY ... ORDER BY ...) AS rk
            FROM child
          ) WHERE rk <= K
        Note: RANK preserves ties at K-th position. The fused kernel
        over-fetches up to `over_fetch_k` rows per partition then
        post-filters to keep all rows whose rank <= K. For Float64
        order keys with ~10K rows/partition the tie probability is
        ~10K * 2^-52 (near-zero), so over_fetch_k = K + 16 closes
        ~99.9999%+ of cases without correctness loss; pathological
        repeated-value inputs may still need fallback (an engine-side
        decision).

    CONTRACT for the engine (PartitionTopN sink dispatch):
      - `func` discriminates ROW_NUMBER vs RANK semantics. Engine MUST
        check func before running a kernel. Unknown func tags MUST raise.
      - `k` is the user-facing K (e.g. K=10 means "top 10 per partition").
      - `over_fetch_k`:
          * For PF_ROW_NUMBER: equal to `k` (no over-fetch needed; row_number
            is unique per partition by definition).
          * For PF_RANK: equal to `k + EPSILON` where EPSILON = 16 (see
            `_PF_RANK_TIE_EPSILON` in optimizer_partition_topn.mojo). The
            engine maintains a per-partition heap of size `over_fetch_k`,
            then in finalize discards entries with rank > k.
      - The sink output schema = child schema (the rn/rk column is NOT
        materialized; the optimizer absorbed the post-window Filter +
        synthetic column).

    Fields:
        partition_keys: Column names to partition by. Empty = single partition.
        sort_keys: Column names defining intra-partition order.
        descending: Per-sort-key sort direction (same length as sort_keys).
        k: Number of rows per partition to keep. Must be >= 0.
        func: Window function discriminant. Currently PF_ROW_NUMBER (0) or
            PF_RANK (1). Default PF_ROW_NUMBER.
            Validation: must be a recognized partition-function tag
            from `partition_expr.mojo`.
        over_fetch_k: Internal heap capacity per partition. >= k. For
            PF_ROW_NUMBER, equals k. For PF_RANK, k + tie-buffer epsilon.
            Engine kernels read this; consumers post-filter to k.
        output_rank_col_name: When `Some(name)`,
            the kernel emits an additional Int64 column with that name
            holding the rank/row_number value for each surviving row. When
            `None` (default), the output schema = child schema (no rank
            column emitted). Used by the
            optimizer's `fuse_partition_topn` rule to preserve correctness
            when downstream operators reference the synthetic rk/rn
            column — instead of skipping fusion we fuse and emit the
            column so the downstream Sort / Project / Filter can resolve
            it normally.
        child: Heap-allocated child plan.

    Sort keys are parallel `keys: List[String]` + `descending: List[Bool]`,
    the same shape SortData / TopNData / PartitionByData use (there is no
    `SortColumn` struct).
    """
    var partition_keys: List[String]
    var sort_keys: List[String]
    var descending: List[Bool]
    var k: Int
    var func: UInt8
    var over_fetch_k: Int
    var output_rank_col_name: Optional[String]
    var child: OwnedPointer[LogicalPlan]

    def __init__(
        out self,
        var partition_keys: List[String],
        var sort_keys: List[String],
        var descending: List[Bool],
        k: Int,
        var child: LogicalPlan,
        func: UInt8 = 0,  # PF_ROW_NUMBER default; explicit to avoid import cycle
        over_fetch_k: Int = -1,  # -1 sentinel = auto-derive from k+func
        var output_rank_col_name: Optional[String] = None,
    ):
        self.partition_keys = partition_keys^
        self.sort_keys = sort_keys^
        self.descending = descending^
        self.k = k
        self.func = func
        # Auto-derive over_fetch_k when caller passes the -1 sentinel.
        # PF_ROW_NUMBER (0): no tie buffer needed.
        # PF_RANK (1): callers should pass an explicit value; sentinel
        #   defaults to `k` (= no over-fetch) which is correctness-safe
        #   only if the engine knows to fall back. The optimizer pass
        #   always passes an explicit value when emitting RANK fused
        #   nodes. Construction sites that don't set this get
        #   the ROW_NUMBER-equivalent shape.
        if over_fetch_k < 0:
            self.over_fetch_k = k
        else:
            self.over_fetch_k = over_fetch_k
        self.output_rank_col_name = output_rank_col_name^
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        """Deep-clone the PartitionTopNData (recurses into the child plan).

        Preserves func + over_fetch_k + output_rank_col_name across the clone
        (matches `optimizer_helpers._copy_plan`).
        """
        var rank_col_copy: Optional[String] = None
        if self.output_rank_col_name:
            rank_col_copy = Optional(self.output_rank_col_name.value().copy())
        return Self(
            self.partition_keys.copy(),
            self.sort_keys.copy(),
            self.descending.copy(),
            self.k,
            self.child[].copy(),
            self.func,
            self.over_fetch_k,
            rank_col_copy^,
        )

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct AsofJoinData(Movable):
    """AsofJoin node payload — time-series "as-of" left join.

    For each left row, pick the right row inside the same equi-key group
    (the `by` columns) whose ASOF column (the `on` column) best matches
    the left row per `strategy`, optionally gated by `tolerance`. Left-join
    semantics: every left row is emitted, with all right columns NULL when
    no match is found.

    Sort hints are parallel `keys: List[String]` + `descending: List[Bool]`,
    the sort/topn/partition_topn shape.

    Fields:
        left_keys: Equi-join keys on the left ("BY" columns). May be empty
            (single-group / O(N*M) semantics — warn in docstrings).
        right_keys: Equi-join keys on the right. Same length as left_keys.
        left_asof: The ASOF ("ON") time column name on the left.
        right_asof: The ASOF column name on the right.
        strategy: One of ASOF_BACKWARD / ASOF_FORWARD / ASOF_NEAREST.
        tolerance: Opaque AsofTolerance (tag=NONE|INT64|FLOAT64).
        left_sort_keys / left_sort_desc: If non-empty, left is already
            sorted on these columns (skip sort phase). Empty =
            compiler sorts before merge.
        right_sort_keys / right_sort_desc: Symmetric pre-sort hint.
        left: Heap-allocated left child.
        right: Heap-allocated right child.
    """
    var left_keys: List[String]
    var right_keys: List[String]
    var left_asof: String
    var right_asof: String
    var strategy: UInt8
    var tolerance: AsofTolerance
    var left_sort_keys: List[String]
    var left_sort_desc: List[Bool]
    var right_sort_keys: List[String]
    var right_sort_desc: List[Bool]
    var left: OwnedPointer[LogicalPlan]
    var right: OwnedPointer[LogicalPlan]

    def __init__(
        out self,
        var left_keys: List[String],
        var right_keys: List[String],
        var left_asof: String,
        var right_asof: String,
        strategy: UInt8,
        tolerance: AsofTolerance,
        var left_sort_keys: List[String],
        var left_sort_desc: List[Bool],
        var right_sort_keys: List[String],
        var right_sort_desc: List[Bool],
        var left: LogicalPlan,
        var right: LogicalPlan,
    ):
        self.left_keys = left_keys^
        self.right_keys = right_keys^
        self.left_asof = left_asof^
        self.right_asof = right_asof^
        self.strategy = strategy
        self.tolerance = tolerance
        self.left_sort_keys = left_sort_keys^
        self.left_sort_desc = left_sort_desc^
        self.right_sort_keys = right_sort_keys^
        self.right_sort_desc = right_sort_desc^
        self.left = OwnedPointer(left^)
        self.right = OwnedPointer(right^)

    def copy(self) -> Self:
        """Deep-clone the AsofJoinData (recurses into both children)."""
        return Self(
            self.left_keys.copy(),
            self.right_keys.copy(),
            self.left_asof.copy(),
            self.right_asof.copy(),
            self.strategy,
            self.tolerance,
            self.left_sort_keys.copy(),
            self.left_sort_desc.copy(),
            self.right_sort_keys.copy(),
            self.right_sort_desc.copy(),
            self.left[].copy(),
            self.right[].copy(),
        )

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

# =============================================================================
# CorrelatedSubqueryData
# =============================================================================
#
# Payload for `Expr` tag `EXPR_CORRELATED_SUBQUERY`.
#
# Subquery kinds (kind: UInt8):
#   - CORR_KIND_EXISTS         → flatten_dependent_joins lowers to JOIN_SEMI
#   - CORR_KIND_NOT_EXISTS     → lowers to JOIN_ANTI
#   - CORR_KIND_SCALAR         → lowers to JOIN_LEFT + agg sink (Q17 shape)
#   - CORR_KIND_IN_CORRELATED  → lowers to JOIN_SEMI with the IN-list
#       equi-predicate (`outer.in_lhs_col = inner.in_rhs_col`) appended to
#       the correlation keys (Q20).
#       Covers both the truly-correlated form (`outer_refs` non-empty:
#       `outer.col IN (SELECT inner.proj FROM ... WHERE outer_col = inner_col)`)
#       AND the uncorrelated subquery-RHS form (`outer_refs` empty:
#       `outer.col IN (SELECT inner.proj FROM ...)`) — the latter is just a
#       semi-join with a single equi-key. DuckDB lowers `IN (subquery)` to a
#       correlated MARK join with "one extra join condition" (the original
#       `IN` comparison); since this engine has no MARK join, the
#       positive-`IN` form maps directly to JOIN_SEMI with that extra key.
#
# `outer_refs: List[String]` are the COLUMN NAMES from the outer scope
# this subquery correlates with. flatten_dependent_joins validates them
# against the outer parent's `output_schema` at lowering time and raises
# `UnresolvedOuterRef` on mismatch.
#
# `in_lhs_col` / `in_rhs_col` are populated ONLY for CORR_KIND_IN_CORRELATED
# (empty `String()` otherwise): `in_lhs_col` is the outer column on the LHS
# of `IN`; `in_rhs_col` is the (single) column the inner plan projects that
# the `IN` matches against. flatten_dependent_joins appends
# `(in_lhs_col, in_rhs_col)` to `(left_on, right_on)` of the semi-join.
#
# ⚠ `CorrelatedSubqueryData` IS DECLARED IN `corr_subquery_data.mojo` — a
# module that imports only `erased_box.mojo` — because `expr.mojo` must be
# able to name the payload WITHOUT naming `LogicalPlan`, and every module in
# this file's closure does. The import at the top of this file is the FACADE
# re-export, so `from komira_plan_ir.logical_plan_variants import
# CorrelatedSubqueryData` (or via `logical_plan`) resolves.
#
# ⚠ THE PLAN IS OWNED BY AN `ErasedBox` and reached with
# `corr_subquery.corr_data_inner_plan_ref(cs)`, which raises on a type-tag
# mismatch. There is no field access to it.


struct UnionData(Movable):
    """Payload for `LogicalPlan` tag `PLAN_UNION`.

    A variadic UNION ALL: the output is the row-by-row concatenation of
    every child's output. Every child MUST advertise an output schema
    structurally identical to the union node's `output_schema` (same
    column names + types in order) — the engine does not coerce / cast
    across branches. `children` is `List[OwnedPointer[LogicalPlan]]`.

    ⚠ `List`, NOT `Slab[OwnedPointer[LogicalPlan]]` — measured on Mojo
    1.0.0, the List form compiles and the Slab form does not.

    The Slab form is refused because it closes a Deinitable cycle that
    1.0.0's non-co-inductive check cannot see through:

        LogicalPlan -> Optional[OwnedPointer[UnionData]]
                    -> UnionData -> Slab[OwnedPointer[LogicalPlan]]
                    -> OwnedPointer[LogicalPlan] -> LogicalPlan

    Every member of that cycle carries an explicit `__deinit__`, LogicalPlan
    included, and it is still refused ("'Slab' parameter 'T' has 'Deinitable
    & Movable' type, but value has type 'AnyStruct[OwnedPointer[
    LogicalPlan]]'"). Explicit `Deinitable` conformances do not help either;
    both were measured. `Slab[T: Movable & Deinitable]`'s bound is what
    forces the question mid-cycle -- `List` does not have that bound, so the
    same graph resolves.

    Fields:
        children: the N input plans, in concatenation order. `len >= 1`
            (a 1-element union is the degenerate single-branch case;
            `plan_compiler` never emits an empty union).
    """
    var children: List[OwnedPointer[LogicalPlan]]

    def __init__(out self, var children: List[OwnedPointer[LogicalPlan]]):
        self.children = children^

    def copy(self) -> Self:
        """Deep-clone the UnionData (recurses into every child)."""
        var children_copy = List[OwnedPointer[LogicalPlan]]()
        for i in range(len(self.children)):
            children_copy.append(OwnedPointer(self.children[i][].copy()))
        return Self(children_copy^)

    @always_inline
    def num_children(self) -> Int:
        return len(self.children)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct ViewRefData(Movable):
    """Payload for `LogicalPlan` tag `PLAN_VIEW_REF`.

    A LAZY reference to a registered view. The node is a LEAF — it has no
    child plans. The `view_resolution_pass` compiler sub-pass looks up
    `view_name` in the EngineContext view registry and splices the
    registered view's expanded plan in place of this node (recursively
    resolving any nested view refs; depth limit 16; cycle detection via a
    name-stack — a `view_name` already on the stack → cycle →
    `ViewRecursionLimitExceeded`).

    Fields:
        view_name: the registered view's name (registry key). Must be
            non-empty (`ctx.view` validates the handle).
        output_schema: a SNAPSHOT of the registered view's output schema,
            taken at `ctx.view(handle)` time. Used as the `LogicalPlan`'s
            `output_schema` (so schema-dependent passes that run BEFORE
            view_resolution_pass — defensively —
            see a stable schema). After resolution the resolved subtree's
            schema is structurally identical to this snapshot.
    """
    var view_name: String
    var output_schema: Schema

    def __init__(out self, var view_name: String, var output_schema: Schema):
        self.view_name = view_name^
        self.output_schema = output_schema^

    def copy(self) -> Self:
        """Deep-clone the ViewRefData (cheap — `view_name` is a String,
        `output_schema` is a Schema clone). No child plans to recurse."""
        return Self(self.view_name, self.output_schema.copy())


struct CseRefData(Movable):
    """Payload for `LogicalPlan` tag `PLAN_CSE_REF`.

    A LEAF reference to the CANONICAL occurrence of a duplicated PURE
    subtree within a single LogicalPlan. The canonical occurrence keeps the
    full subtree; every subsequent (2nd..Nth) occurrence is replaced by a
    `PLAN_CSE_REF` leaf carrying the canonical subtree's `structural_hash`.
    This expresses subtree-sharing WITHOUT making the IR a DAG (no
    OwnedPointer-aliased children — the tree invariant is preserved).

    Fields:
        canonical_hash: the `structural_hash()` of the canonical
            occurrence's subtree. `plan_compiler` keys its
            hash->segment-id side-table on this; the engine reads the
            canonical segment's output. The `LogicalPlan`'s own
            `structural_hash()` is special-cased to return THIS value (so
            a CSE'd plan and a manually-deduplicated plan that references
            the same canonical subtree hash identically — re-CSE idempotence).
        output_schema: a snapshot of the canonical subtree's output schema.
            Carried so the `LogicalPlan.output_schema` field is meaningful
            for any schema-dependent pass that runs after CSE (defensively;
            CSE runs in pass-2).
    """
    var canonical_hash: UInt64
    var output_schema: Schema

    def __init__(out self, canonical_hash: UInt64, var output_schema: Schema):
        self.canonical_hash = canonical_hash
        self.output_schema = output_schema^

    def copy(self) -> Self:
        """Deep-clone the CseRefData (cheap — a UInt64 + a Schema clone).
        No child plans to recurse."""
        return Self(self.canonical_hash, self.output_schema.copy())


struct CastToVarcharData(Movable):
    """Payload for `LogicalPlan` tag `PLAN_CAST_TO_VARCHAR`.

    A single-child node that wraps its input with a per-column cast to
    STRING. The node's `output_schema` (held on the parent `LogicalPlan`)
    is synthesized at factory construction time as the per-column
    STRING-typed mirror of `child.output_schema` — every column keeps
    its name and nullability but its `ArrowType` becomes
    `ArrowType.STRING`. The actual UTF-8 materialization is done at
    engine-execute time by the `CastToVarcharOp` operator
    (`komira_engine_operators/cast_to_varchar.mojo`).

    Fields:
        child: the inner plan whose output will be cast column-by-column
            to STRING. Heap-allocated through an `OwnedPointer` (mirror of
            `LimitData.child`).
    """
    var child: OwnedPointer[LogicalPlan]

    def __init__(out self, var child: LogicalPlan):
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        """Deep-clone the CastToVarcharData (recurses into the child plan)."""
        return Self(self.child[].copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass
