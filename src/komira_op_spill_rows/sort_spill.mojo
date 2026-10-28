# =============================================================================
# sort_spill -- the external merge sort of a row-format sort buffer: sorted
# runs written to disk over a memory budget, then k-way merged at finalize
# =============================================================================
#
# The accumulator is a `RowSortBuffer` (INT64 keys and payloads, one packed row
# per input row; it refuses a NULL in any column). Without a spill it holds
# every row in memory. `RowSortSpillState` bounds that:
#
#   1. SPILL (`maybe_spill_run`, called after each `feed_batch`): when the
#      buffer's `estimated_bytes()` is over the budget, it is sorted, emitted
#      as one sorted batch, written as one THSPLC chunk, and emptied
#      (`reset_keep_directions`). A budget of 0 (or less) never spills.
#
#   2. FINALIZE (`finalize_with_spill`, `finalize_with_spill_yield`): the
#      in-memory remainder is sorted as the last run, every spilled run is
#      read back, and all runs are merged by their key columns with
#      `komira_op_sort`'s `k_way_merge_cursors`. Its comparator orders INT64
#      keys by value, flipped per DESC key, which is the order the buffer's
#      run sort produces. The runs are handed to the merge in input order
#      (spilled runs in spill order, the in-memory run last), and on a full
#      key tie the merge takes the earlier run, so rows with equal keys come
#      out in input order, as the buffer's stable sort leaves them: the merged
#      result equals the sort of the same rows without a spill, row for row.
#
# The storage is ONE `LocalDiskSpillStorage` per sort, created on the first
# spill (so a sort that never spills never touches the filesystem), rooted at
# a new sub-directory of the directory the caller passes, named
# `thsplc_sortrows_<pid>_<counter>` and created exclusively, so two sorts (or
# processes) may share the directory. The caller owns the budget and the
# directory (they come from its flags). The spill files are deleted when the
# finalize returns or raises, and when the state is dropped. Single-threaded.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_row_format.row_block import RowLayout
from komira_row_format.row_sort import RowSortBuffer, SORT_DESC

from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_engine_runtime.spill.native_spill import (
    native_column_read_chunk,
    native_column_write_chunk,
)
from komira_engine_runtime.spill.spill_storage import ChunkId

from .spill_root import create_spill_root
from komira_op_sort.sort_external_merge import RunCursor, k_way_merge_cursors


comptime SORT_MERGE_OUTPUT_ROWS: Int = 8192
"""Rows per batch the merge emits (each yield of `finalize_with_spill_yield`
but the last holds exactly this many)."""


struct RowSortSpillState(Movable, Deinitable):
    """The spill state of one row-format sort: its budget, its spill
    directory, the storage (created on the first spill), the chunk id of each
    spilled run in spill order, and the run schema (every run has the same
    one: the buffer emits `[keys..., payloads...]`, all INT64)."""

    var _budget_bytes: Int
    var _spill_dir: String
    var _storage: Optional[LocalDiskSpillStorage]
    var _run_chunk_ids: List[ChunkId]
    var _schema: Optional[Schema]

    def __init__(out self, budget_bytes: Int, var spill_dir: String):
        """`budget_bytes`: spill when the buffer's estimate passes it; 0 or
        less never spills. `spill_dir`: the directory this sort's spill files
        go in, created on the first spill; the caller gives each sort its
        own."""
        self._budget_bytes = budget_bytes
        self._spill_dir = spill_dir^
        self._storage = Optional[LocalDiskSpillStorage](None)
        self._run_chunk_ids = List[ChunkId]()
        self._schema = Optional[Schema](None)

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

    # -------------------------------------------------------------------------
    # Spill
    # -------------------------------------------------------------------------

    def maybe_spill_run[lo: Origin[mut=False], //](
        mut self,
        mut buffer: RowSortBuffer,
        ref [lo] layout: RowLayout,
        key_names: List[String],
        payload_names: List[String],
    ) raises:
        """Spill `buffer` as one sorted run if the budget is set and the
        buffer's `estimated_bytes()` is over it; the buffer is then empty, with
        its sort directions kept. Otherwise nothing changes."""
        if self._budget_bytes <= 0:
            return
        if buffer.n_rows() == 0:
            return
        if buffer.estimated_bytes() <= self._budget_bytes:
            return
        var run = _sorted_run(buffer, layout, key_names, payload_names)
        if not run:
            buffer.reset_keep_directions()
            return
        var batch = run.take()
        if not self._schema:
            self._schema = Optional[Schema](batch.schema.copy())
        if not self._storage:
            self._storage = Optional[LocalDiskSpillStorage](
                LocalDiskSpillStorage.with_unlimited(
                    create_spill_root(self._spill_dir, "sortrows")
                )
            )
        ref storage = self._storage.value()
        var cid = native_column_write_chunk(storage, batch^)
        storage.sync()
        self._run_chunk_ids.append(cid)
        buffer.reset_keep_directions()

    # -------------------------------------------------------------------------
    # Finalize
    # -------------------------------------------------------------------------

    def finalize_with_spill[lo: Origin[mut=False], //](
        var self,
        mut buffer: RowSortBuffer,
        ref [lo] layout: RowLayout,
        key_names: List[String],
        payload_names: List[String],
        directions: List[UInt8],
    ) raises -> Optional[RecordBatch]:
        """Every row fed, sorted, as one batch (None for no rows):
        `finalize_with_spill_yield`'s batches concatenated in order."""
        var parts = self^.finalize_with_spill_yield(
            buffer, layout, key_names, payload_names, directions
        )
        if len(parts) == 0:
            return None
        if len(parts) == 1:
            return Optional[RecordBatch](parts.take_at(0))
        return Optional[RecordBatch](concat_record_batches_nway(parts^))

    def finalize_with_spill_yield[lo: Origin[mut=False], //](
        var self,
        mut buffer: RowSortBuffer,
        ref [lo] layout: RowLayout,
        key_names: List[String],
        payload_names: List[String],
        directions: List[UInt8],
    ) raises -> Slab[RecordBatch]:
        """Every row fed, sorted, as batches of `SORT_MERGE_OUTPUT_ROWS` rows
        in order (empty for no rows). `directions[k]` is key `k`'s
        `SORT_ASC` / `SORT_DESC`, as given to the buffer. With no spilled run
        this is the buffer's own sort, as one batch. The spill files are
        deleted before this returns."""
        var final_run = Optional[RecordBatch](None)
        if buffer.n_rows() > 0:
            final_run = _sorted_run(buffer, layout, key_names, payload_names)
        var out = Slab[RecordBatch]()
        if len(self._run_chunk_ids) == 0:
            if final_run:
                out.append(final_run.take())
            return out^
        if not self._storage or not self._schema:
            raise Error(
                "RowSortSpillState.finalize_with_spill_yield: runs are recorded"
                " but the spill storage is gone (finalized twice?)"
            )

        # Runs in input order: the spilled ones as they were written, then the
        # in-memory remainder. The merge breaks a full tie toward the earlier
        # run, which is what keeps equal keys in input order.
        var cursors = Slab[RunCursor]()
        var storage = self._storage.take()
        try:
            for i in range(len(self._run_chunk_ids)):
                var rb = native_column_read_chunk(
                    storage,
                    self._run_chunk_ids[i],
                    self._schema.value().copy(),
                )
                var one = Slab[RecordBatch]()
                one.append(rb^)
                cursors.append(RunCursor(one^))
        except e:
            try:
                storage.cleanup()
            except:
                pass
            raise e^
        storage.cleanup()
        if final_run:
            var one = Slab[RecordBatch]()
            one.append(final_run.take())
            cursors.append(RunCursor(one^))

        var n_key = len(key_names)
        var key_indices = List[Int](capacity=n_key)
        var descending = List[Bool](capacity=n_key)
        var arrow_types = List[UInt8](capacity=n_key)
        for k in range(n_key):
            key_indices.append(k)
            descending.append(k < len(directions) and directions[k] == SORT_DESC)
            arrow_types.append(ArrowType.INT64.type_id)
        return k_way_merge_cursors(
            cursors^,
            n_key,
            key_indices^,
            descending^,
            arrow_types^,
            SORT_MERGE_OUTPUT_ROWS,
        )


def _sorted_run[lo: Origin[mut=False], //](
    mut buffer: RowSortBuffer,
    ref [lo] layout: RowLayout,
    key_names: List[String],
    payload_names: List[String],
) raises -> Optional[RecordBatch]:
    """Sort the buffered rows and emit them as one batch."""
    buffer.finalize_sort(layout)
    return buffer.emit_to_record_batch(layout, key_names, payload_names)
