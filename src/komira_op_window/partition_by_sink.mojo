# =============================================================================
# partition_by_sink -- PartitionBySink, the window operator as a MorselSink
# =============================================================================
#
# `PartitionBySink` collects every morsel of a pipeline (each worker appends
# to its own `PartitionBySinkLocal`), folds them into one batch in `combine`,
# and in `finalize` runs the window operator over it on the engine's workers
# (`partition_scan_sink_parallel._execute_partition_by_sink_parallel`, which
# falls back to the single-thread kernel for a small input). Its output is in
# (partition keys ASC ++ order keys per direction) order, NULLs last.
#
# One partition for the executor (`num_partitions` 1): the window needs every
# row of a partition together, and the parallel driver parallelizes inside
# `finalize`.
#
# `PartitionBySinkGlobal` holds an inline Atomic, so it is not Movable: it is
# built in place by `init_global`'s out-parameter.
# =============================================================================

from std.atomic import Atomic
from std.collections.optional import Optional
from std.memory import OwnedPointer

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async_api.worker_pool_traits import KeepAlive
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import (
    materialize_selection_if_present,
)
from komira_operator_api.memory_reservation import MemoryReservation
from komira_operator_api.morsel_sink import (
    FinalizeOutput,
    MorselSink,
    NeverMorselSource,
    PARTITIONS_UNREVIEWED,
    SinkCapabilities,
)
from komira_operator_api.sink_batch_fold import fold_batches_into_one
from komira_physical_plan.physical_plan import PartitionBySinkData

from .partition_scan_sink_parallel import (
    _copy_sink_data,
    _execute_partition_by_sink_parallel,
)


struct PartitionBySinkLocal(Movable, Deinitable):
    """One worker's batches, appended by `consume`, moved out by `combine`."""

    var batches: Slab[RecordBatch]

    def __init__(out self):
        self.batches = Slab[RecordBatch]()

    def num_batches(self) -> Int:
        return len(self.batches)


struct PartitionBySinkGlobal(KeepAlive):
    """The shared state: the one folded batch `combine` builds. Not Movable
    (inline Atomic); built in place by `init_global`."""

    var combined: Optional[RecordBatch]
    var claim: Atomic[DType.int64]

    def __init__(out self):
        self.combined = None
        self.claim = Atomic[DType.int64](Int64(0))

    def __keep_alive(mut self):
        pass


struct PartitionBySink(MorselSink):
    """The window operator of a pipeline, as a `MorselSink`."""

    comptime Local = PartitionBySinkLocal
    comptime Global = PartitionBySinkGlobal
    comptime Output = RecordBatch
    comptime Source = NeverMorselSource

    var _spec: PartitionBySinkData

    def __init__(out self, var spec: PartitionBySinkData):
        self._spec = spec^

    @staticmethod
    def new(var spec: PartitionBySinkData) -> Self:
        return PartitionBySink(spec^)

    def init_local(self) raises -> Self.Local:
        return PartitionBySinkLocal()

    def init_global(self, out sink_global: Self.Global) raises:
        sink_global = PartitionBySinkGlobal()

    def consume[
        o_local: Origin[mut=True], o_global: Origin[mut=True],
    ](
        self,
        worker_id: Int,
        ref [o_local] local: Self.Local,
        ref [o_global] sink_global: Self.Global,
        var batch: RecordBatch,
    ) raises:
        if batch.num_rows() == 0:
            _ = batch^
            return
        # A batch with a selection mask is materialized before it is kept.
        batch = materialize_selection_if_present(batch^)
        if batch.num_rows() == 0:
            _ = batch^
            return
        local.batches.append(batch^)

    def combine[
        o_global: Origin[mut=True], o_mem: Origin[mut=True],
    ](
        self,
        ref [o_global] sink_global: Self.Global,
        var states: Slab[OwnedPointer[Self.Local]],
        ref [o_mem] reservation: MemoryReservation,
    ) raises:
        """Fold every worker's batches, in worker order, into one batch.

        The batches are moved into one staging slab and folded in one sized
        pass (`fold_batches_into_one`), which merges each column's validity
        with its values: a NULL key must stay NULL for the window to group and
        order it. Zero-row batches are dropped; with no rows at all `combined`
        stays empty.
        """
        var n = len(states)
        var states_owned = states^
        var staged = Slab[RecordBatch]()
        for w in range(n):
            var owned_ptr = states_owned.take_slot_unchecked(w)
            var local = owned_ptr^.into_inner()
            var nb = local.num_batches()
            for i in range(nb):
                var b = local.batches.take_slot_unchecked(i)
                if b.num_rows() == 0:
                    _ = b^
                    continue
                staged.append(b^)
            local.batches.set_len_unchecked(0)
            _ = local^
        states_owned.set_len_unchecked(0)
        _ = states_owned^
        if len(staged) == 0:
            _ = staged^
            return
        sink_global.combined = fold_batches_into_one(staged^)

    def num_partitions[o: Origin](
        self, ref [o] sink_global: Self.Global
    ) -> Int:
        return PARTITIONS_UNREVIEWED

    def finalize[disp_o: Origin[mut=True]](
        self,
        var sink_global: Self.Global,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        cancel_token: CancellationToken,
    ) raises -> FinalizeOutput[Self]:
        var out_batch: RecordBatch
        if not sink_global.combined:
            out_batch = RecordBatch()
            _ = sink_global^
        else:
            var batch = sink_global.combined.take()
            _ = sink_global^
            out_batch = _execute_partition_by_sink_parallel(
                batch^,
                _copy_sink_data(self._spec),
                dispatcher_ptr[],
                cancel_token.clone(),
            )
        var out_slab = Slab[Self.Output].create(1)
        out_slab.append(out_batch^)
        return FinalizeOutput[Self](out_slab^)

    def combine_trace_label(self) -> StaticString:
        """This sink's name in the executor's combine trace. Diagnostic only."""
        return "PartitionBySink"

    def capabilities(self) -> SinkCapabilities:
        var caps = SinkCapabilities()
        caps.output_is_batch = True
        return caps
