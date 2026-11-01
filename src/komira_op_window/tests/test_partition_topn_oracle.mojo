# =============================================================================
# test_partition_topn_oracle -- PartitionTopNSink against a stable-sort oracle
# =============================================================================
#
# Every case builds a batch from a seeded generator and computes the expected
# result without the sink or the window operator: per partition, a stable
# insertion sort of the rows by the order keys (NULLs last in both
# directions), ROW_NUMBER = position, RANK = 1 + the rows strictly better. The
# sink's output must hold, per partition, exactly the expected rows in
# exactly that order (best first, ties by input row), each partition's rows
# contiguous, and the rank column equal to the expected number row by row.
# The order BETWEEN partitions is not asserted: the heap path emits
# partitions in first-seen order and the generic path in sorted key order.
#
# Coverage: 0, 1, 2, 9, 60 and 120 rows; one, three and 25 partitions or no
# partition key; k of 0, 1, 2, 5 and 1000; ROW_NUMBER and RANK; both
# directions; two order keys with their own directions; INT64, INT32 and
# STRING partition keys; INT64, INT32 and FLOAT64 order keys with their
# extremes, +-0.0, +inf and NaN payloads; NULL partition and order keys;
# over-fetch variants; INT32 keys that are negative, zero, positive and at
# Int32.MIN / Int32.MAX; and the one-row-partition and k = 1 cases with the
# rank column.
#
# The pooled test runs the same cases on a started pool of 2, 3 and 7 workers
# and compares each output with the serial one exactly, then reads the split
# the heap build recorded.
# =============================================================================

from std.math import inf
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join_shared import SharedForkJoinHandle, serial_fork_join_handle
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_buffer.heap_region import HeapRegion
from komira_engine_runtime.grain_geometry import (
    GRAIN_F_ROWS,
    GRAIN_F_WORKERS,
    grain_geometry_calls,
    grain_geometry_field,
    grain_geometry_reset,
)
from komira_async.runtime.sched_trace import SITE_PTOPN_HEAP_BUILD
from komira_physical_plan.physical_plan import PartitionTopNSinkData
from komira_plan_expr.partition_expr import PF_RANK, PF_ROW_NUMBER

from komira_op_window.partition_topn_sink import PartitionTopNSink


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


struct Lcg(Copyable, Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed * 2654435761 + 12345

    def next(mut self, m: Int) -> Int:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Int((self.s >> 33) % UInt64(m))


struct Case(Copyable, Movable):
    var n: Int
    var np: Int
    var nc: Int
    var g_kind: Int  # 0 i64, 1 i32, 2 string
    var o_kind: Int  # 0 i64, 1 i32, 2 f64
    var gnull: Bool
    var onull: Bool
    var multi: Bool
    var nopk: Bool
    var k: Int
    var desc: Bool
    var desc2: Bool
    var func: UInt8
    var rk: Bool
    var over: Int
    var seed: Int
    var wide: Bool  # INT32 keys span negatives, zero, positives and the extremes

    def __init__(out self):
        self.n = 0
        self.np = 1
        self.nc = 1
        self.g_kind = 0
        self.o_kind = 0
        self.gnull = False
        self.onull = False
        self.multi = False
        self.nopk = False
        self.k = 1
        self.desc = False
        self.desc2 = False
        self.func = PF_ROW_NUMBER
        self.rk = False
        self.over = -1
        self.seed = 0
        self.wide = False


def _wide32(cls: Int) -> Int32:
    """Seven ascending INT32 values: the class index orders like the value."""
    if cls == 0:
        return Int32.MIN
    if cls == 1:
        return Int32(-70000)
    if cls == 2:
        return Int32(-1)
    if cls == 3:
        return Int32(0)
    if cls == 4:
        return Int32(5)
    if cls == 5:
        return Int32(70000)
    return Int32.MAX


def _gen(c: Case, mut gp: List[Int], mut gnullv: List[Bool], mut oc: List[Int], mut onullv: List[Bool], mut o2c: List[Int]):
    var r = Lcg(UInt64(c.seed))
    for i in range(c.n):
        gp.append(0 if c.nopk else r.next(c.np))
        gnullv.append(c.gnull and r.next(5) == 0)
        oc.append(r.next(c.nc))
        onullv.append(c.onull and r.next(5) == 0)
        o2c.append(r.next(3) if c.multi else 0)


def _build(c: Case, gp: List[Int], gnullv: List[Bool], oc: List[Int], onullv: List[Bool], o2c: List[Int]) raises -> RecordBatch:
    var n = c.n
    var r = Lcg(UInt64(c.seed) + 77)
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    # g
    if c.g_kind == 0:
        var a = PrimitiveArray[DType.int64].allocate_nullable(n)
        for i in range(n):
            a.store[1](i, Int64.MIN if gp[i] == 0 else Int64(gp[i]) * 1000003)
            if gnullv[i]:
                a._set_null(i)
        var col = Column.from_primitive[DType.int64](a)
        sb.add_field(Field("g", col.arrow_type, True))
        bb.add_column(col^)
    elif c.g_kind == 1:
        var a = PrimitiveArray[DType.int32].allocate_nullable(n)
        for i in range(n):
            a.store[1](i, _wide32(gp[i]) if c.wide else (Int32.MIN if gp[i] == 0 else Int32(gp[i]) * 7))
            if gnullv[i]:
                a._set_null(i)
        var col = Column.from_primitive[DType.int32](a)
        sb.add_field(Field("g", col.arrow_type, True))
        bb.add_column(col^)
    else:
        var gs = List[String]()
        for i in range(n):
            gs.append(String("p") + String(gp[i]))
        var col = Column.from_string(StringArray.from_strings(gs))
        sb.add_field(Field("g", col.arrow_type, True))
        bb.add_column(col^)
    # o
    if c.o_kind == 0:
        var a = PrimitiveArray[DType.int64].allocate_nullable(n)
        for i in range(n):
            var cl = oc[i]
            a.store[1](i, Int64.MIN if cl == 0 else (Int64.MAX if (cl == c.nc - 1 and c.nc > 1) else Int64(cl)))
            if onullv[i]:
                a._set_null(i)
        var col = Column.from_primitive[DType.int64](a)
        sb.add_field(Field("o", col.arrow_type, True))
        bb.add_column(col^)
    elif c.o_kind == 1:
        var a = PrimitiveArray[DType.int32].allocate_nullable(n)
        for i in range(n):
            var cl = oc[i]
            a.store[1](i, _wide32(cl) if c.wide else (Int32.MIN if cl == 0 else (Int32.MAX if (cl == c.nc - 1 and c.nc > 1) else Int32(cl))))
            if onullv[i]:
                a._set_null(i)
        var col = Column.from_primitive[DType.int32](a)
        sb.add_field(Field("o", col.arrow_type, True))
        bb.add_column(col^)
    else:
        var a = PrimitiveArray[DType.float64].allocate_nullable(n)
        for i in range(n):
            var cl = oc[i]
            var v: Float64 = -1.0
            if cl == 0:
                v = -1.0
            elif cl == 1:
                v = -0.0 if r.next(2) == 0 else 0.0
            elif cl == 2:
                v = 1.0
            elif cl == 3:
                v = inf[DType.float64]()
            else:
                v = Float64(0.0) / Float64(0.0) if r.next(2) == 0 else bitcast[DType.float64](UInt64(0x7FF8000000000001))
            a.store[1](i, v)
            if onullv[i]:
                a._set_null(i)
        var col = Column.from_primitive[DType.float64](a)
        sb.add_field(Field("o", col.arrow_type, True))
        bb.add_column(col^)
    # o2
    var a2 = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        a2.store[1](i, Int64(o2c[i]))
    var col2 = Column.from_primitive[DType.int64](a2)
    sb.add_field(Field("o2", col2.arrow_type, True))
    bb.add_column(col2^)
    var av = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        av.store[1](i, Int64(i))
    var colv = Column.from_primitive[DType.int64](av)
    sb.add_field(Field("v", colv.arrow_type, False))
    bb.add_column(colv^)
    return bb.build(sb.build())


def _cmp(c: Case, a: Int, b: Int, oc: List[Int], onullv: List[Bool], o2c: List[Int]) -> Int:
    # -1 if a better than b
    if onullv[a] != onullv[b]:
        return 1 if onullv[a] else -1
    if not onullv[a] and oc[a] != oc[b]:
        var less = oc[a] < oc[b]
        if c.desc:
            less = not less
        return -1 if less else 1
    if c.multi and o2c[a] != o2c[b]:
        var less = o2c[a] < o2c[b]
        if c.desc2:
            less = not less
        return -1 if less else 1
    return 0


def _run[
    has_pool: Bool, disp_o: Origin[mut=True]
](c: Case, pool: SharedForkJoinHandle[has_pool, disp_o], label: String) raises -> String:
    var gp = List[Int]()
    var gnullv = List[Bool]()
    var oc = List[Int]()
    var onullv = List[Bool]()
    var o2c = List[Int]()
    _gen(c, gp, gnullv, oc, onullv, o2c)
    var batch = _build(c, gp, gnullv, oc, onullv, o2c)
    var n = c.n
    # pid per row
    var pid = List[Int]()
    var reps = List[Int]()
    for i in range(n):
        var f = -1
        for j in range(len(reps)):
            var rr = reps[j]
            var same = (gnullv[rr] and gnullv[i]) or (not gnullv[rr] and not gnullv[i] and gp[rr] == gp[i])
            if same:
                f = j
                break
        if f < 0:
            reps.append(i)
            f = len(reps) - 1
        pid.append(f)
    # oracle
    var exp_seq = List[List[Int]]()
    var exp_rank = List[List[Int]]()
    for p in range(len(reps)):
        var idx = List[Int]()
        for i in range(n):
            if pid[i] == p:
                idx.append(i)
        # stable insertion sort
        for x in range(1, len(idx)):
            var y = x
            while y > 0 and _cmp(c, idx[y], idx[y - 1], oc, onullv, o2c) < 0:
                var t = idx[y]
                idx[y] = idx[y - 1]
                idx[y - 1] = t
                y -= 1
        var seq = List[Int]()
        var rks = List[Int]()
        for x in range(len(idx)):
            var rank = x + 1
            if c.func == PF_RANK:
                rank = 1
                for z in range(len(idx)):
                    if _cmp(c, idx[z], idx[x], oc, onullv, o2c) < 0:
                        rank += 1
            if rank <= c.k:
                seq.append(idx[x])
                rks.append(rank)
        exp_seq.append(seq^)
        exp_rank.append(rks^)
    # sink
    var pk = List[String]()
    if not c.nopk:
        pk.append("g")
    var ok: List[String] = ["o"]
    var dl: List[Bool] = [c.desc]
    if c.multi:
        ok.append("o2")
        dl.append(c.desc2)
    var name: Optional[String] = None
    if c.rk:
        name = String("rk")
    var sch = SchemaBuilder()
    for i in range(batch.schema.num_columns()):
        sch.add_field(batch.schema.field_at(i))
    var spec = PartitionTopNSinkData(pk^, ok^, dl^, c.k, sch.build(), c.func, c.over, name^)
    var sink = PartitionTopNSink(spec^)
    sink.ingest_prebuilt(batch^)
    sink.combine_pooled(pool)
    var out = sink.take_output()
    var total = 0
    for p in range(len(exp_seq)):
        total += len(exp_seq[p])
    assert_equal(out.num_rows(), total, label + " row count")
    var got = List[List[Int]]()
    var gotr = List[List[Int]]()
    for _ in range(len(reps)):
        got.append(List[Int]())
        gotr.append(List[Int]())
    var sig = String()
    var last_p = -1
    var closed = List[Bool]()
    for _ in range(len(reps)):
        closed.append(False)
    ref vcol = out.column_at(3)
    for r in range(out.num_rows()):
        var v = Int(vcol._data.get_typed[Scalar[DType.int64]](vcol._offset + r))
        var p = pid[v]
        if p != last_p:
            assert_true(not closed[p], label + " partition rows not contiguous")
            if last_p >= 0:
                closed[last_p] = True
            last_p = p
        got[p].append(v)
        sig += String(v)
        if c.rk:
            ref rc = out.column_at(4)
            var rv = Int(rc._data.get_typed[Scalar[DType.int64]](rc._offset + r))
            gotr[p].append(rv)
            sig += "/" + String(rv)
        sig += ","
    for p in range(len(reps)):
        assert_equal(len(got[p]), len(exp_seq[p]), label + " part size")
        for x in range(len(got[p])):
            assert_equal(got[p][x], exp_seq[p][x], label + " order in partition " + String(p) + " pos " + String(x))
            if c.rk:
                assert_equal(gotr[p][x], exp_rank[p][x], label + " rank")
    return sig^


def _add_targeted_cases(mut cs: List[Case]):
    var seed = 5000
    # INT32 partition and order keys over negatives, zero, positives and the
    # extremes, both directions, both functions, with the rank column.
    for desc in range(2):
        for fnc in range(2):
            for k in [1, 3, 50]:
                var c = Case()
                c.n = 100
                c.np = 7
                c.nc = 7
                c.g_kind = 1
                c.o_kind = 1
                c.wide = True
                c.k = k
                c.desc = desc == 1
                c.func = PF_RANK if fnc == 0 else PF_ROW_NUMBER
                c.rk = True
                c.seed = seed
                seed += 1
                cs.append(c^)
    # One row; one row per partition; k = 1 over many rows: the one-row fast
    # path of the ROW_NUMBER emitter, with the rank column.
    for fnc in range(2):
        for shape in range(3):
            var c = Case()
            c.n = 1 if shape == 0 else (4 if shape == 1 else 60)
            c.np = 1 if shape == 0 else (4 if shape == 1 else 5)
            c.nc = 50 if shape == 1 else 3
            c.k = 1 if shape == 2 else 3
            c.func = PF_RANK if fnc == 0 else PF_ROW_NUMBER
            c.rk = True
            c.seed = seed
            seed += 1
            cs.append(c^)


def _cases() -> List[Case]:
    var cs = List[Case]()
    var r = Lcg(99)
    var ns = [0, 1, 2, 9, 60, 120]
    var nps = [1, 3, 25]
    var ncs = [1, 2, 4, 5, 40]
    var ks = [0, 1, 2, 5, 1000]
    var seed = 1
    for ni in range(len(ns)):
        for it in range(8):
            var c = Case()
            c.n = ns[ni]
            c.np = nps[r.next(3)]
            c.nc = ncs[r.next(5)]
            c.g_kind = r.next(3)
            c.o_kind = r.next(3)
            c.k = ks[r.next(5)]
            c.desc = r.next(2) == 0
            c.desc2 = r.next(2) == 0
            c.func = PF_RANK if r.next(2) == 0 else PF_ROW_NUMBER
            c.rk = r.next(2) == 0
            var special = r.next(6)
            c.gnull = special == 1 or special == 2
            c.onull = special == 2 or special == 3
            c.multi = special == 4
            c.nopk = special == 5
            if c.g_kind == 2:
                c.gnull = False
            if c.o_kind == 2 and c.nc > 5:
                c.nc = 5
            if c.func == PF_RANK and r.next(3) == 0:
                c.over = c.k + r.next(3)
            c.seed = seed
            seed += 1
            cs.append(c^)
    _add_targeted_cases(cs)
    return cs^


def _sweep[
    has_pool: Bool, disp_o: Origin[mut=True]
](pool: SharedForkJoinHandle[has_pool, disp_o], mut sigs: List[String], first: Bool, tag: String) raises:
    var cs = _cases()
    for i in range(len(cs)):
        var s = _run(cs[i], pool, tag + " case " + String(i) + " n=" + String(cs[i].n) + " np=" + String(cs[i].np) + " nc=" + String(cs[i].nc) + " g=" + String(cs[i].g_kind) + " o=" + String(cs[i].o_kind) + " k=" + String(cs[i].k) + " desc=" + String(cs[i].desc) + " func=" + String(cs[i].func) + " gn=" + String(cs[i].gnull) + " on=" + String(cs[i].onull) + " multi=" + String(cs[i].multi) + " nopk=" + String(cs[i].nopk))
        if first:
            sigs.append(s^)
        else:
            assert_equal(s, sigs[i], tag + " differs from serial, case " + String(i))


def _started_pool(nw: Int) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(nw, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def test_serial_sink_equals_the_stable_sort_oracle() raises:
    var sigs = List[String]()
    _sweep(serial_fork_join_handle(), sigs, True, "serial")


def test_pooled_sink_equals_serial_and_records_its_split() raises:
    var sigs = List[String]()
    _sweep(serial_fork_join_handle(), sigs, True, "serial")
    for nw in [2, 3, 7]:
        var rt = _started_pool(nw)
        ref disp = rt.dispatcher()
        assert_equal(disp.worker_count(), nw, "pool size")
        var h = SharedForkJoinHandle[True, origin_of(disp)](
            Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](Pointer(to=disp))
        )
        _sweep(h, sigs, False, "pool" + String(nw))
        # The split of one heap-path build: one range per worker for 120
        # rows, and no more ranges than rows for 3 rows.
        for rows in [120, 3]:
            var c = Case()
            c.n = rows
            c.np = 2
            c.nc = 5
            c.k = 2
            c.seed = 31
            grain_geometry_reset()
            _ = _run(c, h, "split n=" + String(rows))
            assert_equal(grain_geometry_calls(SITE_PTOPN_HEAP_BUILD), 1)
            assert_equal(grain_geometry_field(SITE_PTOPN_HEAP_BUILD, GRAIN_F_ROWS), rows)
            assert_equal(
                grain_geometry_field(SITE_PTOPN_HEAP_BUILD, GRAIN_F_WORKERS),
                nw if rows > nw else rows,
                "ranges for n=" + String(rows) + " on " + String(nw) + " workers",
            )
        rt.shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
