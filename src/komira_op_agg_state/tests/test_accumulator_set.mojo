# =============================================================================
# Integration test: AccumulatorSet with heterogeneous accumulators
# =============================================================================

from std.memory import alloc

from komira_engine_operators.accumulator_set import AccumulatorSet
from komira_engine_operators.dyn_accumulator import DynAccumulator
from komira_engine_operators.columnar_acc_typed import SumI64Acc, CountI64Acc, MinI64Acc


def test_heterogeneous_accumulator_set() raises:
    """T1: 3 accumulators (SumI64 + CountI64 + MinI64), 3 batches, 3 groups."""
    var acc_set = AccumulatorSet()
    acc_set.add[SumI64Acc](SumI64Acc(), value_col_index=0, output_field_index=1, acc_kind=UInt8(0))
    acc_set.add[CountI64Acc](CountI64Acc(), value_col_index=0, output_field_index=2, acc_kind=UInt8(1))
    acc_set.add[MinI64Acc](MinI64Acc(), value_col_index=0, output_field_index=3, acc_kind=UInt8(2))
    acc_set.finalize_wiring()

    for a in range(acc_set.num_accumulators()):
        acc_set.dyn_accs._mut_ptr(a)[].ensure_capacity(3)

    # Batch 1: gids=[0,1,0]  values=[10, 20, 30]
    var g1 = alloc[Int](3)
    (g1+0).unsafe_write(0)
    (g1+1).unsafe_write(1)
    (g1+2).unsafe_write(0)
    var d1 = alloc[Int64](3)
    (d1+0).unsafe_write(Int64(10))
    (d1+1).unsafe_write(Int64(20))
    (d1+2).unsafe_write(Int64(30))
    for a in range(acc_set.num_accumulators()):
        acc_set.kernels[a].call(Int(g1), Int(d1.bitcast[UInt8]()), 0, 3)
    g1.free()
    d1.free()

    # Batch 2: gids=[1,2,0]  values=[5, 15, 25]
    var g2 = alloc[Int](3)
    (g2+0).unsafe_write(1)
    (g2+1).unsafe_write(2)
    (g2+2).unsafe_write(0)
    var d2 = alloc[Int64](3)
    (d2+0).unsafe_write(Int64(5))
    (d2+1).unsafe_write(Int64(15))
    (d2+2).unsafe_write(Int64(25))
    for a in range(acc_set.num_accumulators()):
        acc_set.kernels[a].call(Int(g2), Int(d2.bitcast[UInt8]()), 0, 3)
    g2.free()
    d2.free()

    # Batch 3: gids=[2,1,2]  values=[100, 200, 300]
    var g3 = alloc[Int](3)
    (g3+0).unsafe_write(2)
    (g3+1).unsafe_write(1)
    (g3+2).unsafe_write(2)
    var d3 = alloc[Int64](3)
    (d3+0).unsafe_write(Int64(100))
    (d3+1).unsafe_write(Int64(200))
    (d3+2).unsafe_write(Int64(300))
    for a in range(acc_set.num_accumulators()):
        acc_set.kernels[a].call(Int(g3), Int(d3.bitcast[UInt8]()), 0, 3)
    g3.free()
    d3.free()

    # Finalize
    var sum_col = acc_set.dyn_accs._mut_ptr(0)[].finalize()
    var count_col = acc_set.dyn_accs._mut_ptr(1)[].finalize()
    var min_col = acc_set.dyn_accs._mut_ptr(2)[].finalize()

    # Verify SUM: g0=10+30+25=65, g1=20+5+200=225, g2=15+100+300=415
    var sp = sum_col._data.view_typed_ro[DType.int64]()
    if sp[0] != Int64(65):
        raise Error("SUM g0 expected 65, got " + String(Int(sp[0])))
    if sp[1] != Int64(225):
        raise Error("SUM g1 expected 225, got " + String(Int(sp[1])))
    if sp[2] != Int64(415):
        raise Error("SUM g2 expected 415, got " + String(Int(sp[2])))

    var cp = count_col._data.view_typed_ro[DType.int64]()
    if cp[0] != Int64(3) or cp[1] != Int64(3) or cp[2] != Int64(3):
        raise Error("COUNT not 3 for all groups")

    var mp = min_col._data.view_typed_ro[DType.int64]()
    if mp[0] != Int64(10):
        raise Error("MIN g0 expected 10, got " + String(Int(mp[0])))
    if mp[1] != Int64(5):
        raise Error("MIN g1 expected 5, got " + String(Int(mp[1])))
    if mp[2] != Int64(15):
        raise Error("MIN g2 expected 15, got " + String(Int(mp[2])))

    # Intentional leak to avoid destructor crash (Mojo DynValue
    # destructor can crash when accumulator state was modified through
    # raw pointer; the DynValue _destroy thunk sees stale metadata).
    _ = acc_set^
    _ = sum_col^
    _ = count_col^
    _ = min_col^
    print("    PASS test_heterogeneous_accumulator_set")


def test_kernel_matches_direct() raises:
    """T2: Monomorphic kernel produces same result as direct accumulator call."""
    var direct_acc = SumI64Acc()
    direct_acc.ensure_capacity(2)
    var gd = alloc[Int](3)
    (gd+0).unsafe_write(0)
    (gd+1).unsafe_write(1)
    (gd+2).unsafe_write(0)
    var dd = alloc[Int64](3)
    (dd+0).unsafe_write(Int64(10))
    (dd+1).unsafe_write(Int64(20))
    (dd+2).unsafe_write(Int64(30))
    direct_acc.update_batch(
        UnsafePointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(gd)),
        dd.bitcast[UInt8](), 0, 3,
    )
    gd.free()
    dd.free()

    var acc_set = AccumulatorSet()
    acc_set.add[SumI64Acc](SumI64Acc(), value_col_index=0, output_field_index=0, acc_kind=UInt8(0))
    acc_set.finalize_wiring()
    acc_set.dyn_accs._mut_ptr(0)[].ensure_capacity(2)
    var gk = alloc[Int](3)
    (gk+0).unsafe_write(0)
    (gk+1).unsafe_write(1)
    (gk+2).unsafe_write(0)
    var dk = alloc[Int64](3)
    (dk+0).unsafe_write(Int64(10))
    (dk+1).unsafe_write(Int64(20))
    (dk+2).unsafe_write(Int64(30))
    acc_set.kernels[0].call(Int(gk), Int(dk.bitcast[UInt8]()), 0, 3)
    gk.free()
    dk.free()

    var kernel_col = acc_set.dyn_accs._mut_ptr(0)[].finalize()
    var kp = kernel_col._data.view_typed_ro[DType.int64]()

    if direct_acc.state[0] != kp[0] or direct_acc.state[1] != kp[1]:
        raise Error("T2 FAIL: kernel != direct")

    _ = acc_set^
    _ = kernel_col^
    print("    PASS test_kernel_matches_direct")


def main() raises:
    print("Running AccumulatorSet integration tests...")
    test_heterogeneous_accumulator_set()
    test_kernel_matches_direct()
    print("All AccumulatorSet tests passed (2/2)")
