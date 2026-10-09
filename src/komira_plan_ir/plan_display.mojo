# =============================================================================
# Plan Display — pretty-print plan tree
# =============================================================================
#
# Contains _write_plan_node() and helper functions for human-readable plan
# tree representation.
# =============================================================================

from komira_plan_expr.null_order_policy import derived_nulls_first
from komira_plan_expr.render_text import write_quoted
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    AsofTolerance,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
    ASOF_TOL_NONE,
    ASOF_TOL_INT64,
    ASOF_TOL_FLOAT64,
    SOURCE_PARQUET,
    SOURCE_CSV,
    SOURCE_NDJSON,
    SOURCE_IN_MEMORY,
    SOURCE_JSON,
    SOURCE_ORC,
    SOURCE_AVRO,
    SOURCE_ARROW,
    SOURCE_BINDING,
    SOURCE_KIND_COLUMNAR,
    SOURCE_KIND_ROW,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_ALGO_AUTO,
    JOIN_ALGO_HASH,
    JOIN_ALGO_SORT_MERGE,
)


comptime INMEM_ID_PLACEHOLDER = "*"
"""What `_write_plan_node` emits for a scan's KIND-SUPPLIED content identity —
`inmem_id=` on the legacy in-memory arm and `bsid=` on a binding-backed one —
when `placeholder_inmem_id` is set. Any fixed token that cannot be produced by
`String(UInt64)` works; `*` is chosen because it is non-numeric, so a
placeholdered render can never coincide with a real id's digits.

⚠ ONE TOKEN FOR BOTH CARRIERS IS DELIBERATE. They are never emitted for the same
scan (the `inmem_id=` branch is guarded on `source_type == SOURCE_IN_MEMORY` and
not binding-backed, the `bsid=` branch on `is_binding_backed()`), and an
in-memory source may be rendered by either carrier. A second token would make
the two carriers' cheap keys differ for a plan whose content identity did not
change."""


def _write_nulls_first[
    W: Writer
](
    mut writer: W,
    descending: List[Bool],
    nulls_first: List[Bool],
    i: Int,
):
    """Emit ` NULLS FIRST` / ` NULLS LAST` for sort key `i`, but ONLY when it
    DEVIATES from the placement derived from `descending[i]`.

    `_resolve_nulls_first` (logical_plan_variants.mojo) derives
    `derived_nulls_first(descending[i])` when the caller passes no override,
    and a plan without an override must render BYTE-IDENTICALLY to one that
    never had the field. Emitting unconditionally would move every sort
    plan's `structural_hash` — a tree-wide plan-cache invalidation with nothing
    going red. Emitting on deviation only keeps every default render
    byte-for-byte and
    still separates `x ASC` from `x ASC NULLS LAST`, which is the whole point.

    Defensive on length: `nulls_first` is resolved to `len(descending)` by the
    ctor, but this walk is also reached from optimizer-rebuilt nodes.
    """
    if i >= len(nulls_first) or i >= len(descending):
        return
    if nulls_first[i] == derived_nulls_first(descending[i]):
        return
    if nulls_first[i]:
        writer.write(" NULLS FIRST")
    else:
        writer.write(" NULLS LAST")


def _write_plan_node[
    W: Writer
](
    mut writer: W,
    plan: LogicalPlan,
    indent: Int,
    placeholder_inmem_id: Bool = False,
):
    """Write a plan node with indentation, recursing into children.

    `placeholder_inmem_id` (default False == the historical, unchanged render)
    substitutes a FIXED token for every scan's KIND-SUPPLIED content identity —
    `inmem_id=` on the legacy in-memory arm (which calls
    `SourceVariant.structural_id()`) and `bsid=` on a binding-backed arm (the
    stored `ScanBinding.structural_id`). Nothing else about the render changes;
    in particular the core-DERIVED `bid=<identity_hash()>` is never
    placeholdered, which is what keeps the substitution free — see the ⚠ block
    at the `bsid=` write. The flag's name predates the second carrier and is
    kept because it is the name `structural_hash_modulo_inmem_id` reads by.

    WHY THE FLAG LIVES ON THIS WALK AND NOT IN A SECOND ONE (load-bearing).
    The placeholdered render is used as a CHEAP KEY that must COARSEN the exact
    one: `structural_hash(a) == structural_hash(b)` MUST imply
    `structural_hash_modulo_inmem_id(a) == structural_hash_modulo_inmem_id(b)`,
    or the agg-CSE pass could put two genuinely-equal aggregate subtrees in
    different key groups and MISS a fold it should make (a silent wrong
    answer). That implication
    holds precisely BECAUSE both renders are the SAME traversal emitting the
    SAME token sequence, differing only where a variable id is replaced by a
    constant: substituting a constant for a variable at a fixed set of emission
    positions can only MERGE equivalence classes, never split one. A separate
    "cheap" walk would need its own proof and could drift out of agreement with
    this one node kind at a time — which is exactly the failure this flag is
    shaped to make impossible.

    It is a RUNTIME argument, not a `comptime` parameter, on purpose: a
    parameter would monomorphize this deeply-recursive function a second time
    per `Writer`, the shape that deterministically wedges the AOT compiler.
    The cost is one predictable branch per in-memory scan node, next
    to a String write.

    ⚠ Every recursive call below MUST forward `placeholder_inmem_id`. Dropping
    it on some branch is FAIL-SAFE (that subtree renders its real ids, so the
    key gets FINER, never coarser — the coarsening implication above still
    holds and no fold is missed) but it silently costs the content hash the
    flag exists to avoid. `test_cheap_key_is_content_invariant_under_every_walked_kind`
    buries an in-memory leaf under each walked node kind to catch exactly that.
    """
    for _ in range(indent):
        writer.write("  ")

    if plan.tag == PLAN_SCAN:
        # The path is quoted with `render_text.write_quoted`: a path holding
        # `"` must not close its own quote (this render is plan identity).
        writer.write("Scan(path=")
        write_quoted(writer, plan._scan.value()[].source_path)
        writer.write(", type=")
        _write_source_type(writer, plan._scan.value()[].source_type)
        # Emit the in-memory source's CONTENT-
        # derived `structural_id()` so two distinct-CONTENT `from_record_batch`
        # sources NEVER produce the same display string (and therefore the same
        # `structural_hash`), while two STRUCTURALLY-IDENTICAL in-mem sources DO
        # (so subquery dedup + the plan-compile cache fire).
        #
        # The synthetic in-memory name is `__inmem_<firstcol>_<numrows>` (see
        # `DataFrame.from_record_batch`), so two batches with the same first
        # column name + row count collide on `source_path` alone. CSE
        # (`plan_cse`) keys on structural_hash and would merge them into one
        # canonical subtree — joining one in-memory table against itself and
        # over/under-producing rows. The discriminator MUST therefore
        # distinguish distinct content.
        #
        # `InMemorySource.fingerprint()` (a process-global per-ctor MONOTONIC
        # counter) is the wrong key: two structurally-IDENTICAL in-mem
        # subqueries would get DIFFERENT per-ctor ids ⇒ DIFFERENT
        # structural_hash ⇒ the subquery cache + the plan-compile cache never
        # dedup. `structural_id()` is the correct key: a CONTENT hash
        # (schema + batch bytes) that is EQUAL for identical content and
        # DISTINCT for two different tables.
        # `fingerprint()` stays the per-ctor IDENTITY (allocator-reuse safety),
        # but it does not enter the structural hash. FILE-PATH sources
        # (parquet/csv/orc/json) keep path-only identity (their `structural_id`
        # == `fingerprint`) so legitimate cross-query same-file CSE/scan-dedup
        # still fires.
        #
        # ⛔ THE `structural_id()` CALL BELOW IS THE O(RESIDENT BYTES) STEP.
        # `placeholder_inmem_id` skips it — see this function's docstring for
        # why that is sound as a COARSENING and why it may not be spelled as a
        # second walk. `structural_id`'s other consumers never see the
        # placeholder.
        #
        # ⚠ `and not is_binding_backed()` — THE INVARIANT `INMEM_ID_PLACEHOLDER`
        # CLAIMS, ENFORCED. That constant's docstring states the two carriers
        # "are never emitted for the same scan". A binding MAY declare
        # `legacy_source_type = SOURCE_IN_MEMORY` (`inmem_scan_binding` does,
        # because a binding-backed in-memory arm must keep answering the
        # `source_type` its readers expect). Unguarded, that binding would
        # render the SAME value twice, as `inmem_id=` and as `bsid=`. This
        # clause makes the invariant a property of the guards rather than of
        # the kinds that happen to exist.
        # Falsifier `test_inmem_content_identity.mojo
        # :test_a_binding_backed_inmem_scan_emits_its_content_identity_once`.
        if (
            plan._scan.value()[].source_type == SOURCE_IN_MEMORY
            and not plan._scan.value()[].source.is_binding_backed()
        ):
            if placeholder_inmem_id:
                writer.write(", inmem_id=", INMEM_ID_PLACEHOLDER)
            else:
                writer.write(
                    ", inmem_id=", plan._scan.value()[].source.structural_id()
                )
        # =====================================================================
        # THE BINDING'S IDENTITY, REACHING THE HASH.
        # =====================================================================
        #
        # Everything else this node emits for a binding-backed arm is `path`
        # (= `binding.name`), `type`, `source_kind`, projection and filter. The
        # params, kind_id, schema and gate would stop at the plan node. Since
        # `LogicalPlan.structural_hash()` is FNV-1a over THIS TEXT and
        # `EngineContext` uses it as `factory_hash`, two distinct out-of-core
        # scans that share a NAME would collide in the plan-compile cache and
        # query A's compiled plan would be returned for query B. A silent wrong
        # answer. Falsified by
        # `test_same_name_different_params_do_not_share_a_plan_cache_key`.
        #
        # ⚠ THE `structural_id()` CALL ABOVE DOES NOT COVER IT: it is guarded
        # by `source_type == SOURCE_IN_MEMORY`, and a binding's `source_type` is
        # `SOURCE_BINDING` (or `SOURCE_ARROW`).
        #
        # WHY THREE VALUES AND NOT ONE. They are independent, and dropping any
        # one re-opens a hole:
        #
        #   `binding=<render()>`   the HUMAN-AUDITABLE form — kind_name, name
        #       and the sorted param map. Without it a plan-text diff cannot
        #       show WHY two plans differ, and EXPLAIN for an out-of-core kind
        #       is a bare name.
        #
        #   `bsid=<structural_id>` the CONTENT identity the KIND supplies and
        #       core cannot compute. IN_MEMORY is the case that needs it: two
        #       batches with the same name+schema differ only in their bytes,
        #       and only `InMemorySource` can hash those.
        #
        #   `bid=<identity_hash()>` the DERIVED identity CORE computes over
        #       kind_id + kind_name + name + params + schema + gate +
        #       orientation (+ snapshot_token iff PINNED). This is the one a
        #       kind author cannot forget to populate, and a kind CAN forget:
        #       `broker_scan_binding` folds only (topic, partition) into its
        #       supplied `structural_id`, so two scans differing only in
        #       `start_offset` carry an IDENTICAL `structural_id`. Emitting
        #       `structural_id` alone would leave that collision live —
        #       asserted by
        #       `test_a_param_the_kind_left_out_of_its_own_fingerprint_still_
        #       reaches_the_key`.
        #
        # DETERMINISM (the other way this could go wrong). Trading a
        # collision for a nondeterministic key would be a permanent cache-miss
        # storm. Every input here is canonical by construction: `ScanParams`
        # keeps `_keys` strictly sorted on `put` and both `render()` and
        # `hash_into()` walk that order, so insertion order cannot reach the
        # text (`scan_params.mojo` module header — "KEYS ARE SORTED, AND THAT
        # IS LOAD-BEARING"); `schema_identity_hash` folds a fixed field list;
        # `PushdownGate.hash_into` folds bits. Pinned by
        # `test_the_same_logical_binding_hashes_identically_across_two_
        # constructions`.
        #
        # THE LIVE-SNAPSHOT CONTRACT SURVIVES. `render()` does not emit
        # `snapshot_token` and `identity_hash()` folds it only when the policy
        # is PINNED, so a per-execution `with_snapshot_token` copy renders
        # byte-identically to the cached plan — the identity/freshness split
        # is preserved through the render, not just through `identity_hash` in
        # isolation.
        #
        # =====================================================================
        # `bsid=` GETS THE PLACEHOLDER, FOR EVERY KIND. The measurement is below.
        # =====================================================================
        #
        # THE QUESTION. `placeholder_inmem_id` does not exist to make the render
        # cheap, it exists to make the CHEAP KEY CONTENT-BLIND: this function's
        # own docstring requires `structural_hash(a) == structural_hash(b)` to
        # imply `structural_hash_modulo_inmem_id(a) == ..._id(b)`, and
        # `test_planner_data_scaling_passes.mojo
        # :_assert_cheap_key_invariant` asserts `ca == cb` over many node kinds
        # for two plans differing ONLY in in-memory content. A binding-backed
        # IN_MEMORY scan carries that content hash in `bsid=`. If `bsid=` has
        # no placeholder branch the content hash re-enters the cheap key and
        # every one of those assertions goes RED.
        #
        # Placeholdering it for the FILE kinds too is legal by the substitution
        # argument in the docstring (it only COARSENS); the question is whether
        # it costs agg-CSE GROUPING PRECISION — whether it merges plans that
        # must stay distinct. MEASURED, over the registry-driven corpora
        # (`core_scan_identity_corpora()`, ALL PAIRS whose `structural_id`
        # differs):
        #
        #     pairs `bsid=` separates that `bid=` does NOT  ......  0
        #     pairs merged by placeholdering `bsid=`  .............  0
        #
        # ZERO, and NOT by luck — it is audit rule R2 restated. R2 already
        # demands that core's DERIVED `identity_hash()` separate every pair
        # whose `fingerprint()` differs, and `structural_id == fingerprint` for
        # every file kind (`SourceVariant.structural_id`). R4 already demands
        # `bid=<identity_hash()>` REACH this text. So for any kind with
        # `structural_id == fingerprint`, `bid=` — which is NOT placeholdered —
        # still separates every pair `bsid=` separated, and the coarsening is
        # provably free. The `bid=`-only pairs (the arrow `codec` /
        # `estimated_rows` params, which `ArrowSource.fingerprint()` does not
        # fold) run the OTHER way and are why `bid=` must never be
        # placeholdered.
        #
        # WHY UNIVERSAL RATHER THAN PER-KIND. A per-kind rule needs a new
        # descriptor field ("is my supplied identity content-derived?"), i.e. a
        # per-kind convention the type system cannot enforce — and getting it
        # wrong in the "do not placeholder" direction silently kills the
        # lever. Universal needs no declaration and costs a measured zero.
        #
        # ⚠ THE PLACEHOLDER IS NOT ABOUT COST. `structural_id` is a STORED
        # `UInt64` FIELD — rendering a binding-backed scan folds 0 content
        # bytes on BOTH keys (`planner_scale_content_hash_bytes()`). So the
        # placeholder is NOT here to avoid a per-render fold; it is here to
        # keep the cheap key's CONTENT-BLINDNESS, which is a property of the
        # KEY and not of its cost.
        #
        # Falsifiers: `test_scan_identity_coverage.mojo` §8 (R10 — the 0-merge
        # measurement, re-run as an assertion over every REGISTERED kind, so a
        # future kind whose supplied identity outruns its derived one goes RED)
        # and `test_planner_data_scaling_passes.mojo
        # :test_cheap_key_is_blind_to_a_bindings_supplied_content_identity`.
        if plan._scan.value()[].source.is_binding_backed():
            ref b = plan._scan.value()[].source.binding_ref()
            writer.write(", binding=", b.render())
            # ⚠ BOTH IDENTITY WRITES BELOW ARE PROTECTED BY CLASS RULES, NOT
            # ONLY BY GOLDENS — AND EACH RULE EXISTS BECAUSE DELETING ITS LINE
            # WOULD OTHERWISE LEAVE THE CLASS GATE GREEN.
            #
            #   `bsid=` -> audit R5 (SUPPLIED REACH + ATTRIBUTION).
            #   `bid=`  -> audit R4 (REACH).
            #
            # R4 alone covers `bid=` only: deleting
            # `writer.write(", bsid=", b.structural_id)` would leave
            # `test_every_registered_scan_kind_covers_its_own_fingerprint`
            # GREEN, because R0-R4 never look at the KIND-SUPPLIED identity at
            # all. Only the FORMAT goldens would go red, and a format golden
            # goes red on any innocuous render change, so its literal gets
            # updated — at which point the kind's own content identity is out of
            # `structural_hash()` (and so out of `factory_hash`) with nothing
            # left to notice. R5 is the second half.
            #
            # Both rules are CONTAINMENT of the VALUE, never of the field NAME,
            # so renaming `bsid=`/`bid=` or reordering these fields stays green
            # while deleting a value does not. R5 additionally ATTRIBUTES a
            # pair's difference to the `structural_id` itself, because "the two
            # texts differ" is satisfiable by `bid=` alone. Falsifiers:
            # `test_scan_identity_coverage.mojo` §6 (R4) and §7 (R5).
            #
            # ⚠ `bsid=` IS PLACEHOLDERED AND `bid=` IS NOT, AND THE ASYMMETRY IS
            # THE WHOLE POINT (see the block above). `bsid=` is the identity
            # the KIND supplies — the one that is a content hash for IN_MEMORY,
            # and the one R2 does not constrain. `bid=` is the identity CORE
            # derives, is O(1) for every kind by construction, and is what makes
            # the `bsid=` coarsening free for every file kind. Placeholdering
            # `bid=` too would merge the arrow `codec` / `estimated_rows` pairs
            # and would be a REAL precision loss.
            if placeholder_inmem_id:
                writer.write(", bsid=", INMEM_ID_PLACEHOLDER)
            else:
                writer.write(", bsid=", b.structural_id)
            writer.write(", bid=", b.identity_hash())
        # Annotate
        # the execution-hierarchy classifier (Hierarchy A = COLUMNAR,
        # Hierarchy B = ROW). Always emitted so EXPLAIN output is
        # unambiguous about which physical path the optimizer-routing
        # slot will select.
        writer.write(", source_kind=")
        _write_source_kind(writer, plan._scan.value()[].source_kind)
        # =====================================================================
        # THE TWO WRITES BELOW ARE PROTECTED BY THE SCAN-NODE AXIS — R7 / R8.
        # =====================================================================
        #
        # ⚠ WITHOUT THAT AXIS THEY ARE PROTECTED BY NOTHING. Neutralising
        # each in turn and running the class gate shows:
        #
        #   * `test_scan_identity_coverage` stays green — and unlike the two
        #     identity twins, NOT EVEN A FORMAT GOLDEN goes red, because the
        #     goldens render a scan with no projection and no filter;
        #   * scan-dedup and plan-CSE tests all pass;
        #   * a test whose predicates sit in a Filter NODE above the scan never
        #     exercises the scan's own `filter=`.
        #
        # Two scans of one path differing only here would render identically ⇒
        # equal `structural_hash()` ⇒ equal `factory_hash`
        # (`EngineContext`'s `var factory_hash = plan.structural_hash()`) and
        # equal `plan_cse` / `optimizer_scan_dedup` key. Same
        # silent-wrong-answer class as the identity twins, a different carrier.
        #
        # ⚠ THE FIX IS NOT A THIRD FORMAT GOLDEN — a format golden is exactly
        # what leaves `bid=` and `bsid=` unprotected. R4/R5 cannot reach these
        # either: `ScanIdentityCorpus` varies `ScanBinding`s, and `projection` /
        # `filter` are SCAN-NODE fields no binding corpus populates. So there is
        # a SECOND CORPUS AXIS through the same containment rules —
        # `komira_plan_ir/scan_identity_render_audit.mojo`'s
        # `ScanNodeCorpus`, run from the SAME entry point (`audit_scan_identity`)
        # over EVERY REGISTERED KIND:
        #
        #   R6 NODE NON-VACUITY — the corpus must vary each field IN ISOLATION,
        #      or deleting one write leaves every pair separated by the other.
        #   R7 NODE REACH       — a: the field's own content is IN the text;
        #      b: it is ABSENT from the CONTROL render, so containment is
        #      CAUSED by the field and not coincident with the binding;
        #      c: the binding's `bid=`/`bsid=` survive the presence of a node
        #      field.
        #   R8 NODE SEPARATION  — differing node fields force differing text.
        #      Attribution is STRUCTURAL, not lexical: the corpus is typed with
        #      ONE binding, so nothing else can be the cause.
        #
        # With the axis, neutralising `projection=` or `filter=` goes RED (R7a
        # for every kind, plus the production falsifiers including the
        # ORDER-only pair).
        # Falsifiers: `test_scan_identity_coverage.mojo` §8.
        if plan._scan.value()[].projection:
            writer.write(", projection=[")
            var proj = plan._scan.value()[].projection.value().copy()
            for i in range(len(proj)):
                if i > 0:
                    writer.write(", ")
                writer.write(proj[i])
            writer.write("]")
        if plan._scan.value()[].filter:
            writer.write(", filter=")
            plan._scan.value()[].filter.value().write_to(writer)
        writer.write(")\n")

    elif plan.tag == PLAN_FILTER:
        # Udf rendered when present (the
        # `.filter_udf[F: FilterFn]` path). The UdfData payload's own
        # write_to provides the canonical compact "udf<FILTER> ..." form
        # that folds into `LogicalPlan.structural_hash` via the text-based
        # FNV-1a path.
        writer.write("Filter(predicate=")
        plan._filter.value()[].predicate.write_to(writer)
        if plan._filter.value()[].udf:
            writer.write(", ")
            plan._filter.value()[].udf.value()[].write_to(writer)
        writer.write(")\n")
        _write_plan_node(
            writer, plan._filter.value()[].child[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_PROJECT:
        # Udf rendered when present (the
        # `.map_udf[M: MapFn]` path). See PLAN_FILTER above for the
        # structural-hash rationale.
        writer.write("Project(exprs=[")
        for i in range(len(plan._project.value()[].exprs)):
            if i > 0:
                writer.write(", ")
            plan._project.value()[].exprs[i].write_to(writer)
        writer.write("]")
        if plan._project.value()[].udf:
            writer.write(", ")
            plan._project.value()[].udf.value()[].write_to(writer)
        writer.write(")\n")
        _write_plan_node(
            writer, plan._project.value()[].child[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_AGGREGATE:
        # Udf rendered when present (the
        # `.agg_udf[A: AggFn]` path). See PLAN_FILTER above for the
        # structural-hash rationale.
        writer.write("Aggregate(group_by=[")
        for i in range(len(plan._aggregate.value()[].group_by)):
            if i > 0:
                writer.write(", ")
            plan._aggregate.value()[].group_by[i].write_to(writer)
        writer.write("], aggs=[")
        for i in range(len(plan._aggregate.value()[].agg_exprs)):
            if i > 0:
                writer.write(", ")
            plan._aggregate.value()[].agg_exprs[i].write_to(writer)
        writer.write("]")
        if plan._aggregate.value()[].udf:
            writer.write(", ")
            plan._aggregate.value()[].udf.value()[].write_to(writer)
        writer.write(")\n")
        _write_plan_node(
            writer, plan._aggregate.value()[].child[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_JOIN:
        writer.write("Join(type=")
        _write_join_type(writer, plan._join.value()[].join_type)
        if plan._join.value()[].has_algo_hint():
            writer.write(", algo=")
            _write_join_algo(writer, plan._join.value()[].algo_hint)
        writer.write(", on=[")
        for i in range(len(plan._join.value()[].left_on)):
            if i > 0:
                writer.write(", ")
            writer.write(plan._join.value()[].left_on[i])
            writer.write("=")
            writer.write(plan._join.value()[].right_on[i])
        writer.write("]")
        if plan._join.value()[].has_residual():
            # Surface the non-EQ residual for EXPLAIN /
            # structural_hash. The residual carries plain (unqualified)
            # col-refs over the joined-row schema after decomposition.
            writer.write(", residual=")
            plan._join.value()[].residual.value()[].write_to(writer)
        writer.write(")\n")
        _write_plan_node(
            writer, plan._join.value()[].left[], indent + 1, placeholder_inmem_id
        )
        _write_plan_node(
            writer, plan._join.value()[].right[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_SORT:
        # ⚠ `nulls_first` IS EMITTED. Without it `ORDER BY x ASC NULLS LAST`
        # and `ORDER BY x ASC` (the default placement) would produce IDENTICAL
        # plan text and therefore the same
        # `structural_hash` / `factory_hash` — the plan-compile cache would
        # hand one query the other's sort. See `_write_nulls_first` for why it
        # is emitted only on DEVIATION from the derived default.
        writer.write("Sort(keys=[")
        for i in range(len(plan._sort.value()[].keys)):
            if i > 0:
                writer.write(", ")
            writer.write(plan._sort.value()[].keys[i])
            if plan._sort.value()[].descending[i]:
                writer.write(" DESC")
            else:
                writer.write(" ASC")
            _write_nulls_first(
                writer,
                plan._sort.value()[].descending,
                plan._sort.value()[].nulls_first,
                i,
            )
        writer.write("])\n")
        _write_plan_node(
            writer, plan._sort.value()[].child[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_LIMIT:
        # offset > 0 == the RANGE primitive; omit it when 0 so the plain-LIMIT
        # rendering is unchanged.
        if plan._limit.value()[].offset > 0:
            writer.write(
                "Limit(n=", plan._limit.value()[].n,
                ", offset=", plan._limit.value()[].offset, ")\n",
            )
        else:
            writer.write("Limit(n=", plan._limit.value()[].n, ")\n")
        _write_plan_node(
            writer, plan._limit.value()[].child[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_DISTINCT:
        writer.write("Distinct(")
        if plan._distinct.value()[].columns:
            writer.write("columns=[")
            var cols = plan._distinct.value()[].columns.value().copy()
            for i in range(len(cols)):
                if i > 0:
                    writer.write(", ")
                writer.write(cols[i])
            writer.write("]")
        else:
            writer.write("all")
        writer.write(")\n")
        _write_plan_node(
            writer, plan._distinct.value()[].child[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_TOPN:
        # `nulls_first` emitted for the same reason as PLAN_SORT above — TopN
        # carries the identical per-key placement field.
        writer.write("TopN(n=", plan._topn.value()[].n, ", keys=[")
        for i in range(len(plan._topn.value()[].keys)):
            if i > 0:
                writer.write(", ")
            writer.write(plan._topn.value()[].keys[i])
            if plan._topn.value()[].descending[i]:
                writer.write(" DESC")
            else:
                writer.write(" ASC")
            _write_nulls_first(
                writer,
                plan._topn.value()[].descending,
                plan._topn.value()[].nulls_first,
                i,
            )
        writer.write("])\n")
        _write_plan_node(
            writer, plan._topn.value()[].child[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_PARTITION_BY:
        # ⛔ THIS RENDER IS THE PLAN-COMPILE CACHE KEY (`structural_hash`). A
        # render that omitted the order keys' direction or printed the
        # functions as a bare `<N> funcs` would let two windows in one
        # EngineContext that differ only in `descending` or in a function
        # (kind, column, offset, default, frame, alias) share one compiled
        # plan: the second query would answer the FIRST one's ranks. Every
        # field of `PartitionByData` and of each `PartitionExpr` is emitted.
        ref pb = plan._partition_by.value()[]
        writer.write("PartitionBy(partition=[")
        for i in range(len(pb.partition_keys)):
            if i > 0:
                writer.write(", ")
            writer.write(pb.partition_keys[i])
        writer.write("], order=[")
        for i in range(len(pb.order_keys)):
            if i > 0:
                writer.write(", ")
            writer.write(pb.order_keys[i])
            if i < len(pb.descending):
                if pb.descending[i]:
                    writer.write(" DESC")
                else:
                    writer.write(" ASC")
        writer.write("], funcs=[")
        for i in range(len(pb.partition_exprs)):
            if i > 0:
                writer.write(", ")
            writer.write(pb.partition_exprs[i])
        writer.write("])\n")
        _write_plan_node(
            writer, plan._partition_by.value()[].child[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_PARTITION_TOPN:
        # func + over_fetch_k printing for
        # RANK-fused nodes. The `k=` prefix is kept as the first field
        # so string-find-based test assertions stay valid.
        # `func=0` → ROW_NUMBER; `func=1` → RANK.
        var pt_func = plan._partition_topn.value()[].func
        var pt_func_name: String
        if pt_func == 0:
            pt_func_name = "ROW_NUMBER"
        elif pt_func == 1:
            pt_func_name = "RANK"
        else:
            pt_func_name = "FUNC_" + String(Int(pt_func))
        writer.write(
            "PartitionTopN(k=", plan._partition_topn.value()[].k,
            ", func=", pt_func_name,
            ", over_fetch_k=", plan._partition_topn.value()[].over_fetch_k,
            ", partition=[",
        )
        for i in range(len(plan._partition_topn.value()[].partition_keys)):
            if i > 0:
                writer.write(", ")
            writer.write(plan._partition_topn.value()[].partition_keys[i])
        writer.write("], sort=[")
        for i in range(len(plan._partition_topn.value()[].sort_keys)):
            if i > 0:
                writer.write(", ")
            writer.write(plan._partition_topn.value()[].sort_keys[i])
            if plan._partition_topn.value()[].descending[i]:
                writer.write(" DESC")
            else:
                writer.write(" ASC")
        # Print output_rank_col_name when set.
        # Empty default `output_rank_col_name=None` is omitted so a plain
        # ROW_NUMBER plan renders without it.
        if plan._partition_topn.value()[].output_rank_col_name:
            writer.write(
                "], output_rank_col=",
                plan._partition_topn.value()[].output_rank_col_name.value(),
                ")\n",
            )
        else:
            writer.write("])\n")
        _write_plan_node(
            writer, plan._partition_topn.value()[].child[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_ASOF_JOIN:
        ref aj = plan._asof_join.value()[]
        writer.write("AsofJoin(strategy=")
        _write_asof_strategy(writer, aj.strategy)
        writer.write(", on=", aj.left_asof, "=", aj.right_asof)
        writer.write(", by=[")
        for i in range(len(aj.left_keys)):
            if i > 0:
                writer.write(", ")
            writer.write(aj.left_keys[i])
            writer.write("=")
            writer.write(aj.right_keys[i])
        writer.write("]")
        # ⛔ PLAN IDENTITY: the tolerance VALUE, not just its tag. This render
        # is `structural_hash`'s input, and a tag-only `tolerance=INT64` let
        # `int64(5)` and `int64(500000)` share a compiled plan: the second
        # query matched inside the first one's window. Falsifier:
        # `test_asof_join_render_identity.mojo`.
        if not aj.tolerance.is_none():
            writer.write(", tolerance=")
            _write_asof_tolerance(writer, aj.tolerance)
        # ⛔ PLAN IDENTITY: a non-empty pre-sort hint tells the kernel to SKIP
        # its sort, so a plan with the hint must not share a compiled plan with
        # one that has to sort. Emitted only when present, so a plain as-of
        # join renders as before.
        if len(aj.left_sort_keys) > 0 or len(aj.left_sort_desc) > 0:
            writer.write(", left_sorted=")
            _write_sort_hint(writer, aj.left_sort_keys, aj.left_sort_desc)
        if len(aj.right_sort_keys) > 0 or len(aj.right_sort_desc) > 0:
            writer.write(", right_sorted=")
            _write_sort_hint(writer, aj.right_sort_keys, aj.right_sort_desc)
        writer.write(")\n")
        _write_plan_node(
            writer, plan._asof_join.value()[].left[], indent + 1, placeholder_inmem_id
        )
        _write_plan_node(
            writer, plan._asof_join.value()[].right[], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        writer.write("Union(branches=", len(ud.children), ")\n")
        for i in range(len(ud.children)):
            _write_plan_node(
            writer, ud.children[i][], indent + 1, placeholder_inmem_id
        )

    elif plan.tag == PLAN_VIEW_REF:
        # Lazy view reference. The `name=` field is the
        # registry key; `view_resolution_pass` replaces this node with
        # the registered view's expanded plan before plan-compile.
        ref vrd = plan._view_ref.value()[]
        writer.write("ViewRef(name=")
        write_quoted(writer, vrd.view_name)
        writer.write(")\n")

    elif plan.tag == PLAN_CSE_REF:
        # Leaf reference to the canonical occurrence
        # of a duplicated PURE subtree, keyed on `canonical_hash`. Produced
        # by `plan_cse.plan_cse_eliminate`; resolved by `plan_compiler`.
        ref crd = plan._cse_ref.value()[]
        writer.write("CseRef(canonical_hash=", crd.canonical_hash, ")\n")

    elif plan.tag == PLAN_CAST_TO_VARCHAR:
        # cast_to_varchar: single-child node that casts
        # every output column of its child to STRING. Produced by
        # `cast_to_varchar_insert.insert_cast_if_text_output` when the
        # feeding sink reports `is_text_output_sink() == True`.
        writer.write("CastToVarchar()\n")
        _write_plan_node(
            writer, plan._cast_to_varchar.value()[].child[], indent + 1, placeholder_inmem_id
        )

    else:
        writer.write("Unknown(tag=", Int(plan.tag), ")\n")


# =============================================================================
# ⚠ THE VOCABULARY HELPERS BELOW **WRITE**; THEY DO NOT **RETURN**.
# =============================================================================
#
# The shape these helpers avoid is `def _<thing>_name(v: UInt8) -> String` —
# an if/elif ladder returning a string LITERAL per arm — with the call site
# reading `writer.write("Join(type=", _join_type_name(...))`. In a shared
# library (`_komira.{dylib,so}`) that shape can crash: a query with a JOIN
# SIGSEGV'd at 0x4 on mac and aborted in `alloc` on linux.
#
# MEASURED CAUSE (lldb, on the shipped dylib):
#
#     cmp  x8, #0x6
#     b.hi <UNKNOWN arm>
#     adrp/add x9, <TABLE A>   ;  ldr x23, [x9, x8, lsl #3]   -> the POINTER
#     adrp/add x9, <TABLE B>   ;  ldr x24, [x9, x8, lsl #3]   -> the LENGTH
#
# The compiler lowers an N-arm literal-returning ladder into TWO PARALLEL
# CONSTANT ARRAYS — one of `ptr`, one of `len` — and binds the site's two
# references INDEPENDENTLY. In the shared library those two bindings CROSSED:
# x23 (the pointer operand) loaded 4 out of a LENGTH-shaped array, and x24 (the
# length operand) loaded a POINTER out of another ladder's pointer array.
# `String.__iadd__` then dereferenced 4. The expected length array was ABSENT
# FROM THE LIBRARY ENTIRELY and PRESENT in an executable built from the same
# sources — so this is `mojo build --emit shared-lib`, not this file.
#
# ⚠ IT IS NOT ONE SITE'S BUG. The binding is a property of the WHOLE program,
# so which literal-returning ladder gets crossed can change on every build.
# Fixing one site would dodge one crash and leave the next render to take it.
#
# THE SHAPE THAT DEFEATS IT: the arm WRITES its literal instead of RETURNING
# it. No value crosses a boundary, so there is nothing to select and no
# parallel arrays are synthesised — every call becomes `bl write_string` with
# an IMMEDIATE length. Verified by disassembly, not by "it stopped crashing":
# a standalone shared lib built from the returning shape emits 4
# register-indexed constant-array loads and the writing shape emits 0.
#
# ⚠ THE RENDERED BYTES ARE UNCHANGED, and they must be — this render IS the
# input to `LogicalPlan.structural_hash` (logical_plan.mojo), which is the
# plan-compile cache key. A changed byte here silently re-buckets every
# cached plan.
# =============================================================================


def _write_source_type[W: Writer](mut writer: W, st: UInt8):
    """Human-readable source type name.

    ⚠ EVERY `SOURCE_*` CONSTANT MUST HAVE AN ARM HERE. This ladder's `else`
    does not fail — it prints `UNKNOWN` — so a constant added to
    `logical_plan.mojo` without a matching arm here degrades EXPLAIN silently
    AND (because the render IS the `structural_hash` input) merges the new
    source type into the same hash bucket as every other unnamed type.

    ⚠ A REPOSITORY LINT ANCHORS ON THIS FUNCTION'S NAME: it locates the ladder
    with `^def _write_source_type[` and checks that every `SOURCE_*` token is
    named in the body. Renaming this function without updating that lint turns
    arm coverage OFF rather than red.
    """
    if st == SOURCE_PARQUET:
        writer.write("PARQUET")
    elif st == SOURCE_CSV:
        writer.write("CSV")
    elif st == SOURCE_NDJSON:
        writer.write("NDJSON")
    elif st == SOURCE_IN_MEMORY:
        writer.write("IN_MEMORY")
    elif st == SOURCE_JSON:
        writer.write("JSON")
    elif st == SOURCE_ORC:
        writer.write("ORC")
    elif st == SOURCE_AVRO:
        writer.write("AVRO")
    elif st == SOURCE_ARROW:
        writer.write("ARROW")
    elif st == SOURCE_BINDING:
        # "not one of the legacy enum's kinds — consult `binding_ref()
        # .kind_id`". The binding's own reverse-DNS `kind_name` is rendered
        # alongside, by the `binding=` field this node also emits, so EXPLAIN
        # still names the concrete kind.
        writer.write("BINDING")
    else:
        writer.write("UNKNOWN")


def _write_source_kind[W: Writer](mut writer: W, sk: UInt8):
    """Human-readable source-kind annotation. One of `COLUMNAR` (Hierarchy A:
    Parquet, Arrow IPC, InMemory) or `ROW` (Hierarchy B: CSV, NDJSON,
    future row-decoded sources)."""
    if sk == SOURCE_KIND_COLUMNAR:
        writer.write("COLUMNAR")
    elif sk == SOURCE_KIND_ROW:
        writer.write("ROW")
    else:
        writer.write("UNKNOWN")


def _write_join_type[W: Writer](mut writer: W, jt: UInt8):
    """Human-readable join type name."""
    if jt == JOIN_INNER:
        writer.write("INNER")
    elif jt == JOIN_LEFT:
        writer.write("LEFT")
    elif jt == JOIN_RIGHT:
        writer.write("RIGHT")
    elif jt == JOIN_FULL:
        writer.write("FULL")
    elif jt == JOIN_SEMI:
        writer.write("SEMI")
    elif jt == JOIN_ANTI:
        writer.write("ANTI")
    elif jt == JOIN_CROSS:
        writer.write("CROSS")
    else:
        writer.write("UNKNOWN")


def _write_join_algo[W: Writer](mut writer: W, algo: UInt8):
    """Human-readable join-algorithm name."""
    if algo == JOIN_ALGO_AUTO:
        writer.write("AUTO")
    elif algo == JOIN_ALGO_HASH:
        writer.write("HASH")
    elif algo == JOIN_ALGO_SORT_MERGE:
        writer.write("SORT_MERGE")
    else:
        writer.write("UNKNOWN")


def _write_asof_strategy[W: Writer](mut writer: W, s: UInt8):
    """Human-readable ASOF match strategy name."""
    if s == ASOF_BACKWARD:
        writer.write("BACKWARD")
    elif s == ASOF_FORWARD:
        writer.write("FORWARD")
    elif s == ASOF_NEAREST:
        writer.write("NEAREST")
    else:
        writer.write("UNKNOWN")


def _write_asof_tolerance[W: Writer](mut writer: W, tol: AsofTolerance):
    """ASOF tolerance: its tag AND the value the tag selects (`INT64(5)`,
    `FLOAT64(0.5)`). The value is plan identity -- see the PLAN_ASOF_JOIN arm.
    """
    var t = tol.tag
    if t == ASOF_TOL_NONE:
        writer.write("NONE")
    elif t == ASOF_TOL_INT64:
        writer.write("INT64(", tol.int_val, ")")
    elif t == ASOF_TOL_FLOAT64:
        writer.write("FLOAT64(", tol.float_val, ")")
    else:
        # An unknown tag keeps both payload slots so two unknown tolerances
        # still render apart.
        writer.write(
            "UNKNOWN(tag=", Int(t), ", ", tol.int_val, ", ", tol.float_val, ")"
        )


def _write_sort_hint[W: Writer](
    mut writer: W, keys: List[String], desc: List[Bool]
):
    """An as-of pre-sort hint: the keys, then the per-key directions as their
    own list (`["k", "ts"]/[F, T]`). The two lists are written separately so a
    length mismatch between them still reaches the render. Each key is QUOTED
    (`write_quoted`): a raw key `k, ts` rendered like the two keys `k`, `ts`,
    and a key could spell `]/[F], right_sorted=[…` and forge the other hint."""
    writer.write("[")
    for i in range(len(keys)):
        if i > 0:
            writer.write(", ")
        write_quoted(writer, keys[i])
    writer.write("]/[")
    for i in range(len(desc)):
        if i > 0:
            writer.write(", ")
        writer.write("T" if desc[i] else "F")
    writer.write("]")
