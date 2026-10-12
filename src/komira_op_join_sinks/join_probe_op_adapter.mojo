# =============================================================================
# join_probe_op_adapter -- `JoinProbeOpAdapter`, the one per-worker probe
# operator type a single-key join pipeline constructs
# =============================================================================
#
# A `MorselOperatorImpl` that wraps one `komira_op_join_probe.JoinProbeOp` and
# forwards to it. Every join type and strategy runs the wrapped operator:
#
#   * INNER with a worker slot and the chained table: the resumable arm
#     (HAVE_MORE_OUTPUT until the morsel's matches are drained, then
#     NEED_MORE_INPUT), or the deferred-output arm when a deferred state is
#     given;
#   * INNER over the perfect-hash or radix table, INNER without a worker slot,
#     LEFT, SEMI and ANTI: the whole morsel's output at once (NEED_MORE_INPUT).
#
# The adapter adds no behaviour of its own. It is the type a driver allocates
# per worker (`Slab[JoinProbeOpAdapter]`), so a later change of which operator
# runs which arm is made here rather than in every driver. Its constructor
# takes the wrapped operator's arguments, in the same order and with the same
# defaults, and its metrics are the wrapped operator's.
#
# Keys follow `JoinProbeOp`: a NULL key matches nothing; see that operator for
# the key types each arm takes.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_exec_types.exec_result import ExecResult
from komira_metrics.metrics_set import MetricsSnapshot
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_perfect_hash import PerfectHashJoin
from komira_op_join_probe.join_deferred import JoinDeferredState
from komira_op_join_probe.join_probe_op import JoinProbeOp
from komira_op_join_probe.join_probe_op_state import (
    STRATEGY_STANDARD,
    ColumnarProbeSharedState,
)
from komira_op_join_probe.radix_join import RadixPartitionedHashJoin
from komira_plan_ir.logical_plan import JOIN_INNER


struct JoinProbeOpAdapter(MorselOperatorImpl):
    """One worker's single-key join probe operator; forwards to the wrapped
    `JoinProbeOp` (see the module header).

    Movable only, like the wrapped operator: drivers construct one per worker
    in a `Slab[JoinProbeOpAdapter]`.
    """

    var _inner: JoinProbeOp

    def __init__(
        out self,
        var index: ArcPointer[HashJoinBuilder],
        var build_batch: ArcPointer[RecordBatch],
        var left_key_name: String,
        var right_key_name: String,
        var output_schema: ArcPointer[Schema],
        join_type: UInt8 = JOIN_INNER,
        var shared: Optional[ArcPointer[ColumnarProbeSharedState]] = None,
        local_id: Int = -1,
        strategy: UInt8 = STRATEGY_STANDARD,
        var perfect: Optional[ArcPointer[PerfectHashJoin]] = None,
        var radix: Optional[ArcPointer[RadixPartitionedHashJoin]] = None,
        count_only: Bool = False,
        var deferred: Optional[ArcPointer[JoinDeferredState]] = None,
        nt_store: Bool = True,
        wave_decomp: Bool = False,
    ) raises:
        """Construct the wrapped `JoinProbeOp` from the same arguments; see
        `JoinProbeOp.__init__` for each one."""
        self._inner = JoinProbeOp(
            index^,
            build_batch^,
            left_key_name^,
            right_key_name^,
            output_schema^,
            join_type,
            shared^,
            local_id,
            strategy,
            perfect^,
            radix^,
            count_only,
            deferred^,
            nt_store,
            wave_decomp,
        )

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """The wrapped operator's `execute`, result and all."""
        return self._inner.execute(morsel)

    def metrics_snapshot(self) -> MetricsSnapshot:
        """The wrapped operator's metrics (the adapter records none)."""
        return self._inner.metrics_snapshot()
