# =============================================================================
# parquet_source_subrg — the morsel source's row-range split
# =============================================================================
#
# With `ParquetScanOptions.subrg_mode` set, a plain scan of one file (no
# pushed predicate, no hash-aggregate payload, every result column a cursor
# column) is cut into row-range units smaller than a row group, so a few
# large row groups no longer bound the scan's parallelism. Units:
#   mode 1: one unit per page of the first result column;
#   mode 2: `subrg_units_per_rg` equal row ranges per row group, snapped to
#           page boundaries when `subrg_snap` and the row group has enough
#           pages.
# Workers claim units from one atomic counter and decode each with
# `subrg_split_decode` (each (row group, column) dictionary decoded once, by
# whichever worker gets there first, when `subrg_shared`). A unit becomes one
# morsel, or several units of a worker are concatenated into morsels of about
# `subrg_emit_rows` rows (`subrg_emit_coarse`). A unit's partition id is
# `rg * SUB_SLOT_STRIDE + k`, `k` its ordinal within the row group, so the
# morsels sort into file order when each holds one unit; a coarse morsel takes the
# id of the first unit it holds. A row group that would need more than
# `SUB_SLOT_STRIDE` units leaves the split off. A unit a cursor refuses after
# the plan probe passed (a column with an actual null, an encoding row group
# 0 does not use) is cut from the whole decode of its row group instead; each
# worker keeps the last whole decode it made, so its consecutive refused
# units of one row group decode it once. Every unit batch, cursor or whole
# decode, carries the field nullability of the whole decode (OPTIONAL columns
# nullable), so a coarse morsel's schema agrees with all its columns.
# =============================================================================

from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import gather_batch
from komira_fs.file_system import FileSystem
from komira_morsel.morsel import Morsel
from komira_parquet.column_decode_context import ColumnDecodeContext

from .parquet_reader import ParquetReader
from .parquet_source_options import SUB_SLOT_STRIDE, ParquetScanOptions, unit_partition_id
from .subrg_cursor_feed import _chunk_is_nullable
from .subrg_scan_executor import SubrgScanPlan
from .subrg_split_decode import (
    SharedColDict,
    SubrgBuildLatch,
    build_shared_col_dict,
    decode_subrg_unit,
    decode_subrg_unit_shared,
    subrg_page_row_boundaries,
    subrg_probe_build_plan,
)


struct _UnitCounter:
    var next: AtomicI64


struct RowRangeUnits(Copyable, Movable):
    """The units of a split: unit `i` is rows `[lo[i], hi[i])` of row group
    `rg[i]`, the `ordinal[i]`-th unit (from 0) of that row group. Units are
    added row group by row group."""

    var rg: List[Int]
    var lo: List[Int]
    var hi: List[Int]
    var ordinal: List[Int]

    def __init__(out self):
        self.rg = List[Int]()
        self.lo = List[Int]()
        self.hi = List[Int]()
        self.ordinal = List[Int]()

    def add(mut self, rg: Int, lo: Int, hi: Int):
        var k = 0
        if len(self.rg) > 0 and self.rg[len(self.rg) - 1] == rg:
            k = self.ordinal[len(self.ordinal) - 1] + 1
        self.rg.append(rg)
        self.lo.append(lo)
        self.hi.append(hi)
        self.ordinal.append(k)

    def max_units_per_rg(self) -> Int:
        """The most units any one row group has."""
        var m = 0
        for i in range(len(self.ordinal)):
            m = max(m, self.ordinal[i] + 1)
        return m

    def max_rows(self) -> Int:
        var m = 0
        for i in range(len(self.lo)):
            m = max(m, self.hi[i] - self.lo[i])
        return m


def plan_row_range_units[FS: FileSystem](
    reader: ParquetReader[FS], driver_col: Int, mode: Int, units_per_rg: Int, snap: Bool
) raises -> RowRangeUnits:
    """The units of the module header for every non-empty row group of the
    file (`driver_col` is the first result column's leaf index)."""
    var units = RowRangeUnits()
    var n = max(units_per_rg, 1)
    for rg in range(len(reader._meta[].row_groups)):
        var rg_rows = Int(reader._meta[].row_groups[rg].num_rows)
        if rg_rows <= 0:
            continue
        if mode == 1 or snap:
            var bounds = subrg_page_row_boundaries[FS](reader, rg, driver_col)
            var n_pages = len(bounds) - 1
            if mode == 1:
                for p in range(n_pages):
                    units.add(rg, bounds[p], bounds[p + 1])
                continue
            if n_pages >= n:
                for g in range(n):
                    var p0 = (n_pages * g) // n
                    var p1 = (n_pages * (g + 1)) // n
                    if p1 > p0:
                        units.add(rg, bounds[p0], bounds[p1])
                continue
        for u in range(n):
            var lo = (rg_rows * u) // n
            var hi = (rg_rows * (u + 1)) // n
            if hi > lo:
                units.add(rg, lo, hi)
    return units^


def subrg_chunk_schema_of_footer[FS: FileSystem](reader: ParquetReader[FS], plan: SubrgScanPlan) raises -> Schema:
    """The chunk batches' schema: `plan`'s names and types in projection
    order, each field nullable unless the footer's column is REQUIRED (the
    nullability of the whole decode's fields; a cursor refuses a column that
    holds a null, so a nullable field here carries no null)."""
    var sb = SchemaBuilder()
    for ci in range(len(plan.proj_names)):
        var nullable = _chunk_is_nullable(reader._meta[].schema[plan.reader_col_idx[ci] + 1])
        sb.add_field(Field(plan.proj_names[ci], plan.col_arrow_types[ci], nullable))
    return sb.build()


struct _WholeDecode(Movable):
    """A worker's last whole decode of a row group, for the units it cuts
    from it."""

    var rg: Int
    var batch: Optional[RecordBatch]

    def __init__(out self):
        self.rg = -1
        self.batch = None


struct SubrgSplitScan(Movable):
    """The row-range split's state (`enabled` False: the split is off)."""

    var enabled: Bool
    var plan: Optional[SubrgScanPlan]
    var chunk_schema: Schema
    var units: RowRangeUnits
    var max_unit_rows: Int
    var shared_on: Bool
    var ncols: Int
    var shared: Slab[SharedColDict]
    var latch: Slab[SubrgBuildLatch]
    var ctx: Slab[ColumnDecodeContext]
    var counter: Slab[_UnitCounter]
    var whole: Slab[_WholeDecode]
    var emit_coarse: Bool
    var emit_rows: Int

    def __init__(out self):
        """The split off."""
        self.enabled = False
        self.plan = None
        self.chunk_schema = Schema()
        self.units = RowRangeUnits()
        self.max_unit_rows = 0
        self.shared_on = False
        self.ncols = 0
        self.shared = Slab[SharedColDict]()
        self.latch = Slab[SubrgBuildLatch]()
        self.ctx = Slab[ColumnDecodeContext]()
        self.counter = Slab[_UnitCounter].create_prefilled(1)
        self.whole = Slab[_WholeDecode]()
        self.emit_coarse = False
        self.emit_rows = 0

    def try_enable[FS: FileSystem](
        mut self, reader: ParquetReader[FS], result_col_names: List[String], num_workers: Int, options: ParquetScanOptions
    ) raises:
        """Turn the split on for `reader`'s file when the mode is set and the
        result columns pass the plan probe (the caller has checked the other
        conditions)."""
        if options.subrg_mode == 0 or len(result_col_names) == 0:
            return
        var maybe_plan = subrg_probe_build_plan[FS](reader, result_col_names)
        if not maybe_plan:
            return
        var plan = maybe_plan.take()
        var units = plan_row_range_units[FS](
            reader, plan.reader_col_idx[0], options.subrg_mode, options.subrg_units_per_rg, options.subrg_snap
        )
        if len(units.rg) == 0 or units.max_units_per_rg() > SUB_SLOT_STRIDE:
            return
        self.chunk_schema = subrg_chunk_schema_of_footer[FS](reader, plan)
        self.max_unit_rows = units.max_rows()
        self.units = units^
        self.ncols = len(plan.reader_col_idx)
        var n_rgs = len(reader._meta[].row_groups)
        if options.subrg_shared:
            var n_shared = max(n_rgs * self.ncols, 1)
            self.shared = Slab[SharedColDict].create(n_shared)
            for _ in range(n_shared):
                self.shared.append(SharedColDict(False))
            self.latch = Slab[SubrgBuildLatch].create_prefilled(n_shared)
            self.shared_on = True
        self.plan = Optional(plan^)
        var ctxs = Slab[ColumnDecodeContext].create(num_workers)
        for _ in range(num_workers):
            ctxs.append(ColumnDecodeContext())
        self.ctx = ctxs^
        var wholes = Slab[_WholeDecode].create(num_workers)
        for _ in range(num_workers):
            wholes.append(_WholeDecode())
        self.whole = wholes^
        self.emit_coarse = options.subrg_emit_coarse
        var emit_rows = options.subrg_emit_rows
        if emit_rows <= 0:
            for rg in range(n_rgs):
                emit_rows = max(emit_rows, Int(reader._meta[].row_groups[rg].num_rows))
        self.emit_rows = emit_rows if emit_rows > 0 else 122_880
        self.enabled = True

    def _ensure_shared_built[FS: FileSystem](self, reader: ParquetReader[FS], rg_idx: Int, col_idx: Int, idx: Int) raises:
        """Make `shared[idx]` the dictionary of (rg_idx, col_idx): the first
        worker to claim the latch builds and publishes it, the others wait
        for `done` (set on a raise too, so no waiter is left spinning)."""
        ref latch = self.latch.get_mut_interior(idx)
        if Int(latch.done.load()) != 0:
            return
        if Int(latch.claim.fetch_add(Int64(1))) == 0:
            try:
                self.shared.get_mut_interior(idx) = build_shared_col_dict[FS](
                    reader, rg_idx, col_idx, reader._meta[].schema
                )
            except e:
                # Release the waiters (they read the refusal sentinel left in
                # the slot) before raising.
                _ = latch.done.fetch_add(Int64(1))
                raise e^
            _ = latch.done.fetch_add(Int64(1))
            return
        while Int(latch.done.load()) == 0:
            pass

    def _range_of_whole_decode[FS: FileSystem](
        self, reader: ParquetReader[FS], plan: SubrgScanPlan, worker_id: Int, rg: Int, row_lo: Int, row_hi: Int
    ) raises -> RecordBatch:
        """Rows `[row_lo, row_hi)` of the whole decode of row group `rg`
        (`worker_id` keeps the decode for its next unit of `rg`).

        Raises:
            If the whole decode has fewer than `row_hi` rows.
        """
        ref slot = self.whole.get_mut_interior(worker_id)
        if slot.rg != rg or not slot.batch:
            slot.batch = None
            slot.rg = -1
            slot.batch = Optional(reader.decode_columns_subset(rg, plan.reader_col_idx.copy(), False))
            slot.rg = rg
        ref whole = slot.batch.value()
        if whole.num_rows() < row_hi:
            raise Error(
                "parquet source: row group " + String(rg) + " decoded to " + String(whole.num_rows())
                + " rows, short of the row range [" + String(row_lo) + ", " + String(row_hi) + ")"
            )
        var rows = List[Int](capacity=row_hi - row_lo)
        for r in range(row_lo, row_hi):
            rows.append(r)
        return gather_batch(whole, rows)

    def _decode_one[FS: FileSystem](self, reader: ParquetReader[FS], worker_id: Int, mut out_rg: Int, mut out_ord: Int) raises -> Optional[RecordBatch]:
        """The next claimed unit with rows, decoded; None when the units are
        exhausted.

        Raises:
            If the whole decode of a refused unit's row group is short.
        """
        ref c = self.counter.get_mut_interior(0)
        ref plan = self.plan.value()
        while True:
            var claim = Int(c.next.fetch_add(Int64(1)))
            if claim >= len(self.units.rg):
                return None
            var rg = self.units.rg[claim]
            var row_lo = self.units.lo[claim]
            var row_hi = self.units.hi[claim]
            ref ctx = self.ctx.get_mut_interior(worker_id)
            var maybe: Optional[RecordBatch]
            if self.shared_on:
                var rg_base = rg * self.ncols
                for ci in range(self.ncols):
                    self._ensure_shared_built(reader, rg, plan.reader_col_idx[ci], rg_base + ci)
                maybe = decode_subrg_unit_shared[FS](
                    reader, row_lo, row_hi, plan, self.chunk_schema, ctx, self.shared, rg_base, self.max_unit_rows
                )
            else:
                maybe = decode_subrg_unit[FS](
                    reader, rg, row_lo, row_hi, plan, self.chunk_schema, ctx, reader._meta[].schema,
                    self.max_unit_rows,
                )
            if not maybe:
                # A cursor refused the range after the plan probe passed (a
                # column with an actual null, an encoding row group 0 does not
                # use, a short fill): the range's rows are cut from the whole
                # decode of its row group, with the whole decode's column
                # types.
                maybe = Optional(self._range_of_whole_decode(reader, plan, worker_id, rg, row_lo, row_hi))
            var batch = maybe.take()
            if batch.num_rows() == 0:
                continue
            out_rg = rg
            out_ord = self.units.ordinal[claim]
            return Optional(batch^)

    def next[FS: FileSystem](self, reader: ParquetReader[FS], worker_id: Int, mut morsel_counter: AtomicI64) raises -> Optional[Morsel]:
        """The next morsel of the split: one unit, or (coarse) the units
        `worker_id` claims until about `emit_rows` rows; None at the end."""
        var rg = 0
        var k = 0
        if not self.emit_coarse:
            var b = self._decode_one(reader, worker_id, rg, k)
            if not b:
                return None
            return Optional(
                Morsel(
                    b.take(),
                    morsel_id=Int(morsel_counter.fetch_add(Int64(1))),
                    partition_id=unit_partition_id(rg, k),
                    origin_hint=0,
                )
            )
        var acc = Slab[RecordBatch]()
        var acc_rows = 0
        var first_rg = 0
        var first_k = 0
        while acc_rows < self.emit_rows:
            var b = self._decode_one(reader, worker_id, rg, k)
            if not b:
                break
            if len(acc) == 0:
                first_rg = rg
                first_k = k
            var bb = b.take()
            acc_rows += bb.num_rows()
            acc.append(bb^)
        if len(acc) == 0:
            return None
        return Optional(
            Morsel(
                concat_record_batches_nway(acc^),
                morsel_id=Int(morsel_counter.fetch_add(Int64(1))),
                partition_id=unit_partition_id(first_rg, first_k),
                origin_hint=0,
            )
        )
