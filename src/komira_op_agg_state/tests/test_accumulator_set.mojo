# =============================================================================
# Integration test: AccumulatorSet with heterogeneous accumulators
# =============================================================================
#
# Drives the monomorphic kernels through `AccumulatorSet.update` with borrowed
# spans (no addresses), and pins the ownership properties of the type-erased
# design:
#   * each kernel updates ITS OWN accumulator (no state cross-talk),
#   * a set that is MOVED between batches still updates the right state (the
#     kernel holds no address of the accumulator),
#   * every accumulator is destroyed exactly once when the set drops.
# =============================================================================

from std.memory import ArcPointer

from komira_core.accumulator_trait import Accumulator
from komira_core.arrow import Column
from komira_core.io.heap_region import HeapRegion

from komira_op_agg_state.accumulator_set import AccumulatorSet
from komira_op_agg_state.columnar_acc_typed import SumI64Acc, CountI64Acc, MinI64Acc


def _ints(a: Int, b: Int, c: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    out.append(c)
    return out^


def _i64s(a: Int, b: Int, c: Int) -> List[Int64]:
    var out = List[Int64]()
    out.append(Int64(a))
    out.append(Int64(b))
    out.append(Int64(c))
    return out^


def _bytes(mut vals: List[Int64]) -> Span[UInt8, origin_of(vals)]:
    """The value column's data buffer, as the kernels take it: bytes."""
    return Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=len(vals) * 8
    )


def _add3(mut acc_set: AccumulatorSet):
    acc_set.add[SumI64Acc](SumI64Acc(), value_col_index=0, output_field_index=1, acc_kind=UInt8(0))
    acc_set.add[CountI64Acc](CountI64Acc(), value_col_index=0, output_field_index=2, acc_kind=UInt8(1))
    acc_set.add[MinI64Acc](MinI64Acc(), value_col_index=0, output_field_index=3, acc_kind=UInt8(2))


def _batch(
    mut acc_set: AccumulatorSet, mut gids: List[Int], mut vals: List[Int64]
) raises:
    for a in range(acc_set.num_accumulators()):
        acc_set.update(a, Span(gids), _bytes(vals), 0, 3)


def _check_totals(mut acc_set: AccumulatorSet) raises:
    var sum_col = acc_set.dyn_accs[0].finalize()
    var count_col = acc_set.dyn_accs[1].finalize()
    var min_col = acc_set.dyn_accs[2].finalize()

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


def test_heterogeneous_accumulator_set() raises:
    """T1: 3 accumulators (SumI64 + CountI64 + MinI64), 3 batches, 3 groups."""
    var acc_set = AccumulatorSet()
    _add3(acc_set)
    for a in range(acc_set.num_accumulators()):
        acc_set.dyn_accs[a].ensure_capacity(3)

    var g1 = _ints(0, 1, 0)
    var v1 = _i64s(10, 20, 30)
    _batch(acc_set, g1, v1)
    var g2 = _ints(1, 2, 0)
    var v2 = _i64s(5, 15, 25)
    _batch(acc_set, g2, v2)
    var g3 = _ints(2, 1, 2)
    var v3 = _i64s(100, 200, 300)
    _batch(acc_set, g3, v3)

    _check_totals(acc_set)
    print("    PASS test_heterogeneous_accumulator_set")


def test_kernel_matches_direct() raises:
    """T2: Monomorphic kernel produces same result as direct accumulator call."""
    var direct_acc = SumI64Acc()
    direct_acc.ensure_capacity(2)
    var gd = _ints(0, 1, 0)
    var dd = _i64s(10, 20, 30)
    direct_acc.update_batch(
        gd.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
        _bytes(dd).unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
        0,
        3,
    )
    # The pointers above are untracked (the trait's shape), so keep the
    # buffers alive past the call by hand.
    _ = gd
    _ = dd

    var acc_set = AccumulatorSet()
    acc_set.add[SumI64Acc](SumI64Acc(), value_col_index=0, output_field_index=0, acc_kind=UInt8(0))
    acc_set.dyn_accs[0].ensure_capacity(2)
    var gk = _ints(0, 1, 0)
    var dk = _i64s(10, 20, 30)
    acc_set.update(0, Span(gk), _bytes(dk), 0, 3)

    var kernel_col = acc_set.dyn_accs[0].finalize()
    var kp = kernel_col._data.view_typed_ro[DType.int64]()

    if direct_acc.state[0] != kp[0] or direct_acc.state[1] != kp[1]:
        raise Error("T2 FAIL: kernel != direct")
    print("    PASS test_kernel_matches_direct")


def test_update_after_the_set_moves() raises:
    """T3: the kernels hold no address, so MOVING the set between batches is
    safe. (A design that cached the accumulator's address at wiring time
    would update freed storage here.)"""
    var first = AccumulatorSet()
    _add3(first)
    for a in range(first.num_accumulators()):
        first.dyn_accs[a].ensure_capacity(3)

    var g1 = _ints(0, 1, 0)
    var v1 = _i64s(10, 20, 30)
    _batch(first, g1, v1)

    # Move the set: the DynAccumulators' inline storage now lives elsewhere
    # (the Slab buffer moves with `first.dyn_accs`; also swap through a List
    # to move the accumulators themselves).
    var moved = first^
    var relocated = List[DynAccumulatorBox]()
    relocated.append(DynAccumulatorBox(moved^))

    ref set_ref = relocated[0].inner
    var g2 = _ints(1, 2, 0)
    var v2 = _i64s(5, 15, 25)
    _batch(set_ref, g2, v2)
    var g3 = _ints(2, 1, 2)
    var v3 = _i64s(100, 200, 300)
    _batch(set_ref, g3, v3)
    _check_totals(set_ref)
    print("    PASS test_update_after_the_set_moves")


struct DynAccumulatorBox(Movable):
    """Holds a set behind one more move, so it is relocated again."""
    var inner: AccumulatorSet

    def __init__(out self, var inner: AccumulatorSet):
        self.inner = inner^


# ---------------------------------------------------------------------------
# Exactly-once destruction: the stored accumulator carries a token whose
# strong count is observable from outside.
# ---------------------------------------------------------------------------

struct _TokenAcc(Accumulator):
    var token: ArcPointer[Int]
    var total: Int

    def __init__(out self, token: ArcPointer[Int]):
        self.token = token
        self.total = 0

    def update_batch(
        mut self,
        gids_ptr: UnsafePointer[Int, MutUntrackedOrigin],
        col_data_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
        col_offset: Int,
        n: Int,
    ) raises:
        var data = col_data_ptr.bitcast[Int64]()
        for i in range(n):
            self.total += Int(data[col_offset + i])

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        raise Error("_TokenAcc.finalize_to_column: not used")

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        raise Error("_TokenAcc.flush_partial_to_column: not used")

    def ensure_capacity(mut self, n_groups: Int) raises:
        pass

    def num_groups(self) -> Int:
        return self.total


def test_each_accumulator_destroyed_exactly_once() raises:
    """T4: dropping the set destroys every stored accumulator once: the
    strong count returns to 1 (a leak leaves it above 1, a double destroy
    takes it below 1 or aborts)."""
    var token = ArcPointer[Int](7)
    if token.count() != 1:
        raise Error("T4 setup: token should start with one owner")
    var vals = _i64s(1, 2, 3)
    var gids = _ints(0, 0, 0)
    var observed_while_alive = 0
    var total_seen = 0
    var holder = List[AccumulatorSet]()
    holder.append(AccumulatorSet())
    holder[0].add[_TokenAcc](_TokenAcc(token), 0, 0, UInt8(0))
    holder[0].add[_TokenAcc](_TokenAcc(token), 0, 1, UInt8(0))
    observed_while_alive = Int(token.count())
    holder[0].update(0, Span(gids), _bytes(vals), 0, 3)
    holder[0].update(1, Span(gids), _bytes(vals), 0, 3)
    total_seen = holder[0].dyn_accs[0].num_groups() + holder[0].dyn_accs[1].num_groups()
    if observed_while_alive != 3:
        raise Error("T4 FAIL: two stored accumulators should hold 2 extra owners, count=" + String(observed_while_alive))
    if total_seen != 12:
        raise Error("T4 FAIL: each kernel must update its own accumulator, total=" + String(total_seen))
    holder.clear()
    if token.count() != 1:
        raise Error("T4 FAIL: accumulators not destroyed exactly once, count=" + String(Int(token.count())))
    print("    PASS test_each_accumulator_destroyed_exactly_once")


def main() raises:
    print("Running AccumulatorSet integration tests...")
    test_heterogeneous_accumulator_set()
    test_kernel_matches_direct()
    test_update_after_the_set_moves()
    test_each_accumulator_destroyed_exactly_once()
    print("All AccumulatorSet tests passed (4/4)")
