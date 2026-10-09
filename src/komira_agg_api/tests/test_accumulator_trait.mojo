# =============================================================================
# Accumulator trait: a minimal conforming accumulator driven only through the
# trait (a generic function bound by `Accumulator`).
#
# What it proves: the trait's five methods have the signatures the kernel
# thunks call (raw group-id and value pointers plus a column offset and row
# count for update_batch; a Column out of finalize and flush), so an
# implementation written against the documented contract conforms, and a
# generic caller can drive one through ensure_capacity -> update_batch ->
# finalize. A renamed or re-typed trait method fails this file's compile.
# The accumulator is a per-group SUM over int64 values honouring
# `col_offset`, so the driver's result is checked, not only compiled.
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion

from komira_agg_api.accumulator_trait import Accumulator


struct SumI64Acc(Accumulator):
    var sums: List[Int64]

    def __init__(out self):
        self.sums = List[Int64]()

    def update_batch(
        mut self,
        gids_ptr: UnsafePointer[Int, MutUntrackedOrigin],
        col_data_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
        col_offset: Int,
        n: Int,
    ) raises:
        var vals = col_data_ptr.bitcast[Int64]()
        for i in range(n):
            self.sums[gids_ptr[i]] += vals[col_offset + i]

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        var a = PrimitiveArray[DType.int64].allocate(len(self.sums))
        for g in range(len(self.sums)):
            a.set(g, self.sums[g])
        return Column.from_primitive[DType.int64](a^)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()

    def ensure_capacity(mut self, n_groups: Int) raises:
        while len(self.sums) < n_groups:
            self.sums.append(0)

    def num_groups(self) -> Int:
        return len(self.sums)


def _drive[
    A: Accumulator
](mut acc: A, mut gids: List[Int], mut vals: List[Int64], offset: Int) raises -> Column[
    HeapRegion
]:
    acc.ensure_capacity(3)
    var gp = gids.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    var vp = vals.unsafe_ptr().bitcast[UInt8]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    acc.update_batch(gp, vp, offset, len(gids))
    return acc.finalize_to_column()


def test_generic_driver_sums_per_group() raises:
    var acc = SumI64Acc()
    var gids: List[Int] = [0, 2, 0, 1]
    # The first value sits before the offset and must not be read.
    var vals: List[Int64] = [1000, 5, 7, 11, 13]
    var col = _drive(acc, gids, vals, 1)
    assert_equal(acc.num_groups(), 3)
    var out = col.as_primitive[DType.int64]()
    assert_equal(out.get(0), 5 + 11)
    assert_equal(out.get(1), 13)
    assert_equal(out.get(2), 7)
    var flushed = acc.flush_partial_to_column().as_primitive[DType.int64]()
    assert_equal(flushed.get(0), 16)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
