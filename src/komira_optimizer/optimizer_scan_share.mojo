# =============================================================================
# Scan SHARE PLANNING -- deciding scan dedup, as data.
#
# ⭐ WHAT THIS MODULE DOES, AND WHAT IT DOES NOT.
#
# The optimizer rewrites logical plans -- it executes
# nothing, opens nothing, calls back into nothing. Deciding a scan share
# therefore takes no `LocalDispatcher`, no `CancellationToken`, no metadata
# cache and no `ScanRegistry`, and reads no Parquet file: this module only
# decides.
#
# ⭐ THE QUESTION THAT DECIDED THE SHAPE: does dedup need the DECODED BATCH, or
# does it only need both scans to AGREE ON ONE READ?
#
#   ANSWER: only the agreement. Every gate that selects a share group is a
#   pure function of the LogicalPlan (plus `ScanData.row_count`, the
#   source-metadata row count already on the scan node). Enumerated:
#
#     * `_collect_scan_keys`            -- (path, filter fingerprint), plan text
#     * `count >= 2` / `multi_table_plan` -- plan text
#     * `_scan_consumer_is_aggregate_only`, `_scan_matching_key_is_filtered`,
#       `_collect_fact_stream_protect_keys`,
#       `_streamable_join_child_key`   -- plan walks
#     * `DEDUP_ROW_THRESHOLD`, `OptimizerConfig.agg_inmem_ceiling_rows`,
#       `.fact_stream_protect_threshold` -- `ScanData.row_count`, already on
#                                         the node
#     * `_detect_hoist_matches`        -- a pure plan walk; it reads join type,
#                                         key arity and the scan's SCHEMA, and
#                                         opens nothing
#     * `_collect_union_projection`, `_lookup_first_filter`,
#       `_session_cache_key`, `_dyn_narrow_cache_key` -- plan text + fingerprints
#
#   The decoded batch is not an input to any decision. This module emits the
#   cache keys and the dynamic-filter slot; it builds no batch, no
#   `ScanRegistry` handle and no dynamic filter, and nothing in
#   komira_optimizer executes the descriptor.
#   The dynamic filter is DuckDB's dynamic-filter-pushdown pattern: the STRUCTURE is decided at
#        plan time (`_detect_hoist_matches`, pure, here), the VALUES are filled
#        at runtime from the completed build side. Plan-time slot, runtime
#        value.
#
# ⇒ So this module only decides; it emits a
#   `ScanSharePlan` -- a self-contained descriptor saying "these scan sites are
#   the same relation, materialize it ONCE with this projection and this
#   filter, and (optionally) narrow the read with a dynamic filter built from
#   that other relation's column".
#
# ⛔ THIS MODULE MAY NOT IMPORT A FILESYSTEM, A READER, A DISPATCHER OR A
# REGISTRY. That is not a style rule, it is the whole point: the optimizer's
# import closure must not reach the parquet reader or the filesystem.
#
# ⚠ A LOST SHARE IS INVISIBLE IN THE ROWS.
# Dedup exists so two identical scans read the file ONCE. Losing it is a pure
# performance regression that no value assertion can see -- the rows are
# identical either way. `parquet_read_counter` (komira_counters) counts Parquet
# source reads; this module's tests pin the share groups it decides.
# =============================================================================

from std.collections import Set

from komira_collections.slab import Slab
from komira_arrow.schema import Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan, ScanData,
    PLAN_SCAN, PLAN_FILTER, PLAN_PROJECT, PLAN_AGGREGATE, PLAN_JOIN,
    PLAN_SORT, PLAN_LIMIT, PLAN_DISTINCT, PLAN_TOPN, PLAN_PARTITION_BY,
    SOURCE_PARQUET, SOURCE_IN_MEMORY,
    JOIN_INNER, JOIN_LEFT, JOIN_SEMI, JOIN_ANTI,
)
from komira_plan_ir.plan_helpers import (
    _expr_fingerprint, _copy_schema, _collect_expr_columns,
)

from .optimizer_config import OptimizerConfig

# =============================================================================
# Threshold: skip dedup above this many rows.
# Rationale: materializing a huge file defeats the streaming Parquet path
# and risks excess memory. 10M is a conservative default; TPC-H Q17 at 6M
# qualifies, TPC-H SF-10 lineitem (60M) does not.
# =============================================================================
comptime DEDUP_ROW_THRESHOLD: Int = 10_000_000

# Separator between path and filter fingerprint in the grouping key.
# A triple-NUL is guaranteed not to appear in filesystem paths or in the
# output of _expr_fingerprint (which produces printable ASCII).
comptime _KEY_SEP: String = "\0\0\0"


# =============================================================================
# Optimizer hoist for dyn-filter pushdown (the q17 shape)
# =============================================================================
#
# In the q17 shape the lineitem read is a shared (dedup'd) read, so by the
# time the join runs its probe source is `SOURCE_IN_MEMORY` and a join-time
# dynamic filter cannot narrow the Parquet decode.
#
# The hoist decides the narrowing at plan time instead: it detects the q17
# shape (a large dedup-eligible scan joined to a small filtered scan) and
# records in the descriptor which small scan and which key columns build a
# `DynamicJoinFilter` for the large read, so the small filtered scan can be
# read FIRST and its join keys narrow the large read.
#
# Conservative gates to avoid regressions:
#   * Join type + direction must be bloom-safe per
#     `_is_safe_to_push_dyn_filter` (helper encodes the formal
#     join-type × build-direction matrix; it admits INNER + SEMI
#     in both directions). SEMI serves TPC-H Q4 (Order Priority).
#     ANTI/LEFT/RIGHT are formally safe in some directions per the matrix
#     and are rejected.
#   * Not checked here: the filter's build side is capped at
#     DYNAMIC_FILTER_BUILD_CAP=65_536 rows by
#     `DynamicJoinFilter.build_int64_from_list` when the filter is built.
#   * Build-side join key must be INT64 (mirrors the dyn-filter typed builder).
#   * Build-side scan must have a non-trivial `pushed_filter` (signals
#     selectivity — without a filter, the in_list pushdown rarely helps).
#   * Unconditional.
#
# Each q17-shape match contributes one `_HoistMatch`; `plan_scan_shares`
# attaches it to the share group whose key equals its `large_key`.
# =============================================================================


@fieldwise_init
struct _HoistMatch(Movable):
    """One detected q17-shape match: a large dedup-eligible scan paired with
    a small filtered scan via a JOIN.

    Fields:
        large_key: scan_key for the large source (matches dedup_keys entries).
        large_join_col: column name on the large side that's joined.
        small_path: file path of the small filtered scan.
        small_filter: pushed_filter on the small scan (cloned).
        small_proj: column projection on the small scan (cloned).
        small_join_col: column name on the small side (the build key).

    Schema is intentionally NOT a field here — `_scan_field_is_int64` runs
    at detect-time and gates membership, so by the time a match enters
    this struct we already know the small side's join key is INT64.
    """
    var large_key: String
    var large_join_col: String
    var small_path: String
    var small_filter: Optional[Expr]
    var small_proj: Optional[List[String]]
    var small_join_col: String


def _unwrap_to_scan(plan: LogicalPlan) -> Optional[Int]:
    """If `plan` is a PLAN_SCAN (or PLAN_PROJECT directly above one),
    return Optional[1] when it's an unfiltered PARQUET scan, Optional[2]
    when it's a filtered PARQUET scan, None otherwise. The numeric tag
    avoids returning a ref-vs-Pointer disambiguation across struct
    boundaries.

    Used by `_detect_hoist_matches` to admit JOIN(SCAN, ...) /
    JOIN(PROJECT(SCAN), ...) shapes uniformly. Projection-pushdown
    is best-effort; some plans land with a PROJECT atop the SCAN for
    column narrowing.

    A PLAN_PROJECT is looked through unconditionally: `ProjectData` carries
    no UDF, so there is no UDF Project to treat as opaque here.
    """
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].source_type != SOURCE_PARQUET:
            return None
        if plan._scan.value()[].filter:
            return Optional[Int](2)
        return Optional[Int](1)
    elif plan.tag == PLAN_PROJECT:
        # No UDF guard: ProjectData carries no `udf`.
        return _unwrap_to_scan(plan._project.value()[].child[])
    return None


def _scan_raw_row_count(plan: LogicalPlan) -> Optional[Int]:
    """Return the raw row_count (parquet footer count, NOT post-filter)
    of the PLAN_SCAN node reached through `plan` (which may be a direct
    PLAN_SCAN or a PLAN_PROJECT(PLAN_SCAN) per `_unwrap_to_scan` shapes).

    Used by `_detect_hoist_matches` to break the both-filtered direction
    tie. Returns None when row_count is
    not populated on the scan node (e.g. synthetic test plans, sources
    that haven't yet probed the parquet footer); callers must handle
    that case gracefully.

    Looks through a PLAN_PROJECT exactly as `_unwrap_to_scan` does.
    """
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].row_count:
            return Optional[Int](plan._scan.value()[].row_count.value())
        return None
    elif plan.tag == PLAN_PROJECT:
        # No UDF guard: ProjectData carries no `udf`.
        return _scan_raw_row_count(plan._project.value()[].child[])
    return None


@fieldwise_init
struct _ScanMeta(Movable):
    """Snapshot of PLAN_SCAN node metadata, materialized as values to
    sidestep origin issues across PLAN_SCAN-vs-PLAN_PROJECT(PLAN_SCAN)
    branches in `_detect_hoist_matches`. Fields wrapped in Optional to
    enable Optional.take() partial-extraction (Mojo does not support
    a partial move out of a struct otherwise).
    """
    var path: Optional[String]
    var filter: Optional[Expr]
    var projection: Optional[List[String]]
    var schema: Optional[Schema]


def _extract_scan_metadata(plan: LogicalPlan) raises -> _ScanMeta:
    """Snapshot the underlying ScanData (via either direct PLAN_SCAN or
    PLAN_PROJECT(PLAN_SCAN)). Caller must have verified shape via
    `_unwrap_to_scan`.

    The PLAN_PROJECT arm reads its child as a PLAN_SCAN without checking:
    a call site that bypasses the `_unwrap_to_scan` gate would fail at
    `child._scan.value()[]`. The contract is "caller has verified shape
    via `_unwrap_to_scan`".
    """
    if plan.tag == PLAN_PROJECT:
        ref child = plan._project.value()[].child[]
        ref sd = child._scan.value()[]
        var sd_filter: Optional[Expr] = None
        if sd.filter:
            sd_filter = Optional[Expr](sd.filter.value().copy())
        var sd_proj: Optional[List[String]] = None
        if sd.projection:
            sd_proj = Optional[List[String]](sd.projection.value().copy())
        var sd_schema: Optional[Schema] = None
        if sd.schema:
            sd_schema = Optional[Schema](_copy_schema(sd.schema.value()))
        return _ScanMeta(
            Optional[String](String(sd.source_path)),
            sd_filter^,
            sd_proj^,
            sd_schema^,
        )
    else:
        ref sd = plan._scan.value()[]
        var sd_filter: Optional[Expr] = None
        if sd.filter:
            sd_filter = Optional[Expr](sd.filter.value().copy())
        var sd_proj: Optional[List[String]] = None
        if sd.projection:
            sd_proj = Optional[List[String]](sd.projection.value().copy())
        var sd_schema: Optional[Schema] = None
        if sd.schema:
            sd_schema = Optional[Schema](_copy_schema(sd.schema.value()))
        return _ScanMeta(
            Optional[String](String(sd.source_path)),
            sd_filter^,
            sd_proj^,
            sd_schema^,
        )


def _scan_field_is_int64(
    schema_opt: Optional[Schema], col_name: String
) -> Bool:
    """Schema-aware INT64 check; sibling of `_join_key_is_int64` but
    operates on a pre-extracted Schema (safer across origin boundaries).
    """
    if not schema_opt:
        return False
    ref schema = schema_opt.value()
    var n = schema.num_columns()
    for i in range(n):
        if schema.field_name(i) == col_name:
            return schema.field_arrow_type(i) == ArrowType.INT64
    return False


def _is_safe_to_push_dyn_filter(
    join_type: UInt8, build_is_left: Bool
) -> Bool:
    """Bloom-safety matrix for dyn-filter pushdown from SMALL (build)
    side to LARGE (probe) scan.

    A dyn-filter built from `build_side`'s join keys is pushed to
    `probe_side`'s scan as `key IN BF(build_keys)`. The probe scan rows
    that DO NOT pass the filter are rows that would never join (zero
    match keys); for some join types removing them changes semantics.

    Per join type:
      INNER: SAFE both directions — only matched rows survive.
      SEMI:  SAFE both directions — SEMI keeps left-rows-with-≥1-match;
             narrowing either side preserves the match relation.
      ANTI:  SAFE when build_is_left only — filter RIGHT to BF(LEFT)
             narrows right; ANTI keeps left rows that match ZERO right,
             which is preserved (a left row not-in-right stays
             not-in-narrowed-right). UNSAFE when build_is_right —
             would filter LEFT to BF(RIGHT), removing the
             ANTI-result rows.
      LEFT:  SAFE when build_is_left — filter RIGHT to BF(LEFT)
             narrows right; unmatched left rows still emit with NULL.
             UNSAFE when build_is_right — would remove unmatched left.
      RIGHT: symmetric — SAFE when build_is_right only.
      FULL:  UNSAFE both directions (preserves unmatched both sides).
      CROSS: UNSAFE (no key correspondence).

    Admission (load-bearing): this helper admits only INNER + SEMI.
    ANTI/LEFT/RIGHT are formally SAFE per the matrix in one direction,
    and this helper conservatively rejects them.

    Args:
        join_type: one of JOIN_INNER/LEFT/RIGHT/FULL/SEMI/ANTI/CROSS.
        build_is_left: True when the SMALL/build side is the LEFT operand
            of the join (so dyn-filter pushes to RIGHT/probe scan).

    Returns:
        True iff the join type is INNER or SEMI (SAFE in both directions).
    """
    # Admission gate: INNER + SEMI only.
    if join_type != JOIN_INNER and join_type != JOIN_SEMI:
        return False
    # INNER/SEMI: SAFE in both directions per matrix.
    return True


def _detect_hoist_matches(
    plan: LogicalPlan, mut out: Slab[_HoistMatch]
) raises:
    """Walk the plan tree; for each PLAN_JOIN where the join type +
    direction is bloom-safe per `_is_safe_to_push_dyn_filter`, AND
    one branch leads to a SCAN(SOURCE_PARQUET, no filter) and the
    other to a SCAN(SOURCE_PARQUET, has filter), record a hoist match
    keyed by the large (no-filter) side.

    Admits JOIN(SCAN, SCAN), JOIN(PROJECT(SCAN), SCAN),
    JOIN(SCAN, PROJECT(SCAN)) — projection-pushdown can land any of
    these. Q17's filtered lineitem-part join is JOIN(SCAN, SCAN)
    after filter pushdown. Q4's EXISTS subquery becomes a similar shape
    with JOIN_SEMI as join_type.

    Restrictions:
      * Join-type gated through `_is_safe_to_push_dyn_filter`
        (INNER + SEMI only; ANTI/LEFT/RIGHT are formally safe in
         some directions and are rejected).
      * Single-key joins only.
      * Recursive descent into all child subtrees.
    """
    if plan.tag == PLAN_JOIN:
        ref jd = plan._join.value()[]
        if len(jd.left_on) == 1 and len(jd.right_on) == 1:
            ref left = jd.left[]
            ref right = jd.right[]
            var left_kind = _unwrap_to_scan(left)
            var right_kind = _unwrap_to_scan(right)
            var left_is_unfiltered_parquet = (
                left_kind and left_kind.value() == 1
            )
            var right_is_unfiltered_parquet = (
                right_kind and right_kind.value() == 1
            )
            var left_is_filtered_parquet = (
                left_kind and left_kind.value() == 2
            )
            var right_is_filtered_parquet = (
                right_kind and right_kind.value() == 2
            )

            # Both-filtered direction tiebreaker. Emitting BOTH
            # directions for a both-filtered shape leaves the 65K
            # `build_int64_from_list` cap, applied when a filter is built,
            # as the only selectivity gate. For Q4
            # (orders[date]=1.5M filtered to ~57K SEMI lineitem[flag]=6M
            # filtered to ~3.79M) both directions would land in
            # `_HoistMatch`, and the wrong-direction match (large=orders,
            # small=lineitem=3.79M) would give the orders group a slot
            # whose build side is the 3.79M-row lineitem read.
            #
            # So: when BOTH sides are filtered AND raw row_count is
            # known for both, emit ONLY the direction whose SMALL side
            # has the smaller raw row_count. Raw row_count is the parquet
            # footer count (not post-filter); for TPC-H/-DS, smaller raw
            # row_count is overwhelmingly correlated with smaller post-
            # filter build set. When row_count is unknown on either side
            # (synthetic plans), fall back to emitting both — the 65K
            # cap is then the only gate. Single-filtered shapes (q17, q11)
            # are unaffected: the admission asymmetry (one side
            # unfiltered) restricts emission to one direction.
            var both_filtered = (
                left_is_filtered_parquet and right_is_filtered_parquet
            )
            # For both-filtered: decide which direction wins the
            # row-count tiebreak. Defaults to "emit both" when either
            # row_count is unknown.
            var emit_left_as_large = True   # small=right
            var emit_right_as_large = True  # small=left
            if both_filtered:
                var left_rc_opt = _scan_raw_row_count(left)
                var right_rc_opt = _scan_raw_row_count(right)
                if left_rc_opt and right_rc_opt:
                    var l_rc = left_rc_opt.value()
                    var r_rc = right_rc_opt.value()
                    if r_rc < l_rc:
                        # small=right, large=left → emit left-as-large only.
                        emit_right_as_large = False
                    elif l_rc < r_rc:
                        # small=left, large=right → emit right-as-large only.
                        emit_left_as_large = False
                    # Equal row counts: keep both (no asymmetry to break).

            # Match: large=left, small=right (right is filtered).
            # Build side = RIGHT (small/filtered) → build_is_left = False.
            #
            # Q4 SEMI: _is_safe_to_push_dyn_filter encodes the
            # join-type × build-direction safety matrix; INNER + SEMI
            # both safe both directions per the matrix.
            #
            # Q4 both-filtered: admit shapes where
            # both sides are filtered (left filtered too). Q4 has
            # orders[o_orderdate ∈ range] ⋈semi lineitem[l_late_delivery=1]
            # — DuckDB pushes a dyn-filter from the post-filter orders set
            # (57K rows) onto the lineitem scan. The matrix admits SEMI; this
            # branch admits the both-filtered shape by NOT requiring
            # `left_is_unfiltered_parquet`. The 65K build cap inside
            # `build_int64_from_list` is the natural selectivity gate:
            # if the small side (build) exceeds it, `build_int64_from_list`
            # returns None and no dynamic filter is built. Selectivity
            # heuristic is implicit in that cap.
            #
            # The large side's filter (if any) is included in the
            # `large_key`, so `_find_hoist_match` in `plan_scan_shares`
            # matches it against the per-call dedup_keys, which
            # also incorporate the large filter (`_collect_scan_keys`).
            if (
                (left_is_unfiltered_parquet or left_is_filtered_parquet)
                and right_is_filtered_parquet
                and _is_safe_to_push_dyn_filter(jd.join_type, False)
                and emit_left_as_large
            ):
                var large_meta = _extract_scan_metadata(left)
                var small_meta = _extract_scan_metadata(right)
                # Self-join guard: when LARGE and SMALL
                # are the SAME file path (e.g., file A filtered on grp==0
                # joined to file A filtered on grp==1), record no match. The
                # small side's read uses an AUGMENTED projection (join key
                # plus filter-referenced cols, `_hoist_small_augmented_proj`)
                # over the same file the large side reads, so the two reads
                # of one path would differ only in projection. The hoist
                # offers no benefit on same-file joins (identical scans are
                # already one share group, and different-filter same-file
                # scans are 2 narrow filtered slices, not a LARGE × SMALL
                # asymmetric pair). Skip cleanly.
                var paths_differ = True
                if large_meta.path and small_meta.path:
                    paths_differ = large_meta.path.value() != small_meta.path.value()
                # Verify the join key on the small (build) side has INT64
                # type — `DynamicJoinFilter.build_int64_from_list` is the
                # only typed builder today.
                if paths_differ and _scan_field_is_int64(small_meta.schema, jd.right_on[0]):
                    # Include the LARGE-side filter in the
                    # large_key fingerprint so `_find_hoist_match` in
                    # `plan_scan_shares` matches it against the per-call
                    # dedup_keys (which incorporate the LARGE filter via
                    # `_collect_scan_keys`).
                    var large_f_for_key: Optional[Expr] = None
                    if large_meta.filter:
                        large_f_for_key = Optional[Expr](
                            large_meta.filter.value().copy()
                        )
                    var large_path = large_meta.path.take()
                    var large_key = _scan_key(large_path, large_f_for_key^)
                    var sm_path = small_meta.path.take()
                    # Take owned Optionals out of small_meta — leaves
                    # them in None state, struct still destructor-safe.
                    var sm_filter_opt: Optional[Expr] = None
                    if small_meta.filter:
                        sm_filter_opt = Optional[Expr](small_meta.filter.take())
                    var sm_proj_opt: Optional[List[String]] = None
                    if small_meta.projection:
                        sm_proj_opt = Optional[List[String]](
                            small_meta.projection.take()
                        )
                    out.append(_HoistMatch(
                        large_key,
                        String(jd.left_on[0]),
                        sm_path,
                        sm_filter_opt^,
                        sm_proj_opt^,
                        String(jd.right_on[0]),
                    ))
            # Match: large=right, small=left (left is filtered).
            # Build side = LEFT (small/filtered) → build_is_left = True.
            # Admit both-filtered (right also filtered) by not
            # requiring `right_is_unfiltered_parquet`. This is
            # `if` (not `elif`) so when BOTH sides are filtered and the
            # row-count tiebreak above cannot choose, we emit hoist
            # entries in BOTH directions; each is keyed on a different
            # `large_key`. The 65K build cap then selects: for the
            # direction whose build side exceeds it,
            # `build_int64_from_list` returns None and no dynamic filter
            # is built. Either way the join's answer is unchanged.
            if (
                (right_is_unfiltered_parquet or right_is_filtered_parquet)
                and left_is_filtered_parquet
                and _is_safe_to_push_dyn_filter(jd.join_type, True)
                and emit_right_as_large
            ):
                var large_meta = _extract_scan_metadata(right)
                var small_meta = _extract_scan_metadata(left)
                # Self-join guard (see sibling branch above).
                var paths_differ = True
                if large_meta.path and small_meta.path:
                    paths_differ = large_meta.path.value() != small_meta.path.value()
                if paths_differ and _scan_field_is_int64(small_meta.schema, jd.left_on[0]):
                    var large_f_for_key: Optional[Expr] = None
                    if large_meta.filter:
                        large_f_for_key = Optional[Expr](
                            large_meta.filter.value().copy()
                        )
                    var large_path = large_meta.path.take()
                    var large_key = _scan_key(large_path, large_f_for_key^)
                    var sm_path = small_meta.path.take()
                    var sm_filter_opt: Optional[Expr] = None
                    if small_meta.filter:
                        sm_filter_opt = Optional[Expr](small_meta.filter.take())
                    var sm_proj_opt: Optional[List[String]] = None
                    if small_meta.projection:
                        sm_proj_opt = Optional[List[String]](
                            small_meta.projection.take()
                        )
                    out.append(_HoistMatch(
                        large_key,
                        String(jd.right_on[0]),
                        sm_path,
                        sm_filter_opt^,
                        sm_proj_opt^,
                        String(jd.left_on[0]),
                    ))

        # Recurse into both children (deeper joins may yield more matches).
        _detect_hoist_matches(jd.left[], out)
        _detect_hoist_matches(jd.right[], out)
        return
    elif plan.tag == PLAN_FILTER:
        _detect_hoist_matches(plan._filter.value()[].child[], out)
    elif plan.tag == PLAN_PROJECT:
        _detect_hoist_matches(plan._project.value()[].child[], out)
    elif plan.tag == PLAN_AGGREGATE:
        _detect_hoist_matches(plan._aggregate.value()[].child[], out)
    elif plan.tag == PLAN_SORT:
        _detect_hoist_matches(plan._sort.value()[].child[], out)
    elif plan.tag == PLAN_LIMIT:
        _detect_hoist_matches(plan._limit.value()[].child[], out)
    elif plan.tag == PLAN_DISTINCT:
        _detect_hoist_matches(plan._distinct.value()[].child[], out)
    elif plan.tag == PLAN_TOPN:
        _detect_hoist_matches(plan._topn.value()[].child[], out)
    elif plan.tag == PLAN_PARTITION_BY:
        _detect_hoist_matches(plan._partition_by.value()[].child[], out)


def _join_key_is_int64(scan: ScanData, col_name: String) -> Bool:
    """Check whether the named column has INT64 type in the scan's schema.

    Returns False if the schema is unavailable or the column is missing.
    The `ScanData` form of `_scan_field_is_int64`, which is the one
    `_detect_hoist_matches` calls.
    """
    if not scan.schema:
        return False
    ref schema = scan.schema.value()
    var n = schema.num_columns()
    for i in range(n):
        if schema.field_name(i) == col_name:
            return schema.field_arrow_type(i) == ArrowType.INT64
    return False



def _find_hoist_match(matches: Slab[_HoistMatch], dedup_key: String) -> Int:
    """Linear search for the first hoist match whose `large_key` equals
    `dedup_key`. Returns the index, or -1 if no match.

    The list is short by construction (one entry per detected
    LARGE-paired-with-SMALL JOIN). Linear scan is fine.
    """
    for i in range(matches.len()):
        if matches[i].large_key == dedup_key:
            return i
    return -1


def _hoist_small_augmented_proj(hm: _HoistMatch) raises -> Optional[List[String]]:
    """The small side's read projection for a hoist match: start with
    `hm.small_proj`,
    add `hm.small_join_col` if absent, then add any columns referenced by
    `hm.small_filter` that aren't already in the projection.

    `plan_scan_shares` uses it for `ScanShareHoist.small_proj` and, through
    `_hoist_small_session_key`, for the small side's session key, from which
    `_dyn_narrow_cache_key` builds the LARGE side's dyn-narrow key.
    """
    var p_aug: Optional[List[String]]
    if hm.small_proj:
        var p = hm.small_proj.value().copy()
        var has_key = False
        for i in range(len(p)):
            if p[i] == hm.small_join_col:
                has_key = True
                break
        if not has_key:
            p.append(hm.small_join_col)
        p_aug = Optional[List[String]](p^)
    else:
        var p2 = List[String]()
        p2.append(hm.small_join_col)
        p_aug = Optional[List[String]](p2^)

    if hm.small_filter and p_aug:
        var fcols = Set[String]()
        _collect_expr_columns(hm.small_filter.value(), fcols)
        var ext = p_aug.value().copy()
        for c in fcols:
            var present = False
            for i in range(len(ext)):
                if ext[i] == c:
                    present = True
                    break
            if not present:
                ext.append(c)
        p_aug = Optional[List[String]](ext^)
    return p_aug^


def _hoist_small_session_key(hm: _HoistMatch) raises -> String:
    """Build the session-cache key for the SMALL side of a hoist match:
    `_session_cache_key` over the small path, the small filter and the
    projection `_hoist_small_augmented_proj` returns, which is also what
    `plan_scan_shares` stores in `ScanShareHoist.small_proj`.
    """
    var sm_proj_aug = _hoist_small_augmented_proj(hm)
    var sm_filter_clone: Optional[Expr] = None
    if hm.small_filter:
        sm_filter_clone = Optional[Expr](hm.small_filter.value().copy())
    return _session_cache_key(hm.small_path, sm_filter_clone^, sm_proj_aug^)


def _dyn_narrow_cache_key(large_sess_key: String, small_sess_key: String) -> String:
    """Compose a content-fingerprinted cache key for a dyn-narrowed LARGE
    read.

    The result of reading LARGE narrowed by the dynamic filter depends
    on (LARGE path/filter/proj) AND (the dyn-filter contents, which are a
    function of the SMALL path/filter/proj). When both inputs are
    identical across calls (a repeated Q17/Q12), the narrowed
    batch is identical too, so one key may name it.

    Format: <large_sess_key> \\0\\0\\0 "DYN:" \\0\\0\\0 <small_sess_key>.
    The "DYN:" separator distinguishes this key family from any plain
    `_session_cache_key` (which never contains "DYN:" because filter
    fingerprints don't emit that literal).
    """
    return large_sess_key + _KEY_SEP + "DYN:" + _KEY_SEP + small_sess_key


# =============================================================================
# Public API
# =============================================================================

def _session_cache_key(
    source_path: String,
    filter_opt: Optional[Expr],
    union_proj: Optional[List[String]],
) -> String:
    """Build the SESSION-cache key from (path, filter, projection).

    Distinct from `_scan_key` (the
    within-call dedup key) because the session cache value is a
    materialized batch with a SPECIFIC projection. q11's nation scan
    narrowed to `n_nationkey` by projection pushdown is a different
    materialized shape from a hypothetical scan that projects all 4
    nation columns; they must NOT collide.

    Format: <path> \\0 \\0 \\0 <filter_fp> \\0 \\0 \\0 <proj_fp>
        where proj_fp is "*" (all columns) or a comma-separated sorted
        column-name list. Sort order matters for hash stability — two
        plans that project ["a", "b"] and ["b", "a"] read the same
        column set, so we sort to make their keys collide intentionally.

    Why _KEY_SEP-3 between path/filter and filter/proj: triple-NUL is
    not a valid filename character or fingerprint character, so this
    cannot be ambiguous with content.
    """
    var fp = ""
    if filter_opt:
        fp = _expr_fingerprint(filter_opt.value())

    var proj_fp = "*"
    if union_proj:
        # Sort the projection column names for stable fingerprint.
        # A scan projects a few columns, so an insertion sort is enough.
        ref names = union_proj.value()
        var sorted = List[String]()
        for i in range(len(names)):
            sorted.append(names[i])
        # In-place stable sort (insertion sort since N is small).
        for i in range(1, len(sorted)):
            var j = i
            while j > 0 and sorted[j] < sorted[j - 1]:
                var tmp = sorted[j]
                sorted[j] = sorted[j - 1]
                sorted[j - 1] = tmp
                j -= 1
        proj_fp = String("")
        for i in range(len(sorted)):
            if i > 0:
                proj_fp += ","
            proj_fp += sorted[i]

    return source_path + _KEY_SEP + fp + _KEY_SEP + proj_fp


# q18 agg ceiling. A singleton scan whose only consumer (above Filter/Project)
# is an Aggregate and whose raw row_count EXCEEDS
# `OptimizerConfig.agg_inmem_ceiling_rows()` (default
# `AGG_INMEM_MAX_ROWS_DEFAULT` = 4M) stays SOURCE_PARQUET: it is not admitted
# as a SOURCE_IN_MEMORY (multi-table singleton) share group. The ceiling
# mirrors the in-memory aggregate's row limit, so an aggregate input above it
# is left a Parquet source rather than shared as one resident batch.


# =============================================================================
# FACT-STREAM protection. SINGLE-USE LARGE FACT
# scan that is a child of a STREAMING-both-parquet-eligible JOIN stays
# SOURCE_PARQUET, so the join can read it as a Parquet source instead of as
# a shared resident batch.
#
# ★ WHY single-use scans are share groups here at all:
# the multi_table_plan singleton branch admits EVERY single-use scan as a
# share group (a SOURCE_IN_MEMORY read with a cross-CALL session key)
# for the q11/q15/q22 pattern that re-issues the same scan chain across
# calls on one session. For a LARGE single-use FACT scan (q9/q5
# lineitem = 6M) with a JOIN consumer this is PURE OVERHEAD on the single-run
# path (the "cache" caches a batch nothing reads) AND — the load-bearing cost —
# it turns the fact into a RESIDENT 6M decode where the join could
# otherwise read it as a Parquet source. The eligible shape is a join whose
# two children are BOTH `PLAN_FILTER?->PLAN_SCAN(SOURCE_PARQUET)`; a join
# with one shared (in-memory) child no longer has that shape, so the
# protection keeps BOTH children of the eligible join parquet.
#
# ★ HOW this differs from `_collect_streaming_join_protected_keys` (which
# `plan_scan_shares` does not call). That collection keeps every eligible
# join's unfiltered children parquet whatever their size, which would also
# drop the cross-call key of small scans. This protection is NARROWER (only
# fires when a child's raw row_count exceeds the fact threshold + the join is
# NOT a dyn-filter-hoist match), so small scans are still admitted.
#
# ★ HOIST EXCLUSION (load-bearing zero-regression guard). The dyn-filter hoist
# narrows a large fact to a SMALL resident batch (q17 lineitem->74K,
# q12 orders->30K) — streaming the FULL fact there would REGRESS. So a join
# whose child is a hoist `large_key` is EXCLUDED from protection. q5's hoist is
# on `nation` (25 rows), NOT lineitem, so q5's lineitem join is still protected
# (its hoist never narrows lineitem — over-cap). q19's join carries a residual
# and is excluded by the no-residual gate.
#
# Threshold is `OptimizerConfig.fact_stream_protect_threshold()` (default
# 2,000,000). Protection is unconditional.
# =============================================================================


def _scan_consumer_is_aggregate_only(plan: LogicalPlan, target_key: String) -> Bool:
    """Does every PLAN_SCAN matching `target_key` feed into
    an Aggregate consumer (above Filter/Project) without first passing
    through a JOIN, SORT, LIMIT, DISTINCT, TOPN, or PARTITION_BY node?

    Walks the plan tree top-down. The recursion carries a flag
    `seen_agg` that becomes True when we descend through a
    PLAN_AGGREGATE; if we then reach a matching PLAN_SCAN with the flag
    still True, the scan qualifies. Any descent through a
    JOIN/SORT/LIMIT/DISTINCT/TOPN/PARTITION_BY resets the flag to
    False (those are NOT agg-only consumers; the scan's downstream
    sees raw rows). If ANY matching scan fails this check, returns
    False (be conservative — only skip dedup when ALL matches are
    agg-only).

    Returns True if every match has an agg ancestor with only
    Filter/Project in between. Returns True trivially if there are no
    matches (caller guards on this via outer loop).
    """
    var any_match = False
    var all_agg_capped = True
    _walk_scan_consumers(plan, target_key, False, any_match, all_agg_capped)
    if not any_match:
        return False
    return all_agg_capped


def _walk_scan_consumers(
    plan: LogicalPlan,
    target_key: String,
    seen_agg: Bool,
    mut any_match: Bool,
    mut all_agg_capped: Bool,
):
    """Tail of `_scan_consumer_is_aggregate_only`. Recursive walker."""
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].source_type == SOURCE_PARQUET:
            var f_opt: Optional[Expr] = None
            if plan._scan.value()[].filter:
                f_opt = plan._scan.value()[].filter.value().copy()
            var k = _scan_key(plan._scan.value()[].source_path, f_opt^)
            if k == target_key:
                any_match = True
                if not seen_agg:
                    all_agg_capped = False
        return
    elif plan.tag == PLAN_AGGREGATE:
        # Descending under an Aggregate caps the consumer chain for any
        # scan beneath: those scans feed an agg consumer.
        _walk_scan_consumers(
            plan._aggregate.value()[].child[],
            target_key, True, any_match, all_agg_capped,
        )
    elif plan.tag == PLAN_FILTER:
        # Filter is transparent (preserves seen_agg).
        _walk_scan_consumers(
            plan._filter.value()[].child[],
            target_key, seen_agg, any_match, all_agg_capped,
        )
    elif plan.tag == PLAN_PROJECT:
        # Project is transparent (preserves seen_agg).
        _walk_scan_consumers(
            plan._project.value()[].child[],
            target_key, seen_agg, any_match, all_agg_capped,
        )
    elif plan.tag == PLAN_JOIN:
        # Join breaks the agg-only chain (consumer sees raw scan rows).
        _walk_scan_consumers(
            plan._join.value()[].left[],
            target_key, False, any_match, all_agg_capped,
        )
        _walk_scan_consumers(
            plan._join.value()[].right[],
            target_key, False, any_match, all_agg_capped,
        )
    elif plan.tag == PLAN_SORT:
        _walk_scan_consumers(
            plan._sort.value()[].child[],
            target_key, False, any_match, all_agg_capped,
        )
    elif plan.tag == PLAN_LIMIT:
        _walk_scan_consumers(
            plan._limit.value()[].child[],
            target_key, False, any_match, all_agg_capped,
        )
    elif plan.tag == PLAN_DISTINCT:
        _walk_scan_consumers(
            plan._distinct.value()[].child[],
            target_key, False, any_match, all_agg_capped,
        )
    elif plan.tag == PLAN_TOPN:
        _walk_scan_consumers(
            plan._topn.value()[].child[],
            target_key, False, any_match, all_agg_capped,
        )
    elif plan.tag == PLAN_PARTITION_BY:
        _walk_scan_consumers(
            plan._partition_by.value()[].child[],
            target_key, False, any_match, all_agg_capped,
        )


def _scan_matching_key_is_filtered(plan: LogicalPlan, target_key: String) -> Bool:
    """True iff the (singleton) parquet scan matching `target_key` carries a
    PUSHED scan filter OR sits under a PLAN_FILTER node.

    FACT-STREAM rule (b) uses this to fire ONLY on UNFILTERED large facts. For a
    FILTERED fact the raw parquet-footer row_count OVER-STATES the data actually
    flowing into the join (q12/q14 lineitem: raw 6M but the `l_shipmode`/
    `l_shipdate` pushdown narrows it to a small post-filter set) — treating
    that as "large" would keep a small post-filter read out of the share
    groups. An UNFILTERED fact's raw row_count IS its
    data volume (q5 lineitem 6M), so rule (b) is sound there. rule (a)
    (both-parquet protection) also protects a FILTERED fact (q7), so this
    restriction is rule-(b)-only."""
    var found = False
    var filtered = False
    _walk_scan_filter_state(plan, target_key, False, found, filtered)
    return filtered


def _walk_scan_filter_state(
    plan: LogicalPlan,
    target_key: String,
    saw_filter: Bool,
    mut found: Bool,
    mut filtered: Bool,
):
    """Tail of `_scan_matching_key_is_filtered`. Threads a `saw_filter` flag down
    through PLAN_FILTER ancestors; at the matching scan, records whether it is
    filtered (pushed filter OR a filter ancestor)."""
    if found:
        return
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].source_type == SOURCE_PARQUET:
            var f_opt: Optional[Expr] = None
            if plan._scan.value()[].filter:
                f_opt = plan._scan.value()[].filter.value().copy()
            var k = _scan_key(plan._scan.value()[].source_path, f_opt^)
            if k == target_key:
                found = True
                filtered = saw_filter or Bool(plan._scan.value()[].filter)
        return
    elif plan.tag == PLAN_FILTER:
        _walk_scan_filter_state(
            plan._filter.value()[].child[], target_key, True, found, filtered
        )
    elif plan.tag == PLAN_PROJECT:
        _walk_scan_filter_state(
            plan._project.value()[].child[], target_key, saw_filter, found, filtered
        )
    elif plan.tag == PLAN_AGGREGATE:
        _walk_scan_filter_state(
            plan._aggregate.value()[].child[], target_key, saw_filter, found, filtered
        )
    elif plan.tag == PLAN_JOIN:
        _walk_scan_filter_state(
            plan._join.value()[].left[], target_key, saw_filter, found, filtered
        )
        _walk_scan_filter_state(
            plan._join.value()[].right[], target_key, saw_filter, found, filtered
        )
    elif plan.tag == PLAN_SORT:
        _walk_scan_filter_state(
            plan._sort.value()[].child[], target_key, saw_filter, found, filtered
        )
    elif plan.tag == PLAN_LIMIT:
        _walk_scan_filter_state(
            plan._limit.value()[].child[], target_key, saw_filter, found, filtered
        )
    elif plan.tag == PLAN_DISTINCT:
        _walk_scan_filter_state(
            plan._distinct.value()[].child[], target_key, saw_filter, found, filtered
        )
    elif plan.tag == PLAN_TOPN:
        _walk_scan_filter_state(
            plan._topn.value()[].child[], target_key, saw_filter, found, filtered
        )
    elif plan.tag == PLAN_PARTITION_BY:
        _walk_scan_filter_state(
            plan._partition_by.value()[].child[], target_key, saw_filter, found, filtered
        )


def _count_plan_joins(plan: LogicalPlan) -> Int:
    """Walk the plan tree counting PLAN_JOIN nodes (≈ count of
    OP_JOIN_PROBE in the physical plan).

    `plan_scan_shares` does not call it: `multi_table_plan` does not compare
    the join count with the distinct-key count (see the note above
    `multi_table_plan` in `plan_scan_shares`).
    """
    if plan.tag == PLAN_JOIN:
        return 1 + _count_plan_joins(plan._join.value()[].left[]) + \
            _count_plan_joins(plan._join.value()[].right[])
    elif plan.tag == PLAN_FILTER:
        return _count_plan_joins(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return _count_plan_joins(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        return _count_plan_joins(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_SORT:
        return _count_plan_joins(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        return _count_plan_joins(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return _count_plan_joins(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return _count_plan_joins(plan._topn.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY:
        return _count_plan_joins(plan._partition_by.value()[].child[])
    return 0


# =============================================================================
# STREAMING-JOIN PROTECTED KEYS (`plan_scan_shares` calls neither function below)
# =============================================================================
# The collection gathers the scan keys of every streaming-join-eligible
# JOIN's direct unfiltered-parquet children. `plan_scan_shares` does not
# exclude them from singleton admission; FACT-STREAM protection (above) is
# the narrower rule it applies instead.
#
# Narrow by construction: only UNFILTERED (`_unwrap_to_scan == 1`) parquet
# children of an INNER/SEMI/LEFT/ANTI single-I64-key no-residual join are
# collected. Filtered scans (q4/q12/q17 dyn-filter-hoist + q11/q15/q22
# multi-table caching territory) are NOT — their join children carry a pushed
# filter (`_unwrap_to_scan == 2`) or are aggregations/multi-key.
# =============================================================================


def _join_child_protected_scan_key(
    child: LogicalPlan,
    key_col: String,
) raises -> Optional[String]:
    """If `child` resolves to an UNFILTERED single-file parquet scan (directly
    or through a pure col-select PLAN_PROJECT) whose `key_col` column is INT64,
    return its `_scan_key` (unfiltered → empty filter fingerprint). Else None.

    The stricter sibling of `_streamable_join_child_key`: it looks through a
    PLAN_PROJECT but not a PLAN_FILTER, and refuses a filtered scan."""
    var unwrapped = _unwrap_to_scan(child)
    # value 1 == unfiltered SOURCE_PARQUET scan (looking through a PLAN_PROJECT);
    # a filtered parquet scan (value 2) or non-parquet (None) is never protected.
    # The value-1 guarantee makes a re-check of source_type redundant.
    if not unwrapped or unwrapped.value() != 1:
        return None
    var meta = _extract_scan_metadata(child)
    if not meta.path:
        return None  # cov: unreachable both arms of _extract_scan_metadata set path
    if not _scan_field_is_int64(meta.schema, key_col):
        return None
    # Unfiltered → empty filter fingerprint (matches `_collect_scan_keys`'s
    # key for a no-filter scan).
    var no_filter: Optional[Expr] = None
    return Optional[String](_scan_key(meta.path.value(), no_filter^))


def _collect_streaming_join_protected_keys(
    plan: LogicalPlan,
    mut out: List[String],
) raises:
    """Walk `plan`; for every PLAN_JOIN whose shape is streaming-hash-join-
    eligible (INNER/SEMI/LEFT/ANTI, single key, no residual, BOTH children an
    unfiltered single-file INT64-key parquet scan), append the `_scan_key` of
    each child to `out`. `plan_scan_shares` does not call it (see the section header).

    The join types are {INNER, SEMI, LEFT, ANTI}, the same set
    `_collect_fact_stream_protect_keys` admits."""
    if plan.tag == PLAN_JOIN:
        ref jd = plan._join.value()[]
        var jt = jd.join_type
        var eligible_type = (
            jt == JOIN_INNER or jt == JOIN_SEMI
            or jt == JOIN_LEFT or jt == JOIN_ANTI
        )
        var single_key = (len(jd.left_on) == 1 and len(jd.right_on) == 1)
        if eligible_type and single_key and not jd.has_residual():
            var lk = String(jd.left_on[0])
            var rk = String(jd.right_on[0])
            var left_key = _join_child_protected_scan_key(jd.left[], lk)
            var right_key = _join_child_protected_scan_key(jd.right[], rk)
            # Protect ONLY when BOTH sides are eligible (the protected shape
            # is a join whose two children are both parquet scans).
            if left_key and right_key:
                out.append(left_key.value())
                out.append(right_key.value())
        # Recurse into both branches (nested joins / chained plans).
        _collect_streaming_join_protected_keys(jd.left[], out)
        _collect_streaming_join_protected_keys(jd.right[], out)
    elif plan.tag == PLAN_FILTER:
        _collect_streaming_join_protected_keys(plan._filter.value()[].child[], out)
    elif plan.tag == PLAN_PROJECT:
        _collect_streaming_join_protected_keys(plan._project.value()[].child[], out)
    elif plan.tag == PLAN_AGGREGATE:
        _collect_streaming_join_protected_keys(plan._aggregate.value()[].child[], out)
    elif plan.tag == PLAN_SORT:
        _collect_streaming_join_protected_keys(plan._sort.value()[].child[], out)
    elif plan.tag == PLAN_LIMIT:
        _collect_streaming_join_protected_keys(plan._limit.value()[].child[], out)
    elif plan.tag == PLAN_DISTINCT:
        _collect_streaming_join_protected_keys(plan._distinct.value()[].child[], out)
    elif plan.tag == PLAN_TOPN:
        _collect_streaming_join_protected_keys(plan._topn.value()[].child[], out)
    elif plan.tag == PLAN_PARTITION_BY:
        _collect_streaming_join_protected_keys(plan._partition_by.value()[].child[], out)


def _streamable_join_child_key(
    child: LogicalPlan,
    key_col: String,
) raises -> Optional[String]:
    """If `child` resolves to a single-file parquet scan through a
    `PLAN_PROJECT? -> PLAN_FILTER? -> PLAN_SCAN(parquet)` chain whose `key_col`
    column is INT64, return the SCAN's `_scan_key` (path + pushed-filter
    fingerprint, matching `_collect_scan_keys`). Else None.

    This is the child shape fact-stream protection treats as streamable:
    `PLAN_PROJECT? -> PLAN_FILTER? -> PLAN_SCAN(parquet)`.
    Two forms of predicate land here and BOTH are accepted:
      * a PUSHED filter on the SCAN node (`sd.filter`, e.g. q7's `l_shipdate`
        range) — its fingerprint is part of the scan_key,
      * an un-pushable PLAN_FILTER node ABOVE the scan (e.g. q9's part
        `p_name LIKE '%green%'`, which cannot RG-prune) — the scan itself has
        NO pushed filter, so the scan_key is `path + empty-fp`, matching what
        `_collect_scan_keys` records for that same scan.
    `_unwrap_to_scan` is NOT reused because it does not traverse a PLAN_FILTER
    node — the exact miss that left q9's part (PROJECT->FILTER->SCAN) unseen."""
    if child.tag == PLAN_PROJECT:
        return _streamable_join_child_key(
            child._project.value()[].child[], key_col
        )
    if child.tag == PLAN_FILTER:
        return _streamable_join_child_key(
            child._filter.value()[].child[], key_col
        )
    if child.tag == PLAN_SCAN:
        ref sd = child._scan.value()[]
        if sd.source_type != SOURCE_PARQUET:
            return None
        if not _scan_field_is_int64(sd.schema, key_col):
            return None
        var f_for_key: Optional[Expr] = None
        if sd.filter:
            f_for_key = Optional[Expr](sd.filter.value().copy())
        return Optional[String](_scan_key(String(sd.source_path), f_for_key^))
    return None


def _streamable_child_row_count(child: LogicalPlan) -> Optional[Int]:
    """The raw parquet-footer row_count of the SCAN reached through a
    `PLAN_PROJECT? -> PLAN_FILTER? -> PLAN_SCAN` chain (sibling of
    `_streamable_join_child_key`; `_scan_raw_row_count` does not traverse a
    PLAN_FILTER). None if the chain does not bottom out in a row_count-populated
    parquet scan."""
    if child.tag == PLAN_PROJECT:
        return _streamable_child_row_count(child._project.value()[].child[])
    if child.tag == PLAN_FILTER:
        return _streamable_child_row_count(child._filter.value()[].child[])
    if child.tag == PLAN_SCAN:
        if child._scan.value()[].row_count:
            return Optional[Int](child._scan.value()[].row_count.value())
    return None


def _collect_fact_stream_protect_keys(
    plan: LogicalPlan,
    hoist_matches: Slab[_HoistMatch],
    threshold_rows: Int,
    mut out: List[String],
) raises:
    """Walk `plan`; for every PLAN_JOIN whose shape is streaming-both-parquet
    eligible (INNER/LEFT/SEMI/ANTI, SINGLE
    equi-key, NO residual, BOTH children a `PLAN_FILTER?->PLAN_SCAN(parquet)`
    INT64-key shape) AND at least one child's RAW row_count exceeds
    `threshold_rows`, append BOTH children's `_scan_key`s to `out`.

    These keys are EXCLUDED from singleton admission in `plan_scan_shares`
    so both children stay SOURCE_PARQUET (the eligible shape needs BOTH
    children parquet; a join with one materialized child no longer has it,
    so protecting one alone is inert).

    HOIST EXCLUSION: a join either of whose children is a dyn-filter-hoist
    `large_key` is SKIPPED — the hoist narrows that fact to a small resident
    batch (q17/q12), and streaming the full fact there would regress.
    `_find_hoist_match` keys on the SAME `_scan_key` `_detect_hoist_matches`
    records, so the exclusion is exact.

    Composite (>=2) keys and a residual are outside the eligible shape,
    so neither is protected."""
    if plan.tag == PLAN_JOIN:
        ref jd = plan._join.value()[]
        var jt = jd.join_type
        var eligible_type = (
            jt == JOIN_INNER or jt == JOIN_SEMI
            or jt == JOIN_LEFT or jt == JOIN_ANTI
        )
        var single_key = (len(jd.left_on) == 1 and len(jd.right_on) == 1)
        if eligible_type and single_key and not jd.has_residual():
            var lk = _streamable_join_child_key(jd.left[], String(jd.left_on[0]))
            var rk = _streamable_join_child_key(
                jd.right[], String(jd.right_on[0])
            )
            # Protect ONLY when BOTH sides are streamable parquet scans (the
            # eligible shape needs both children parquet).
            if lk and rk:
                var l_rows = _streamable_child_row_count(jd.left[])
                var r_rows = _streamable_child_row_count(jd.right[])
                var has_large = (
                    (l_rows and l_rows.value() > threshold_rows)
                    or (r_rows and r_rows.value() > threshold_rows)
                )
                var hoist_excluded = (
                    _find_hoist_match(hoist_matches, lk.value()) >= 0
                    or _find_hoist_match(hoist_matches, rk.value()) >= 0
                )
                if has_large and not hoist_excluded:
                    out.append(lk.value())
                    out.append(rk.value())
        # Recurse into both branches (nested joins / chained plans).
        _collect_fact_stream_protect_keys(jd.left[], hoist_matches, threshold_rows, out)
        _collect_fact_stream_protect_keys(jd.right[], hoist_matches, threshold_rows, out)
    elif plan.tag == PLAN_FILTER:
        _collect_fact_stream_protect_keys(plan._filter.value()[].child[], hoist_matches, threshold_rows, out)
    elif plan.tag == PLAN_PROJECT:
        _collect_fact_stream_protect_keys(plan._project.value()[].child[], hoist_matches, threshold_rows, out)
    elif plan.tag == PLAN_AGGREGATE:
        _collect_fact_stream_protect_keys(plan._aggregate.value()[].child[], hoist_matches, threshold_rows, out)
    elif plan.tag == PLAN_SORT:
        _collect_fact_stream_protect_keys(plan._sort.value()[].child[], hoist_matches, threshold_rows, out)
    elif plan.tag == PLAN_LIMIT:
        _collect_fact_stream_protect_keys(plan._limit.value()[].child[], hoist_matches, threshold_rows, out)
    elif plan.tag == PLAN_DISTINCT:
        _collect_fact_stream_protect_keys(plan._distinct.value()[].child[], hoist_matches, threshold_rows, out)
    elif plan.tag == PLAN_TOPN:
        _collect_fact_stream_protect_keys(plan._topn.value()[].child[], hoist_matches, threshold_rows, out)
    elif plan.tag == PLAN_PARTITION_BY:
        _collect_fact_stream_protect_keys(plan._partition_by.value()[].child[], hoist_matches, threshold_rows, out)


# =============================================================================
# Internals -- plan-tree walks
# =============================================================================

def _scan_key(source_path: String, filter_opt: Optional[Expr]) -> String:
    """Build the grouping key from (path, filter fingerprint)."""
    var fp = ""
    if filter_opt:
        fp = _expr_fingerprint(filter_opt.value())
    return source_path + _KEY_SEP + fp


def _collect_scan_keys(plan: LogicalPlan, mut keys: List[String]):
    """Append one key per Parquet Scan node, walking the tree."""
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].source_type == SOURCE_PARQUET:
            var f_opt: Optional[Expr] = None
            if plan._scan.value()[].filter:
                f_opt = plan._scan.value()[].filter.value().copy()
            keys.append(_scan_key(plan._scan.value()[].source_path, f_opt^))
        return
    elif plan.tag == PLAN_FILTER:
        _collect_scan_keys(plan._filter.value()[].child[], keys)
    elif plan.tag == PLAN_PROJECT:
        _collect_scan_keys(plan._project.value()[].child[], keys)
    elif plan.tag == PLAN_AGGREGATE:
        _collect_scan_keys(plan._aggregate.value()[].child[], keys)
    elif plan.tag == PLAN_JOIN:
        _collect_scan_keys(plan._join.value()[].left[], keys)
        _collect_scan_keys(plan._join.value()[].right[], keys)
    elif plan.tag == PLAN_SORT:
        _collect_scan_keys(plan._sort.value()[].child[], keys)
    elif plan.tag == PLAN_LIMIT:
        _collect_scan_keys(plan._limit.value()[].child[], keys)
    elif plan.tag == PLAN_DISTINCT:
        _collect_scan_keys(plan._distinct.value()[].child[], keys)
    elif plan.tag == PLAN_TOPN:
        _collect_scan_keys(plan._topn.value()[].child[], keys)
    elif plan.tag == PLAN_PARTITION_BY:
        _collect_scan_keys(plan._partition_by.value()[].child[], keys)


def _lookup_first_path(plan: LogicalPlan, target: String) -> Optional[String]:
    """Return the source_path of the first Scan whose key matches target."""
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].source_type == SOURCE_PARQUET:
            var f_opt: Optional[Expr] = None
            if plan._scan.value()[].filter:
                f_opt = plan._scan.value()[].filter.value().copy()
            if _scan_key(plan._scan.value()[].source_path, f_opt^) == target:
                return Optional[String](plan._scan.value()[].source_path)
        return None
    elif plan.tag == PLAN_FILTER:
        return _lookup_first_path(plan._filter.value()[].child[], target)
    elif plan.tag == PLAN_PROJECT:
        return _lookup_first_path(plan._project.value()[].child[], target)
    elif plan.tag == PLAN_AGGREGATE:
        return _lookup_first_path(plan._aggregate.value()[].child[], target)
    elif plan.tag == PLAN_JOIN:
        var l = _lookup_first_path(plan._join.value()[].left[], target)
        if l:
            return l^
        return _lookup_first_path(plan._join.value()[].right[], target)
    elif plan.tag == PLAN_SORT:
        return _lookup_first_path(plan._sort.value()[].child[], target)
    elif plan.tag == PLAN_LIMIT:
        return _lookup_first_path(plan._limit.value()[].child[], target)
    elif plan.tag == PLAN_DISTINCT:
        return _lookup_first_path(plan._distinct.value()[].child[], target)
    elif plan.tag == PLAN_TOPN:
        return _lookup_first_path(plan._topn.value()[].child[], target)
    elif plan.tag == PLAN_PARTITION_BY:
        return _lookup_first_path(plan._partition_by.value()[].child[], target)
    return None


def _lookup_row_count(plan: LogicalPlan, target: String) -> Optional[Int]:
    """Return the row_count of the first Scan whose key matches target."""
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].source_type == SOURCE_PARQUET:
            var f_opt: Optional[Expr] = None
            if plan._scan.value()[].filter:
                f_opt = plan._scan.value()[].filter.value().copy()
            if _scan_key(plan._scan.value()[].source_path, f_opt^) == target:
                if plan._scan.value()[].row_count:
                    return Optional[Int](plan._scan.value()[].row_count.value())
        return None
    elif plan.tag == PLAN_FILTER:
        return _lookup_row_count(plan._filter.value()[].child[], target)
    elif plan.tag == PLAN_PROJECT:
        return _lookup_row_count(plan._project.value()[].child[], target)
    elif plan.tag == PLAN_AGGREGATE:
        return _lookup_row_count(plan._aggregate.value()[].child[], target)
    elif plan.tag == PLAN_JOIN:
        var l = _lookup_row_count(plan._join.value()[].left[], target)
        if l:
            return l^
        return _lookup_row_count(plan._join.value()[].right[], target)
    elif plan.tag == PLAN_SORT:
        return _lookup_row_count(plan._sort.value()[].child[], target)
    elif plan.tag == PLAN_LIMIT:
        return _lookup_row_count(plan._limit.value()[].child[], target)
    elif plan.tag == PLAN_DISTINCT:
        return _lookup_row_count(plan._distinct.value()[].child[], target)
    elif plan.tag == PLAN_TOPN:
        return _lookup_row_count(plan._topn.value()[].child[], target)
    elif plan.tag == PLAN_PARTITION_BY:
        return _lookup_row_count(plan._partition_by.value()[].child[], target)
    return None


def _lookup_first_filter(plan: LogicalPlan, target: String) -> Optional[Expr]:
    """Return a copy of the pushed_filter of the first Scan matching target."""
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].source_type == SOURCE_PARQUET:
            var f_opt: Optional[Expr] = None
            if plan._scan.value()[].filter:
                f_opt = plan._scan.value()[].filter.value().copy()
            if _scan_key(plan._scan.value()[].source_path, f_opt^) == target:
                if plan._scan.value()[].filter:
                    return Optional[Expr](plan._scan.value()[].filter.value().copy())
        return None
    elif plan.tag == PLAN_FILTER:
        return _lookup_first_filter(plan._filter.value()[].child[], target)
    elif plan.tag == PLAN_PROJECT:
        return _lookup_first_filter(plan._project.value()[].child[], target)
    elif plan.tag == PLAN_AGGREGATE:
        return _lookup_first_filter(plan._aggregate.value()[].child[], target)
    elif plan.tag == PLAN_JOIN:
        var l = _lookup_first_filter(plan._join.value()[].left[], target)
        if l:
            return l^
        return _lookup_first_filter(plan._join.value()[].right[], target)
    elif plan.tag == PLAN_SORT:
        return _lookup_first_filter(plan._sort.value()[].child[], target)
    elif plan.tag == PLAN_LIMIT:
        return _lookup_first_filter(plan._limit.value()[].child[], target)
    elif plan.tag == PLAN_DISTINCT:
        return _lookup_first_filter(plan._distinct.value()[].child[], target)
    elif plan.tag == PLAN_TOPN:
        return _lookup_first_filter(plan._topn.value()[].child[], target)
    elif plan.tag == PLAN_PARTITION_BY:
        return _lookup_first_filter(plan._partition_by.value()[].child[], target)
    return None


def _collect_union_projection(
    plan: LogicalPlan, target: String
) -> Optional[List[String]]:
    """Union of `scan.projection` over all duplicate scans matching target.

    Each consumer scan keeps its own projection over the shared batch,
    so the shared read only needs columns referenced by AT LEAST ONE
    duplicate. If any duplicate has projection=None (= read all cols), the
    union is None (read all cols).
    """
    var acc = List[String]()
    var has_any = False
    var any_unprojected = False
    _walk_union_proj(plan, target, acc, has_any, any_unprojected)
    if any_unprojected:
        return Optional[List[String]](None)
    if not has_any:
        return Optional[List[String]](None)
    return Optional[List[String]](acc^)


def _walk_union_proj(
    plan: LogicalPlan,
    target: String,
    mut acc: List[String],
    mut has_any: Bool,
    mut any_unprojected: Bool,
):
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].source_type == SOURCE_PARQUET:
            var f_opt: Optional[Expr] = None
            if plan._scan.value()[].filter:
                f_opt = plan._scan.value()[].filter.value().copy()
            if _scan_key(plan._scan.value()[].source_path, f_opt^) == target:
                has_any = True
                if plan._scan.value()[].projection:
                    ref proj = plan._scan.value()[].projection.value()
                    for i in range(len(proj)):
                        var name = proj[i]
                        var present = False
                        for j in range(len(acc)):
                            if acc[j] == name:
                                present = True
                                break
                        if not present:
                            acc.append(name)
                else:
                    any_unprojected = True
        return
    elif plan.tag == PLAN_FILTER:
        _walk_union_proj(plan._filter.value()[].child[], target, acc, has_any, any_unprojected)
    elif plan.tag == PLAN_PROJECT:
        _walk_union_proj(plan._project.value()[].child[], target, acc, has_any, any_unprojected)
    elif plan.tag == PLAN_AGGREGATE:
        _walk_union_proj(plan._aggregate.value()[].child[], target, acc, has_any, any_unprojected)
    elif plan.tag == PLAN_JOIN:
        _walk_union_proj(plan._join.value()[].left[], target, acc, has_any, any_unprojected)
        _walk_union_proj(plan._join.value()[].right[], target, acc, has_any, any_unprojected)
    elif plan.tag == PLAN_SORT:
        _walk_union_proj(plan._sort.value()[].child[], target, acc, has_any, any_unprojected)
    elif plan.tag == PLAN_LIMIT:
        _walk_union_proj(plan._limit.value()[].child[], target, acc, has_any, any_unprojected)
    elif plan.tag == PLAN_DISTINCT:
        _walk_union_proj(plan._distinct.value()[].child[], target, acc, has_any, any_unprojected)
    elif plan.tag == PLAN_TOPN:
        _walk_union_proj(plan._topn.value()[].child[], target, acc, has_any, any_unprojected)
    elif plan.tag == PLAN_PARTITION_BY:
        _walk_union_proj(plan._partition_by.value()[].child[], target, acc, has_any, any_unprojected)



# =============================================================================
# THE DESCRIPTOR -- what `plan_scan_shares` emits.
# =============================================================================
#
# Every field is plain data: strings, ints, `Expr` (the inert plan-level
# expression IR) and column-name lists. Nothing here is a handle, a pointer
# into a registry, or a decoded batch, so building it reads nothing.
# =============================================================================


@fieldwise_init
struct ScanShareHoist(Movable):
    """The DYNAMIC-FILTER SLOT for one share group -- plan-time structure,
    runtime value (DuckDB's dynamic-filter-pushdown pattern).

    The optimizer decides THAT the large side's read may be narrowed by the
    keys of a small, selective relation, and says exactly which relation and
    which column. It does NOT read either one; the slot's values are the
    small side's key column, known only once that side is read.

    Fields:
        small_path: file path of the small (build) relation.
        small_join_col: the small side's join key column -- the values that
            become the dynamic filter.
        large_join_col: the large side's join key column -- where the filter
            is applied.
        small_proj: the small side's read projection, ALREADY AUGMENTED with
            the join key and every filter-referenced column.

            `plan_scan_shares` computes it with `_hoist_small_augmented_proj`,
            the same function `_hoist_small_session_key` uses for
            `small_sess_key`, so the projection and the key describe the same
            read.
        small_filter: the small side's pushed filter, if any.
        small_sess_key: the small side's session-cache key.
    """
    var small_path: String
    var small_join_col: String
    var large_join_col: String
    var small_proj: Optional[List[String]]
    var small_filter: Optional[Expr]
    var small_sess_key: String


@fieldwise_init
struct ScanShareGroup(Movable):
    """ONE "these scan sites are the same relation" marker.

    Fields:
        key: the `(path, filter fingerprint)` dedup key. Every `PLAN_SCAN`
            in the plan whose `_scan_key` equals this reads the SAME relation
            and must be served by ONE read.
        path: the source file path.
        union_proj: the union of every consumer's projection, extended with
            every column the absorbed filter references. `None` = all columns.
        filter: the pushed filter to ABSORB into the one read, so the shared
            batch arrives already filtered.
        sess_key: the cross-call session-cache key for the un-narrowed read.
        dyn_narrow_key: the cache key for the DYN-NARROWED read; empty when
            `hoist` is None.
        hoist: the dynamic-filter slot, if the optimizer found one.
    """
    var key: String
    var path: String
    var union_proj: Optional[List[String]]
    var filter: Optional[Expr]
    var sess_key: String
    var dyn_narrow_key: String
    var hoist: Optional[ScanShareHoist]


@fieldwise_init
struct ScanSharePlan(Movable):
    """The whole decision, as data.

    An empty `groups` means "nothing to share": no scan is grouped (a
    single-scan query, for example).
    """
    var groups: Slab[ScanShareGroup]

    def len(self) -> Int:
        """Number of share groups the optimizer decided on."""
        return self.groups.len()


# =============================================================================
# THE PURE PASS
# =============================================================================


def plan_scan_shares(
    plan: LogicalPlan, config: OptimizerConfig, session_memo: Bool = True
) raises -> ScanSharePlan:
    """Decide which scans share one read.

    ⭐ `session_memo`.
    FALSE removes the CROSS-CALL bet and NOTHING ELSE: the `count >= 2` arm
    below is untouched by it, because two identical scans in one plan are
    common-subexpression elimination -- which DuckDB performs too
    (`__common_subplan_1`) -- not a bet on a later call. The default is TRUE,
    so a call that omits it keeps the cross-call bet.

    **Reads no file, opens no handle, touches no registry, takes no
    dispatcher.**

    The decision runs in a fixed order -- Step 1 (collect scan keys),
    Step 1.6 (fact-stream protection), Step 2 (candidate selection) and the
    descriptor part of Step 3 (path / row-count threshold / union projection /
    filter absorption / cache keys / dyn-filter slot). It does not
    materialize, look up a session cache or bind a registry: it returns the
    descriptor.

    ⚠ THE ROW-COUNT GATES READ `ScanData.row_count`. That is not a purity
    violation: the count is a field on the scan node (`LogicalPlan.scan`'s
    `row_count`, from source metadata such as the Parquet footer). This pass
    reads a field that is already on the node; it does not open the footer
    itself.

    Args:
        plan: The optimized logical plan to decide over.
        config: The optimizer configuration; reads `disable_scan_dedup`,
            `disable_scan_dedup_for_agg`, `fact_stream_protect_rows` and
            `agg_inmem_max_rows`.
        session_memo: When False, do not admit a SINGLETON scan whose only
            justification is the `multi_table_plan` cross-call bet. A
            singleton with a dynamic-filter HOIST match is still admitted --
            that narrowing is a within-query win (DuckDB's dynamic filter
            pushdown), not amortisation across calls.

    Returns:
        A `ScanSharePlan`. Empty when dedup is disabled, when the plan has no
        scans, or when no group qualifies.
    """
    var groups = Slab[ScanShareGroup]()

    # --- Full-pass-through escape hatch. ---
    # When config.disable_scan_dedup is set, decide nothing: every scan
    # stays a SOURCE_PARQUET source.
    if config.disable_scan_dedup:
        return ScanSharePlan(groups^)

    var hoist_matches = Slab[_HoistMatch]()
    # The hoist is unconditional.
    var hoist_on = True
    if hoist_on:
        _detect_hoist_matches(plan, hoist_matches)

    # --- Step 1: collect one key per Scan node. ---
    var keys = List[String]()
    _collect_scan_keys(plan, keys)

    if len(keys) == 0:
        return ScanSharePlan(groups^)

    # --- No Step 1.5: `_collect_streaming_join_protected_keys` is not
    # called; see the section header above `_join_child_protected_scan_key`.

    # --- Step 1.6 (FACT-STREAM protection). ---
    # Collect the keys of BOTH children of every streaming-both-parquet-eligible
    # JOIN that has a LARGE (raw row_count > threshold) child and is NOT a
    # dyn-filter-hoist match. These are excluded from singleton admission
    # below so the scans stay SOURCE_PARQUET and the join reads the fact as a
    # Parquet source instead of a shared resident decode. See the FACT-STREAM
    # protection header block above `_scan_consumer_is_aggregate_only` for the
    # rationale.
    # NARROW by construction: fires only on large-fact eligible joins, so
    # cross-call caching of small scans is untouched.
    var fact_protect_keys = List[String]()
    _collect_fact_stream_protect_keys(
        plan, hoist_matches, config.fact_stream_protect_threshold(), fact_protect_keys
    )

    # --- Step 2: identify candidate keys for share groups. ---
    # Candidate keys are EITHER:
    #   (a) groups with ≥2 occurrences in this plan (within-call dedup),
    #       OR
    #   (b) singleton (count==1) scans when the plan has ≥2 distinct
    #       scan keys (multi-table query — q11-shape; signals likely
    #       cross-call reuse on the next call on the same session),
    #       subject to the gates below.
    #
    # Why the multi-table gate on singletons:
    #   Single-table single-call queries (TPC-H q1) have NO cross-call
    #   reuse pattern; a shared read of them adds a deep
    #   copy of the shared batch without any future
    #   benefit. Multi-table queries are the typical q11/q15/q22 pattern
    #   that DOES re-issue the same scan chain across calls on one
    #   session.
    var n_distinct_keys = 0
    var seen_keys = List[String]()
    for i in range(len(keys)):
        var k = keys[i]
        var already = False
        for j in range(len(seen_keys)):
            if seen_keys[j] == k:
                already = True
                break
        if not already:
            seen_keys.append(k)
            n_distinct_keys += 1

    # No pure-join-chain refinement: `multi_table_plan` is
    # `n_distinct_keys >= 2` alone. It does not also compare
    # `n_distinct_keys` with the join count (`_count_plan_joins`, which this
    # pass does not call), so a pure join chain such as q12's
    # lineitem(filtered) JOIN orders (2 keys, 1 join) is still multi-table.
    var multi_table_plan = n_distinct_keys >= 2

    var dedup_keys = List[String]()
    for i in range(len(keys)):
        var k = keys[i]
        var already = False
        for j in range(len(dedup_keys)):
            if dedup_keys[j] == k:
                already = True
                break
        if already:
            continue
        # Count within-call occurrences.
        var count = 0
        for j in range(len(keys)):
            if keys[j] == k:
                count += 1
        # Always include ≥2-dup groups (within-call dedup).
        if count >= 2:
            dedup_keys.append(k)
            continue
        # Singleton scan: include only if the plan is multi-table.
        # Single-table single-call queries (TPC-H q1) are not
        # admitted; the per-iter deep-copy cost would regress them
        # with no future benefit.
        #
        # Note: there is no session-cache-hit gate here: the cache key
        # requires the union projection, which Step 3 computes, and
        # this pass performs no cache lookup.
        if multi_table_plan:
            # ⭐ CROSS-CALL MEMO OFF. A singleton scan reaches this
            # arm on ONE justification only -- the Step 2 comment above says
            # it outright: "Multi-table queries are the typical q11/q15/q22
            # pattern that DOES re-issue the same scan chain across calls on
            # one session." That is a bet on a LATER
            # call. Within THIS call the admission is pure COST: it turns a
            # SOURCE_PARQUET leaf into a shared resident read, which is the
            # cost the fact-stream protection below avoids for large facts.
            #
            # So with the memo off the bet is not worth placing, and this pass
            # declines it HERE -- at the admission.
            #
            # ⛔ THE HOIST IS NOT PART OF THE BET. A singleton carrying a
            # `_HoistMatch` is admitted so its decode can be NARROWED by the
            # small side's key column (q17-shape) -- a within-query dynamic
            # filter, which DuckDB also performs. Declining it would drop that
            # narrowing, which does not depend on a later call.
            if not session_memo and _find_hoist_match(hoist_matches, k) < 0:
                continue
            # (`_collect_streaming_join_protected_keys` adds no skip here; see
            # the section header above `_join_child_protected_scan_key`.)
            # Consumer-aware tightening.
            # When config.disable_scan_dedup_for_agg is set, skip singleton
            # scans whose ONLY consumer is an Aggregate (above
            # Filter/Project). This preserves SOURCE_PARQUET shape so
            # a streaming aggregate can read them
            # (Q18-shape lineitem subtree). Behaviour is unchanged at
            # the default (off).
            if config.disable_scan_dedup_for_agg and \
                    _scan_consumer_is_aggregate_only(plan, k):
                # Skip: leave this scan as SOURCE_PARQUET so a
                # streaming aggregate can read it.
                continue
            # q18 agg ceiling. A singleton scan whose SOLE
            # consumer is an Aggregate and whose raw row_count EXCEEDS
            # `OptimizerConfig.agg_inmem_ceiling_rows()` stays SOURCE_PARQUET
            # and is not shared as SOURCE_IN_MEMORY. The ceiling mirrors the
            # in-memory aggregate's row limit (q18's aggregate input is 6M
            # lineitem rows, above the 4M default). With row_count known
            # (6M, below the 10M DEDUP_ROW_THRESHOLD) Step 3 alone would admit
            # it, so this gate is what keeps it a Parquet source for EXACTLY
            # the >ceiling agg-input case. It fires only above the ceiling.
            # See `OptimizerConfig.agg_inmem_ceiling_rows`.
            if _scan_consumer_is_aggregate_only(plan, k):
                var rc_agg = _lookup_row_count(plan, k)
                if rc_agg and rc_agg.value() > config.agg_inmem_ceiling_rows():
                    continue
            # FACT-STREAM protection. Keep a
            # single-use LARGE fact scan SOURCE_PARQUET so its JOIN consumer reads
            # it as a Parquet source instead of a shared resident read.
            # Two rules, both
            # gated on `raw row_count > threshold`, NOT a dyn-filter-hoist match
            # (`_find_hoist_match` — the hoist narrows a fact to a small resident
            # batch, which streaming the full fact would regress: q17/q12), and
            # always on:
            #
            #   (a) BOTH-PARQUET STREAMING (`fact_protect_keys`, Step 1.6). The
            #       fact AND its streamable sibling in a single-INT64-key,
            #       no-residual INNER/LEFT/SEMI/ANTI join both stay parquet
            #       — q9 `lineitem⋈part`, q7. The sibling is protected too
            #       because the eligible shape needs BOTH children parquet; one
            #       in-memory child takes the join out of that shape.
            #
            #   (b) BREAKER-CHILD. A large UNFILTERED fact whose join partner
            #       is a BREAKER (sub-join / agg) is outside rule (a)'s shape;
            #       it stays parquet too, so the join reads the fact itself
            #       rather than a shared resident copy (q5 `subjoin⋈lineitem`).
            #       Restricted to `not _scan_consumer_is_aggregate_
            #       only` so the agg-only path stays owned by the q18 gate above.
            #
            # ZERO-REGRESSION: at the 2M default only fact-scale scans qualify;
            # small-scan cross-call caching and the
            # ≥2-dup within-plan dedup are untouched. See the FACT-STREAM protection header block.
            var _fact_protected = False
            for _fp in range(len(fact_protect_keys)):
                if fact_protect_keys[_fp] == k:
                    _fact_protected = True
                    break
            if _fact_protected:
                continue
            # Rule (b): UNFILTERED large fact + join-consumer (not agg-only)
            # + not hoist. The UNFILTERED gate is load-bearing: a FILTERED
            # fact's raw row_count over-states its post-filter volume (q12/q14
            # lineitem narrows to a small post-filter set), so it is not a
            # large fact. rule (a) still protects a filtered fact.
            var _rc_fact = _lookup_row_count(plan, k)
            if (
                _rc_fact
                and _rc_fact.value() > config.fact_stream_protect_threshold()
                and not _scan_matching_key_is_filtered(plan, k)
                and _find_hoist_match(hoist_matches, k) < 0
                and not _scan_consumer_is_aggregate_only(plan, k)
            ):
                continue
            dedup_keys.append(k)
            continue
        # Else: skip. Single-table single-call shape — leave as
        # SOURCE_PARQUET.

    if len(dedup_keys) == 0:
        return ScanSharePlan(groups^)

    # --- Step 3: per group, verify the threshold and build the
    # descriptor. This pass materializes nothing.
    for g in range(len(dedup_keys)):
        var k = dedup_keys[g]

        # Re-traverse to find the first scan with this key: once for its
        # path, once for its row_count (both are on the same node).
        var path_opt = _lookup_first_path(plan, k)
        if not path_opt:
            continue  # cov: unreachable _collect_scan_keys walked these nodes to make k
        var rc_opt = _lookup_row_count(plan, k)
        if not rc_opt:
            # Unknown row count -- conservative: skip.
            continue
        if rc_opt.value() > DEDUP_ROW_THRESHOLD:
            continue

        # The group's read uses the union-of-consumer
        # projections AND absorbs the pushed filter, so the one-time read
        # produces a batch that's already filtered and column-narrowed.
        # Each consumer scan keeps its own projection, which narrows the
        # shared batch per consumer.
        var union_proj = _collect_union_projection(plan, k)
        var filter_opt_mat: Optional[Expr] = None
        var first_filter = _lookup_first_filter(plan, k)
        if first_filter:
            filter_opt_mat = Optional[Expr](first_filter.value().copy())
            # Ensure filter-referenced cols are in the read projection;
            # otherwise the source won't decode them and evaluating the
            # predicate will fail. If union_proj is None ("all cols"), no-op.
            if union_proj:
                var cols = Set[String]()
                _collect_expr_columns(filter_opt_mat.value(), cols)
                var extended = union_proj.value().copy()
                for c in cols:
                    var present = False
                    for i in range(len(extended)):
                        if extended[i] == c:
                            present = True
                            break
                    if not present:
                        extended.append(c)
                union_proj = Optional[List[String]](extended^)

        # --- Session-cache key. ---
        # Build the SESSION cache key from path+filter+projection (the
        # value-bearing tuple — two scans of the same path with the same
        # filter but different projections produce different batches and
        # must not collide).
        var sess_filter_clone: Optional[Expr] = None
        if filter_opt_mat:
            sess_filter_clone = Optional[Expr](filter_opt_mat.value().copy())
        var sess_proj_clone: Optional[List[String]] = None
        if union_proj:
            sess_proj_clone = Optional[List[String]](union_proj.value().copy())
        var sess_key = _session_cache_key(
            path_opt.value(), sess_filter_clone^, sess_proj_clone^
        )
        # If `k` matches a hoist entry, the
        # large-side read may be DYN-NARROWED by a filter built from
        # the small relation. The narrowed result is content-equivalent across
        # calls iff (large path/filter/proj) AND the small relation's
        # session-cache key are both unchanged, so the key is composed from
        # both -- and is known BEFORE either the small read or the large
        # decode.
        var dyn_narrow_key = String("")
        var hoist_desc: Optional[ScanShareHoist] = None
        if hoist_on:
            var hm_idx = _find_hoist_match(hoist_matches, k)
            if hm_idx >= 0:
                ref hm = hoist_matches[hm_idx]
                var small_sess_key = _hoist_small_session_key(hm)
                dyn_narrow_key = _dyn_narrow_cache_key(
                    sess_key, small_sess_key
                )
                var sm_filter_clone: Optional[Expr] = None
                if hm.small_filter:
                    sm_filter_clone = Optional[Expr](
                        hm.small_filter.value().copy()
                    )
                hoist_desc = Optional[ScanShareHoist](
                    ScanShareHoist(
                        String(hm.small_path),
                        String(hm.small_join_col),
                        String(hm.large_join_col),
                        _hoist_small_augmented_proj(hm),
                        sm_filter_clone^,
                        small_sess_key,
                    )
                )

        groups.append(
            ScanShareGroup(
                String(k),
                String(path_opt.value()),
                union_proj^,
                filter_opt_mat^,
                sess_key,
                dyn_narrow_key,
                hoist_desc^,
            )
        )

    return ScanSharePlan(groups^)

