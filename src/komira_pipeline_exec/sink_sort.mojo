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
# Memory. The sink holds, at its peak, the morsels it collected, the one batch
# they are concatenated into, the sorted copy and the key batch with the
# kernel's temporaries (`sort_nulls.sort_scratch_bytes`, a bound). Every byte of
# that is drawn, as it is about to exist, from the segment pool and from a pool
# of the sort's own sized by `SortSinkData.memory_budget` (when positive):
#
#   * a worker draws the buffer bytes of each morsel when it consumes it, so
#     the consume that takes the collected input past either budget fails;
#   * at `combine` the sink draws the concatenation (the bytes kept again),
#     then, once the batch is concatenated and the workers' morsels are gone,
#     the sorted copy and the scratch. The memory budget is therefore a bound on
#     the peak, not on the input;
#   * when the sort is done the sink holds the sorted copy only, and returns it
#     when the output is taken, and when it is dropped without a combine (a
#     failed query).
#
# A denied draw fails the query by name; there is no spill, and nothing is
# truncated. Refused when the sink is built: no sort key, a direction or NULL
# placement list that does not have one entry per key, and, when the schema of
# the rows is known, a key that is not a column of it or whose type cannot be
# sorted (`sort_nulls.check_sort_keys`). When the schema is not known the same
# check runs when the rows are sorted.

from std.memory import ArcPointer

from komira_arrow.schema import RecordBatch, Schema
from komira_column_kernels.compiler_helpers import batch_buffer_bytes
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.pipeline_execution import PipelineExecution
from komira_physical_plan.physical_plan import SortSinkData

from .segment_pool import POOL_UNBOUNDED, SegmentPool, WorkerReservation
from .sink_collect import CollectSink
from .sort_nulls import (
    check_sort_keys,
    resolve_nulls_first,
    sort_batch_with_null_placement,
    sort_scratch_bytes,
)

comptime _DRAWN: Int = 0
comptime _POOL_DENIED: Int = 1
comptime _BUDGET_DENIED: Int = 2


struct _Draw(Movable):
    """A tally against the segment pool and against the sort's own budget."""

    var seg: WorkerReservation
    var cap: WorkerReservation

    def __init__(out self, var seg: SegmentPool, var cap: SegmentPool):
        self.seg = WorkerReservation(seg^)
        self.cap = WorkerReservation(cap^)

    def grow(mut self, bytes: Int) -> Int:
        if not self.cap.try_grow(bytes):
            return _BUDGET_DENIED
        if not self.seg.try_grow(bytes):
            self.cap.release(bytes)
            return _POOL_DENIED
        return _DRAWN

    def give_back_all(mut self):
        self.seg.give_back_all()
        self.cap.give_back_all()


struct SortSink(MorselSinkImpl):
    """Collects the rows of a segment and sorts them by the plan's keys."""

    var _seg_id: Int
    var _keys: List[String]
    var _descending: List[Bool]
    var _nulls_first: List[Bool]
    var _budget: Int
    var _pool: SegmentPool
    var _cap: SegmentPool
    var _inner: CollectSink
    # One draw per worker, each behind its own ArcPointer in a List: a
    # reservation is heap-tracked state, never kept in a Slab mutated through
    # get_mut_interior. A worker touches only the slot of its own task id.
    var _slots: List[ArcPointer[_Draw]]
    var _work: _Draw
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
            check_sort_keys(output_schema.value(), data.sort_keys, where_)
        self._seg_id = seg_id
        self._keys = data.sort_keys.copy()
        self._descending = data.descending.copy()
        self._budget = data.memory_budget
        self._cap = SegmentPool(
            data.memory_budget if data.memory_budget > 0 else POOL_UNBOUNDED
        )
        self._inner = CollectSink(output_schema^)
        self._work = _Draw(pool.share(), self._cap.share())
        self._pool = pool^
        self._slots = List[ArcPointer[_Draw]]()
        self._sorted = None

    def _denied(self, code: Int, what: String, bytes: Int) -> Error:
        var head = (
            "komira_pipeline_exec: the sort sink of segment "
            + String(self._seg_id)
        )
        if code == _BUDGET_DENIED:
            return Error(
                head
                + " would hold more than its memory budget of "
                + String(self._budget)
                + " bytes ("
                + String(bytes)
                + " more for "
                + what
                + "); the in-memory sort does not spill"
            )
        return Error(
            head
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
        self._slots = List[ArcPointer[_Draw]](capacity=num_workers)
        for _ in range(num_workers):
            self._slots.append(
                ArcPointer[_Draw](_Draw(self._pool.share(), self._cap.share()))
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
        var code = self._slots[worker_id][].grow(bytes)
        if code != _DRAWN:
            raise self._denied(code, "a morsel it keeps", bytes)
        self._inner.consume(worker_id, morsel^)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        var kept = 0
        for w in range(len(self._slots)):
            kept += self._slots[w][].seg.used()
        # The concatenation is another batch the size of what was kept.
        var code = self._work.grow(kept)
        if code != _DRAWN:
            raise self._denied(code, "the concatenation", kept)
        self._inner.combine(pipeline)
        var rows = self._inner.take_output()
        for w in range(len(self._slots)):
            self._slots[w][].give_back_all()
        # The workers' morsels are gone; the sorted copy and the key batch with
        # the kernel's temporaries are what the sort adds to `rows`.
        check_sort_keys(
            rows.schema,
            self._keys,
            "komira_pipeline_exec: the sort sink of segment "
            + String(self._seg_id),
        )
        var out_bytes = batch_buffer_bytes(rows)
        var extra = out_bytes + sort_scratch_bytes(rows, self._keys)
        code = self._work.grow(extra)
        if code != _DRAWN:
            raise self._denied(code, "the sorted copy and the key batch", extra)
        var result = sort_batch_with_null_placement(
            rows^, self._keys, self._descending, self._nulls_first
        )
        # Only the sorted copy is left.
        self._work.give_back_all()
        code = self._work.grow(out_bytes)
        if code != _DRAWN:
            raise self._denied(code, "the sorted output", out_bytes)
        self._sorted = Optional(result^)

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
