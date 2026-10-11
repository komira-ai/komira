# =============================================================================
# parquet_source — the Parquet morsel source (`MorselSourceImpl`)
# =============================================================================
#
# `ParquetSource` serves a pipeline's workers morsels of the row groups of one
# or several Parquet files (a `FileDiscovery`: a path, a glob, a known file
# list, a Hive tree). Workers claim row groups from one atomic cursor, a
# stride at a time (`adaptive_stride`: one when there are few row groups),
# each keeping its claimed range in its own slots; every worker has its own
# reader of every file (`ParquetReaderFactory`: worker 0's from the session
# footer cache, the others sharing its mapping and footer).
#
# Per claimed row group, in order:
#   * a row window, a top-N boundary that excludes the row group's key range,
#     the statistics prune of the pushed predicate (done once for every row
#     group when the source is built, else per claim) and the bloom prune
#     skip it;
#   * the read-ahead hint for the next row group of the file;
#   * a decode filter, a dynamic join filter or a count-only consumer take
#     the filtered decodes (`parquet_source_arms`, `parquet_source_late_mat`);
#   * otherwise the plain decode: a single-INT64-key hash aggregate's fused
#     payload, the cursor-grain route (`parquet_source_grain`), or the whole
#     row group, by name in a multi-file scan, with any Hive partition
#     columns appended.
# A batch larger than `morsel_rows` is cut into sub-morsels
# (`parquet_source_emit`); morsel partition ids sort back into file order. A
# plain single-file scan may instead be split into row ranges
# (`parquet_source_subrg`).
#
# The claim order can be restricted (`claim_units`), permuted (`claim_order`,
# a heaviest-first order) or follow a top-N plan's order; a consumer that is
# insensitive to which worker consumes what can share parked sub-morsels with
# idle workers (`share_parked`, `parked_morsel_share`).
#
# Ported to the plan models: the worker count is the caller's (the host
# profile's thread count), every switch is a `ParquetScanOptions` field or a
# process setter, and nothing reads the environment or probes the machine.
# =============================================================================

from std.memory import OwnedPointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_dynamic_filter.selectivity_tracker import (
    BLOOM_SELECTIVITY_THRESHOLD,
    IN_LIST_SELECTIVITY_THRESHOLD,
    RANGE_SELECTIVITY_THRESHOLD,
    SelectivityTracker,
)
from komira_fs.column_set import ColumnSet
from komira_fs.file_discovery import EagerGlobDiscovery, FileDiscovery
from komira_fs.file_system import FileSystem
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_morsel.hash_agg_decoded import HashAggDecodedRG
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl
from komira_morsel.topn_boundary import TopNBoundary
from komira_parquet.parquet_source_constants import _build_constant_column
from komira_parquet.parquet_source_helpers import _build_union_by_name_schema
from komira_parquet.scan_copy_trace import prefetch_mode
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_stats.source_statistics import SourceStatistics
from komira_scan_planning.source_capability_config import SourceCapabilityConfig
from komira_scan_source.source_capabilities import SourceCapabilities

from .parked_morsel_share import ParkedMorselShare, parked_share_admitted
from .parquet_reader import ParquetReader
from .parquet_reader_factory import ParquetReaderFactory
from .parquet_source_claim import decode_claim
from .cursor_grain_feed import incr_cursor_grain_decline, note_whole_rg_decode
from .parquet_source_emit import ClaimOutcome, CursorState, OUTCOME_SKIP, emit_outcome
from .parquet_source_grain import CursorGrainScan
from .parquet_source_options import MAX_WORKERS, ParquetScanOptions, adaptive_stride, rg_partition_id
from .parquet_source_subrg import SubrgSplitScan
from .rg_prune_counter import rg_prune_perclaim_incr, rg_prune_setup_record
from .topn_rg_bounds import TopNRgPrunePlan


def _project_union(
    projection: ColumnSet, union_names: List[String], union_types: List[ArrowType]
) -> Tuple[List[String], List[ArrowType]]:
    """The projection's columns of the union schema, in projection order."""
    if projection.project_all:
        return (union_names.copy(), union_types.copy())
    var names = List[String]()
    var types = List[ArrowType]()
    var idxs = projection.projected_indices(len(union_names))
    for i in range(len(idxs)):
        var ci = idxs[i]
        if ci >= 0 and ci < len(union_names):
            names.append(union_names[ci])
            types.append(union_types[ci])
    return (names^, types^)


struct ParquetSource[
    FS: FileSystem,
    DISC: FileDiscovery,
    cache_o: Origin[mut=True],
    expr_o: Origin[mut=True],
    filter_o: Origin[mut=True],
](MorselSourceImpl):
    """The Parquet morsel source over the files of a `DISC` on `FS`.

    `next_morsel(self, worker_id)` is called concurrently by the workers;
    everything it mutates is a worker's own slot (`get_mut_interior`) or an
    atomic.
    """

    comptime HOOKS_CONSUMED_AT_CONSTRUCTION: Bool = True

    var _fs: Self.FS
    var _discovery: Self.DISC
    var _factory: ParquetReaderFactory[Self.cache_o, Self.FS]
    # `_readers[worker][file]`.
    var _readers: Slab[Slab[ParquetReader[Self.FS]]]
    var _projection: ColumnSet
    # The result schema: the projection over the union by name of the files'
    # schemas (`_union_*`), in projection order.
    var _result_col_names: List[String]
    var _result_col_types: List[ArrowType]
    var _union_names: List[String]
    var _union_types: List[ArrowType]
    var _preserve_dict: Bool
    var _num_rgs: Int
    var _cursor_stride: Int64
    var _cursor_state: Slab[CursorState]
    # Two slots per worker: the next claim index of its range and the end.
    var _range_slab: Slab[Int64]
    var _num_workers: Int
    var _caps: SourceCapabilityConfig
    var _options: ParquetScanOptions
    var _expr_pool: Optional[Pointer[ExprPool, Self.expr_o]]
    var _dynamic_filter: Optional[Pointer[DynamicJoinFilter, Self.filter_o]]
    var _pending_slab: Slab[Slab[Morsel]]
    var _parked_share: ParkedMorselShare
    var _bloom_trackers: Slab[SelectivityTracker]
    var _range_trackers: Slab[SelectivityTracker]
    var _in_list_trackers: Slab[SelectivityTracker]
    var _subrg: SubrgSplitScan
    var _cg: CursorGrainScan
    # The statistics prune ran over every row group at construction.
    var _rg_setup_evaluated: Bool
    # Claims walk `_surviving_units` (pruned, restricted or reordered).
    var _rg_prune_active: Bool
    var _surviving_units: List[Int]
    var _claim_order_active: Bool
    var _claim_order_prefetch: Bool
    var _topn_boundary: Optional[TopNBoundary]
    var _topn_prune: Optional[TopNRgPrunePlan]
    var _topn_prune_active: Bool

    def __init__(
        out self,
        var fs: Self.FS,
        path_spec: String,
        var factory: ParquetReaderFactory[Self.cache_o, Self.FS],
        var projection: ColumnSet,
        expr_pool: Optional[Pointer[ExprPool, Self.expr_o]],
        dynamic_filter: Optional[Pointer[DynamicJoinFilter, Self.filter_o]],
        num_workers: Int,
        preserve_dict: Bool = False,
        var caps: SourceCapabilityConfig = SourceCapabilityConfig.default(),
        var options: ParquetScanOptions = ParquetScanOptions.default(),
        var topn_boundary: Optional[TopNBoundary] = None,
        var topn_prune: Optional[TopNRgPrunePlan] = None,
        var claim_units: Optional[List[Int]] = None,
        var claim_order: Optional[List[Int]] = None,
        share_parked: Bool = False,
        share_parked_ragged: Bool = False,
    ) raises:
        """A source over the files `path_spec` names (`DISC.open`)."""
        var discovery = Self.DISC.open(fs, path_spec)
        self = Self(
            fs^, discovery^, factory^, projection^, expr_pool, dynamic_filter, num_workers,
            preserve_dict=preserve_dict, caps=caps^, options=options^, topn_boundary=topn_boundary^,
            topn_prune=topn_prune^, claim_units=claim_units^, claim_order=claim_order^,
            share_parked=share_parked, share_parked_ragged=share_parked_ragged,
        )

    def __init__(
        out self,
        var fs: Self.FS,
        var discovery: Self.DISC,
        var factory: ParquetReaderFactory[Self.cache_o, Self.FS],
        var projection: ColumnSet,
        expr_pool: Optional[Pointer[ExprPool, Self.expr_o]],
        dynamic_filter: Optional[Pointer[DynamicJoinFilter, Self.filter_o]],
        num_workers: Int,
        preserve_dict: Bool = False,
        var caps: SourceCapabilityConfig = SourceCapabilityConfig.default(),
        var options: ParquetScanOptions = ParquetScanOptions.default(),
        var topn_boundary: Optional[TopNBoundary] = None,
        var topn_prune: Optional[TopNRgPrunePlan] = None,
        var claim_units: Optional[List[Int]] = None,
        var claim_order: Optional[List[Int]] = None,
        share_parked: Bool = False,
        share_parked_ragged: Bool = False,
    ) raises:
        """A source over `discovery`'s files, for `num_workers` workers (the
        host's thread count, 1 to `MAX_WORKERS`).

        Args:
            fs: The file system.
            discovery: The files.
            factory: Builds the readers (from the session footer cache).
            projection: The leaf columns to emit (`ColumnSet.all()`: all).
            expr_pool: The expressions the capabilities' ids name.
            dynamic_filter: A hash join build's filter on
                `caps.dynamic_filter_key_name`.
            num_workers: The workers that will call `next_morsel`.
            preserve_dict: Keep dictionary columns as dictionaries.
            caps: The capabilities (filters, count-only, morsel rows, ...).
            options: The source's switches.
            topn_boundary: A running top-N cut-off, with `topn_prune` its
                per-row-group key bounds (both, or neither, is used).
            claim_units: Claim only these flat row groups.
            claim_order: Claim in this order (a permutation).
            share_parked: The consumer accepts parked sub-morsels from other
                workers; `share_parked_ragged` also in the last round.

        Raises:
            If `num_workers` is out of range, or a file does not open.
        """
        if num_workers < 1 or num_workers > MAX_WORKERS:
            raise Error(
                "parquet source: num_workers must be in [1, " + String(MAX_WORKERS) + "], got "
                + String(num_workers)
            )
        var nw = num_workers
        var n_files = discovery.num_paths()
        # A row window builds full readers only for the files it overlaps.
        var window = caps.row_window_active
        var readers = Slab[Slab[ParquetReader[Self.FS]]].create(nw)
        var total_units = 0
        var row0 = Slab[ParquetReader[Self.FS]].create(max(n_files, 1))
        for i in range(n_files):
            var path = discovery.path_at(i)
            if window:
                var fo = factory.open_footer_only(fs, path)
                var cnt = fo.unit_count_for_file()
                var overlaps = cnt > 0 and total_units + cnt - 1 >= caps.row_window_first_rg
                overlaps = overlaps and total_units <= caps.row_window_last_rg
                total_units += cnt
                if overlaps:
                    row0.append(factory.open(fs, path))
                else:
                    row0.append(fo^)
            else:
                var reader = factory.open(fs, path)
                total_units += reader.unit_count_for_file()
                row0.append(reader^)
        readers.append(row0^)
        for _ in range(1, nw):
            var row = Slab[ParquetReader[Self.FS]].create(max(n_files, 1))
            for j in range(n_files):
                row.append(factory.clone_reader_for_worker(readers[0][j]))
            readers.append(row^)
        self._fs = fs^
        self._discovery = discovery^
        self._factory = factory^
        self._readers = readers^
        self._projection = projection^
        self._union_names = List[String]()
        self._union_types = List[ArrowType]()
        self._result_col_names = List[String]()
        self._result_col_types = List[ArrowType]()
        if n_files > 0:
            var file_schemas = List[Schema]()
            var file_paths = List[String]()
            for f in range(n_files):
                file_schemas.append(self._readers[0][f].build_arrow_schema_for_file())
                file_paths.append(self._discovery.path_at(f))
            var union = _build_union_by_name_schema(file_schemas, file_paths)
            self._union_names = union[0].copy()
            self._union_types = union[1].copy()
        var selected = _project_union(self._projection, self._union_names, self._union_types)
        self._result_col_names = selected[0].copy()
        self._result_col_types = selected[1].copy()
        self._preserve_dict = preserve_dict
        self._caps = caps^
        self._options = options^
        self._expr_pool = expr_pool
        self._dynamic_filter = dynamic_filter
        self._num_rgs = total_units
        self._num_workers = nw
        self._cursor_stride = adaptive_stride(total_units, nw)
        var stride_forced = self._options.forced_cursor_stride > 0
        if stride_forced:
            self._cursor_stride = Int64(self._options.forced_cursor_stride)
        self._cursor_state = Slab[CursorState].create_prefilled(1)
        self._range_slab = Slab[Int64].create(2 * MAX_WORKERS)
        for _ in range(2 * MAX_WORKERS):
            self._range_slab.append(Int64(0))
        self._pending_slab = Slab[Slab[Morsel]].create(MAX_WORKERS)
        self._bloom_trackers = Slab[SelectivityTracker].create(MAX_WORKERS)
        self._range_trackers = Slab[SelectivityTracker].create(MAX_WORKERS)
        self._in_list_trackers = Slab[SelectivityTracker].create(MAX_WORKERS)
        for _ in range(MAX_WORKERS):
            self._pending_slab.append(Slab[Morsel]())
            self._bloom_trackers.append(SelectivityTracker(BLOOM_SELECTIVITY_THRESHOLD))
            self._range_trackers.append(SelectivityTracker(RANGE_SELECTIVITY_THRESHOLD))
            self._in_list_trackers.append(SelectivityTracker(IN_LIST_SELECTIVITY_THRESHOLD))
        self._parked_share = ParkedMorselShare(False)
        self._subrg = SubrgSplitScan()
        self._cg = CursorGrainScan()
        self._rg_setup_evaluated = False
        self._rg_prune_active = False
        self._surviving_units = List[Int]()
        self._claim_order_active = False
        self._claim_order_prefetch = False
        # A top-N plan must cover exactly this source's row groups.
        var topn_ok = topn_boundary.__bool__() and topn_prune.__bool__()
        if topn_ok and topn_prune.value().num_units() != total_units:
            topn_ok = False
        self._topn_prune_active = topn_ok
        self._topn_boundary = topn_boundary^ if topn_ok else None
        self._topn_prune = topn_prune^ if topn_ok else None
        self._maybe_enable_subrg_split()
        self._maybe_enable_cursor_grain()
        self._maybe_enable_rg_prune()
        if claim_units:
            self._restrict_claim_units(claim_units.take())
        # The top-N order is only walked when nothing else rewrote the claim
        # space, and is claimed one row group at a time so the boundary
        # tightens early.
        if self._topn_prune_active and (self._subrg.enabled or self._cg.enabled or self._rg_prune_active):
            self._topn_prune_active = False
        if self._topn_prune_active and not stride_forced:
            self._cursor_stride = 1
        if claim_order:
            self._apply_claim_order(claim_order.take(), stride_forced)
        self._parked_share = ParkedMorselShare(
            parked_share_admitted(
                share_parked,
                self._caps.morsel_rows,
                self._rg_claim_count(),
                self._num_workers,
                self._subrg.enabled or self._cg.enabled,
                self._options.decode_arena,
                self._caps.hash_agg_key_col_idx.__bool__(),
                ragged_tail=share_parked_ragged,
            )
        )

    def _select_result_columns(mut self):
        """The result columns: the projection over the union schema."""
        var selected = _project_union(self._projection, self._union_names, self._union_types)
        self._result_col_names = selected[0].copy()
        self._result_col_types = selected[1].copy()

    # -------------------------------------------------------------------------
    # Setup
    # -------------------------------------------------------------------------

    def _single_plain_file(self) -> Bool:
        """One file, no partition column, a result schema."""
        return (
            self._readers.len() > 0 and self._readers[0].len() == 1 and len(self._result_col_names) > 0
            and self._discovery.num_partition_cols() == 0
        )

    def _maybe_enable_subrg_split(mut self) raises:
        """The row-range split (`parquet_source_subrg`) for a plain scan of
        one file: no pushed predicate, no hash-aggregate payload."""
        if self._options.subrg_mode == 0 or self._caps.pushed_predicate or self._caps.hash_agg_key_col_idx:
            return
        if not self._single_plain_file():
            return
        self._subrg.try_enable[Self.FS](self._readers[0][0], self._result_col_names, self._num_workers, self._options)

    def _maybe_enable_cursor_grain(mut self) raises:
        """The cursor-grain route (`parquet_source_grain`) for one file, no
        row-range split, no dictionary preservation, no hash-aggregate
        payload."""
        if self._subrg.enabled or self._preserve_dict or self._caps.hash_agg_key_col_idx:
            return
        if not self._single_plain_file():
            return
        self._cg.try_enable[Self.FS](
            self._readers[0][0], self._result_col_names, self._num_workers, self._caps.morsel_rows, self._options
        )

    def _maybe_enable_rg_prune(mut self) raises:
        """Evaluate the pushed predicate against every row group's statistics
        once, and claim only the survivors (then no claim re-checks them).
        Not with a top-N plan (its claim order) or the cursor-grain route."""
        if not self._caps.pushed_predicate or not self._expr_pool:
            return
        if self._readers.len() == 0 or self._readers[0].len() == 0:
            return
        if self._topn_prune_active or self._cg.enabled:
            return
        ref expr = self._expr_pool.value()[].resolve(self._caps.pushed_predicate.value())
        var surviving = List[Int]()
        for flat in range(self._num_rgs):
            var loc = self._resolve_unit(flat)
            if not self._readers[0][loc[0]].can_prune_unit(loc[1], expr):
                surviving.append(flat)
        var n_surv = len(surviving)
        self._rg_setup_evaluated = True
        rg_prune_setup_record(self._num_rgs - n_surv)
        if n_surv < self._num_rgs:
            self._surviving_units = surviving^
            self._rg_prune_active = True
            if self._options.forced_cursor_stride == 0:
                self._cursor_stride = adaptive_stride(n_surv, self._num_workers)

    def _apply_claim_order(mut self, var order: List[Int], stride_forced: Bool):
        """Claim in `order` (a permutation of the row groups), one at a time;
        kept to the survivors of an earlier prune or restriction. Ignored
        with a top-N plan, the row-range split, the cursor-grain route, a
        forced stride, or an order that is not a permutation."""
        if self._topn_prune_active or self._subrg.enabled or self._cg.enabled or stride_forced:
            return
        var n = len(order)
        if n != self._num_rgs or n == 0:
            return
        var seen = List[Bool](length=n, fill=False)
        for i in range(n):
            var f = order[i]
            if f < 0 or f >= n or seen[f]:
                return
            seen[f] = True
        var was_compacted = self._rg_prune_active
        var claim = List[Int]()
        if was_compacted:
            var keep = List[Bool](length=n, fill=False)
            for i in range(len(self._surviving_units)):
                keep[self._surviving_units[i]] = True
            for i in range(n):
                if keep[order[i]]:
                    claim.append(order[i])
        else:
            claim = order^
        self._surviving_units = claim^
        self._rg_prune_active = True
        self._claim_order_active = True
        self._claim_order_prefetch = not was_compacted
        self._cursor_stride = 1

    def _restrict_claim_units(mut self, var units: List[Int]):
        """Claim only the flat row groups in `units` (and among the survivors
        of a prune), in file order."""
        var keep = List[Bool](length=self._num_rgs, fill=False)
        for i in range(len(units)):
            if units[i] >= 0 and units[i] < self._num_rgs:
                keep[units[i]] = True
        if self._rg_prune_active:
            var inter = List[Bool](length=self._num_rgs, fill=False)
            for i in range(len(self._surviving_units)):
                var f = self._surviving_units[i]
                if keep[f]:
                    inter[f] = True
            keep = inter^
        var out = List[Int]()
        for f in range(self._num_rgs):
            if keep[f]:
                out.append(f)
        if self._options.forced_cursor_stride == 0:
            self._cursor_stride = adaptive_stride(len(out), self._num_workers)
        self._surviving_units = out^
        self._rg_prune_active = True

    # -------------------------------------------------------------------------
    # Claims and geometry
    # -------------------------------------------------------------------------

    @always_inline
    def claim_order_active(self) -> Bool:
        """A claim order was applied."""
        return self._claim_order_active

    def claim_unit_at(self, claim_idx: Int) -> Int:
        """The flat row group of claim `claim_idx`."""
        return self._rg_flat_index(claim_idx)

    @always_inline
    def _rg_claim_count(self) -> Int:
        if self._rg_prune_active:
            return len(self._surviving_units)
        return self._num_rgs

    @always_inline
    def _rg_flat_index(self, claim_idx: Int) -> Int:
        if self._rg_prune_active:
            if claim_idx >= 0 and claim_idx < len(self._surviving_units):
                return self._surviving_units[claim_idx]
            return claim_idx
        if self._topn_prune_active:
            ref order = self._topn_prune.value().claim_order
            if claim_idx >= 0 and claim_idx < len(order):
                return order[claim_idx]
        return claim_idx

    def num_row_groups(self) -> Int:
        """Row groups over all files."""
        return self._num_rgs

    def num_files(self) -> Int:
        """Files."""
        return self._readers[0].len() if self._readers.len() > 0 else 0

    def num_workers(self) -> Int:
        """The worker count."""
        return self._num_workers

    def cursor_stride(self) -> Int64:
        """Row groups claimed per cursor bump."""
        return self._cursor_stride

    def claimable_units(self) -> Int:
        """Row groups the claims walk."""
        return self._rg_claim_count()

    def rgs_allmatch(self) -> Int:
        """Row groups counted from their statistics so far."""
        return Int(self._cursor_state.get_mut_interior(0).rgs_allmatch.load())

    def rgs_decoded(self) -> Int:
        """Claimed row groups that passed every prune so far."""
        return Int(self._cursor_state.get_mut_interior(0).rgs_decoded.load())

    def _resolve_unit(self, flat_idx: Int) -> Tuple[Int, Int]:
        """(file, row group in file) of a flat row group index."""
        var acc = 0
        if self._readers.len() == 0:
            return (0, 0)
        ref row0 = self._readers[0]
        for i in range(row0.len()):
            var per_file = row0[i].unit_count_for_file()
            if flat_idx < acc + per_file:
                return (i, flat_idx - acc)
            acc += per_file
        return (0, 0)

    def _claim(self, worker_id: Int) -> Int:
        """The next claim index of `worker_id` (from its range, else a new
        stride from the cursor; one at a time near the end), or -1."""
        ref rng_next = self._range_slab.get_mut_interior(2 * worker_id)
        ref rng_end = self._range_slab.get_mut_interior(2 * worker_id + 1)
        if rng_next < rng_end:
            var c = rng_next
            rng_next += 1
            return Int(c)
        ref cs = self._cursor_state.get_mut_interior(0)
        var claim_count = Int64(self._rg_claim_count())
        var stride = self._cursor_stride
        if stride > 1 and claim_count - cs.rg_cursor.load() <= Int64(self._num_workers) * stride:
            stride = 1
        var fa = cs.rg_cursor.fetch_add(stride)
        _ = cs.cursor_fetch_adds.fetch_add(Int64(1))
        var end = min(fa + stride, claim_count)
        if fa >= end:
            return -1
        rng_next = fa + 1
        rng_end = end
        return Int(fa)

    # -------------------------------------------------------------------------
    # Schema, hints, setters
    # -------------------------------------------------------------------------

    def _append_partition_columns(self, mut batch: RecordBatch, file_idx: Int) raises:
        """Append the Hive partition columns of file `file_idx`, one value
        per row (NULL for an absent key)."""
        var n_part = self._discovery.num_partition_cols()
        if n_part == 0:
            return
        var pv = self._discovery.partition_values_at(file_idx)
        var path = self._discovery.path_at(file_idx)
        for p in range(n_part):
            var name = self._discovery.partition_col_name_at(p)
            var t = self._discovery.partition_col_type_at(p)
            var value = String("")
            for k in range(len(pv.keys)):
                if pv.keys[k] == name:
                    value = String(pv.values[k])
                    break
            batch.append_column(Field(name, t, False), _build_constant_column(t, value, batch.num_rows(), name, path))

    def output_schema(self) -> Schema:
        """The emitted schema: each result column's field from the first file
        holding it (else its union type, nullable), then the partition
        columns; empty on an error."""
        try:
            if self._readers.len() == 0 or self._readers[0].len() == 0:
                return Schema()
            if len(self._result_col_names) == 0:
                return self._readers[0][0].build_arrow_schema_for_file()
            var file_schemas = List[Schema]()
            for f in range(self._readers[0].len()):
                file_schemas.append(self._readers[0][f].build_arrow_schema_for_file())
            var sb = SchemaBuilder()
            for r in range(len(self._result_col_names)):
                var added = False
                for f in range(len(file_schemas)):
                    ref fsch = file_schemas[f]
                    for c in range(fsch.num_columns()):
                        if fsch.field_name(c) == self._result_col_names[r]:
                            sb.add_field(fsch.field_at_unchecked(c))
                            added = True
                            break
                    if added:
                        break
                if not added:
                    sb.add_field(Field(self._result_col_names[r], self._result_col_types[r], True))
            for p in range(self._discovery.num_partition_cols()):
                sb.add_field(
                    Field(self._discovery.partition_col_name_at(p), self._discovery.partition_col_type_at(p), False)
                )
            return sb.build()
        except:
            return Schema()

    def partition_hint(self) -> Int:
        return self._num_rgs

    def row_count_hint(self) -> Int:
        var acc = 0
        if self._readers.len() == 0:
            return 0
        ref row0 = self._readers[0]
        for i in range(row0.len()):
            for u in range(row0[i].unit_count_for_file()):
                acc += row0[i].unit_num_rows(u)
        return acc

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities(
            supports_projection=True,
            supports_decode_filter=True,
            supports_dict_preservation=True,
            supports_dynamic_filter=True,
            supports_row_group_pruning=True,
            supports_bypass_columns=True,
            supports_as_source=False,
        )

    def statistics(self) -> SourceStatistics:
        return SourceStatistics()

    def has_decode_filter(self) -> Bool:
        return self._caps.decode_filter_stages.__bool__() and len(self._caps.decode_filter_stages.value()) > 0

    def set_projection(mut self, cols: List[Int]) -> None:
        """Project the union schema's columns `cols` (an empty list changes
        nothing)."""
        if len(cols) == 0:
            return
        self._projection = ColumnSet.columns(cols.copy())
        self._select_result_columns()

    def set_decode_filter(mut self, stages: List[ExprId]) -> None:
        self._caps.decode_filter_stages = Optional(stages.copy())

    def set_pushed_predicate(mut self, expr: ExprId) -> None:
        self._caps.pushed_predicate = Optional(expr)

    def set_bypass_columns(mut self, cols: List[Int]) -> None:
        if len(cols) == 0:
            self._caps.bypass_set = None
            return
        self._caps.bypass_set = Optional(ColumnSet.columns(cols.copy()))

    def set_dict_preservation(mut self, on: Bool) -> None:
        self._preserve_dict = on

    def set_morsel_rows(mut self, rows: Int) -> None:
        self._caps.morsel_rows = rows

    def set_prefetch_enabled(mut self, on: Bool) -> None:
        self._caps.prefetch_enabled = on

    def set_count_only(mut self, on: Bool) -> None:
        self._caps.count_only = on

    # -------------------------------------------------------------------------
    # Morsels
    # -------------------------------------------------------------------------

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        """The next morsel for `worker_id`, or None when the source is done
        for it. With parked sharing on: a shared parked morsel first, then a
        claim (whose parked morsels are published), then a wait for the
        claims in flight."""
        if not self._parked_share.enabled():
            return self._next_morsel_claim(worker_id)
        var shared = self._parked_share.try_take(worker_id)
        if shared:
            return shared^
        self._parked_share.enter()
        var m: Optional[Morsel]
        try:
            m = self._next_morsel_claim(worker_id)
        except e:
            self._parked_share.leave()
            raise e^
        ref parked = self._pending_slab.get_mut_interior(worker_id)
        if len(parked) > 0:
            self._parked_share.publish(parked, worker_id)
        self._parked_share.leave()
        if m:
            return m^
        return self._parked_share.wait_take(worker_id)

    def parked_share_active(self) -> Bool:
        return self._parked_share.enabled()

    def parked_share_published(self) -> Int:
        return self._parked_share.published_count()

    def parked_share_foreign(self) -> Int:
        return self._parked_share.foreign_count()

    def _skip_by_prune(self, reader: ParquetReader[Self.FS], claimed_rg: Int, rg_in_file: Int) raises -> Bool:
        """The top-N boundary excludes the row group's key range, or the
        pushed predicate's statistics (per claim, unless done at setup) or
        bloom filters prove no row matches."""
        if self._topn_prune_active:
            ref tp = self._topn_prune.value()
            if claimed_rg >= 0 and claimed_rg < len(tp.key_min):
                if self._topn_boundary.value().prunes_range(tp.key_min[claimed_rg], tp.key_max[claimed_rg]):
                    return True
        if self._caps.pushed_predicate and self._expr_pool:
            ref expr = self._expr_pool.value()[].resolve(self._caps.pushed_predicate.value())
            if not self._rg_setup_evaluated:
                rg_prune_perclaim_incr()
                if reader.can_prune_unit(rg_in_file, expr):
                    return True
            if reader.can_prune_unit_by_bloom(rg_in_file, expr):
                return True
        return False

    def _prefetch_next(self, reader: ParquetReader[Self.FS], claim_idx: Int, claimed_rg: Int, file_idx: Int) raises:
        """Read-ahead hint for the next row group this source's order will
        claim, when it is in the same file."""
        if not self._caps.prefetch_enabled or (self._rg_prune_active and not self._claim_order_prefetch):
            return
        var next_flat = claimed_rg + 1
        if self._topn_prune_active or self._claim_order_prefetch:
            next_flat = self._rg_flat_index(claim_idx + 1)
        if next_flat < 0 or next_flat >= self._num_rgs:
            return
        var next_loc = self._resolve_unit(next_flat)
        if next_loc[0] == file_idx:
            reader.advise_prefetch_next(
                next_loc[1], self._projection.projected_indices(reader.unit_num_columns(next_loc[1])), prefetch_mode()
            )

    def _next_morsel_claim(self, worker_id: Int) raises -> Optional[Morsel]:
        """`next_morsel` without parked sharing."""
        if worker_id < 0 or worker_id >= self._num_workers:
            raise Error(
                "parquet source: worker " + String(worker_id) + " is not in [0, " + String(self._num_workers) + ")"
            )
        ref cs = self._cursor_state.get_mut_interior(0)
        if self._subrg.enabled:
            return self._subrg.next[Self.FS](self._readers[worker_id][0], worker_id, cs.morsel_counter)
        var morsel_rows = self._caps.morsel_rows
        ref pending = self._pending_slab.get_mut_interior(worker_id)
        if self._cg.enabled:
            var cg_m = self._cg.pull(worker_id, morsel_rows, cs.morsel_counter, pending)
            if cg_m:
                return cg_m^
        if morsel_rows > 0 and len(pending) > 0:
            var parked = pending.pop()
            if parked:
                return parked^
        while True:
            var claim_idx = self._claim(worker_id)
            if claim_idx < 0:
                return None
            var claimed_rg = self._rg_flat_index(claim_idx)
            if self._caps.row_window_active and (
                claimed_rg < self._caps.row_window_first_rg or claimed_rg > self._caps.row_window_last_rg
            ):
                continue
            var loc = self._resolve_unit(claimed_rg)
            var file_idx = loc[0]
            var rg_in_file = loc[1]
            ref reader = self._readers.get_mut_interior(worker_id).get_mut_interior(file_idx)
            if self._skip_by_prune(reader, claimed_rg, rg_in_file):
                continue
            _ = cs.rgs_decoded.fetch_add(Int64(1))
            self._prefetch_next(reader, claim_idx, claimed_rg, file_idx)
            var outcome = decode_claim[Self.FS, Self.expr_o, Self.filter_o](
                reader,
                rg_in_file,
                self._caps,
                self._options,
                self._expr_pool,
                self._dynamic_filter,
                self._projection,
                self._preserve_dict,
                self._result_col_names,
                self._result_col_types,
                self._union_names,
                self._union_types,
                self._range_trackers.get_mut_interior(worker_id),
                self._in_list_trackers.get_mut_interior(worker_id),
                self._bloom_trackers.get_mut_interior(worker_id),
            )
            if outcome.kind == OUTCOME_SKIP:
                continue
            if outcome.allmatch:
                _ = cs.rgs_allmatch.fetch_add(Int64(1))
            if outcome.batch:
                return emit_outcome(outcome^, morsel_rows, claimed_rg, cs.morsel_counter, pending)
            # The plain decode.
            var plain = self._plain_claim(reader, rg_in_file, claimed_rg, file_idx, worker_id)
            if plain:
                return plain^

    def _plain_claim(
        self, reader: ParquetReader[Self.FS], rg_in_file: Int, claimed_rg: Int, file_idx: Int, worker_id: Int
    ) raises -> Optional[Morsel]:
        """The plain decode of a claimed row group: the fused hash-aggregate
        payload (a single INT64 key, no pushed predicate, no morsel split),
        the cursor-grain route's first grain, or the whole row group (by
        name, with the partition columns); None for an empty hash-aggregate
        row group."""
        ref cs = self._cursor_state.get_mut_interior(0)
        ref pending = self._pending_slab.get_mut_interior(worker_id)
        var morsel_rows = self._caps.morsel_rows
        if self._caps.hash_agg_key_col_idx and not self._caps.pushed_predicate and morsel_rows == 0:
            var agg_cols = List[Int]()
            if self._caps.hash_agg_agg_col_indices:
                agg_cols = self._caps.hash_agg_agg_col_indices.value().copy()
            var maybe_dec = reader.decode_for_hash_agg(
                rg_in_file, self._caps.hash_agg_key_col_idx.value(), agg_cols, self._preserve_dict
            )
            if not maybe_dec:
                return None
            var parts = maybe_dec.take()
            var payload = HashAggDecodedRG(
                parts.take_key_array(),
                parts.take_hashes(),
                parts.take_fingerprints(),
                parts.take_partition_ids(),
                parts.take_agg_input_columns(),
                parts.num_rows(),
            )
            var m = Morsel(
                RecordBatch(),
                morsel_id=Int(cs.morsel_counter.fetch_add(Int64(1))),
                partition_id=rg_partition_id(claimed_rg),
                origin_hint=0,
            )
            m.attach_hash_agg_decoded(OwnedPointer[HashAggDecodedRG](payload^))
            return Optional(m^)
        if self._cg.enabled:
            if self._cg.open[Self.FS](reader, rg_in_file, claimed_rg, worker_id):
                var first = self._cg.pull(worker_id, morsel_rows, cs.morsel_counter, pending)
                if first:
                    return first^
            else:
                incr_cursor_grain_decline()
        var batch: RecordBatch
        if len(self._result_col_names) > 0:
            batch = reader.decode_columns_by_name_remap(
                rg_in_file, self._result_col_names, self._result_col_types, self._preserve_dict
            )
        else:
            batch = reader.decode_columns_subset(
                rg_in_file, self._projection.projected_indices(reader.unit_num_columns(rg_in_file)), self._preserve_dict
            )
        self._append_partition_columns(batch, file_idx)
        note_whole_rg_decode(batch.num_rows())
        return Optional(emit_outcome(ClaimOutcome.emit(batch^), morsel_rows, claimed_rg, cs.morsel_counter, pending))


# The source of one file, or of a known list of files, over the default
# discovery (a path, a glob or an explicit list).
comptime ParquetSourceSingle[
    FS: FileSystem,
    cache_o: Origin[mut=True],
    expr_o: Origin[mut=True],
    filter_o: Origin[mut=True],
] = ParquetSource[FS, EagerGlobDiscovery, cache_o, expr_o, filter_o]
