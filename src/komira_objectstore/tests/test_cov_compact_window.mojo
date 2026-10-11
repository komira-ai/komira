# =============================================================================
# tests/test_cov_compact_window.mojo
#   compact_once's LOST outcome and run_clamped_retire's best-effort retire,
#   over a scripted CompactionSource.
# =============================================================================
#
# What each case catches:
#   * a LOST watermark advance that still retires inputs (the winner owns the
#     reap window) or reports the wrong range / counts;
#   * one failing retire aborting the rest of the range (or the compaction),
#     or being counted as retired;
#   * a no-op range reporting a non-zero span.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.compact_window import (
    COMPACT_LOST,
    CompactProduct,
    CompactRange,
    CompactSummary,
    CompactionSource,
    compact_once,
    run_clamped_retire,
)


struct _Src(CompactionSource, Movable, Deinitable):
    comptime OutputRef = Int64

    var lo: Int64
    var hi: Int64
    var win: Bool
    var fail_idx: Int64
    var retired: List[Int64]
    var attempted: List[Int64]

    def __init__(out self, lo: Int64, hi: Int64, win: Bool, fail_idx: Int64 = Int64(-1)):
        self.lo = lo
        self.hi = hi
        self.win = win
        self.fail_idx = fail_idx
        self.retired = List[Int64]()
        self.attempted = List[Int64]()

    def plan_range(mut self) raises -> CompactRange:
        return CompactRange(lo=self.lo, hi=self.hi)

    def fold_and_materialize(
        mut self, range: CompactRange
    ) raises -> CompactProduct[Int64]:
        return CompactProduct[Int64](range, Int64(77), range.hi, range.span() * Int64(10))

    def advance_watermark(mut self, product: CompactProduct[Int64]) raises -> Bool:
        return self.win

    def retire_input(mut self, idx: Int64) raises:
        self.attempted.append(idx)
        if idx == self.fail_idx:
            raise Error("transient retire failure")
        self.retired.append(idx)

    def safe_retire_floor(self, product: CompactProduct[Int64]) raises -> Int64:
        return product.materialized_thru + Int64(1)


def test_span() raises:
    assert_equal(CompactRange.noop().span(), Int64(0))
    assert_true(CompactRange.noop().is_noop())
    assert_equal(CompactRange(lo=Int64(2), hi=Int64(5)).span(), Int64(4))
    assert_equal(CompactRange(lo=Int64(3), hi=Int64(3)).span(), Int64(1))


def test_lost_advance_retires_nothing() raises:
    var src = _Src(Int64(2), Int64(4), win=False)
    var s = compact_once[_Src](src)
    assert_equal(s.outcome, COMPACT_LOST)
    assert_true(s.lost())
    assert_false(s.won())
    assert_false(s.is_noop())
    assert_equal(s.lo, Int64(2))
    assert_equal(s.hi, Int64(4))
    assert_equal(s.materialized_thru, Int64(4))
    assert_equal(s.retired_count, Int64(0))
    assert_equal(s.row_count, Int64(30))
    assert_equal(len(src.attempted), 0)


def test_retire_failure_is_best_effort() raises:
    var src = _Src(Int64(0), Int64(3), win=True, fail_idx=Int64(1))
    var s = compact_once[_Src](src)
    assert_true(s.won())
    # idx 1 failed: the other three are retired, every one was attempted.
    assert_equal(s.retired_count, Int64(3))
    assert_equal(len(src.attempted), 4)
    assert_equal(src.attempted[3], Int64(3))
    assert_equal(len(src.retired), 3)
    assert_equal(src.retired[1], Int64(2))
    # The helper alone, with the failure on the last index.
    var src2 = _Src(Int64(0), Int64(1), win=True, fail_idx=Int64(1))
    var p = CompactProduct[Int64](CompactRange(lo=Int64(0), hi=Int64(1)), Int64(1), Int64(1))
    assert_equal(run_clamped_retire[_Src](src2, CompactRange(lo=Int64(0), hi=Int64(1)), p), Int64(1))


def main() raises:
    test_span()
    test_lost_advance_retires_nothing()
    test_retire_failure_is_best_effort()
    print("[test_cov_compact_window] PASS")
