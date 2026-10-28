# =============================================================================
# sink_collect -- SINK_COLLECT, the rows of a segment as one batch
# =============================================================================
#
# `CollectSink` keeps every morsel a worker hands it in that worker's own slot
# (indexed by worker id; `consume` writes only the caller's slot). A morsel
# that still carries a selection mask is gathered first, so what the sink
# holds is dense, and a morsel with no rows is not kept.
#
# `combine` runs once after every worker has joined. It orders the morsels by
# the position the source stamped on them, (partition id, origin hint), so a
# scan collects in file order whatever the schedule was; morsels with the same
# position keep the order of the workers that held them and, within a worker,
# the order they arrived in. `take_output` concatenates them into one batch.
#
# A segment with no output rows still has an output schema: the sink is built
# with the schema the segment's rows would have had, and `take_output` returns
# a batch of that schema with no rows. A sink built without one refuses to
# answer an empty segment, by name.
#
# The concatenation is `komira_arrow`'s N-way concat on the calling thread. The
# parallel concat of `komira_engine_runtime` needs a dispatcher and a token of
# its own; the sink trait gives `combine` neither, so a later slice that wants
# the fan-out adds it where the dispatch is in hand.

from std.builtin.swap import swap

from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.schema import RecordBatch, Schema
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import (
    empty_batch_like_schema,
    materialize_selection_if_present,
)
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.pipeline_execution import PipelineExecution


struct _Chunk(Movable):
    """One dense batch and the position the source gave it."""

    var batch: RecordBatch
    var partition_id: Int
    var origin_hint: Int

    def __init__(
        out self, var batch: RecordBatch, partition_id: Int, origin_hint: Int
    ):
        self.batch = batch^
        self.partition_id = partition_id
        self.origin_hint = origin_hint

    def take_batch(deinit self) -> RecordBatch:
        return self.batch^


struct _WorkerSlot(Movable):
    var chunks: List[_Chunk]

    def __init__(out self):
        self.chunks = List[_Chunk]()


def _before(
    a_part: Int, a_hint: Int, b_part: Int, b_hint: Int
) -> Bool:
    """True when position a sorts strictly before position b."""
    if a_part != b_part:
        return a_part < b_part
    return a_hint < b_hint


def _stable_order(parts: List[Int], hints: List[Int]) -> List[Int]:
    """The indices 0..n-1 sorted by (part, hint), equal positions in index
    order (a bottom-up merge sort)."""
    var n = len(parts)
    var order = List[Int](capacity=n)
    for i in range(n):
        order.append(i)
    var scratch = List[Int](length=n, fill=0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var l = lo
            var r = mid
            var k = lo
            while l < mid and r < hi:
                var a = order[l]
                var b = order[r]
                if _before(parts[b], hints[b], parts[a], hints[a]):
                    scratch[k] = b
                    r += 1
                else:
                    scratch[k] = a
                    l += 1
                k += 1
            while l < mid:
                scratch[k] = order[l]
                l += 1
                k += 1
            while r < hi:
                scratch[k] = order[r]
                r += 1
                k += 1
            lo += 2 * width
        swap(order, scratch)
        width *= 2
    return order^


struct CollectSink(MorselSinkImpl):
    """Collects the rows of every morsel into one batch."""

    var _empty_schema: Optional[Schema]
    var _slots: Slab[_WorkerSlot]
    var _merged: Slab[RecordBatch]
    var _combined: Bool

    def __init__(out self, var output_schema: Optional[Schema]):
        self._empty_schema = output_schema^
        self._slots = Slab[_WorkerSlot]()
        self._merged = Slab[RecordBatch]()
        self._combined = False

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._slots = Slab[_WorkerSlot](capacity=num_workers)
        for _ in range(num_workers):
            self._slots.append(_WorkerSlot())

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if worker_id < 0 or worker_id >= len(self._slots):
            raise Error(
                "komira_pipeline_exec: the collect sink holds "
                + String(len(self._slots))
                + " worker slots, got worker "
                + String(worker_id)
            )
        var partition_id = morsel.partition_id
        var origin_hint = morsel.origin_hint
        var batch = materialize_selection_if_present(morsel^.take_batch())
        if batch.num_rows() == 0:
            return
        ref slot = self._slots.get_mut_interior(worker_id)
        slot.chunks.append(_Chunk(batch^, partition_id, origin_hint))

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        var parts = List[Int]()
        var hints = List[Int]()
        var at_worker = List[Int]()
        var at_index = List[Int]()
        for w in range(len(self._slots)):
            ref slot = self._slots.get_mut_interior(w)
            for i in range(len(slot.chunks)):
                parts.append(slot.chunks[i].partition_id)
                hints.append(slot.chunks[i].origin_hint)
                at_worker.append(w)
                at_index.append(i)
        var order = _stable_order(parts, hints)
        for k in range(len(order)):
            ref slot = self._slots.get_mut_interior(at_worker[order[k]])
            var chunk = _Chunk(RecordBatch(), 0, 0)
            swap(chunk, slot.chunks[at_index[order[k]]])
            self._merged.append(chunk^.take_batch())
        self._combined = True

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._combined:
            raise Error(
                "komira_pipeline_exec: the collect sink was read before it"
                " was combined"
            )
        if len(self._merged) == 0:
            if not self._empty_schema:
                raise Error(
                    "komira_pipeline_exec: the segment produced no rows and"
                    " its output schema could not be derived"
                )
            return empty_batch_like_schema(self._empty_schema.value())
        var batches = Slab[RecordBatch]()
        swap(batches, self._merged)
        return concat_record_batches_nway(batches^)
