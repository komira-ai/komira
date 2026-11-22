# =============================================================================
# PublishedOutputs -- the batches finished segments leave for their dependents
# =============================================================================
#
# One slot per segment id. The driver publishes a segment's output when the
# segment has finished; a dependent's builder takes it with `take`. What no one
# took is what `run_plan` returns.
#
# A segment's output may have several readers: every SOURCE_SINK_OUTPUT and
# SOURCE_CONCAT of the plan that names it in its source spec is one reader,
# and a concatenation that names it twice is two (a shared subplan that
# lowering cut once, read by every reference to it). Built from the plan,
# the outputs count each segment's readers; `take` hands each reader but the
# last a copy of the batch and the last one the batch itself, so every reader
# sees the same rows and the slot is empty once all of them have read it.
# Built from a segment count alone, no slot has a counted reader and `take`
# moves the batch out on the first call.

from arrow.schema import RecordBatch
from column_kernels.compiler_helpers import copy_batch
from physical_plan.physical_plan import (
    SegmentDescPod,
    SOURCE_CONCAT,
    SOURCE_SINK_OUTPUT,
)


struct PublishedOutputs(Movable):
    """The output batch of each finished segment, by segment id."""

    var _slots: List[Optional[RecordBatch]]
    var _readers: List[Int]
    """Per segment, the readers that have not taken its output yet."""

    def __init__(out self, num_segments: Int):
        self._slots = List[Optional[RecordBatch]]()
        self._readers = List[Int]()
        for _ in range(num_segments):
            self._slots.append(Optional[RecordBatch]())
            self._readers.append(0)

    def __init__(out self, ref descs: List[SegmentDescPod]):
        """One slot per segment of `descs`, each counting the source specs of
        `descs` that read it. An id outside the plan is not counted; the
        builder refuses the segment that names it."""
        self._slots = List[Optional[RecordBatch]]()
        self._readers = List[Int]()
        for _ in range(len(descs)):
            self._slots.append(Optional[RecordBatch]())
            self._readers.append(0)
        for i in range(len(descs)):
            ref desc = descs[i]
            if (
                desc.source_kind != SOURCE_SINK_OUTPUT
                and desc.source_kind != SOURCE_CONCAT
            ):
                continue
            ref ids = desc.source_spec.dep_seg_ids
            for j in range(len(ids)):
                if ids[j] >= 0 and ids[j] < len(descs):
                    self._readers[ids[j]] += 1

    def num_segments(self) -> Int:
        return len(self._slots)

    def has(self, seg_id: Int) -> Bool:
        """True when segment `seg_id` published an output nobody took."""
        if seg_id < 0 or seg_id >= len(self._slots):
            return False
        return Bool(self._slots[seg_id])

    def publish(mut self, seg_id: Int, var batch: RecordBatch) raises:
        """Store the output of segment `seg_id`. Raises when the id is outside
        the plan or the segment already published."""
        if seg_id < 0 or seg_id >= len(self._slots):
            raise Error(
                "pipeline_exec: publish for segment "
                + String(seg_id)
                + ", which is not in the plan"
            )
        if self._slots[seg_id]:
            raise Error(
                "pipeline_exec: segment "
                + String(seg_id)
                + " published twice"
            )
        self._slots[seg_id] = Optional[RecordBatch](batch^)

    def take(mut self, seg_id: Int) raises -> RecordBatch:
        """The output of segment `seg_id` for one reader: a copy while more
        than one counted reader is left, and otherwise the batch itself, moved
        out. Raises when it is not there: the segment has not finished, or its
        last reader took it."""
        if not self.has(seg_id):
            raise Error(
                "pipeline_exec: no output of segment "
                + String(seg_id)
                + " is available; it has not finished or it was taken"
            )
        if self._readers[seg_id] > 1:
            self._readers[seg_id] -= 1
            return copy_batch(self._slots[seg_id].value())
        self._readers[seg_id] = 0
        return self._slots[seg_id].take()
