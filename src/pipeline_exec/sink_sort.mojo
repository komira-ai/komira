# =============================================================================
# sink_sort -- (SINK_SORT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR) and
# (SINK_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)
# =============================================================================
#
# The in-memory sort: the rows of a segment, sorted by the plan's keys. Built
# from a `SortSinkData` it answers every row; built from a `TopNSinkData` it
# answers rows [offset, offset + n) of the same order (ORDER BY ... LIMIT n
# OFFSET m), and holds about `offset + n` rows per worker rather than every
# row (none when n is 0). The external sort is a later step.
#
# The order. Ties keep the collected order: the order of the source's morsel
# positions, then worker slots, then the order a worker received its morsels
# (`CollectSink`'s). A top-N answers exactly the rows of that order the full
# sort would put in its range: every row it keeps carries its position in
# hidden columns that break every tie the same way (`sort_range`), so its
# answer is the full sort's slice on any number of workers and any schedule.
# The keys, their directions and their NULL placement are the plan's; an
# empty `nulls_first` asks for the engine's default placement.
#
# The full sort. Collecting is `CollectSink`'s: each worker keeps its morsels
# in its own slot, `combine` orders them by (partition id, origin hint) and
# concatenates them, and the sort runs on that one batch
# (`sort_nulls.sort_batch_with_null_placement` over
# `op_sort.sort_batch_by_keys`).
#
# The top-N. A worker tags each morsel it receives with its position and
# keeps it in its own slot. Once it holds `sort_range.compact_at(offset + n)`
# rows or more, it concatenates and sorts them by the keys and the position
# and keeps the first `offset + n`. `combine` concatenates what every worker
# kept, sorts it the same way, keeps rows [offset, offset + n) and drops the
# hidden columns. With `n` zero, or an offset past the input, the answer has
# no row and the input's schema.
#
# Memory. Every byte the sink holds is drawn, as it is about to exist, from
# the segment pool and from a pool of the sort's own sized by
# `SortSinkData.memory_budget` (when positive; a top-N has no budget of its
# own and draws on the segment pool alone):
#
#   * a worker draws the buffer bytes of each morsel when it consumes it (a
#     top-N: with the hidden columns), so the consume that takes what it holds
#     past either budget fails;
#   * a top-N worker that sorts what it holds draws the concatenation, then
#     the sorted copy with the key batch and the kernel's temporaries
#     (`sort_nulls.sort_scratch_bytes`, a conservative estimate), then the rows
#     it keeps, and takes off its tally each of those as it is freed;
#   * at `combine` the sink draws the concatenation (the bytes kept again),
#     then, once the batch is concatenated and the workers' morsels are gone,
#     the sorted copy and the scratch. The memory budget therefore bounds the
#     estimated peak, not the input;
#   * when the sort is done the sink holds its answer only, and returns it
#     when the output is taken, and when it is dropped without a combine (a
#     failed query).
#
# A denied draw fails the query by name; there is no spill, and nothing is
# truncated. Refused when the sink is built: no sort key, a direction or NULL
# placement list that does not have one entry per key, a top-N count or offset
# below zero, and, when the schema of the rows is known, a key that is not a
# column of it or whose type cannot be sorted (`sort_nulls.check_sort_keys`).
# When the schema is not known the same check runs when the rows are sorted.

from std.builtin.swap import swap
from std.memory import ArcPointer

from arrow.concat import concat_record_batches_nway
from arrow.schema import RecordBatch, Schema
from column_kernels.batch_slice import _slice_batch_first_n, _slice_batch_range
from column_kernels.compiler_helpers import (
    batch_buffer_bytes,
    empty_batch_like_schema,
    materialize_selection_if_present,
)
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.morsel_sink import MorselSinkImpl
from morsel.pipeline_execution import PipelineExecution
from physical_plan.physical_plan import SortSinkData, TopNSinkData

from .segment_pool import (
    MEMORY_BUDGET_EXCEEDED,
    POOL_UNBOUNDED,
    SegmentPool,
    WorkerReservation,
)
from .sink_collect import CollectSink
from .sort_nulls import (
    check_sort_keys,
    resolve_nulls_first,
    sort_batch_with_null_placement,
    sort_scratch_bytes,
)
from .sort_range import (
    TagNames,
    compact_at,
    drop_tags,
    rows_to_keep,
    tag_batch,
    with_tag_order,
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

    def release(mut self, bytes: Int):
        """Take `bytes` that are gone off both tallies."""
        self.seg.release(bytes)
        self.cap.release(bytes)

    def give_back_all(mut self):
        self.seg.give_back_all()
        self.cap.give_back_all()


struct _Kept(Movable):
    """What one worker of a top-N holds: its tagged morsels, or after a cut
    the first rows of their order, and how many rows and drawn bytes that
    is."""

    var chunks: List[RecordBatch]
    var rows: Int
    var bytes: Int
    var tagged: Int
    """The rows this worker has tagged: the next row's sequence."""
    var schema: Optional[Schema]
    """The schema of the rows this worker was handed, without tags."""

    def __init__(out self):
        self.chunks = List[RecordBatch]()
        self.rows = 0
        self.bytes = 0
        self.tagged = 0
        self.schema = None


def _concat(mut chunks: List[RecordBatch]) raises -> RecordBatch:
    """The chunks as one batch, in list order; the list is left empty."""
    var slab = Slab[RecordBatch]()
    for i in range(len(chunks)):
        var one = RecordBatch()
        swap(one, chunks[i])
        slab.append(one^)
    chunks.clear()
    return concat_record_batches_nway(slab^)


@fieldwise_init
struct _Refusal(Movable):
    """A draw a worker's cut was denied: the code, what it was for and how
    many bytes; `code` is `_DRAWN` when nothing was denied."""

    var code: Int
    var what: String
    var bytes: Int

    @staticmethod
    def none() -> _Refusal:
        return _Refusal(_DRAWN, String(""), 0)


def _sort_by_position(
    var rows: RecordBatch,
    keys: List[String],
    descending: List[Bool],
    nulls_first: List[Bool],
) raises -> RecordBatch:
    """`rows`, tagged, sorted by the keys and then by their position."""
    var names = TagNames.of_tagged(rows.schema)
    return sort_batch_with_null_placement(
        rows^,
        names.keys(keys),
        with_tag_order(descending),
        with_tag_order(nulls_first),
    )


def _cut(
    mut kept: _Kept,
    mut draw: _Draw,
    keys: List[String],
    descending: List[Bool],
    nulls_first: List[Bool],
    keep: Int,
) raises -> _Refusal:
    """Sort what one worker holds and keep its first `keep` rows, drawing
    each batch as it is about to exist and taking each off the tally as it is
    freed."""
    var held = kept.bytes
    # The concatenation is another batch the size of what is held.
    var code = draw.grow(held)
    if code != _DRAWN:
        return _Refusal(code, "the concatenation of what a worker holds", held)
    var all = _concat(kept.chunks)
    draw.release(held)
    # The sort's keys include the three hidden ones.
    var extra = held + sort_scratch_bytes(
        all, TagNames.of_tagged(all.schema).keys(keys)
    )
    code = draw.grow(extra)
    if code != _DRAWN:
        return _Refusal(
            code, "the sorted copy and the key batch of a worker", extra
        )
    var sorted = _sort_by_position(all^, keys, descending, nulls_first)
    # The unsorted batch and the kernel's temporaries are gone: the sorted
    # copy, `held` bytes, is what is left.
    draw.release(extra)
    var rows = min(keep, sorted.num_rows())
    var first = _slice_batch_first_n(sorted, rows)
    var first_bytes = batch_buffer_bytes(first)
    code = draw.grow(first_bytes)
    if code != _DRAWN:
        return _Refusal(code, "the rows a worker keeps", first_bytes)
    draw.release(held)
    kept.chunks.append(first^)
    kept.rows = rows
    kept.bytes = first_bytes
    return _Refusal.none()


struct SortSink(MorselSinkImpl):
    """Collects the rows of a segment and sorts them by the plan's keys; a
    top-N keeps a range of that order."""

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
    # A top-N's rows, one slot per worker, held the same way.
    var _kept: List[ArcPointer[_Kept]]
    var _work: _Draw
    var _sorted: Optional[RecordBatch]
    var _top_n: Bool
    """Built from a `TopNSinkData`: answer rows [offset, offset + count)."""
    var _offset: Int
    var _count: Int
    var _keep: Int
    """`offset + count`, the rows of the order a top-N ever needs; 0 when
    `count` is 0."""
    var _schema: Optional[Schema]

    def __init__(
        out self,
        ref data: SortSinkData,
        var pool: SegmentPool,
        seg_id: Int,
        var output_schema: Optional[Schema],
    ) raises:
        """The full sort of `data`."""
        var where_ = Self._where(seg_id)
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
        self._schema = output_schema.copy()
        self._inner = CollectSink(output_schema^)
        self._work = _Draw(pool.share(), self._cap.share())
        self._pool = pool^
        self._slots = List[ArcPointer[_Draw]]()
        self._kept = List[ArcPointer[_Kept]]()
        self._sorted = None
        self._top_n = False
        self._offset = 0
        self._count = 0
        self._keep = 0

    def __init__(
        out self,
        ref data: TopNSinkData,
        var pool: SegmentPool,
        seg_id: Int,
        var output_schema: Optional[Schema],
    ) raises:
        """Rows [data.offset, data.offset + data.n) of the sort of `data`."""
        if data.n < 0 or data.offset < 0:
            raise Error(
                "pipeline_exec: the top-n sink of segment "
                + String(seg_id)
                + " keeps "
                + String(data.n)
                + " rows after "
                + String(data.offset)
                + "; neither may be negative"
            )
        var sort = SortSinkData(
            data.sort_keys.copy(),
            data.descending.copy(),
            0,
            data.nulls_first.copy(),
        )
        self = Self(sort, pool^, seg_id, output_schema^)
        self._top_n = True
        self._offset = data.offset
        self._count = data.n
        # A count of zero answers no row whatever the offset: nothing is held.
        self._keep = 0 if data.n == 0 else rows_to_keep(data.offset, data.n)

    @staticmethod
    def _where(seg_id: Int) -> String:
        return "pipeline_exec: the sort sink of segment " + String(seg_id)

    def _denied(self, code: Int, what: String, bytes: Int) -> Error:
        var head = String(MEMORY_BUDGET_EXCEEDED) + ": " + self._where(
            self._seg_id
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
        self._kept = List[ArcPointer[_Kept]](capacity=num_workers)
        for _ in range(num_workers):
            self._slots.append(
                ArcPointer[_Draw](_Draw(self._pool.share(), self._cap.share()))
            )
            self._kept.append(ArcPointer[_Kept](_Kept()))

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if worker_id < 0 or worker_id >= len(self._slots):
            raise Error(
                "pipeline_exec: the sort sink holds "
                + String(len(self._slots))
                + " worker slots, got worker "
                + String(worker_id)
            )
        if self._top_n:
            self._consume_top_n(worker_id, morsel^)
            return
        var bytes = batch_buffer_bytes(morsel.batch)
        var code = self._slots[worker_id][].grow(bytes)
        if code != _DRAWN:
            raise self._denied(code, "a morsel it keeps", bytes)
        self._inner.consume(worker_id, morsel^)

    def _consume_top_n(self, worker_id: Int, var morsel: Morsel) raises:
        var partition_id = morsel.partition_id
        var origin_hint = morsel.origin_hint
        var batch = materialize_selection_if_present(morsel^.take_batch())
        ref kept = self._kept[worker_id][]
        if not kept.schema:
            kept.schema = Optional(batch.schema.copy())
        var rows = batch.num_rows()
        if rows == 0 or self._keep == 0:
            return
        var names = TagNames.for_input(batch.schema)
        var tagged = tag_batch(
            batch^, names, partition_id, origin_hint, worker_id, kept.tagged
        )
        kept.tagged += rows
        var bytes = batch_buffer_bytes(tagged)
        ref draw = self._slots[worker_id][]
        var code = draw.grow(bytes)
        if code != _DRAWN:
            raise self._denied(code, "a morsel it keeps", bytes)
        kept.chunks.append(tagged^)
        kept.rows += rows
        kept.bytes += bytes
        if kept.rows >= compact_at(self._keep):
            var refused = _cut(
                kept,
                draw,
                self._keys,
                self._descending,
                self._nulls_first,
                self._keep,
            )
            if refused.code != _DRAWN:
                raise self._denied(refused.code, refused.what, refused.bytes)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        if self._top_n:
            self._combine_top_n()
            return
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
        check_sort_keys(rows.schema, self._keys, self._where(self._seg_id))
        var out_bytes = batch_buffer_bytes(rows)
        var extra = out_bytes + sort_scratch_bytes(rows, self._keys)
        code = self._work.grow(extra)
        if code != _DRAWN:
            raise self._denied(code, "the sorted copy and the key batch", extra)
        var result = sort_batch_with_null_placement(
            rows^, self._keys, self._descending, self._nulls_first
        )
        self._hold(result^, out_bytes)

    def _hold(mut self, var result: RecordBatch, bytes: Int) raises:
        """Keep `result`, `bytes` of it drawn, as the answer."""
        # Only the answer is left. It is returned and drawn again, not
        # carried over: against a pool that other segments filled in the gap
        # the draw can be refused. That is a refusal by name and nothing
        # leaks (the sink returns what it holds when it is dropped).
        self._work.give_back_all()
        var code = self._work.grow(bytes)
        if code != _DRAWN:
            raise self._denied(code, "the sorted output", bytes)
        self._sorted = Optional(result^)

    def _empty_answer(self) raises -> RecordBatch:
        """A top-N's answer when no worker holds a row: no row, under the
        schema of the rows the sink was built for or was handed."""
        var schema = self._schema.copy()
        for w in range(len(self._kept)):
            if not schema and self._kept[w][].schema:
                schema = self._kept[w][].schema.copy()
        if not schema:
            raise Error(
                self._where(self._seg_id)
                + " produced no rows and its output schema could not be"
                " derived"
            )
        check_sort_keys(schema.value(), self._keys, self._where(self._seg_id))
        return empty_batch_like_schema(schema.value())

    def _combine_top_n(mut self) raises:
        var held = 0
        var chunks = List[RecordBatch]()
        for w in range(len(self._kept)):
            ref kept = self._kept[w][]
            held += kept.bytes
            for i in range(len(kept.chunks)):
                var one = RecordBatch()
                swap(one, kept.chunks[i])
                chunks.append(one^)
            kept.chunks.clear()
            kept.rows = 0
            kept.bytes = 0
        if len(chunks) == 0:
            for w in range(len(self._slots)):
                self._slots[w][].give_back_all()
            self._hold(self._empty_answer(), 0)
            return
        var code = self._work.grow(held)
        if code != _DRAWN:
            raise self._denied(code, "the concatenation", held)
        var rows = _concat(chunks)
        for w in range(len(self._slots)):
            self._slots[w][].give_back_all()
        check_sort_keys(rows.schema, self._keys, self._where(self._seg_id))
        var extra = held + sort_scratch_bytes(
            rows, TagNames.of_tagged(rows.schema).keys(self._keys)
        )
        code = self._work.grow(extra)
        if code != _DRAWN:
            raise self._denied(code, "the sorted copy and the key batch", extra)
        var sorted = _sort_by_position(
            rows^, self._keys, self._descending, self._nulls_first
        )
        var start = min(self._offset, sorted.num_rows())
        var length = min(self._count, sorted.num_rows() - start)
        var answer = drop_tags(_slice_batch_range(sorted, start, length))
        var answer_bytes = batch_buffer_bytes(answer)
        self._hold(answer^, answer_bytes)

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._sorted:
            raise Error(
                "pipeline_exec: the sort sink was read before it was"
                " combined"
            )
        var out = self._sorted.take()
        self._work.give_back_all()
        return out^
