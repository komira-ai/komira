# =============================================================================
# row_column_reroute.mojo — the footerless-source execution-site re-route
# =============================================================================
#
# ONE QUESTION, asked at the EXECUTION site and nowhere else:
#
#   this plan reads a ROW source (`SOURCE_KIND_ROW`) — does the COLUMNAR
#   decoder of that source format read the same bytes faster WITHOUT changing
#   the answer?
#
# For a footerless source (CSV / JSONL / Avro) the answer is decided by ONE
# property of the format's COLUMNAR decoder, and this module is where that
# property is written down per format:
#
#     PARALLEL          it shards the byte stream and decodes partitions
#                       concurrently; AND
#     SCHEMA-DIRECTED   it accepts the leaf's DECLARED schema and parses at
#                       those dtypes, so re-routing cannot change the ANSWER.
#
# BOTH are required. Parallel-but-not-schema-directed is a value change wearing
# a speedup's clothes: `all_varchar=true` over a cell holding `"0001"` re-infers
# INT64 -> 1 -> renders back as `"1"`, which is a different answer, and a CAST
# after the fact cannot undo it (the parse already happened at the wrong dtype).
#
# # THE VERDICT IS THREE-VALUED (`row_column_reroute_verdict_for_arm`)
#
#   REROUTE_DIRECT_BATCH  the plan IS the scan leaf — nothing above it to
#                         execute. The decoded batch IS the answer, so the
#                         caller returns it: no in-memory source is built and
#                         nothing is bound into a scan registry.
#
#   REROUTE_DEMOTE        there is a plan ABOVE the leaf (filter / project /
#                         aggregate / join / …), so the caller re-roots the
#                         decoded batch as an in-memory scan the column path
#                         can run. It is a separate gate from the direct arm
#                         because the two arms have different costs: the
#                         demote holds the whole decoded batch resident.
#
#   REROUTE_NONE          the re-route does not fire: the gate is off, some ROW
#                         leaf vetoes it, or the plan is a bare scan whose leaf
#                         carries work of its own.
#
# # A BARE SCAN IS NOT AUTOMATICALLY A BARE READ — `ScanData` CARRIES WORK
#
# `PLAN_SCAN` alone is NOT sufficient for the direct return. `ScanData` has a
# `projection: Optional[List[String]]` and a `filter: Optional[Expr]`, both of
# which are the LEAF's own work, not a parent node's. Returning the decoded batch
# while either is present drops a column prune or a predicate and answers the
# wrong question with no error anywhere — the same silent-value-change failure
# mode this module exists to prevent, arriving from the other side. Both are
# therefore checked and either one VETOES the direct arm.
#
# # THE FORMAT TABLE. Adding a format = one arm + its reason.
#
#   JSONL  SOURCE_VARIANT_JSON   RE-ROUTE. The columnar JSONL materializer takes
#            the declared schema and applies it to every partition, and it
#            builds its per-partition structural index in the same fork-join —
#            parallel AND schema-directed.
#
#   CSV    SOURCE_VARIANT_CSV    RE-ROUTE. `CsvReadOptions.declared_column_types`
#            is the declared-schema input, and `komira_csv`'s serial and
#            parallel readers both resolve their per-column dtypes from it
#            instead of inferring when it is set. The caller must pass the LEAF,
#            not the path, so the dialect is recovered off the leaf
#            (`row_source_csv_options`) instead of rebuilt as a default
#            `CsvReadOptions`.
#
#   AVRO   SOURCE_VARIANT_AVRO   RE-ROUTE. Avro has no inferrer: the schema is
#            the OCF header's, and the bind and the decode reach it through the
#            same calls over the same bytes, so there is nothing to declare.
#            The columnar reader partitions the OCF block list across workers.
#
# # THE TYPE ENVELOPE — why a format arm alone is not enough
#
# The row and column decoders do not accept the same dtype set. For JSONL:
#
#     row     I64 F64 I32 F32 STRING + depth-1 LIST / STRUCT
#     column  INT64 BOOL STRING FLOAT64 DATE32 DECIMAL128 LIST STRUCT MAP
#
# INT32 / FLOAT32 are ROW-ONLY. A declared JSONL schema carrying one (a typed
# read — the inferrer never produces them) would RAISE in the columnar
# materializer, i.e. the re-route would turn a working query into an error. So
# the envelope is checked per FIELD (`declared_schema_is_column_decodable`),
# and a schema outside it VETOES the re-route rather than being coerced into it.
#
# Nested (LIST / STRUCT / MAP) is DECLINED here even though the columnar
# materializer supports it: the two decoders reach the child type through
# different accessors with different arity requirements, so "both support
# LIST" is not the same claim as "both support THIS LIST". For Avro the two
# decoders are not ordered in either direction (each takes types the other
# refuses), and the envelope's exclusion of nested types is what keeps a nested
# Avro read off the column decoder. Widening it wants its own falsifier.
#
# Read-only plan walk; this module allocates nothing and mutates nothing.
# =============================================================================

from komira_plan_ir.logical_plan import (
    LogicalPlan,
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
    PLAN_CAST_TO_VARCHAR,
    SOURCE_KIND_ROW,
)
from komira_scan_source.source_variant import (
    SOURCE_VARIANT_JSON,
    SOURCE_VARIANT_CSV,
    SOURCE_VARIANT_AVRO,
    SOURCE_VARIANT_PARQUET,
)
# The TWO SCAN-LEAF WALKERS at the end of this module read the leaf's PATH and
# its source-variant TAG off the plan IR and nothing else. The third walker,
# `_row_source_csv_options_for_dispatch`, returns a `komira_csv.CsvReadOptions`
# and lives in the sibling `row_source_csv_options.mojo`.
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema


# The re-route's default: ON. `row_column_reroute_verdict` uses it; a caller
# that reads the switch from a flag passes it to
# `row_column_reroute_verdict_for_arm` instead. OFF means no plan is re-routed.
comptime ROW_COLUMN_REROUTE_DEFAULT_ON: Bool = True

# The DEMOTE sub-arm's default: ON. It stays a SECOND gate rather than a
# widening of the first: the two arms have different costs (the demote holds the
# whole decoded batch resident), so one switch could not express "the direct
# arm on, the demote off".
comptime ROW_COLUMN_REROUTE_DEMOTE_DEFAULT_ON: Bool = True

# Sentinel returned by the census walk when some ROW leaf VETOES the re-route.
comptime _CENSUS_VETO: Int = -1

# THE VERDICT. Three-valued — see the header for why the third value exists.
comptime REROUTE_NONE: Int = 0
comptime REROUTE_DIRECT_BATCH: Int = 1
comptime REROUTE_DEMOTE: Int = 2


def column_decode_is_parallel_and_schema_directed(source_variant_tag: UInt8) -> Bool:
    """THE FORMAT TABLE. True iff this source format's COLUMNAR decoder is
    both parallel and directed by a caller-supplied schema — see the module
    header for the per-format reason.

    JSONL, CSV and AVRO — every footerless source. For AVRO the SCHEMA half
    holds by construction — the OCF header is the bind's schema and the
    decode's schema, derived by the same call chain over the same bytes. See
    the module header's format table.

    ⛔ ADDING A FORMAT HERE IS NOT SUFFICIENT ON ITS OWN. The caller dispatches
    the DECODER by the same tag and RAISES on one it does not know; a format
    added here and not there turns every bare scan of that format into a hard
    error."""
    return (
        source_variant_tag == SOURCE_VARIANT_JSON
        or source_variant_tag == SOURCE_VARIANT_CSV
        or source_variant_tag == SOURCE_VARIANT_AVRO
    )


def declared_schema_is_column_decodable(imm schema: Schema) -> Bool:
    """True iff EVERY field's Arrow type is inside the JSONL columnar
    materializer's flat envelope (INT64 / BOOL / STRING / FLOAT64 / DATE32 /
    DECIMAL128).

    A field outside it — INT32 / FLOAT32 (row-only), or any nested type
    (see the header) — returns False, which VETOES the re-route. An empty
    schema is not decodable: there is nothing to check and nothing to gain."""
    var n = schema.num_columns()
    if n == 0:
        return False
    for i in range(n):
        var at = schema.field_arrow_type(i)
        if (
            at != ArrowType.INT64
            and at != ArrowType.BOOL
            and at != ArrowType.STRING
            and at != ArrowType.FLOAT64
            and at != ArrowType.DATE32
            and at != ArrowType.DECIMAL128
        ):
            return False
    return True


def scan_leaf_carries_no_own_work(imm plan: LogicalPlan) -> Bool:
    """True iff this `PLAN_SCAN` leaf has NOTHING pushed down onto it — no
    `projection`, no `filter`.

    THE PRECONDITION OF THE DIRECT RETURN, and the reason `plan.tag ==
    PLAN_SCAN` is not enough on its own. `ScanData.projection` prunes columns
    and `ScanData.filter` is a pushed-down predicate; both are the LEAF's work.
    Handing the caller the decoded batch while either is set silently answers a
    different question — extra columns, or unfiltered rows — with no error.

    ⚠ This is a check on the LEAF, not on the plan shape. A caller must ALSO
    have established that the leaf is the whole plan; `row_column_reroute_
    verdict` is the only place both halves are asked together."""
    if not plan._scan:
        return False
    ref sd = plan.scan_data_ref()
    if sd.projection:
        return False
    if sd.filter:
        return False
    return True


def _scan_leaf_census(imm plan: LogicalPlan) -> Int:
    """One ROW scan leaf: 1 if it is column-decodable, `_CENSUS_VETO` if it is
    a ROW leaf that is not. A non-ROW leaf contributes 0 (it is already on the
    column path and says nothing about the re-route)."""
    if not plan._scan:
        return _CENSUS_VETO
    ref sd = plan.scan_data_ref()
    if sd.source_kind != SOURCE_KIND_ROW:
        return 0
    if not column_decode_is_parallel_and_schema_directed(sd.source.tag):
        return _CENSUS_VETO
    # THE DECLARED SCHEMA IS REQUIRED, not merely preferred. The demote decodes
    # AT this schema; without it the decode would fall back to the whole-file
    # inferrer and could hand the plan a column type it was not bound against.
    # No schema -> no re-route.
    if not sd.schema:
        return _CENSUS_VETO
    if not declared_schema_is_column_decodable(sd.schema.value()):
        return _CENSUS_VETO
    return 1


def _row_leaf_census(imm plan: LogicalPlan) -> Int:
    """Walk the plan and count ROW scan leaves that the column decoder can read
    faster WITHOUT changing the answer.

    Returns `_CENSUS_VETO` if ANY ROW leaf fails the test — one un-re-routable
    leaf disqualifies the whole plan, because the demote re-routes EVERY leaf
    and a mixed plan would send the disqualified one through a decoder that
    re-infers its schema.

    Mirrors the variant tag-dispatch walk of
    `lower_untyped._has_row_source_signal`."""
    var tag = plan.tag
    if tag == PLAN_SCAN:
        return _scan_leaf_census(plan)
    if tag == PLAN_FILTER and plan._filter:
        return _row_leaf_census(plan.filter_data_ref().child[])
    if tag == PLAN_PROJECT and plan._project:
        return _row_leaf_census(plan.project_data_ref().child[])
    if tag == PLAN_AGGREGATE and plan._aggregate:
        return _row_leaf_census(plan.aggregate_data_ref().child[])
    if tag == PLAN_SORT and plan._sort:
        return _row_leaf_census(plan.sort_data_ref().child[])
    if tag == PLAN_LIMIT and plan._limit:
        return _row_leaf_census(plan.limit_data_ref().child[])
    if tag == PLAN_DISTINCT and plan._distinct:
        return _row_leaf_census(plan.distinct_data_ref().child[])
    if tag == PLAN_TOPN and plan._topn:
        return _row_leaf_census(plan.topn_data_ref().child[])
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        return _row_leaf_census(plan.partition_by_data_ref().child[])
    if tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        return _row_leaf_census(plan.partition_topn_data_ref().child[])
    if tag == PLAN_CAST_TO_VARCHAR and plan._cast_to_varchar:
        return _row_leaf_census(plan.cast_to_varchar_data_ref().child[])
    if tag == PLAN_JOIN and plan._join:
        ref jd = plan.join_data_ref()
        var l = _row_leaf_census(jd.left[])
        if l == _CENSUS_VETO:
            return _CENSUS_VETO
        var r = _row_leaf_census(jd.right[])
        if r == _CENSUS_VETO:
            return _CENSUS_VETO
        return l + r
    if tag == PLAN_ASOF_JOIN and plan._asof_join:
        ref ad = plan.asof_join_data_ref()
        var l2 = _row_leaf_census(ad.left[])
        if l2 == _CENSUS_VETO:
            return _CENSUS_VETO
        var r2 = _row_leaf_census(ad.right[])
        if r2 == _CENSUS_VETO:
            return _CENSUS_VETO
        return l2 + r2
    if tag == PLAN_UNION and plan._union:
        ref ud = plan.union_data_ref()
        var total = 0
        for i in range(ud.num_children()):
            var c = _row_leaf_census(ud.children[i][])
            if c == _CENSUS_VETO:
                return _CENSUS_VETO
            total = total + c
        return total
    # A leaf shape this walker does not know (PLAN_VIEW_REF / PLAN_CSE_REF /
    # any node whose payload is unexpectedly absent) contributes nothing AND
    # must not be silently assumed row-free: an unknown subtree could hide a
    # ROW leaf the demote would then decode without a declared schema.
    return _CENSUS_VETO


def row_column_reroute_verdict(imm plan: LogicalPlan) -> Int:
    """THE POLICY, three-valued. See the module header.

    `REROUTE_DIRECT_BATCH` — the plan IS a single re-routable scan leaf that
        carries no projection and no filter, so the decoded batch is the whole
        answer and is returned directly. No InMemorySource, no ScanRegistry
        bind, no unpaired acquire.
    `REROUTE_DEMOTE` — every ROW leaf is re-routable but there is a plan above
        the leaf, so the batch must be re-rooted for the column path.
    `REROUTE_NONE` — the re-route does not fire.

    A non-NONE answer means "the column decoder reads these same bytes faster
    and returns the same answer"; it says nothing about whether any other path
    could serve the plan.

    Uses the two gates' defaults (`ROW_COLUMN_REROUTE_DEFAULT_ON`,
    `ROW_COLUMN_REROUTE_DEMOTE_DEFAULT_ON`) and delegates to
    `row_column_reroute_verdict_for_arm`, which a caller holding the two
    switches as flags calls directly."""
    return row_column_reroute_verdict_for_arm(
        plan,
        enabled=ROW_COLUMN_REROUTE_DEFAULT_ON,
        demote_enabled=ROW_COLUMN_REROUTE_DEMOTE_DEFAULT_ON,
    )


def row_column_reroute_verdict_for_arm(
    imm plan: LogicalPlan, enabled: Bool, demote_enabled: Bool,
) -> Int:
    """THE POLICY'S SHAPE HALF, with the two gate states passed IN.
    `row_column_reroute_verdict` is this with both defaults.

    WHY THE SPLIT EXISTS: a test that asserts the policy through the defaulted
    entry silently carries "and the default is ON" as an unstated premise, and
    when a default moves it reports a failure about the policy that is really
    about the default. So the shape question is asked HERE, at a named arm, and
    the defaults are pinned by one test that says so."""
    if not enabled:
        return REROUTE_NONE
    var census = _row_leaf_census(plan)
    if census <= 0:
        return REROUTE_NONE
    # THE LEAK-SAFE SHAPE: the plan is the leaf, and the leaf carries no work
    # of its own. `census == 1` is implied by `tag == PLAN_SCAN` but is asserted
    # rather than assumed — a future leaf node holding two sources would
    # otherwise inherit a direct return it has no answer for.
    if plan.tag == PLAN_SCAN and census == 1:
        if scan_leaf_carries_no_own_work(plan):
            return REROUTE_DIRECT_BATCH
        return REROUTE_NONE
    if demote_enabled:
        return REROUTE_DEMOTE
    return REROUTE_NONE


def row_plan_prefers_column_decode(imm plan: LogicalPlan) -> Bool:
    """True iff the re-route fires at all for `plan`, in either shape.

    Retained as the one-bit question ("did the policy admit this plan") for
    callers and falsifiers that do not care WHICH arm ran.
    `row_column_reroute_verdict` is what the execution site consults, because
    the two arms are not interchangeable — one returns the batch and the other
    re-roots it as a whole-file in-memory source (they differ in PEAK RSS)."""
    return row_column_reroute_verdict(plan) != REROUTE_NONE


def row_plan_prefers_column_decode_for_arm(
    imm plan: LogicalPlan, enabled: Bool, demote_enabled: Bool,
) -> Bool:
    """`row_plan_prefers_column_decode` at an explicitly named arm — the
    form the falsifiers assert through. See
    `row_column_reroute_verdict_for_arm`."""
    return row_column_reroute_verdict_for_arm(
        plan, enabled=enabled, demote_enabled=demote_enabled
    ) != REROUTE_NONE


# =============================================================================
# SCAN-LEAF WALKERS
#
# ⚠ THREE WALKERS, NOT ONE. Each is independently callable and the chain
# shapes must not drift: adding a new single-child plan node means adding the
# arm to ALL THREE.
# =============================================================================

def _row_source_path_for_dispatch(imm plan: LogicalPlan) raises -> String:
    """Walk the plan to its SCAN leaf and return the row source's file path.

    The in-scope shapes are linear single-child chains over a row source
    (filter / project / limit / sort / distinct / aggregate / partition by /
    partition top-n / top-n). Descend the single child until the PLAN_SCAN
    leaf, then read the path off whichever SourceVariant arm the scan landed
    on (a legacy CSV scan rides the SOURCE_VARIANT_PARQUET arm with
    source_kind == ROW).
    """
    var tag = plan.tag
    if tag == PLAN_SCAN:
        if not plan._scan:
            raise Error(
                "row scan walk: PLAN_SCAN missing ScanData (IR"
                " invariant violated)."
            )
        ref scan_data = plan.scan_data_ref()
        if scan_data.source_kind != SOURCE_KIND_ROW:
            raise Error(
                "row scan walk: scan leaf is not SOURCE_KIND_ROW —"
                " route_plan_shape_row_streaming classified a non-row source."
            )
        ref src = scan_data.source
        if src.tag == SOURCE_VARIANT_CSV:
            # The CSV arm is binding-backed, so there is
            # no `CsvSource` to reach. `ScanBinding.name` IS the file path —
            # `_csv_binding` sets `name=csv.path` and `ScanData.__init__`
            # derives `source_path` from the same field. Same shape as AVRO
            # below.
            return String(src.binding_ref().name)
        if src.tag == SOURCE_VARIANT_JSON:
            # The JSON arm is binding-backed, so there
            # is no `JsonSource` to reach. `ScanBinding.name` IS the file
            # path — `_json_binding` sets `name=json.path` and
            # `ScanData.__init__` derives `source_path` from the same field.
            # Same shape as the CSV arm above and the AVRO arm below.
            return String(src.binding_ref().name)
        if src.tag == SOURCE_VARIANT_PARQUET and src._parquet:
            return String(src._parquet.value().path)
        if src.tag == SOURCE_VARIANT_AVRO:
            # The AVRO arm is binding-backed, so there is
            # no `AvroSource` to reach. `ScanBinding.name` IS the OCF path —
            # `_avro_binding` sets `name=avro.path` and `ScanData.__init__`
            # derives `source_path` from the same field.
            return String(src.binding_ref().name)
        raise Error(
            "row scan walk: SOURCE_KIND_ROW scan has no on-wire path"
            " arm (in-memory row sources are not supported yet)."
        )
    # Single-child descent for the linear in-scope chain shapes.
    if tag == PLAN_FILTER and plan._filter:
        return _row_source_path_for_dispatch(plan.filter_data_ref().child[])
    if tag == PLAN_PROJECT and plan._project:
        return _row_source_path_for_dispatch(plan.project_data_ref().child[])
    if tag == PLAN_LIMIT and plan._limit:
        return _row_source_path_for_dispatch(plan.limit_data_ref().child[])
    if tag == PLAN_SORT and plan._sort:
        return _row_source_path_for_dispatch(plan.sort_data_ref().child[])
    if tag == PLAN_DISTINCT and plan._distinct:
        return _row_source_path_for_dispatch(plan.distinct_data_ref().child[])
    if tag == PLAN_AGGREGATE and plan._aggregate:
        return _row_source_path_for_dispatch(
            plan.aggregate_data_ref().child[]
        )
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        return _row_source_path_for_dispatch(
            plan.partition_by_data_ref().child[]
        )
    # PLAN_PARTITION_TOPN (per-partition top_n) is a single-child chain node
    # too; without this arm the walk raises "not a single-child chain node".
    if tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        return _row_source_path_for_dispatch(
            plan.partition_topn_data_ref().child[]
        )
    # PLAN_TOPN (the optimizer-fused global Sort+Limit) is a root the walker
    # must descend to find the scan leaf.
    if tag == PLAN_TOPN and plan._topn:
        return _row_source_path_for_dispatch(plan.topn_data_ref().child[])
    raise Error(
        "row scan walk: plan tag "
        + String(Int(tag))
        + " is not a row-streaming single-child chain node — cannot reach the"
        " scan leaf to recover the source path."
    )


# =============================================================================
# _row_source_variant_for_dispatch — recover the on-wire FORMAT of the row scan
# =============================================================================


def _row_source_variant_for_dispatch(imm plan: LogicalPlan) raises -> UInt8:
    """Walk the plan to its SCAN leaf and return the SourceVariant TAG of the
    row source. The producer dispatch picks the CSV vs JSONL direct reader by
    this tag.

    The legacy CSV factory (`LogicalPlan.scan(path, SOURCE_CSV, ...)`) rides the
    `SOURCE_VARIANT_PARQUET` arm with `source_kind == ROW` (see
    `_row_source_path_for_dispatch`), so a PARQUET-tag SOURCE_KIND_ROW scan is
    the transitional CSV form. A `SOURCE_VARIANT_JSON` arm with `source_kind ==
    ROW` (built via `scan_from_source(JsonSource, source_kind=ROW)`) is the
    JSONL row source. The genuine `SOURCE_VARIANT_CSV` arm (binding-backed)
    also routes to the CSV reader.
    """
    var tag = plan.tag
    if tag == PLAN_SCAN:
        if not plan._scan:
            raise Error(
                "row scan walk: PLAN_SCAN missing ScanData (IR"
                " invariant violated)."
            )
        ref scan_data = plan.scan_data_ref()
        return scan_data.source.tag
    if tag == PLAN_FILTER and plan._filter:
        return _row_source_variant_for_dispatch(plan.filter_data_ref().child[])
    if tag == PLAN_PROJECT and plan._project:
        return _row_source_variant_for_dispatch(
            plan.project_data_ref().child[]
        )
    if tag == PLAN_LIMIT and plan._limit:
        return _row_source_variant_for_dispatch(plan.limit_data_ref().child[])
    if tag == PLAN_SORT and plan._sort:
        return _row_source_variant_for_dispatch(plan.sort_data_ref().child[])
    if tag == PLAN_DISTINCT and plan._distinct:
        return _row_source_variant_for_dispatch(
            plan.distinct_data_ref().child[]
        )
    if tag == PLAN_AGGREGATE and plan._aggregate:
        return _row_source_variant_for_dispatch(
            plan.aggregate_data_ref().child[]
        )
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        return _row_source_variant_for_dispatch(
            plan.partition_by_data_ref().child[]
        )
    # PLAN_PARTITION_TOPN single-child arm.
    if tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        return _row_source_variant_for_dispatch(
            plan.partition_topn_data_ref().child[]
        )
    # PLAN_TOPN (the global-top_n root) single-child arm.
    if tag == PLAN_TOPN and plan._topn:
        return _row_source_variant_for_dispatch(plan.topn_data_ref().child[])
    raise Error(
        "row scan walk: plan tag "
        + String(Int(tag))
        + " is not a row-streaming single-child chain node — cannot reach the"
        " scan leaf to recover the source variant."
    )
