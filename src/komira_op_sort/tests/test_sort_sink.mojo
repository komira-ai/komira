# =============================================================================
# SortSink: every route gives the rows of one serial sort, on a live pool
# =============================================================================
#
# Each case feeds batches to `SortSink` as several workers would (one local
# per worker), runs `combine`, `combine_partition` for every partition the
# sink reports, and `finalize` on a real 4-worker dispatcher, then compares
# the output with `_execute_sort_sink` over all the rows in worker order: the
# same keys and the same payload (the input row) in every row.
#
# The route is asserted too, so a case cannot pass on a route it did not take:
#
#   * partitioned INT64 (3 partitions, `combine_partition` sorts each,
#     finalize merges): ASC and DESC; FLOAT64 with NaNs of both signs and both
#     zeros, which the merge's flat key has to order as `sort_key_lt`;
#   * partitioned STRING (a high-cardinality key);
#   * the dense-rank counting sort (a low-cardinality STRING key, with NULLs;
#     no partitions);
#   * serial: routes switched off, two keys, one worker, a small input under
#     the default floor, and no rows at all.
#
# Also pinned: a batch with a selection mask loses its rejected rows
# (`test_selection_masked_batches_*`); `routes.dictrank_max_distinct` declines
# the counting sort (`test_dictrank_ceiling_*`); and the row floor is inclusive
# (`test_total_rows_at_the_floor_*`).
#
# One worker (one partition) takes the serial route: a lone partition is never
# sorted by `combine_partition`, so the sink must not choose the partitioned
# route for it (`test_one_worker_takes_serial_route`).
# =============================================================================

from std.memory import bitcast, OwnedPointer
from std.math import inf
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.string_array import StringArray
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_collections.slab import Slab
from komira_operator_api.memory_reservation import MemoryReservation
from komira_physical_plan.physical_plan import SortSinkData

from komira_op_sort.sort_sink import SortSink, SortSinkLocal, SortSinkRoutes
from komira_op_sort.sort_topn_sink import _execute_sort_sink


comptime _ROUTE_SERIAL: Int = 0
comptime _ROUTE_PARTITIONED: Int = 1
comptime _ROUTE_DICTRANK: Int = 2


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _f64_bits(u: UInt64) -> Float64:
    return bitcast[DType.float64, 1](SIMD[DType.uint64, 1](u))[0]


# -----------------------------------------------------------------------------
# Fixtures: a key column `k` and payload `orig` (the row's index over all
# workers, in worker order).
# -----------------------------------------------------------------------------


def _num_batch[dt: DType](
    keys: List[Scalar[dt]], lo: Int, hi: Int
) raises -> RecordBatch:
    var k = List[Scalar[dt]]()
    var p = List[Int64]()
    for i in range(lo, hi):
        k.append(keys[i])
        p.append(Int64(i))
    var schema = Schema.from_fields_2(
        Field("k", dt, True), Field("orig", DType.int64, True)
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[dt](PrimitiveArray[dt].from_list(k^)),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(p^)
        ),
    )


def _str_batch(
    keys: List[String], valid: List[Bool], lo: Int, hi: Int
) raises -> RecordBatch:
    var k = List[String]()
    var v = List[Bool]()
    var p = List[Int64]()
    for i in range(lo, hi):
        k.append(keys[i])
        v.append(valid[i] if len(valid) > 0 else True)
        p.append(Int64(i))
    var sa = (
        StringArray.from_strings(k) if len(valid) == 0
        else StringArray.from_strings_with_validity(k, v)
    )
    var schema = Schema.from_fields_2(
        Field("k", ArrowType.STRING, True), Field("orig", DType.int64, True)
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_string(sa^),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(p^)
        ),
    )


def _spec(desc: Bool) -> SortSinkData:
    var keys: List[String] = ["k"]
    var d: List[Bool] = [desc]
    return SortSinkData(keys^, d^)


# -----------------------------------------------------------------------------
# The driver: one local per worker, combine, combine_partition, finalize.
# -----------------------------------------------------------------------------


struct _Feed(Movable):
    """The batches each worker consumes: `owner[i]` is batch i's worker."""

    var batches: Slab[RecordBatch]
    var owner: List[Int]
    var n_workers: Int

    def __init__(out self, n_workers: Int):
        self.batches = Slab[RecordBatch]()
        self.owner = List[Int]()
        self.n_workers = n_workers

    def add(mut self, worker: Int, var batch: RecordBatch):
        self.batches.append(batch^)
        self.owner.append(worker)


def _drive(
    sink: SortSink, var feed: _Feed, expect_route: Int
) raises -> RecordBatch:
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()

    var g = sink.init_global()
    var states = Slab[OwnedPointer[SortSinkLocal]].create(feed.n_workers)
    for w in range(feed.n_workers):
        var local = sink.init_local()
        for b in range(len(feed.owner)):
            if feed.owner[b] == w:
                sink.consume(w, local, g, feed.batches.take_slot_unchecked(b))
        states.append(OwnedPointer[SortSinkLocal](local^))
    # Every slot was taken above.
    feed.batches.set_len_unchecked(0)
    _ = feed^
    var reservation = MemoryReservation()
    sink.combine(g, states^, reservation)

    var np = sink.num_partitions(g)
    if expect_route == _ROUTE_PARTITIONED:
        assert_true(np > 1, "expected the partitioned route")
        assert_false(g.string_dictrank)
    elif expect_route == _ROUTE_DICTRANK:
        assert_true(g.string_dictrank, "expected the counting sort")
        assert_equal(np, 1)
    else:
        assert_false(g.string_dictrank, "expected the serial route")
        assert_equal(np, 1)
        assert_equal(len(g.partitions), 0)
    if np > 1:
        for p in range(np):
            sink.combine_partition(g, p)

    var fr = sink.finalize(g^, Pointer(to=disp), ct)
    var out = fr.output.take_slot_unchecked(0)
    fr.output.set_len_unchecked(0)
    _ = fr^
    _ = runtime^
    return out^


def _split[dt: DType](keys: List[Scalar[dt]], n_workers: Int) raises -> _Feed:
    """Each worker gets a contiguous share, in two batches."""
    var feed = _Feed(n_workers)
    var n = len(keys)
    for w in range(n_workers):
        var lo = (w * n) // n_workers
        var hi = ((w + 1) * n) // n_workers
        var mid = (lo + hi) // 2
        feed.add(w, _num_batch[dt](keys, lo, mid))
        feed.add(w, _num_batch[dt](keys, mid, hi))
    return feed^


def _split_str(
    keys: List[String], valid: List[Bool], n_workers: Int
) raises -> _Feed:
    var feed = _Feed(n_workers)
    var n = len(keys)
    for w in range(n_workers):
        var lo = (w * n) // n_workers
        var hi = ((w + 1) * n) // n_workers
        feed.add(w, _str_batch(keys, valid, lo, hi))
    return feed^


def _payload(imm b: RecordBatch) raises -> List[Int]:
    var out = List[Int]()
    var p = b.column_at(1).as_primitive[DType.int64]()
    for i in range(p.length):
        out.append(Int(p.get_typed[Scalar[DType.int64]](i)))
    return out^


def _assert_same_payload(imm a: RecordBatch, imm b: RecordBatch) raises:
    """The payload is the input row, so equal payloads mean equal rows."""
    assert_equal(a.num_rows(), b.num_rows())
    var pa = _payload(a)
    var pb = _payload(b)
    for i in range(len(pa)):
        assert_equal(pa[i], pb[i])


def _routes_all_rows() -> SortSinkRoutes:
    """The default routes with no row floor and three merge slices."""
    return SortSinkRoutes(parallel_min_rows=1, num_workers=3)


# -----------------------------------------------------------------------------
# Partitioned routes
# -----------------------------------------------------------------------------


def _int_keys(n: Int) -> List[Int64]:
    var keys = List[Int64]()
    for i in range(n):
        keys.append(Int64((i * 7919) % 97) - 40)
    return keys^


def test_partitioned_int_matches_serial() raises:
    var keys = _int_keys(3000)
    for desc in [False, True]:
        var got = _drive(
            SortSink(_spec(desc), _routes_all_rows()),
            _split[DType.int64](keys, 3),
            _ROUTE_PARTITIONED,
        )
        var want = _execute_sort_sink(
            _num_batch[DType.int64](keys, 0, len(keys)), _spec(desc)
        )
        _assert_same_payload(got, want)


def test_partitioned_float_nan_and_zeros_match_serial() raises:
    var pos_nan = _f64_bits(0x7FF8000000000000)
    var neg_nan = _f64_bits(0xFFF8000000000000)
    var keys = List[Float64]()
    for i in range(600):
        var m = (i * 31) % 11
        if m == 0:
            keys.append(neg_nan)
        elif m == 1:
            keys.append(pos_nan)
        elif m == 2:
            keys.append(-0.0)
        elif m == 3:
            keys.append(0.0)
        elif m == 4:
            keys.append(inf[DType.float64]())
        elif m == 5:
            keys.append(-inf[DType.float64]())
        else:
            keys.append(Float64(m) - 8.5)
    for desc in [False, True]:
        var got = _drive(
            SortSink(_spec(desc), _routes_all_rows()),
            _split[DType.float64](keys, 3),
            _ROUTE_PARTITIONED,
        )
        var want = _execute_sort_sink(
            _num_batch[DType.float64](keys, 0, len(keys)), _spec(desc)
        )
        _assert_same_payload(got, want)


def test_partitioned_string_matches_serial() raises:
    var keys = List[String]()
    for i in range(900):
        keys.append(String("s") + String((i * 7919) % 1000))
    for desc in [False, True]:
        var got = _drive(
            SortSink(_spec(desc), _routes_all_rows()),
            _split_str(keys, List[Bool](), 3),
            _ROUTE_PARTITIONED,
        )
        var want = _execute_sort_sink(
            _str_batch(keys, List[Bool](), 0, len(keys)), _spec(desc)
        )
        _assert_same_payload(got, want)


# -----------------------------------------------------------------------------
# Selection masks and the route switches
# -----------------------------------------------------------------------------


def _masked_num_batch(
    keys: List[Int64], lo: Int, hi: Int, reject_mod: Int
) raises -> RecordBatch:
    """Rows [lo, hi) with every row whose index is a multiple of `reject_mod`
    rejected by a selection mask."""
    var b = _num_batch[DType.int64](keys, lo, hi)
    var mask = BooleanArray.allocate(hi - lo)
    for i in range(lo, hi):
        mask.set(i - lo, i % reject_mod != 0)
    b.set_selection_mask(mask^)
    return b^


def _expected_live_payload(keys: List[Int64], reject_mod: Int, desc: Bool) -> List[Int]:
    """The live rows' indices in stable key order (ties by index)."""
    var live = List[Int]()
    for i in range(len(keys)):
        if i % reject_mod != 0:
            live.append(i)
    for a in range(1, len(live)):
        var cur = live[a]
        var j = a - 1
        while j >= 0:
            var before = (
                keys[live[j]] > keys[cur] if not desc
                else keys[live[j]] < keys[cur]
            )
            if not before:
                break
            live[j + 1] = live[j]
            j -= 1
        live[j + 1] = cur
    return live^


def test_selection_masked_batches_drop_their_rejected_rows() raises:
    var keys = _int_keys(400)
    for partitioned in [False, True]:
        for desc in [False, True]:
            var feed = _Feed(2)
            feed.add(0, _masked_num_batch(keys, 0, 130, 3))
            feed.add(0, _masked_num_batch(keys, 130, 200, 3))
            feed.add(1, _masked_num_batch(keys, 200, 400, 3))
            var routes = (
                _routes_all_rows() if partitioned else SortSinkRoutes()
            )
            var got = _drive(
                SortSink(_spec(desc), routes^), feed^,
                _ROUTE_PARTITIONED if partitioned else _ROUTE_SERIAL,
            )
            var want = _expected_live_payload(keys, 3, desc)
            assert_equal(got.num_rows(), len(want))
            var pg = _payload(got)
            for i in range(len(want)):
                assert_equal(pg[i], want[i])


def _seven_word_keys(n: Int) -> List[String]:
    var words: List[String] = ["kiwi", "fig", "", "figs", "date", "plum", "pear"]
    var keys = List[String]()
    for i in range(n):
        keys.append(words[(i * 3) % 7])
    return keys^


def test_dictrank_ceiling_below_distinct_count_declines_counting_sort() raises:
    """Seven distinct values: a ceiling of 5 sends the sink to the partitioned
    route, a ceiling of 7 to the counting sort; the rows are the same."""
    var keys = _seven_word_keys(1200)
    for ceiling in [5, 7]:
        var got = _drive(
            SortSink(
                _spec(False),
                SortSinkRoutes(
                    parallel_min_rows=1, num_workers=3,
                    dictrank_max_distinct=ceiling,
                ),
            ),
            _split_str(keys, List[Bool](), 3),
            _ROUTE_PARTITIONED if ceiling == 5 else _ROUTE_DICTRANK,
        )
        var want = _execute_sort_sink(
            _str_batch(keys, List[Bool](), 0, len(keys)), _spec(False)
        )
        _assert_same_payload(got, want)


def test_total_rows_at_the_floor_take_the_parallel_route() raises:
    """The floor is inclusive: 3000 rows with `parallel_min_rows` 3000 are
    partitioned; with 3001 they are sorted serially."""
    var keys = _int_keys(3000)
    var want = _execute_sort_sink(
        _num_batch[DType.int64](keys, 0, len(keys)), _spec(False)
    )
    var at = _drive(
        SortSink(
            _spec(False), SortSinkRoutes(parallel_min_rows=3000, num_workers=3)
        ),
        _split[DType.int64](keys, 3),
        _ROUTE_PARTITIONED,
    )
    _assert_same_payload(at, want)
    var under = _drive(
        SortSink(
            _spec(False), SortSinkRoutes(parallel_min_rows=3001, num_workers=3)
        ),
        _split[DType.int64](keys, 3),
        _ROUTE_SERIAL,
    )
    _assert_same_payload(under, want)


# -----------------------------------------------------------------------------
# The counting sort
# -----------------------------------------------------------------------------


def test_dictrank_with_nulls_matches_serial() raises:
    var words: List[String] = ["kiwi", "fig", "", "figs", "date"]
    var keys = List[String]()
    var valid = List[Bool]()
    for i in range(1200):
        keys.append(words[(i * 3) % 5])
        valid.append(i % 13 != 6)
    for nworkers in [1, 3]:
        for desc in [False, True]:
            var got = _drive(
                SortSink(_spec(desc), _routes_all_rows()),
                _split_str(keys, valid, nworkers),
                _ROUTE_DICTRANK,
            )
            var want = _execute_sort_sink(
                _str_batch(keys, valid, 0, len(keys)), _spec(desc)
            )
            _assert_same_payload(got, want)


# -----------------------------------------------------------------------------
# The serial route
# -----------------------------------------------------------------------------


def test_routes_off_take_serial_route() raises:
    var words: List[String] = ["kiwi", "fig", "date"]
    var keys = List[String]()
    for i in range(300):
        keys.append(words[i % 3])
    var off = SortSinkRoutes(
        dictrank=False, parallel_string=False, parallel_min_rows=1
    )
    var got = _drive(
        SortSink(_spec(True), off), _split_str(keys, List[Bool](), 3),
        _ROUTE_SERIAL,
    )
    var want = _execute_sort_sink(
        _str_batch(keys, List[Bool](), 0, len(keys)), _spec(True)
    )
    _assert_same_payload(got, want)


def test_two_keys_take_serial_route() raises:
    var keys = _int_keys(500)
    var names: List[String] = ["k", "orig"]
    var desc: List[Bool] = [True, False]
    var spec = SortSinkData(names.copy(), desc.copy())
    var got = _drive(
        SortSink(spec^, _routes_all_rows()), _split[DType.int64](keys, 3),
        _ROUTE_SERIAL,
    )
    var want = _execute_sort_sink(
        _num_batch[DType.int64](keys, 0, len(keys)),
        SortSinkData(names^, desc^),
    )
    _assert_same_payload(got, want)


def test_one_worker_takes_serial_route() raises:
    var keys = _int_keys(400)
    var got = _drive(
        SortSink(_spec(False), _routes_all_rows()),
        _split[DType.int64](keys, 1),
        _ROUTE_SERIAL,
    )
    var want = _execute_sort_sink(
        _num_batch[DType.int64](keys, 0, len(keys)), _spec(False)
    )
    _assert_same_payload(got, want)


def test_small_input_under_default_floor_takes_serial_route() raises:
    var keys = _int_keys(400)
    var got = _drive(
        SortSink(_spec(False)), _split[DType.int64](keys, 3), _ROUTE_SERIAL
    )
    var want = _execute_sort_sink(
        _num_batch[DType.int64](keys, 0, len(keys)), _spec(False)
    )
    _assert_same_payload(got, want)


def test_no_rows_gives_an_empty_batch() raises:
    var got = _drive(
        SortSink(_spec(False), _routes_all_rows()), _Feed(2), _ROUTE_SERIAL
    )
    assert_equal(got.num_rows(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
