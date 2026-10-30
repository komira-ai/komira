# =============================================================================
# sink_sort -- (SINK_SORT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)
# =============================================================================
#
# The in-memory sort: the rows of a segment, collected into one batch and
# sorted by the plan's keys. It is the sort of a small result (TPC-H Q1's
# ORDER BY over its four grouped rows); the general sort, the top-N and the
# external sort are later steps.
#
# Collecting is `CollectSink`'s: each worker keeps its morsels in its own slot,
# `combine` orders them by (partition id, origin hint) and concatenates them.
# The sort then runs on that one batch (`sort_nulls.sort_batch_with_null_placement`
# over `komira_op_sort.sort_batch_by_keys`), so ties keep the collected order:
# the order of the source's morsel positions, then worker slots. The keys, their
# directions and their NULL placement are the plan's `SortSinkData`; an empty
# `nulls_first` asks for the engine's default placement.
#
# Memory. Every worker draws the buffer bytes of each morsel it keeps from the
# segment pool, when it consumes the morsel; a denied draw fails the query by
# name. At `combine` the sink draws what the concatenation and the sorted copy
# need besides (twice the bytes kept: the peak is about three copies of the
# input), and refuses when the total passes `SortSinkData.memory_budget` (when
# positive) or the pool. There is no spill: an input that does not fit is
# refused, never truncated. The reservations return to the pool when the output
# is taken, and when the sink is dropped without a combine (a failed query).
#
# Refused when the sink is built: no sort key, a direction list or a NULL
# placement list that does not have one entry per key, and, when the schema of
# the rows is known, a key that is not a column of it.

from std.memory import ArcPointer

from komira_arrow.schema import RecordBatch, Schema
from komira_column_kernels.compiler_helpers import batch_buffer_bytes
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.pipeline_execution import PipelineExecution
from komira_physical_plan.physical_plan import SortSinkData

from .segment_pool import SegmentPool, WorkerReservation
from .sink_collect import CollectSink
from .sort_nulls import resolve_nulls_first, sort_batch_with_null_placement


struct _SortSlot(Movable):
    var reservation: WorkerReservation

    def __init__(out self, var reservation: WorkerReservation):
        self.reservation = reservation^


struct SortSink(MorselSinkImpl):
    """Collects the rows of a segment and sorts them by the plan's keys."""

    var _seg_id: Int
    var _keys: List[String]
    var _descending: List[Bool]
    var _nulls_first: List[Bool]
    var _budget: Int
    var _pool: SegmentPool
    var _inner: CollectSink
    # One slot per worker, each behind its own ArcPointer in a List: a
    # reservation is heap-tracked state, never kept in a Slab mutated through
    # get_mut_interior. A worker touches only the slot of its own task id.
    var _slots: List[ArcPointer[_SortSlot]]
    var _work: WorkerReservation
    var _sorted: Optional[RecordBatch]

    def __init__(
        out self,
        ref data: SortSinkData,
        var pool: SegmentPool,
        seg_id: Int,
        var output_schema: Optional[Schema],
    ) raises:
        var where_ = (
            "komira_pipeline_exec: the sort sink of segment " + String(seg_id)
        )
        if len(data.sort_keys) == 0:
            raise Error(where_ + " has no sort key")
        if len(data.descending) != len(data.sort_keys):
            raise Error(
                where_
                + " lists "
                + String(len(data.descending))
                + " directions for "
                + String(len(data.sort_keys))
                + " sort keys"
            )
        self._nulls_first = resolve_nulls_first(
            len(data.sort_keys), data.nulls_first, data.descending, where_
        )
        if output_schema:
            ref schema = output_schema.value()
            for k in range(len(data.sort_keys)):
                var found = False
                for c in range(schema.num_columns()):
                    if schema.field_name(c) == data.sort_keys[k]:
                        found = True
                if not found:
                    raise Error(
                        where_
                        + " sorts by '"
                        + data.sort_keys[k]
                        + "', which is not a column of its input"
                    )
        self._seg_id = seg_id
        self._keys = data.sort_keys.copy()
        self._descending = data.descending.copy()
        self._budget = data.memory_budget
        self._inner = CollectSink(output_schema^)
        self._work = WorkerReservation(pool.share())
        self._pool = pool^
        self._slots = List[ArcPointer[_SortSlot]]()
        self._sorted = None

    def _denied(self, what: String, bytes: Int) -> Error:
        return Error(
            "komira_pipeline_exec: the sort sink of segment "
            + String(self._seg_id)
            + " was denied "
            + String(bytes)
            + " bytes for "
            + what
            + " (segment pool budget "
            + String(self._pool.budget())
            + ", granted "
            + String(self._pool.granted())
            + "); the in-memory sort does not spill"
        )

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._inner.resize_worker_state(num_workers)
        self._slots = List[ArcPointer[_SortSlot]](capacity=num_workers)
        for _ in range(num_workers):
            self._slots.append(
                ArcPointer[_SortSlot](
                    _SortSlot(WorkerReservation(self._pool.share()))
                )
            )

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if worker_id < 0 or worker_id >= len(self._slots):
            raise Error(
                "komira_pipeline_exec: the sort sink holds "
                + String(len(self._slots))
                + " worker slots, got worker "
                + String(worker_id)
            )
        var bytes = batch_buffer_bytes(morsel.batch)
        ref slot = self._slots[worker_id][]
        if not slot.reservation.try_grow(bytes):
            raise self._denied("a morsel it keeps", bytes)
        self._inner.consume(worker_id, morsel^)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        var kept = 0
        for w in range(len(self._slots)):
            kept += self._slots[w][].reservation.used()
        if self._budget > 0 and kept > self._budget:
            raise Error(
                "komira_pipeline_exec: the sort sink of segment "
                + String(self._seg_id)
                + " collected "
                + String(kept)
                + " bytes, over its memory budget of "
                + String(self._budget)
                + "; the in-memory sort does not spill"
            )
        # The concatenation and the sorted copy are two more batches the size
        # of what was kept.
        if not self._work.try_grow(2 * kept):
            raise self._denied("the concatenation and the sorted copy", 2 * kept)
        self._inner.combine(pipeline)
        var rows = self._inner.take_output()
        for w in range(len(self._slots)):
            self._slots[w][].reservation.give_back_all()
        self._sorted = Optional(
            sort_batch_with_null_placement(
                rows^, self._keys, self._descending, self._nulls_first
            )
        )

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._sorted:
            raise Error(
                "komira_pipeline_exec: the sort sink was read before it was"
                " combined"
            )
        var out = self._sorted.take()
        self._work.give_back_all()
        return out^
