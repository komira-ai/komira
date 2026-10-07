# =============================================================================
# bench_agg_state.mojo -- microbenchmark of the accumulator update path
# (not a gated test)
# =============================================================================
#
# Times the typed-erasure seams of this package with fixed inputs, best of
# TRIALS runs, one `RESULT <name> ns_per_unit=<x>` line per measurement:
#
#   soa_kernel_call_3accs_per_row_per_acc  AccumulatorSet.update over a 262144-row
#                                          batch for SumI64 / CountI64 / MinI64
#   soa_kernel_call_batch64_per_row        the same kernel over 64-row batches
#                                          (the per-call overhead is visible)
#   aos_batch_sum_count_f64_per_row        the AoS sum+count kernel, rows
#                                          scattered over 1024 entries
#   aos_row_thunk_sum_count_f64_per_row    the per-row thunk, one fn-ptr call
#                                          per row
#   vtable_finalize_int64_per_call         per-gid readback through the vtable
#   vtable_merge_at_per_call               per-gid merge through the vtable
#
# Run it on a quiet machine, pinned to one core, several times, and compare the
# minimum: one run on a shared box is noise.
#
#   taskset -c 2 timeout 300 buck2 run //src/komira_op_agg_state:agg_state_bench
# =============================================================================

from std.time import perf_counter_ns

from komira_op_agg_state.accumulator_set import (
    AccumulatorSet,
    AosAccKernel,
    AOS_KERNEL_SUM_COUNT_F64,
    resolve_row_thunk,
)
from komira_op_agg_state.accumulator_factory import make_single_dyn_acc
from komira_op_agg_state.columnar_acc_typed import SumI64Acc, CountI64Acc, MinI64Acc
from komira_op_agg_state.columnar_agg_accumulator import ACC_SUM_INT64
from komira_agg_api.agg_layout import ACC_SUM_COUNT_F64

comptime N = 262144
comptime G = 1024
comptime REPS = 40
comptime TRIALS = 9


def report(name: String, best_ns: Int, per: Int):
    var x = Float64(best_ns) / Float64(per)
    print("RESULT", name, "ns_per_unit=", x)


def main() raises:
    var gids = List[Int](length=N, fill=0)
    var vals = List[Int64](length=N, fill=Int64(0))
    var fvals = List[Float64](length=N, fill=0.0)
    var seed = 88172645463325252
    for i in range(N):
        seed = (seed * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
        gids[i] = (seed >> 20) % G
        vals[i] = Int64(i % 1000)
        fvals[i] = Float64(i % 1000)
    var gspan = Span(gids)
    var vbytes = Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=N * 8
    )
    var fbytes = Span[UInt8, origin_of(fvals)](
        unsafe_ptr=fvals.unsafe_ptr().bitcast[UInt8](), length=N * 8
    )

    # --- SoA monomorphic kernel (Sum/Count/Min i64) ---
    var acc_set = AccumulatorSet()
    acc_set.add[SumI64Acc](SumI64Acc(), 0, 0, UInt8(0))
    acc_set.add[CountI64Acc](CountI64Acc(), 0, 1, UInt8(1))
    acc_set.add[MinI64Acc](MinI64Acc(), 0, 2, UInt8(2))
    for a in range(acc_set.num_accumulators()):
        acc_set.dyn_accs[a].ensure_capacity(G)
    var best = Int.MAX
    for t in range(TRIALS):
        var t0 = Int(perf_counter_ns())
        for r in range(REPS):
            for a in range(3):
                acc_set.update(a, gspan, vbytes, 0, N)
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    report("soa_kernel_call_3accs_per_row_per_acc", best, N * REPS * 3)

    # --- SoA kernel, batch of 64 rows (call overhead visible) ---
    best = Int.MAX
    for t in range(TRIALS):
        var t0 = Int(perf_counter_ns())
        for r in range(REPS):
            var off = 0
            while off + 64 <= N:
                acc_set.update(
                    0,
                    Span[Int, origin_of(gids)](
                        unsafe_ptr=gids.unsafe_ptr() + off, length=64
                    ),
                    vbytes,
                    off,
                    64,
                )
                off += 64
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    report("soa_kernel_call_batch64_per_row", best, (N // 64) * 64 * REPS)

    # --- AoS batch kernel (sum+count f64, 16B slot) ---
    var tbl = List[UInt8](length=G * 16, fill=UInt8(0))
    var offsets = List[Int](length=N, fill=0)
    for i in range(N):
        offsets[i] = gids[i] * 16
    var kern = AosAccKernel(AOS_KERNEL_SUM_COUNT_F64, 0, 0)
    best = Int.MAX
    for t in range(TRIALS):
        var t0 = Int(perf_counter_ns())
        for r in range(REPS):
            kern.call(Span(tbl), Span(offsets), fbytes, 0, N)
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    report("aos_batch_sum_count_f64_per_row", best, N * REPS)

    # --- AoS per-row thunk (fn-ptr per row) ---
    var rt = resolve_row_thunk(ACC_SUM_COUNT_F64)
    best = Int.MAX
    for t in range(TRIALS):
        var t0 = Int(perf_counter_ns())
        for r in range(REPS):
            for i in range(N):
                rt.call(
                    Span[UInt8, origin_of(tbl)](
                        unsafe_ptr=tbl.unsafe_ptr() + offsets[i], length=16
                    ),
                    0,
                    fvals[i],
                )
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    report("aos_row_thunk_sum_count_f64_per_row", best, N * REPS)

    # --- vtable cold path: per-gid readback + merge_at ---
    var d1 = make_single_dyn_acc(ACC_SUM_INT64)
    var d2 = make_single_dyn_acc(ACC_SUM_INT64)
    d1.ensure_capacity(G)
    d2.ensure_capacity(G)
    var sink = Int64(0)
    best = Int.MAX
    for t in range(TRIALS):
        var t0 = Int(perf_counter_ns())
        for r in range(REPS * 20):
            for g in range(G):
                sink += d1.finalize_int64(g)
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    report("vtable_finalize_int64_per_call", best, G * REPS * 20)
    best = Int.MAX
    for t in range(TRIALS):
        var t0 = Int(perf_counter_ns())
        for r in range(REPS * 20):
            for g in range(G):
                d1.merge_at(g, d2, g)
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    report("vtable_merge_at_per_call", best, G * REPS * 20)
    print("sink", sink, Int(tbl[0]))
