# =============================================================================
# topn_stage -- the top-N heap of one INT64 key, ascending or descending
# =============================================================================
#
# `TopNStageScaffoldI64[N]` (capacity N at compile time) and
# `TopNStageScaffoldI64Dynamic` (capacity at run time) keep the N smallest
# (ASC) or N largest (DESC) keys of a stream of (key, row id) pairs and give
# them back in order. Both wrap a max-heap that keeps the N smallest STORED
# keys; for DESC the stored key is `~key` (bitwise NOT), which reverses the
# order of every Int64. Negation does not: `-Int64.MIN` overflows to
# `Int64.MIN`, so a DESC top-N stored by negation would treat the smallest
# key as the largest. The key is un-flipped (`~stored`) on the way out.
# =============================================================================

from komira_expr.expr_sortable_key import SORT_DIR_ASC, SORT_DIR_DESC

from .bounded_heap import (
    BoundedHeapInt64Payload,
    BoundedHeapInt64PayloadDynamic,
    HeapSlot,
)


@always_inline
def _stored_key(key: Int64, sort_dir: UInt8) -> Int64:
    """The heap key: `key` for ASC, `~key` for DESC (order-reversing, and
    its own inverse)."""
    if sort_dir == SORT_DIR_DESC:
        return ~key
    return key


def _emit(var sorted_stored: List[HeapSlot], sort_dir: UInt8) -> List[HeapSlot]:
    """Ascending stored order is the output order in both directions; DESC
    un-flips each key."""
    if sort_dir != SORT_DIR_DESC:
        return sorted_stored^
    var out = List[HeapSlot](capacity=len(sorted_stored))
    for i in range(len(sorted_stored)):
        var e = sorted_stored[i]
        out.append(HeapSlot(~e.key, e.payload_row_id))
    return out^


@fieldwise_init
struct TopNStageScaffoldI64[N: Int](Copyable, Movable):
    """The top-N of one INT64 key, capacity N at compile time.
    `sort_dir` is `SORT_DIR_ASC` (N smallest) or `SORT_DIR_DESC` (N
    largest)."""

    var heap: BoundedHeapInt64Payload[Self.N]
    var sort_dir: UInt8
    var emitted_row_count: Int

    @staticmethod
    def new(sort_dir: UInt8) -> TopNStageScaffoldI64[Self.N]:
        return TopNStageScaffoldI64[Self.N](
            heap=BoundedHeapInt64Payload[Self.N](),
            sort_dir=sort_dir,
            emitted_row_count=0,
        )

    @always_inline
    def push_row(mut self, key: Int64, row_id: Int64):
        self.heap.push(_stored_key(key, self.sort_dir), row_id)

    def finalize_emit(mut self) -> List[HeapSlot]:
        """The kept (key, row id) pairs, best first."""
        var sorted = self.heap.extract_sorted()
        self.emitted_row_count = len(sorted)
        return _emit(sorted^, self.sort_dir)


@fieldwise_init
struct TopNStageScaffoldI64Dynamic(Copyable, Movable):
    """`TopNStageScaffoldI64` with a run-time capacity."""

    var heap: BoundedHeapInt64PayloadDynamic
    var sort_dir: UInt8
    var emitted_row_count: Int

    @staticmethod
    def new(capacity: Int, sort_dir: UInt8) -> TopNStageScaffoldI64Dynamic:
        return TopNStageScaffoldI64Dynamic(
            heap=BoundedHeapInt64PayloadDynamic(capacity=capacity),
            sort_dir=sort_dir,
            emitted_row_count=0,
        )

    @always_inline
    def push_row(mut self, key: Int64, row_id: Int64):
        self.heap.push(_stored_key(key, self.sort_dir), row_id)

    def finalize_emit(mut self) -> List[HeapSlot]:
        """The kept (key, row id) pairs, best first."""
        var sorted = self.heap.extract_sorted()
        self.emitted_row_count = len(sorted)
        return _emit(sorted^, self.sort_dir)
