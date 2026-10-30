# =============================================================================
# PublishedOutputs -- the batches finished segments leave for their dependents
# =============================================================================
#
# One slot per segment id. The driver publishes a segment's output when the
# segment has finished; a dependent's builder takes it with `take`. What no one
# took is what `run_plan` returns.

from komira_arrow.schema import RecordBatch


struct PublishedOutputs(Movable):
    """The output batch of each finished segment, by segment id."""

    var _slots: List[Optional[RecordBatch]]

    def __init__(out self, num_segments: Int):
        self._slots = List[Optional[RecordBatch]]()
        for _ in range(num_segments):
            self._slots.append(Optional[RecordBatch]())

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
                "komira_pipeline_exec: publish for segment "
                + String(seg_id)
                + ", which is not in the plan"
            )
        if self._slots[seg_id]:
            raise Error(
                "komira_pipeline_exec: segment "
                + String(seg_id)
                + " published twice"
            )
        self._slots[seg_id] = Optional[RecordBatch](batch^)

    def take(mut self, seg_id: Int) raises -> RecordBatch:
        """Move the output of segment `seg_id` out. Raises when it is not
        there: the segment has not finished, or its output was taken."""
        if not self.has(seg_id):
            raise Error(
                "komira_pipeline_exec: no output of segment "
                + String(seg_id)
                + " is available; it has not finished or it was taken"
            )
        return self._slots[seg_id].take()
