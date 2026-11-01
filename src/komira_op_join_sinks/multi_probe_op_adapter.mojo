# =============================================================================
# multi_probe_op_adapter -- per-worker operators that run a CASCADE of join
# probes over one morsel: `MultiProbeOpAdapter` (single-key probes) and
# `MultiKeyProbeCascadeAdapter` (composite-key probes)
# =============================================================================
#
# A cascade is a chain of joins against builds that are all finished before
# the probe side streams: probe 0 joins the input morsel against its build,
# probe 1 joins probe 0's output against its build, and so on. Each adapter
# holds its probes in cascade order and, per morsel, runs them in turn on the
# same morsel: each probe replaces `morsel.batch` with its output, which is
# the next probe's input.
#
#   * `MultiProbeOpAdapter` chains `JoinProbeOp`s (single INT64 key each).
#     With one probe it is the probe: the result, HAVE_MORE_OUTPUT included,
#     is returned as the probe returned it.
#   * `MultiKeyProbeCascadeAdapter` chains `MultiKeyJoinProbeOp`s (1 to 8
#     keys each, INNER); a single-key join in such a cascade is a 1-key
#     composite probe, so one probe type covers the whole chain. With one
#     probe it too is the probe.
#
# THE CHAIN NEEDS EVERY PROBE TO FINISH ITS MORSEL IN ONE CALL. A probe that
# returns HAVE_MORE_OUTPUT has put only part of its output in the morsel and
# expects to be called again on the same input before anything downstream
# reads it again; in a chain, the next probe would overwrite that state, and
# the rest of the output would be lost. So with two or more probes, a probe
# that returns HAVE_MORE_OUTPUT is an error (the driver must give a cascade
# only single-shot probes: a perfect-hash or radix INNER, an INNER without a
# worker slot, LEFT, SEMI or ANTI). It is refused, not passed on as a smaller
# answer.
#
# A probe whose output has no rows ends the chain for that morsel: the probes
# after it would see an empty input and produce an empty output. FINISHED from
# any probe ends the chain with FINISHED.
#
# Metrics: the first probe's (every probe sees the same input stream).
# =============================================================================

from komira_collections.slab import Slab
from komira_exec_types.exec_result import ExecResult, FINISHED, NEED_MORE_INPUT
from komira_metrics.metrics_set import MetricsSnapshot
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_op_join_probe.join_probe_op import JoinProbeOp
from komira_op_join_probe.multi_key_probe_op import MultiKeyJoinProbeOp


def _refuse_partial(adapter: StaticString, i: Int, n: Int) raises:
    raise Error(
        String(adapter)
        + ": probe "
        + String(i)
        + " of a "
        + String(n)
        + "-probe cascade returned HAVE_MORE_OUTPUT; a cascade takes only"
        " probes that finish a morsel in one call (the rest of that probe's"
        " output would be lost)"
    )


struct MultiProbeOpAdapter(MorselOperatorImpl):
    """One worker's cascade of single-key `JoinProbeOp`s; see the module
    header. Movable only; one per worker in a `Slab[MultiProbeOpAdapter]`.
    """

    var _inner: Slab[JoinProbeOp]
    var _n: Int

    def __init__(out self, var inner: Slab[JoinProbeOp]) raises:
        """A cascade of `inner`'s probes, in slab order.

        Raises:
            If `inner` is empty.
        """
        self._n = len(inner)
        if self._n == 0:
            raise Error("MultiProbeOpAdapter: a cascade needs at least one probe")
        self._inner = inner^

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Run the probes in order on `morsel`; see the module header."""
        if self._n == 1:
            return self._inner[0].execute(morsel)
        for i in range(self._n):
            var rc = self._inner[i].execute(morsel)
            if rc.is_have_more_output():
                _refuse_partial("MultiProbeOpAdapter", i, self._n)
            if morsel.num_rows() == 0:
                return ExecResult(NEED_MORE_INPUT)
            if rc.is_finished():
                return ExecResult(FINISHED)
        return ExecResult(NEED_MORE_INPUT)

    def metrics_snapshot(self) -> MetricsSnapshot:
        """The first probe's metrics."""
        return self._inner[0].metrics_snapshot()


struct MultiKeyProbeCascadeAdapter(MorselOperatorImpl):
    """One worker's cascade of composite-key `MultiKeyJoinProbeOp`s; see the
    module header. Movable only; one per worker.
    """

    var _inner: Slab[MultiKeyJoinProbeOp]
    var _n: Int

    def __init__(out self, var inner: Slab[MultiKeyJoinProbeOp]) raises:
        """A cascade of `inner`'s probes, in slab order.

        Raises:
            If `inner` is empty.
        """
        self._n = len(inner)
        if self._n == 0:
            raise Error(
                "MultiKeyProbeCascadeAdapter: a cascade needs at least one probe"
            )
        self._inner = inner^

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Run the probes in order on `morsel`; see the module header."""
        if self._n == 1:
            return self._inner[0].execute(morsel)
        for i in range(self._n):
            var rc = self._inner[i].execute(morsel)
            if rc.is_have_more_output():
                _refuse_partial("MultiKeyProbeCascadeAdapter", i, self._n)
            if morsel.num_rows() == 0:
                return ExecResult(NEED_MORE_INPUT)
            if rc.is_finished():
                return ExecResult(FINISHED)
        return ExecResult(NEED_MORE_INPUT)

    def metrics_snapshot(self) -> MetricsSnapshot:
        """The first probe's metrics."""
        return self._inner[0].metrics_snapshot()
