# =============================================================================
# parquet_source_grain — the morsel source's cursor-grain route
# =============================================================================
#
# When the cursor-grain gate is on (`cursor_grain_feed.cursor_grain_enabled`)
# and the scan qualifies (one file, a plain projection of cursor-supported
# columns, no dictionary preservation, no hash-aggregate payload, no
# partition columns), a worker that claims a row group opens column cursors
# over it (`cursor_grain_open`) and then emits one grain per `next_morsel`
# call until the row group is done, instead of decoding it whole. A grain is
# cut into `morsel_rows` sub-morsels like any whole-row-group batch
# (`cursor_grain_split_emit`); grain `g`'s sub-slots start at
# `g * subs_per_grain`, so all of a row group's morsels sort into file order.
# A row group the cursors refuse is decoded whole.
#
# `CursorGrainScan` holds the route's state: the read plan, the chunk schema,
# the grain, and each worker's open row group and decode buffers.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem
from komira_morsel.morsel import Morsel
from komira_parquet.column_decode_context import ColumnDecodeContext

from .cursor_grain_feed import (
    CursorGrainRg,
    cursor_grain_enabled,
    cursor_grain_next,
    cursor_grain_open,
    cursor_grain_rows,
)
from .cursor_grain_split_emit import (
    cursor_grain_split_enabled,
    cursor_grain_sub_count,
    note_cursor_grain_nosplit,
    note_cursor_grain_split,
)
from .parquet_reader import ParquetReader
from .parquet_source_emit import split_and_stash_first
from .parquet_source_options import SUB_SLOT_STRIDE, ParquetScanOptions
from .parquet_source_subrg import subrg_chunk_schema_of_footer
from .subrg_scan_executor import SubrgScanPlan
from .subrg_split_decode import subrg_probe_build_plan


struct CursorGrainScan(Movable):
    """The cursor-grain route's state (`enabled` False: the route is off).

    Fields:
        grain_rows: rows per grain.
        subs_per_grain: sub-morsels a full grain is cut into.
    """

    var enabled: Bool
    var grain_rows: Int
    var subs_per_grain: Int
    var plan: Optional[SubrgScanPlan]
    var chunk_schema: Schema
    var state: Slab[CursorGrainRg]
    var ctx: Slab[ColumnDecodeContext]

    def __init__(out self):
        """The route off."""
        self.enabled = False
        self.grain_rows = 0
        self.subs_per_grain = 1
        self.plan = None
        self.chunk_schema = Schema()
        self.state = Slab[CursorGrainRg]()
        self.ctx = Slab[ColumnDecodeContext]()

    def try_enable[FS: FileSystem](
        mut self,
        reader: ParquetReader[FS],
        result_col_names: List[String],
        num_workers: Int,
        morsel_rows: Int,
        options: ParquetScanOptions,
    ) raises:
        """Turn the route on when the gate is on and every result column is
        a cursor column of `reader`'s file (the caller has checked the other
        conditions of the module header). The grain is
        `options.cursor_grain_rows` when positive, else derived from the
        projected row width, the worker count, `morsel_rows` and
        `options.l3_cache_bytes`."""
        if not cursor_grain_enabled() or len(result_col_names) == 0:
            return
        var maybe_plan = subrg_probe_build_plan[FS](reader, result_col_names)
        if not maybe_plan:
            return
        var plan = maybe_plan.take()
        var chunk_schema = subrg_chunk_schema_of_footer[FS](reader, plan)
        var grain = options.cursor_grain_rows
        if grain <= 0:
            grain = cursor_grain_rows(chunk_schema.row_width_bytes(), num_workers, morsel_rows, options.l3_cache_bytes)
        var st = Slab[CursorGrainRg].create(num_workers)
        var ctxs = Slab[ColumnDecodeContext].create(num_workers)
        for _ in range(num_workers):
            st.append(CursorGrainRg())
            ctxs.append(ColumnDecodeContext())
        self.state = st^
        self.ctx = ctxs^
        self.chunk_schema = chunk_schema^
        self.grain_rows = grain
        self.subs_per_grain = cursor_grain_sub_count(grain, morsel_rows)
        self.plan = Optional(plan^)
        self.enabled = True

    def open[FS: FileSystem](self, reader: ParquetReader[FS], rg_in_file: Int, claimed_rg: Int, worker_id: Int) raises -> Bool:
        """Open the cursors of a claimed row group for `worker_id`; False
        when they refuse it."""
        return cursor_grain_open[FS](
            reader, rg_in_file, claimed_rg, self.plan.value(), reader._meta[].schema,
            self.state.get_mut_interior(worker_id),
        )

    def pull(self, worker_id: Int, morsel_rows: Int, mut morsel_counter: AtomicI64, mut pending: Slab[Morsel]) raises -> Optional[Morsel]:
        """The next morsel of `worker_id`'s open row group: a parked
        sub-morsel first, else the next grain (cut to `morsel_rows` when the
        split gate is on); None when the worker has no open row group."""
        if not self.enabled:
            return None
        if morsel_rows > 0 and len(pending) > 0:
            var stashed = pending.pop()
            if stashed:
                return Optional(stashed.take())
        ref st = self.state.get_mut_interior(worker_id)
        if not st.active():
            return None
        var claimed_rg = st.claimed_rg
        var grain_idx = st.grain_idx
        var maybe = cursor_grain_next(
            st, self.plan.value(), self.chunk_schema, self.ctx.get_mut_interior(worker_id), self.grain_rows
        )
        if not maybe:
            return None
        var batch = maybe.take()
        var n_rows = batch.num_rows()
        var split_on = cursor_grain_split_enabled() and morsel_rows > 0
        var slot_base = grain_idx * self.subs_per_grain if split_on else grain_idx
        if split_on and n_rows > morsel_rows:
            note_cursor_grain_split(n_rows, cursor_grain_sub_count(n_rows, morsel_rows))
            return Optional(split_and_stash_first(batch^, morsel_rows, claimed_rg, morsel_counter, pending, slot_base))
        note_cursor_grain_nosplit(n_rows)
        return Optional(
            Morsel(
                batch^,
                morsel_id=Int(morsel_counter.fetch_add(Int64(1))),
                partition_id=claimed_rg * SUB_SLOT_STRIDE + slot_base,
                origin_hint=slot_base,
            )
        )
