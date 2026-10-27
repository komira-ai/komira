# =============================================================================
# Multi-key top-K over a RecordBatch by a bounded heap: O(N log K)
# =============================================================================
#
# The heap holds the row indices of the K best rows seen so far, the WORST of
# them on top (the eviction candidate). Each later row replaces the top when
# it sorts strictly before it. The K survivors are then insertion-sorted and
# gathered.
#
# Keys compare lexicographically, key 0 first, each in its own direction. Two
# rows that tie on every key compare by row index, the earlier row first, so
# the order is total: the rows kept and the order they come out in are those
# of a stable full sort, in both directions.
# Four key types have a comparator arm: INT64, INT32, FLOAT64 and STRING
# (byte-wise, the shorter first on a shared prefix: DuckDB's default VARCHAR
# collation). FLOAT64 orders by `sort.sort_key_lt` (NaN above +inf). The
# router (`sort_topn_sink._heap_can_order_all_keys`) sends only those types
# here; anything else raises rather than comparing as "equal".
#
# The comparator reads values, not validity: the router keeps a STRING key
# that carries NULLs away from the heap. A numeric key is compared by its
# stored value on the heap and on the full-sort routes alike.
#
# A key column is read as the type the schema reports, so its stored type must
# be that type: a numeric-dictionary column (stored as codes, reported as the
# value type) is refused here and kept away from the heap by the router.
#
# The key columns are read through `KeyColumnView`s whose origin is the
# batch's, so the compiler holds the batch alive for every read and no
# wildcard origin is needed.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.key_column_view import KeyColumnView
from komira_arrow.record_batch import RecordBatch
from komira_physical_plan.physical_plan import TopNSinkData

from .sort import sort_key_lt


comptime _KEY_I64: Int = 0
comptime _KEY_F64: Int = 1
comptime _KEY_I32: Int = 2
comptime _KEY_STR: Int = 3


struct _HeapKeys[o: Origin[mut=False]](Movable):
    """The sort keys of one batch, as typed read-only views.

    Key `i` is of kind `kinds[i]` and lives at `slots[i]` in that kind's
    view list (a STRING key has one entry in `str_offs` and one in
    `str_data`)."""

    var kinds: List[Int]
    var slots: List[Int]
    var desc: List[Bool]
    var i64: List[KeyColumnView[DType.int64, Self.o]]
    var f64: List[KeyColumnView[DType.float64, Self.o]]
    var i32: List[KeyColumnView[DType.int32, Self.o]]
    # A STRING key's offsets, already shifted by the column's `_offset`, so
    # row r spans data[offs[r], offs[r + 1]).
    var str_offs: List[KeyColumnView[DType.int32, Self.o]]
    var str_data: List[KeyColumnView[DType.uint8, Self.o]]

    def __init__(
        out self,
        ref [Self.o] batch: RecordBatch,
        topn_data: TopNSinkData,
    ) raises:
        self.kinds = List[Int]()
        self.slots = List[Int]()
        self.desc = List[Bool]()
        self.i64 = List[KeyColumnView[DType.int64, Self.o]]()
        self.f64 = List[KeyColumnView[DType.float64, Self.o]]()
        self.i32 = List[KeyColumnView[DType.int32, Self.o]]()
        self.str_offs = List[KeyColumnView[DType.int32, Self.o]]()
        self.str_data = List[KeyColumnView[DType.uint8, Self.o]]()
        var n = batch.num_rows()
        for i in range(len(topn_data.sort_keys)):
            var name = topn_data.sort_keys[i]
            var ci = batch.schema.column_index(name)
            var at = batch.schema.field_arrow_type(ci)
            ref col = batch.column_at(ci)
            if col.arrow_type != at:
                raise Error(
                    "_topn_heap: key column '" + name + "' is stored as type "
                    + String(col.arrow_type) + " but its schema type is "
                    + String(at)
                )
            var off = col._offset
            self.desc.append(topn_data.descending[i])
            # SAFETY: each pointer is borrowed from a buffer of `batch`'s
            # column `ci`. `column_at` hands back a sub-origin of the batch;
            # it is re-labelled onto the batch origin `Self.o`, which bounds
            # it (the batch owns its columns). The views never outlive
            # `Self.o`, and each is read only at rows < `n` (offsets: < n+1).
            if at == ArrowType.INT64:
                var v = col._data.view_ro()
                var p = v._unsafe_ptr().bitcast[Scalar[DType.int64]]()
                self.kinds.append(_KEY_I64)
                self.slots.append(len(self.i64))
                self.i64.append(KeyColumnView[DType.int64, Self.o](
                    p.unsafe_origin_cast[Self.o]() + off, n
                ))
            elif at == ArrowType.FLOAT64:
                var v = col._data.view_ro()
                var p = v._unsafe_ptr().bitcast[Scalar[DType.float64]]()
                self.kinds.append(_KEY_F64)
                self.slots.append(len(self.f64))
                self.f64.append(KeyColumnView[DType.float64, Self.o](
                    p.unsafe_origin_cast[Self.o]() + off, n
                ))
            elif at == ArrowType.INT32:
                var v = col._data.view_ro()
                var p = v._unsafe_ptr().bitcast[Scalar[DType.int32]]()
                self.kinds.append(_KEY_I32)
                self.slots.append(len(self.i32))
                self.i32.append(KeyColumnView[DType.int32, Self.o](
                    p.unsafe_origin_cast[Self.o]() + off, n
                ))
            elif at == ArrowType.STRING:
                if col.arrow_type != ArrowType.STRING or not col._offsets:
                    raise Error(
                        "_topn_heap: STRING key column '" + name
                        + "' has no offsets buffer"
                    )
                var ov = col._offsets.value().view_ro()
                var op = ov._unsafe_ptr().bitcast[Scalar[DType.int32]]()
                var dv = col._data.view_ro()
                var dp = dv._unsafe_ptr()
                self.kinds.append(_KEY_STR)
                self.slots.append(len(self.str_offs))
                self.str_offs.append(KeyColumnView[DType.int32, Self.o](
                    op.unsafe_origin_cast[Self.o]() + off, n + 1
                ))
                self.str_data.append(KeyColumnView[DType.uint8, Self.o](
                    dp.unsafe_origin_cast[Self.o](), dv.len()
                ))
            else:
                raise Error(
                    "_topn_heap: unsupported key type " + String(at)
                    + " for column '" + name + "'"
                )

    @always_inline
    def row_before(self, a: Int, b: Int) -> Bool:
        """True iff row `a` sorts strictly before row `b`: by the keys, and
        when every key ties, the earlier row first."""
        for i in range(len(self.kinds)):
            var kind = self.kinds[i]
            var s = self.slots[i]
            var c: Int
            if kind == _KEY_I64:
                c = _cmp3(self.i64[s].get(a), self.i64[s].get(b))
            elif kind == _KEY_F64:
                c = _cmp3(self.f64[s].get(a), self.f64[s].get(b))
            elif kind == _KEY_I32:
                c = _cmp3(self.i32[s].get(a), self.i32[s].get(b))
            else:
                c = _str_cmp3(self.str_offs[s], self.str_data[s], a, b)
            if c != 0:
                return c > 0 if self.desc[i] else c < 0
        return a < b


@always_inline
def _cmp3[dt: DType](a: Scalar[dt], b: Scalar[dt]) -> Int:
    """-1 / 0 / +1 in the `sort_key_lt` order."""
    if sort_key_lt(a, b):
        return -1
    if sort_key_lt(b, a):
        return 1
    return 0


@always_inline
def _str_cmp3[o: Origin[mut=False]](
    offs: KeyColumnView[DType.int32, o],
    data: KeyColumnView[DType.uint8, o],
    a: Int,
    b: Int,
) -> Int:
    """Three-way byte-wise compare of two STRING rows: the common prefix byte
    by byte, UNSIGNED (a 0xC3 lead byte sorts after every ASCII byte), then
    the shorter string first."""
    var a_start = Int(offs.get(a))
    var a_len = Int(offs.get(a + 1)) - a_start
    var b_start = Int(offs.get(b))
    var b_len = Int(offs.get(b + 1)) - b_start
    var m = a_len if a_len < b_len else b_len
    for i in range(m):
        var ca = data.get(a_start + i)
        var cb = data.get(b_start + i)
        if ca != cb:
            return -1 if ca < cb else 1
    if a_len == b_len:
        return 0
    return -1 if a_len < b_len else 1


def topn_heap_select(
    batch: RecordBatch, topn_data: TopNSinkData
) raises -> List[Int]:
    """The row indices of the first `topn_data.n` rows of `batch` in sort
    order (fewer when the batch is shorter), tied rows in input order. Every
    key must be INT64, FLOAT64, INT32 or STRING, stored as that type; another
    type raises."""
    var keys = _HeapKeys(batch, topn_data)
    var num_rows = batch.num_rows()
    var k = min(topn_data.n, num_rows)
    var heap = List[Int](capacity=max(k, 1))
    if k <= 0:
        return heap^

    # PERF-CRITICAL: O(N log K). The first K rows build the heap; each later
    # row costs one comparison against the top unless it gets in.
    for row in range(k):
        heap.append(row)
        _sift_up(heap, len(heap) - 1, keys)
    for row in range(k, num_rows):
        if keys.row_before(row, heap[0]):
            heap[0] = row
            _sift_down(heap, 0, keys)

    # Heap order is not sort order: insertion-sort the K survivors.
    for i in range(1, k):
        var cur = heap[i]
        var j = i
        while j > 0 and keys.row_before(cur, heap[j - 1]):
            heap[j] = heap[j - 1]
            j -= 1
        heap[j] = cur
    return heap^


def _sift_up[o: Origin[mut=False]](
    mut heap: List[Int], var idx: Int, keys: _HeapKeys[o]
):
    """Move `heap[idx]` up while its parent sorts before it (the parent must
    be the worse of the two)."""
    while idx > 0:
        var parent = (idx - 1) // 2
        if not keys.row_before(heap[parent], heap[idx]):
            break
        var tmp = heap[parent]
        heap[parent] = heap[idx]
        heap[idx] = tmp
        idx = parent


def _sift_down[o: Origin[mut=False]](
    mut heap: List[Int], var idx: Int, keys: _HeapKeys[o]
):
    """Move `heap[idx]` down until no child sorts after it (the top is the
    worst of the K)."""
    var n = len(heap)
    while True:
        var worst = idx
        var left = 2 * idx + 1
        var right = 2 * idx + 2
        if left < n and keys.row_before(heap[worst], heap[left]):
            worst = left
        if right < n and keys.row_before(heap[worst], heap[right]):
            worst = right
        if worst == idx:
            break
        var tmp = heap[idx]
        heap[idx] = heap[worst]
        heap[worst] = tmp
        idx = worst
