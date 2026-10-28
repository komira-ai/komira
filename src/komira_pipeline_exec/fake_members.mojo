# =============================================================================
# fake_members -- sources, an operator and sinks that record what the driver does
# =============================================================================
#
# Each fake keeps its counters in a shared `Tally` (`fake_support`), so a test
# can say how many morsels were claimed, how often the end of input was seen,
# how many rows reached a sink, whether a sink was combined once and after every
# worker, and whether a sink was destroyed.

from komira_arrow.schema import RecordBatch, Schema
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_exec_types.exec_result import (
    ExecResult,
    FILTERED_EMPTY,
    FINISHED,
    HAVE_MORE_OUTPUT,
    NEED_MORE_INPUT,
)
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.morsel_source import MorselSourceImpl, SourceCapabilities
from komira_morsel.pipeline_execution import PipelineExecution

from .fake_support import (
    MAX_FAKE_WORKERS,
    SLOT_BATCH_CURSOR,
    SLOT_COMBINES,
    SLOT_CONSUMED_MORSELS,
    SLOT_CONSUMED_ROWS,
    SLOT_CURSOR,
    SLOT_EOF_AT_COMBINE,
    SLOT_EOF_SEEN,
    SLOT_EXECUTES,
    SLOT_FINALIZES,
    SLOT_GROW_DENIED,
    SLOT_GROW_HELD,
    SLOT_PER_WORKER_CURSOR,
    SLOT_PER_WORKER_EOF,
    SLOT_PULLED_AFTER_EOF,
    SLOT_SINK_DROPS,
    SLOT_TAKES,
    Tally,
    batch_values,
    fake_values,
    int64_batch,
)


def _note_eof(tally: Tally, worker_id: Int):
    _ = tally.add(SLOT_EOF_SEEN, 1)
    if worker_id >= 0 and worker_id < MAX_FAKE_WORKERS:
        var flag = SLOT_PER_WORKER_EOF + worker_id
        if tally.add(flag, 1) > 0:
            _ = tally.add(SLOT_PULLED_AFTER_EOF, 1)


# ---- sources ----------------------------------------------------------------

comptime SOURCE_CURSOR = 0
"""One shared cursor: morsels 0..n-1 go to whichever worker asks."""
comptime SOURCE_PER_WORKER = 1
"""Worker w gets its own n morsels with keys `w * 100 + j`."""


struct FakeSource(MorselSourceImpl):
    """Emits morsels of `rows` rows. In `SOURCE_CURSOR` mode `n_morsels` morsels
    keyed 0..n-1 are claimed from one cursor; in `SOURCE_PER_WORKER` mode every
    worker gets `n_morsels` of its own. A source built with `fail_at_claim`
    raises on that claim of the shared cursor."""

    var mode: Int
    var n_morsels: Int
    var rows: Int
    var fail_at_claim: Int
    var tally: Tally

    def __init__(
        out self,
        mode: Int,
        n_morsels: Int,
        rows: Int,
        var tally: Tally,
        fail_at_claim: Int = -1,
    ):
        self.mode = mode
        self.n_morsels = n_morsels
        self.rows = rows
        self.fail_at_claim = fail_at_claim
        self.tally = tally^

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        var key: Int
        if self.mode == SOURCE_PER_WORKER:
            var j = self.tally.add(SLOT_PER_WORKER_CURSOR + worker_id, 1)
            if j >= self.n_morsels:
                _note_eof(self.tally, worker_id)
                return None
            key = worker_id * 100 + j
        else:
            var claim = self.tally.add(SLOT_CURSOR, 1)
            if claim == self.fail_at_claim:
                raise Error(
                    "fake source failed at claim " + String(claim)
                )
            if claim >= self.n_morsels:
                _note_eof(self.tally, worker_id)
                return None
            key = claim
        return Morsel(
            int64_batch(fake_values(key, self.rows)), key, worker_id
        )

    def output_schema(self) -> Schema:
        return Schema()

    def partition_hint(self) -> Int:
        return self.n_morsels

    def row_count_hint(self) -> Int:
        return self.n_morsels * self.rows

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()


struct FakeBatchSource(MorselSourceImpl):
    """Emits the values it was given, `chunk_rows` at a time, from one shared
    cursor. The source of a segment that reads a producer's published output."""

    var values: List[Int64]
    var chunk_rows: Int
    var tally: Tally

    def __init__(
        out self, var values: List[Int64], chunk_rows: Int, var tally: Tally
    ):
        self.values = values^
        self.chunk_rows = chunk_rows
        self.tally = tally^

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        var c = self.tally.add(SLOT_BATCH_CURSOR, 1)
        var start = c * self.chunk_rows
        if start >= len(self.values):
            _note_eof(self.tally, worker_id)
            return None
        var stop = start + self.chunk_rows
        if stop > len(self.values):
            stop = len(self.values)
        var chunk = List[Int64]()
        for i in range(start, stop):
            chunk.append(self.values[i])
        return Morsel(int64_batch(chunk), c, worker_id)

    def output_schema(self) -> Schema:
        return Schema()

    def partition_hint(self) -> Int:
        return 1

    def row_count_hint(self) -> Int:
        return len(self.values)

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()


# ---- operator ---------------------------------------------------------------

comptime OP_PASS = 0
"""Leaves the morsel as it is."""
comptime OP_DROP_ODD = 1
"""Reports FILTERED_EMPTY for a morsel whose id is odd."""
comptime OP_ADD = 2
"""Adds `arg` to every value."""
comptime OP_MUL = 3
"""Multiplies every value by `arg`."""
comptime OP_REPEAT = 4
"""Emits each input `arg` times, as HAVE_MORE_OUTPUT chunks."""
comptime OP_FINISH_AT = 5
"""Reports FINISHED on the `arg`-th execute of the tally."""
comptime OP_FAIL_AT = 6
"""Raises on the `arg`-th execute of the tally."""
comptime OP_CANCEL_AT = 7
"""Cancels its token on the `arg`-th execute of the tally."""


struct FakeOp(MorselOperatorImpl):
    """An operator whose behaviour is the `kind` it was built with."""

    var kind: Int
    var arg: Int
    var tally: Tally
    var token: Optional[CancellationToken]
    var _held: List[Int64]
    var _emitted: Int

    def __init__(
        out self,
        kind: Int,
        arg: Int,
        var tally: Tally,
        var token: Optional[CancellationToken] = None,
    ):
        self.kind = kind
        self.arg = arg
        self.tally = tally^
        self.token = token^
        self._held = List[Int64]()
        self._emitted = 0

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        var n = self.tally.add(SLOT_EXECUTES, 1) + 1
        if self.kind == OP_PASS:
            return ExecResult(NEED_MORE_INPUT)
        if self.kind == OP_DROP_ODD:
            if morsel.morsel_id % 2 == 1:
                morsel.replace_batch(RecordBatch())
                return ExecResult(FILTERED_EMPTY)
            return ExecResult(NEED_MORE_INPUT)
        if self.kind == OP_ADD or self.kind == OP_MUL:
            var vals = batch_values(morsel.batch)
            for i in range(len(vals)):
                if self.kind == OP_ADD:
                    vals[i] = vals[i] + Int64(self.arg)
                else:
                    vals[i] = vals[i] * Int64(self.arg)
            morsel.replace_batch(int64_batch(vals))
            return ExecResult(NEED_MORE_INPUT)
        if self.kind == OP_REPEAT:
            if self._emitted == 0:
                self._held = batch_values(morsel.batch)
            else:
                morsel.replace_batch(int64_batch(self._held))
            self._emitted += 1
            if self._emitted < self.arg:
                return ExecResult(HAVE_MORE_OUTPUT)
            self._emitted = 0
            return ExecResult(NEED_MORE_INPUT)
        if self.kind == OP_FINISH_AT:
            if n == self.arg:
                return ExecResult(FINISHED)
            return ExecResult(NEED_MORE_INPUT)
        if self.kind == OP_FAIL_AT:
            if n == self.arg:
                raise Error("fake operator failed at execute " + String(n))
            return ExecResult(NEED_MORE_INPUT)
        if self.kind == OP_CANCEL_AT:
            if n == self.arg and self.token:
                self.token.value().cancel(String("fake operator cancelled"))
            return ExecResult(NEED_MORE_INPUT)
        raise Error("FakeOp: unknown kind " + String(self.kind))


# ---- sinks ------------------------------------------------------------------


struct _SinkSlot(Movable):
    var values: List[Int64]

    def __init__(out self):
        self.values = List[Int64]()


struct FakeSink(MorselSinkImpl):
    """Collects the values of every morsel in the slot of the worker that
    consumed it. `combine` concatenates the slots in worker id order and
    `take_output` gives the result as one batch. With `budget_bytes` >= 0 it
    charges 8 bytes a row against that budget and raises, naming the denial,
    when a morsel does not fit."""

    var tally: Tally
    var budget_bytes: Int
    var _slots: Slab[_SinkSlot]
    var _merged: List[Int64]

    def __init__(out self, var tally: Tally, budget_bytes: Int = -1):
        self.tally = tally^
        self.budget_bytes = budget_bytes
        self._slots = Slab[_SinkSlot]()
        self._merged = List[Int64]()

    def __deinit__(deinit self):
        _ = self.tally.add(SLOT_SINK_DROPS, 1)

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._slots = Slab[_SinkSlot](capacity=num_workers)
        for _ in range(num_workers):
            self._slots.append(_SinkSlot())

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        var rows = morsel.num_rows()
        if self.budget_bytes >= 0:
            var held = self.tally.add(SLOT_GROW_HELD, rows * 8) + rows * 8
            if held > self.budget_bytes:
                _ = self.tally.add(SLOT_GROW_HELD, -(rows * 8))
                _ = self.tally.add(SLOT_GROW_DENIED, 1)
                raise Error(
                    "fake sink: memory budget of "
                    + String(self.budget_bytes)
                    + " bytes denied a grow of "
                    + String(rows * 8)
                    + " bytes"
                )
        ref slot = self._slots.get_mut_interior(worker_id)
        var vals = batch_values(morsel.batch)
        for i in range(len(vals)):
            slot.values.append(vals[i])
        _ = self.tally.add(SLOT_CONSUMED_MORSELS, 1)
        _ = self.tally.add(SLOT_CONSUMED_ROWS, rows)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        _ = self.tally.add(SLOT_COMBINES, 1)
        var eof = self.tally.get(SLOT_EOF_SEEN)
        _ = self.tally.add(SLOT_EOF_AT_COMBINE, eof)
        for w in range(len(self._slots)):
            ref slot = self._slots.get_mut_interior(w)
            for i in range(len(slot.values)):
                self._merged.append(slot.values[i])

    def finalize(mut self) raises:
        _ = self.tally.add(SLOT_FINALIZES, 1)

    def take_output(mut self) raises -> RecordBatch:
        _ = self.tally.add(SLOT_TAKES, 1)
        return int64_batch(self._merged)


struct FakeCountSink(MorselSinkImpl):
    """Counts the rows each worker consumed and outputs the total as a one-row
    batch."""

    var tally: Tally
    var _rows: Slab[_SinkSlot]
    var _total: Int

    def __init__(out self, var tally: Tally):
        self.tally = tally^
        self._rows = Slab[_SinkSlot]()
        self._total = 0

    def __deinit__(deinit self):
        _ = self.tally.add(SLOT_SINK_DROPS, 1)

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._rows = Slab[_SinkSlot](capacity=num_workers)
        for _ in range(num_workers):
            self._rows.append(_SinkSlot())

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        ref slot = self._rows.get_mut_interior(worker_id)
        slot.values.append(Int64(morsel.num_rows()))
        _ = self.tally.add(SLOT_CONSUMED_MORSELS, 1)
        _ = self.tally.add(SLOT_CONSUMED_ROWS, morsel.num_rows())

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        _ = self.tally.add(SLOT_COMBINES, 1)
        for w in range(len(self._rows)):
            ref slot = self._rows.get_mut_interior(w)
            for i in range(len(slot.values)):
                self._total += Int(slot.values[i])

    def finalize(mut self) raises:
        _ = self.tally.add(SLOT_FINALIZES, 1)

    def take_output(mut self) raises -> RecordBatch:
        _ = self.tally.add(SLOT_TAKES, 1)
        var out = List[Int64]()
        out.append(Int64(self._total))
        return int64_batch(out)
