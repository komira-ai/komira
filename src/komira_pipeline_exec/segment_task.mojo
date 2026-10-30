# =============================================================================
# segment_task -- the worker body of one segment
# =============================================================================
#
# `SegmentRun` is the state one segment's workers share for the dispatch
# window: the source, the operator instances (one chain per worker, in one
# slab), the sink, the pipeline's cancel flag and first-error slot, and the
# caller's cancellation token. `SegmentTask` is the unit the dispatcher runs
# once per worker; its task id is the worker id.
#
# A worker loops: at each morsel boundary it reads the cancel flag and the
# token and stops if either is set; it claims a morsel from the source, which
# returns None at the end of input and is not called again by that worker;
# it runs the operator chain; it hands what is left to the sink. A raise at any
# step is recorded in the first-error slot, which keeps the first error and
# drops the rest, and sets the cancel flag so the other workers stop at their
# next boundary.

from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_arrow.schema import RecordBatch
from komira_exec_types.engine_error import EngineError
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.morsel_source import MorselSourceImpl
from komira_morsel.pipeline_execution import PipelineExecution
from komira_phase_timers.phase_timers import (
    PH_CLAIM,
    PH_END_STAMP,
    PH_OPS,
    PH_SINK,
    PH_TASK,
    pt_now,
    pt_record,
    pt_record_wake,
    pt_stamp,
)
from std.builtin.swap import swap
from std.memory import UnsafePointer


struct SegmentRun[
    S: MorselSourceImpl, O: MorselOperatorImpl, K: MorselSinkImpl
](KeepAlive):
    """The state the workers of one segment share. Not movable: it holds the
    pipeline's atomics, and the dispatcher borrows it for the dispatch window."""

    var source: Self.S
    var ops: List[Self.O]
    var sink: Self.K
    var pipeline: PipelineExecution
    var token: CancellationToken
    var n_ops: Int

    def __init__(
        out self,
        var source: Self.S,
        var ops: List[Self.O],
        var sink: Self.K,
        num_workers: Int,
        n_ops: Int,
        var token: CancellationToken,
    ) raises:
        self.source = source^
        self.ops = ops^
        self.sink = sink^
        self.pipeline = PipelineExecution(num_workers, n_ops)
        self.token = token^
        self.n_ops = n_ops

    def should_stop(self) -> Bool:
        """True when the pipeline was cancelled (by a failed worker) or the
        caller cancelled the token."""
        return self.pipeline.is_cancelled() or self.token.is_cancelled()

    def fail(mut self, err: Error):
        """Record `err` if it is the first error, and cancel the pipeline."""
        _ = self.pipeline.set_error_cas(EngineError.from_error(err))
        self.pipeline.cancel()


def _push[
    S: MorselSourceImpl, O: MorselOperatorImpl, K: MorselSinkImpl
](
    mut run: SegmentRun[S, O, K], wid: Int, first_op: Int, var m: Morsel
) raises -> Bool:
    """Run `m` through operators `first_op` onward, then into the sink.

    An operator that returns HAVE_MORE_OUTPUT is executed again on the same
    morsel until it does not; each chunk it leaves is pushed on through the
    rest of the chain before the next is asked for. A morsel with no rows is
    dropped. A cancel is checked before each further chunk is asked for, so a
    cancel does not wait for an operator to finish emitting. Returns True when
    the worker must stop claiming: an operator reported FINISHED (the rows it
    held still go on) or the run was cancelled.
    """
    var finished = False
    var i = first_op
    while i < run.n_ops:
        # The operator is borrowed afresh at each call: the recursive push
        # below borrows `run` mutably, so no reference into `ops` may live
        # across it.
        var op_index = wid * run.n_ops + i
        var t_op = pt_now()
        var rc = run.ops[op_index].execute(m)
        pt_record[PH_OPS](t_op)
        while rc.is_have_more_output():
            if m.num_rows() > 0:
                var chunk = RecordBatch()
                swap(chunk, m.batch)
                var chunk_morsel = Morsel(
                    chunk^, m.morsel_id, m.partition_id, m.origin_hint
                )
                if _push(run, wid, i + 1, chunk_morsel^):
                    return True
            if run.should_stop():
                return True
            var t_more = pt_now()
            rc = run.ops[op_index].execute(m)
            pt_record[PH_OPS](t_more)
        if rc.is_finished():
            finished = True
        if rc.is_filtered_empty() or m.num_rows() == 0:
            return finished
        i += 1
    if m.num_rows() > 0:
        var t_sink = pt_now()
        run.sink.consume(wid, m^)
        pt_record[PH_SINK](t_sink)
    return finished


def _work[
    S: MorselSourceImpl, O: MorselOperatorImpl, K: MorselSinkImpl
](mut run: SegmentRun[S, O, K], wid: Int) raises:
    while True:
        if run.should_stop():
            return
        var t_claim = pt_now()
        var maybe = run.source.next_morsel(wid)
        pt_record[PH_CLAIM](t_claim)
        if not maybe:
            return
        if _push(run, wid, 0, maybe.take()):
            return


struct SegmentTask[
    S: MorselSourceImpl, O: MorselOperatorImpl, K: MorselSinkImpl
](Segment):
    """The unit the dispatcher runs once per worker."""

    var _pad: Int32

    def __init__(out self):
        self._pad = 0

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # The state must be the `SegmentRun` this task was instantiated for; a
        # wrong instantiation fails to compile instead of reinterpreting bytes.
        comptime assert (
            State == SegmentRun[Self.S, Self.O, Self.K]
        ), "SegmentTask.execute: the dispatch state must be SegmentRun[S, O, K]"
        # SAFETY: the comptime assert above proves `State` is exactly
        # `SegmentRun[S, O, K]`, so the bitcast is the identity. Each task
        # touches only the slots of its own task id (its operator chain in
        # `ops` and the sink's slot); everything shared is atomic or read-only
        # during the dispatch window. The task id, not the worker id, indexes
        # the slots: a dispatcher may run several tasks on one worker, or name
        # its workers by any numbering.
        var sp = UnsafePointer(to=state).bitcast[SegmentRun[Self.S, Self.O, Self.K]]()
        var wid = Int(task_id)
        pt_record_wake()
        var t_task = pt_now()
        try:
            _work(sp[], wid)
        except e:
            sp[].fail(e)
        pt_record[PH_TASK](t_task)
        pt_stamp[PH_END_STAMP]()
