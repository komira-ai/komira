# =============================================================================
# agg_spill -- the spill of a row-format hash aggregate: partial tables written
# to disk over a memory budget, then folded back by key at finalize
# =============================================================================
#
# The accumulator is a `RowHashAggTable` (packed key cells and aggregate-state
# cells, one row per group). Without a spill it holds every distinct group in
# memory. `RowHashAggSpillState` bounds that:
#
#   1. SPILL (`maybe_spill_run`, called after each `upsert_batch`): when the
#      table's `agg_estimated_bytes()` is over the budget, its group rows are
#      written as one THSPILL2 chunk and the table is emptied
#      (`reset_keep_aggs`); accumulation continues into the empty table. Each
#      spilled run is a PARTIAL aggregate over the rows fed since the last
#      spill. A budget of 0 (or less) never spills.
#
#   2. FINALIZE (`finalize_with_spill`, `finalize_with_spill_yield`): the
#      spilled runs are read back and folded into the surviving in-memory
#      table with `RowHashAggTable.combine`, which merges by key (COUNT and
#      SUM add, MIN and MAX keep the extreme). Folding the partial tables over
#      rows R_1 .. R_n gives the table over R_1 ++ .. ++ R_n, so the result has
#      the same groups and the same aggregates as an aggregate that never
#      spilled.
#
#      If the folded table's group rows (plus its string heap) pass the budget
#      while folding, the fold is abandoned and the finalize repartitions
#      instead: the in-memory table as it was before the fold and every
#      spilled run are split by key hash into `AGG_RECURSE_FANOUT` parts, and
#      each part is folded and emitted on its own. A key hashes to the same part
#      in every source, so each part's fold is complete. A part still over the
#      budget is split again on the next `AGG_BITS_PER_LEVEL` hash bits, down
#      to `AGG_RECURSE_MAX_DEPTH` levels; a part at the depth limit (or of one
#      group) is emitted whatever its size.
#
# The storage is ONE `LocalDiskSpillStorage` per aggregate, created on the
# first spill (so an aggregate that never spills never touches the
# filesystem). Its root is a new sub-directory of the directory the caller
# passes, named `thsplc_agg_<pid>_<counter>` and created exclusively, so two
# aggregates (or processes) may share the directory. The caller owns the
# budget and the directory (they come from its flags). The spill files are
# deleted when the finalize returns or raises, and when the state is dropped.
# Single-threaded: the finalize runs on one thread.
# =============================================================================

from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.record_batch import RecordBatch
from komira_async.runtime.spill_prefetch import SpillPrefetcher
from komira_collections.slab import Slab

from komira_row_format.row_block import RowHashAggTable, RowLayout

from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_engine_runtime.spill.spill_storage import ChunkId

from .spill_root import create_spill_root
from .agg_spill_codec import (
    AggRegistration,
    agg_layout_fingerprint,
    encode_group_rows_to_storage,
    prefetch_run,
    restore_shell_from_chunk,
    shell_from_image,
)


comptime AGG_RECURSE_FANOUT: Int = 8
"""Parts per repartition level."""

comptime AGG_BITS_PER_LEVEL: Int = 3
"""log2(AGG_RECURSE_FANOUT): the hash bits one level consumes. Level `d`
splits on `(hash >> d * AGG_BITS_PER_LEVEL) % AGG_RECURSE_FANOUT`, so a part
that is split again splits on bits its parent did not use."""

comptime AGG_RECURSE_MAX_DEPTH: Int = 8
"""The deepest repartition level (8^8 parts). Only keys whose hashes agree on
every consumed bit reach it; such a part is emitted whole (still correct, just
not bounded by the budget)."""


struct RowHashAggSpillState(Movable, Deinitable):
    """The spill state of one row-format hash aggregate: its budget, its
    spill directory, the storage (created on the first spill) and one entry
    per spilled run (its chunk id and group count)."""

    var _budget_bytes: Int
    var _spill_dir: String
    var _storage: Optional[LocalDiskSpillStorage]
    var _run_chunk_ids: List[ChunkId]
    var _run_n_groups: List[Int]
    var _last_finalize_subparts: Int

    def __init__(out self, budget_bytes: Int, var spill_dir: String):
        """`budget_bytes`: spill when the table's estimate passes it; 0 or
        less never spills. `spill_dir`: the directory this aggregate's spill
        files go in, created on the first spill; the caller gives each
        aggregate its own."""
        self._budget_bytes = budget_bytes
        self._spill_dir = spill_dir^
        self._storage = Optional[LocalDiskSpillStorage](None)
        self._run_chunk_ids = List[ChunkId]()
        self._run_n_groups = List[Int]()
        self._last_finalize_subparts = 0

    def __del__(deinit self):
        """Release the spill files of a state dropped before finalize (a
        cancelled or failed query). Best-effort: a destructor cannot raise."""
        if self._storage:
            try:
                self._storage.value().cleanup()
            except:
                pass

    def budget_bytes(self) -> Int:
        return self._budget_bytes

    def has_spilled(self) -> Bool:
        return len(self._run_chunk_ids) > 0

    def num_spilled_runs(self) -> Int:
        return len(self._run_chunk_ids)

    def last_finalize_subpartitions(self) -> Int:
        """How the last finalize re-aggregated: 1 for a fold into the
        in-memory table, `AGG_RECURSE_FANOUT` for a repartition, 0 before any
        finalize."""
        return self._last_finalize_subparts

    # -------------------------------------------------------------------------
    # Spill
    # -------------------------------------------------------------------------

    def maybe_spill_run(mut self, mut table: RowHashAggTable) raises:
        """Spill `table` as one run if the budget is set and the table's
        `agg_estimated_bytes()` is over it; the table is then empty, with its
        aggregates still registered. Otherwise nothing changes."""
        if self._budget_bytes <= 0:
            return
        var n_groups = table.n_groups()
        if n_groups == 0:
            return
        if table.agg_estimated_bytes() <= self._budget_bytes:
            return
        var image = table.spill_group_rows_sab()
        var fingerprint = agg_layout_fingerprint(table)
        if not self._storage:
            self._storage = Optional[LocalDiskSpillStorage](
                LocalDiskSpillStorage.with_unlimited(
                    create_spill_root(self._spill_dir, "agg")
                )
            )
        var cid = encode_group_rows_to_storage(
            self._storage.value(),
            image^,
            n_groups,
            len(table.var_key_offsets) > 0,
            fingerprint,
        )
        self._run_chunk_ids.append(cid)
        self._run_n_groups.append(n_groups)
        table.reset_keep_aggs()

    # -------------------------------------------------------------------------
    # Finalize
    # -------------------------------------------------------------------------

    def finalize_with_spill(
        mut self,
        mut table: RowHashAggTable,
        ref [_] layout: RowLayout,
        key_names: List[String],
        agg_names: List[String],
        mut prefetcher: SpillPrefetcher,
    ) raises -> Optional[RecordBatch]:
        """The aggregate over every row fed, as one batch (None for no
        groups): `finalize_with_spill_yield`'s batches concatenated in order.
        Group order is the fold's (or the parts' in order), not sorted."""
        var parts = self.finalize_with_spill_yield(
            table, layout, key_names, agg_names, prefetcher
        )
        if len(parts) == 0:
            return None
        if len(parts) == 1:
            return Optional[RecordBatch](parts.take_at(0))
        return Optional[RecordBatch](concat_record_batches_nway(parts^))

    def finalize_with_spill_yield(
        mut self,
        mut table: RowHashAggTable,
        ref [_] layout: RowLayout,
        key_names: List[String],
        agg_names: List[String],
        mut prefetcher: SpillPrefetcher,
    ) raises -> Slab[RecordBatch]:
        """The aggregate over every row fed, as a slab of batches a consumer
        pulls one at a time: one batch when the runs folded into `table`
        within the budget (or nothing spilled), else one batch per
        top-level part of the repartition (at most `AGG_RECURSE_FANOUT`; a
        part split deeper is concatenated into its one batch). Every group
        appears in exactly one batch.

        `prefetcher` reads the next run's chunk into the page cache while the
        current one folds; one with no IO lane does nothing. The spill files
        are deleted before this returns. `table` is consumed as a source (its
        contents afterwards are unspecified)."""
        var out = Slab[RecordBatch]()
        if len(self._run_chunk_ids) == 0:
            self._last_finalize_subparts = 1
            var rb = table.emit_to_record_batch(layout, key_names, agg_names)
            if rb:
                out.append(rb.take())
            return out^
        if not self._storage:
            raise Error(
                "RowHashAggSpillState.finalize_with_spill_yield: runs are"
                " recorded but the spill storage is gone (finalized twice?)"
            )
        var reg = AggRegistration(table)
        var storage = self._storage.take()
        # The fold mutates `table`; a repartition must start from the table as
        # it was, or the runs folded before the overflow would count twice.
        try:
            var snapshot = table.partition_group_rows_to_sab(1, 0, 0)
            var overflowed = self._fold_runs(storage, table, reg, prefetcher)
            if not overflowed:
                self._last_finalize_subparts = 1
                var rb = table.emit_to_record_batch(
                    layout, key_names, agg_names
                )
                if rb:
                    out.append(rb.take())
            else:
                self._last_finalize_subparts = AGG_RECURSE_FANOUT
                var surviving = shell_from_image(snapshot^, reg)
                self._repartition_collect(
                    storage, surviving, reg, layout, key_names, agg_names, out
                )
        except e:
            try:
                storage.cleanup()
            except:
                pass
            raise e^
        storage.cleanup()
        return out^

    def _fold_runs(
        self,
        mut storage: LocalDiskSpillStorage,
        mut table: RowHashAggTable,
        reg: AggRegistration,
        mut prefetcher: SpillPrefetcher,
    ) raises -> Bool:
        """Fold every spilled run into `table`. Returns True, stopping early,
        once the folded group rows plus the string heap pass a set budget (the
        directory's slots are left out: they are not what a repartition
        shrinks)."""
        var n_runs = len(self._run_chunk_ids)
        prefetch_run(prefetcher, storage, self._run_chunk_ids, 0)
        for i in range(n_runs):
            prefetch_run(prefetcher, storage, self._run_chunk_ids, i + 1)
            var shell = restore_shell_from_chunk(
                storage, self._run_chunk_ids[i], self._run_n_groups[i], reg
            )
            table.combine(shell^)
            if self._budget_bytes > 0 and (
                _group_bytes(table, reg) > self._budget_bytes
            ):
                return True
        return False

    def _repartition_collect(
        self,
        mut storage: LocalDiskSpillStorage,
        table: RowHashAggTable,
        reg: AggRegistration,
        ref [_] layout: RowLayout,
        key_names: List[String],
        agg_names: List[String],
        mut out: Slab[RecordBatch],
    ) raises:
        """Split `table` (the pre-fold snapshot) and every spilled run into
        `AGG_RECURSE_FANOUT` parts by key hash; fold, emit and append each
        part as one batch."""
        for p in range(AGG_RECURSE_FANOUT):
            var sub = shell_from_image(
                table.partition_group_rows_to_sab(AGG_RECURSE_FANOUT, p, 0),
                reg,
            )
            for ri in range(len(self._run_chunk_ids)):
                var run_shell = restore_shell_from_chunk(
                    storage,
                    self._run_chunk_ids[ri],
                    self._run_n_groups[ri],
                    reg,
                )
                var frag = shell_from_image(
                    run_shell.partition_group_rows_to_sab(
                        AGG_RECURSE_FANOUT, p, 0
                    ),
                    reg,
                )
                _ = run_shell^
                sub.combine(frag^)
            var pieces = Slab[RecordBatch]()
            self._emit_part(sub^, reg, layout, key_names, agg_names, 0, pieces)
            if len(pieces) == 1:
                out.append(pieces.take_at(0))
            elif len(pieces) > 1:
                out.append(concat_record_batches_nway(pieces^))

    def _emit_part(
        self,
        var sub: RowHashAggTable,
        reg: AggRegistration,
        ref [_] layout: RowLayout,
        key_names: List[String],
        agg_names: List[String],
        depth: Int,
        mut out: Slab[RecordBatch],
    ) raises:
        """Emit a fully folded part, splitting it again on fresh hash bits
        while it is over the budget, holds more than one group and the depth
        limit allows."""
        var split = (
            self._budget_bytes > 0
            and _group_bytes(sub, reg) > self._budget_bytes
            and depth + 1 < AGG_RECURSE_MAX_DEPTH
            and sub.n_groups() > 1
        )
        if not split:
            var rb = sub.emit_to_record_batch(layout, key_names, agg_names)
            if rb:
                out.append(rb.take())
            return
        var shift = (depth + 1) * AGG_BITS_PER_LEVEL
        for p in range(AGG_RECURSE_FANOUT):
            var frag = shell_from_image(
                sub.partition_group_rows_to_sab(AGG_RECURSE_FANOUT, p, shift),
                reg,
            )
            self._emit_part(
                frag^, reg, layout, key_names, agg_names, depth + 1, out
            )


def _group_bytes(table: RowHashAggTable, reg: AggRegistration) -> Int:
    """The bytes a table's groups occupy: fixed rows plus the string heap (a
    string key's row holds only an 8-byte descriptor; its bytes are in the
    heap)."""
    return table.n_groups() * reg.fixed_stride + table.rows.var_storage_used
