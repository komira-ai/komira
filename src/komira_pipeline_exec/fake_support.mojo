# =============================================================================
# fake_support -- shared counters and batch helpers for the fake members
# =============================================================================
#
# The fakes that drive the scheduler in tests (`fake_members`, `fake_builder`)
# record what happened to counters in a `Tally`: a row of atomic cells behind a
# shared handle, so a fake inside the driver and the test that built it read and
# write the same cells. Their data is one INT64 column named `v`.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from std.memory import ArcPointer

comptime I64 = DType.int64

# Cells of a Tally.
comptime SLOT_CURSOR = 0
"""The shared claim cursor of a cursor source; it counts every call."""
comptime SLOT_EOF_SEEN = 1
"""How many calls of a source returned None."""
comptime SLOT_PULLED_AFTER_EOF = 2
"""How many calls came from a worker that had already seen None."""
comptime SLOT_EXECUTES = 3
"""How many times an operator executed."""
comptime SLOT_CONSUMED_MORSELS = 4
"""How many morsels reached a sink."""
comptime SLOT_CONSUMED_ROWS = 5
"""How many rows reached a sink."""
comptime SLOT_COMBINES = 6
"""How many times a sink combined."""
comptime SLOT_FINALIZES = 7
"""How many times a sink finalized."""
comptime SLOT_TAKES = 8
"""How many times a sink gave its output away."""
comptime SLOT_SINK_DROPS = 9
"""How many sinks were destroyed."""
comptime SLOT_EOF_AT_COMBINE = 10
"""The value of `SLOT_EOF_SEEN` when a sink combined."""
comptime SLOT_GROW_HELD = 11
"""Bytes a sink holds against its budget."""
comptime SLOT_GROW_DENIED = 12
"""How many grows a sink's budget denied."""
comptime SLOT_BATCH_CURSOR = 13
"""The shared claim cursor of a published-batch source."""
comptime SLOT_PER_WORKER_EOF = 16
"""First of 16 cells: cell `SLOT_PER_WORKER_EOF + w` is 1 once worker w saw None."""
comptime SLOT_PER_WORKER_CURSOR = 32
"""First of 16 cells: the claim cursor of worker w of a per-worker source."""
comptime MAX_FAKE_WORKERS = 16
comptime TALLY_SLOTS = 48


struct Tally(Movable):
    """Atomic counters behind a shared handle. `share()` makes a second handle
    on the same cells."""

    var _cells: ArcPointer[Slab[AtomicI64]]

    def __init__(out self):
        self._cells = ArcPointer[Slab[AtomicI64]](
            Slab[AtomicI64].create_prefilled(TALLY_SLOTS)
        )

    def __init__(out self, *, shared_with: Self):
        self._cells = ArcPointer(copy=shared_with._cells)

    def share(self) -> Tally:
        """Another handle on the same cells."""
        return Tally(shared_with=self)

    def add(self, slot: Int, n: Int) -> Int:
        """Add `n` to a cell and return the value it held before."""
        return Int(self._cells[].get_mut_interior(slot).fetch_add(Int64(n)))

    def get(self, slot: Int) -> Int:
        """The current value of a cell."""
        return Int(self._cells[].get_mut_interior(slot).load())


def int64_batch(values: List[Int64]) raises -> RecordBatch:
    """A batch of one INT64 column `v` holding `values`."""
    var n = len(values)
    var arr = PrimitiveArray[I64].allocate(n)
    for i in range(n):
        arr.set(i, values[i])
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[I64](arr^))
    return b.build(sb.build())


def batch_values(ref batch: RecordBatch) raises -> List[Int64]:
    """The values of column 0 of `batch`, which must be INT64."""
    var out = List[Int64]()
    if batch.num_columns() == 0:
        return out^
    var col = batch.column_at(0).as_primitive[I64]()
    for i in range(batch.num_rows()):
        out.append(col.get(i))
    return out^


def fake_values(key: Int, rows: Int) -> List[Int64]:
    """The values of the morsel with key `key` and `rows` rows: `key * 100 + r`
    for r in 0..rows-1. Distinct keys give distinct values while rows < 100."""
    var out = List[Int64]()
    for r in range(rows):
        out.append(Int64(key * 100 + r))
    return out^
