# =============================================================================
# group_positions -- a grouped sink's float folds by source position
# =============================================================================
#
# A double sum depends on the order of its additions. A grouped sink that
# folds each worker's rows into the worker's table and merges the tables in
# worker order gives a float SUM or AVG whose last bits depend on which worker
# took which morsel. For an ORDER_ROW_RANGE segment (`lowering` cuts a grouped
# float SUM or AVG so, as it cuts the ungrouped one) the grouped sinks fold
# their float aggregates by source position instead, the way the ungrouped
# sink does (`sink_agg`):
#
#   * A worker keeps, beside its group table, one grain per source position
#     it folded (the (`partition_id`, `origin_hint`) its source stamped on the
#     morsel, `position_order`). A grain holds, for each of the worker's
#     groups a row of that morsel reached, one float cell (a count and a
#     double) per positional aggregate, folded from empty in row order with
#     the steps of `agg_fold` (`float_step`). The chunks of one morsel an
#     operator cut (one position, one after the other on one worker) fold
#     into the same grain.
#   * A positional aggregate is a SUM, AVG, MIN or MAX whose argument is a
#     FLOAT32 or FLOAT64 column, fixed by the first morsel the worker folds
#     with its type; a later morsel whose argument has another type is refused
#     by name, as a cell refuses it. Its cells in the worker's group table
#     stay empty; every other aggregate folds there, as without a position.
#   * `merge_positions` runs at combine, after the workers' tables were merged
#     into the merged table: it sorts every worker's grains into source
#     position order and merges each grain's cells into the merged groups
#     (`merge_cell`) in that order. Which worker held a position no longer
#     matters, so a float SUM or AVG per group is the same bits on every
#     worker count and schedule given the same morsels, and a MIN or MAX that
#     meets -0.0 and 0.0 keeps the one first in source order. Two grains at
#     one position (a source that stamps no position) are refused by name.
#
# Memory: charged to the worker's position reservation (its own, beside the
# one of the worker's tables, so the grains can outlive the worker's tables in
# combine) before it is made: each doubling of the list of grains, each
# doubling of a grain's rows (a row is the group's id and 16 bytes per
# positional aggregate), and each growth of the per-group index the worker
# keeps of its current grain (two `Int`s a group, grown by doubling). A
# denial makes nothing and is reported by the caller by name. Not charged:
# the per-aggregate slot and type lists (one entry per aggregate) and the
# position order `merge_positions` builds (a few `Int`s per grain). The
# reservation is returned when the grains are merged, or dropped. The state
# grows with the number of (position, group) pairs the rows reach: one entry
# per group per morsel, so few groups cost little, and at most one entry per
# row. The grains are not written to a spill file, so a sink that folds by
# position does not spill (the sinks say so when given a spill directory).

from std.sys import size_of

from arrow.arrow_types import ArrowType
from plan_expr.agg_expr import AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM

from .agg_fold import AggCell, IN_FLOAT, WideColumn, float_step, merge_cell
from .position_order import position_order
from .segment_pool import WorkerReservation


@fieldwise_init
struct _FloatCell(Copyable, Movable):
    """The float fold of one aggregate over one group's rows of one
    position."""

    var count: Int
    var value: Float64


struct _GroupGrain(Movable):
    """The positional cells of the groups the rows of one source position
    reached on one worker."""

    var partition_id: Int
    var origin_hint: Int
    # The worker's group ids, in the order the rows first reached them.
    var groups: List[Int]
    # `len(groups)` rows of `np` cells: row `j` is the group `groups[j]`.
    var cells: List[_FloatCell]
    # The rows `groups` and `cells` are reserved for, and charged.
    var cap: Int

    def __init__(out self, partition_id: Int, origin_hint: Int):
        self.partition_id = partition_id
        self.origin_hint = origin_hint
        self.groups = List[Int]()
        self.cells = List[_FloatCell]()
        self.cap = 0


# The rows a grain first reserves; it doubles from there.
comptime _FIRST_ROWS: Int = 8


def _positional_func(func: UInt8) -> Bool:
    return (
        func == AGG_SUM
        or func == AGG_MEAN
        or func == AGG_MIN
        or func == AGG_MAX
    )


struct GroupPositions(Movable):
    """One worker's grains, and which of its aggregates fold into them."""

    var grains: List[_GroupGrain]
    # The grains `grains` is reserved for, and charged.
    var _grains_cap: Int
    # Per aggregate: its column in a grain's row of cells, -1 when it folds
    # into the group table. Empty until the first morsel fixed it.
    var slot_of: List[Int]
    # Per positional aggregate: the FLOAT32 or FLOAT64 type of its argument.
    var _arrows: List[ArrowType]
    # The number of positional aggregates (cells in a grain's row).
    var np: Int
    # Per worker group: the grain that last reached it, and its row there.
    var _grain_of: List[Int]
    var _row_of: List[Int]
    # The bytes the pool last refused (`row_for` returned -1).
    var denied_bytes: Int
    # What the grains and the per-group index are charged to.
    var reservation: WorkerReservation

    def __init__(out self, var reservation: WorkerReservation):
        self.reservation = reservation^
        self.grains = List[_GroupGrain]()
        self._grains_cap = 0
        self.slot_of = List[Int]()
        self._arrows = List[ArrowType]()
        self.np = 0
        self._grain_of = List[Int]()
        self._row_of = List[Int]()
        self.denied_bytes = 0

    def entry_bytes(self) -> Int:
        """The bytes a grain entry is charged: the group id and its cells."""
        return size_of[Int]() + self.np * size_of[_FloatCell]()

    def begin(
        mut self,
        ref funcs: List[UInt8],
        ref args: List[WideColumn],
        ref labels: List[String],
        partition_id: Int,
        origin_hint: Int,
    ) raises -> Bool:
        """Start folding a morsel at position (`partition_id`,
        `origin_hint`): fix the positional aggregates from `args` (one per
        aggregate, as the sink read them) on the first call, refuse by name an
        argument whose type is not the one fixed, and continue the last grain
        when it has this position (a chunk of the same morsel), else open a
        new one. False, with nothing opened and `denied_bytes` set, when the
        pool denies the new grain's charge."""
        if len(self.slot_of) == 0:
            for i in range(len(funcs)):
                if (
                    _positional_func(funcs[i])
                    and args[i].bind.kind == IN_FLOAT
                ):
                    self.slot_of.append(self.np)
                    self._arrows.append(args[i].bind.arrow)
                    self.np += 1
                else:
                    self.slot_of.append(-1)
        for i in range(len(funcs)):
            var s = self.slot_of[i]
            if s < 0:
                continue
            if (
                args[i].bind.kind != IN_FLOAT
                or args[i].bind.arrow != self._arrows[s]
            ):
                raise Error(
                    "pipeline_exec: "
                    + labels[i]
                    + " saw a column of another type or scale than the"
                    " morsels before it"
                )
        if self.np == 0:
            return True
        var n = len(self.grains)
        if (
            n > 0
            and self.grains[n - 1].partition_id == partition_id
            and self.grains[n - 1].origin_hint == origin_hint
        ):
            return True
        # A grain lives in the list of grains: when the list is full, its
        # doubling is charged before it is made.
        if n == self._grains_cap:
            var grain_cap = max(2 * n, 4)
            var bytes = (grain_cap - n) * size_of[_GroupGrain]()
            if not self.reservation.try_grow(bytes):
                self.denied_bytes = bytes
                return False
            self.grains.reserve(grain_cap)
            self._grains_cap = grain_cap
        self.grains.append(_GroupGrain(partition_id, origin_hint))
        return True

    def row_for(mut self, g: Int) -> Int:
        """The index of the first cell of worker group `g` in the current
        grain's cells, adding the group's row (empty cells) when the grain
        has none yet. -1, with nothing added and `denied_bytes` set, when the
        pool denies the charge."""
        var cur = len(self.grains) - 1
        if g >= len(self._grain_of):
            var want = max(max(g + 1, 2 * len(self._grain_of)), 64)
            var grow = want - len(self._grain_of)
            var bytes = grow * 2 * size_of[Int]()
            if not self.reservation.try_grow(bytes):
                self.denied_bytes = bytes
                return -1
            self._grain_of.reserve(want)
            self._row_of.reserve(want)
            for _ in range(grow):
                self._grain_of.append(-1)
                self._row_of.append(0)
        if self._grain_of[g] == cur:
            return self._row_of[g] * self.np
        var row = len(self.grains[cur].groups)
        if row == self.grains[cur].cap:
            # Rows are reserved by doubling, each doubling charged before it
            # is made, as a group table's are.
            var cap = self.grains[cur].cap
            var new_cap = _FIRST_ROWS if cap == 0 else 2 * cap
            var bytes = (new_cap - cap) * self.entry_bytes()
            if not self.reservation.try_grow(bytes):
                self.denied_bytes = bytes
                return -1
            self.grains[cur].groups.reserve(new_cap)
            self.grains[cur].cells.reserve(new_cap * self.np)
            self.grains[cur].cap = new_cap
        self.grains[cur].groups.append(g)
        for _ in range(self.np):
            self.grains[cur].cells.append(_FloatCell(0, 0.0))
        self._grain_of[g] = cur
        self._row_of[g] = row
        return row * self.np

    def fold(
        mut self, at: Int, i: Int, func: UInt8, ref w: WideColumn, row: Int
    ):
        """Fold row `row` of `w`, the argument of aggregate `i`, into the
        current grain's cells from index `at` (`row_for`). A NULL is
        skipped."""
        if len(w.valid) > 0 and not w.valid[row]:
            return
        ref cell = self.grains[len(self.grains) - 1].cells[at + self.slot_of[i]]
        float_step(cell.value, cell.count, func, w.fvals[row])
        cell.count += 1


def merge_positions(
    ref workers: List[GroupPositions],
    ref group_maps: List[List[Int]],
    mut merged: List[AggCell],
    ref funcs: List[UInt8],
    ref labels: List[String],
    ref where_: String,
) raises:
    """Merge the grains of every worker (`workers[w]`, whose group `g` is the
    merged group `group_maps[w][g]`) into `merged` (`len(funcs)` cells a
    group), in source position order. Raises, naming the position, when two
    grains carry one position, and, as `merge_cell` does, when two workers
    saw an argument of different types."""
    var na = len(funcs)
    var parts = List[Int]()
    var hints = List[Int]()
    var at_worker = List[Int]()
    var at_index = List[Int]()
    for w in range(len(workers)):
        ref grains = workers[w].grains
        for k in range(len(grains)):
            parts.append(grains[k].partition_id)
            hints.append(grains[k].origin_hint)
            at_worker.append(w)
            at_index.append(k)
    var order = position_order(parts, hints)
    var cell = AggCell()
    for k in range(len(order)):
        var at = order[k]
        if k > 0:
            var before = order[k - 1]
            if parts[before] == parts[at] and hints[before] == hints[at]:
                raise Error(
                    where_
                    + " folds its float aggregates by source position, and two"
                    " morsels carried position (partition "
                    + String(parts[at])
                    + ", origin "
                    + String(hints[at])
                    + "); its source does not stamp one position per morsel"
                )
        var w = at_worker[at]
        ref pos = workers[w]
        ref grain = pos.grains[at_index[at]]
        ref gmap = group_maps[w]
        for j in range(len(grain.groups)):
            var mg = gmap[grain.groups[j]]
            for i in range(na):
                var s = pos.slot_of[i]
                if s < 0:
                    continue
                ref fc = grain.cells[j * pos.np + s]
                cell.kind = IN_FLOAT
                cell.arrow = pos._arrows[s]
                cell.count = fc.count
                cell.fvalue = fc.value
                merge_cell(merged[mg * na + i], cell, funcs[i], labels[i])
