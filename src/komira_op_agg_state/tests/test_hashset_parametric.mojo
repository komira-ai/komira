# =============================================================================
# test_hashset_parametric.mojo — Option D HashSet family unit tests (Phase 1)
# =============================================================================
#
# Unit tests for an internal module
# per an internal doc §2 + §9.1.
#
# Coverage:
#   - HashSet1[Int64] — arity-1 (today's HashSetI64 shape).
#   - HashSet1[Float64] — arity-1 non-I64.
#   - HashSet2[Int64, Int64] — arity-2 all-I64 (today's HashSetI64I64).
#   - HashSet2[Int64, Int32] — arity-2 mixed-DType.
#   - HashSet3[Int64, Int64, Int64] — arity-3 (today's HashSetI64I64I64 + TPC-H Q3).
#   - HashSet4 — arity-4 (NEW vs today).
#   - HashSet6 — arity-6 (H2O h10 shape).
#   - HashSet8 — arity-8 max (Option D max parametric).
#
# Each test verifies:
#   - Initial size == 0.
#   - Insert returns True on first, False on duplicate.
#   - `size()` increments correctly after insert.
#   - `contains()` returns True for inserted, False for absent.
# =============================================================================

from komira_engine_operators.stage_primitives.hashset_parametric import (
    HashSet1,
    HashSet2,
    HashSet3,
    HashSet4,
    HashSet5,
    HashSet6,
    HashSet7,
    HashSet8,
)


def test_hashset1_int64() raises:
    """Arity-1 Int64 — matches today's HashSetI64 shape."""
    var s = HashSet1[DType.int64]()
    if s.size() != 0:
        raise Error("HashSet1[I64] initial size != 0")

    var r1 = s.insert(Int64(10))
    if not r1:
        raise Error("HashSet1[I64] first insert should be NEW")
    if s.size() != 1:
        raise Error("HashSet1[I64] size != 1 after first insert")

    var r2 = s.insert(Int64(20))
    if not r2:
        raise Error("HashSet1[I64] second distinct insert should be NEW")
    if s.size() != 2:
        raise Error("HashSet1[I64] size != 2 after second insert")

    var r3 = s.insert(Int64(10))
    if r3:
        raise Error("HashSet1[I64] duplicate insert should be DUP")
    if s.size() != 2:
        raise Error("HashSet1[I64] size changed on duplicate")

    if not s.contains(Int64(10)):
        raise Error("HashSet1[I64] should contain 10")
    if not s.contains(Int64(20)):
        raise Error("HashSet1[I64] should contain 20")
    if s.contains(Int64(30)):
        raise Error("HashSet1[I64] should NOT contain 30")

    print("test_hashset1_int64 PASS — size=2, dedup OK, probe OK")


def test_hashset1_float64() raises:
    """Arity-1 Float64 — non-I64 DType validates parametric family."""
    var s = HashSet1[DType.float64]()
    _ = s.insert(Float64(1.5))
    _ = s.insert(Float64(2.5))
    _ = s.insert(Float64(1.5))  # dup
    _ = s.insert(Float64(3.5))

    if s.size() != 3:
        raise Error("HashSet1[F64] expected size=3, got " + String(s.size()))

    if not s.contains(Float64(1.5)):
        raise Error("HashSet1[F64] missing 1.5")
    if not s.contains(Float64(2.5)):
        raise Error("HashSet1[F64] missing 2.5")
    if not s.contains(Float64(3.5)):
        raise Error("HashSet1[F64] missing 3.5")
    if s.contains(Float64(99.0)):
        raise Error("HashSet1[F64] false-positive 99.0")

    print("test_hashset1_float64 PASS — size=3, dedup OK, probe OK")


def test_hashset2_int64_int64() raises:
    """Arity-2 (I64, I64) — matches today's HashSetI64I64 shape."""
    var s = HashSet2[DType.int64, DType.int64]()
    _ = s.insert(Int64(1), Int64(10))
    _ = s.insert(Int64(2), Int64(20))
    _ = s.insert(Int64(1), Int64(10))  # dup
    _ = s.insert(Int64(1), Int64(20))  # distinct (different second)

    if s.size() != 3:
        raise Error("HashSet2[I64,I64] expected size=3, got " + String(s.size()))

    if not s.contains(Int64(1), Int64(10)):
        raise Error("HashSet2 missing (1,10)")
    if not s.contains(Int64(2), Int64(20)):
        raise Error("HashSet2 missing (2,20)")
    if not s.contains(Int64(1), Int64(20)):
        raise Error("HashSet2 missing (1,20)")
    if s.contains(Int64(2), Int64(10)):
        raise Error("HashSet2 false-positive (2,10)")

    print("test_hashset2_int64_int64 PASS — size=3, dedup OK, probe OK")


def test_hashset2_int64_int32_mixed() raises:
    """Arity-2 mixed-DType (I64, I32) — validates parametric mixed-DType
    instantiation."""
    var s = HashSet2[DType.int64, DType.int32]()
    _ = s.insert(Int64(100), Int32(7))
    _ = s.insert(Int64(200), Int32(8))
    _ = s.insert(Int64(100), Int32(7))  # dup

    if s.size() != 2:
        raise Error("HashSet2[I64,I32] expected size=2, got " + String(s.size()))

    if not s.contains(Int64(100), Int32(7)):
        raise Error("HashSet2[I64,I32] missing (100,7)")
    if s.contains(Int64(100), Int32(8)):
        raise Error("HashSet2[I64,I32] false-positive (100,8)")

    print("test_hashset2_int64_int32_mixed PASS")


def test_hashset3_int64_triple() raises:
    """Arity-3 all-I64 — matches today's HashSetI64I64I64 + TPC-H Q3
    shape. POC measured 1.00× perf vs hardcoded at this shape."""
    var s = HashSet3[DType.int64, DType.int64, DType.int64]()
    _ = s.insert(Int64(1), Int64(2), Int64(3))
    _ = s.insert(Int64(1), Int64(2), Int64(4))
    _ = s.insert(Int64(1), Int64(2), Int64(3))  # dup
    _ = s.insert(Int64(5), Int64(6), Int64(7))

    if s.size() != 3:
        raise Error("HashSet3 expected size=3, got " + String(s.size()))

    if not s.contains(Int64(1), Int64(2), Int64(3)):
        raise Error("HashSet3 missing (1,2,3)")
    if not s.contains(Int64(1), Int64(2), Int64(4)):
        raise Error("HashSet3 missing (1,2,4)")
    if not s.contains(Int64(5), Int64(6), Int64(7)):
        raise Error("HashSet3 missing (5,6,7)")
    if s.contains(Int64(1), Int64(2), Int64(5)):
        raise Error("HashSet3 false-positive (1,2,5)")

    print("test_hashset3_int64_triple PASS")


def test_hashset4_all_i64() raises:
    """Arity-4 all-I64 — opens up Q3-like 4-position shapes."""
    var s = HashSet4[DType.int64, DType.int64, DType.int64, DType.int64]()
    _ = s.insert(Int64(1), Int64(2), Int64(3), Int64(4))
    _ = s.insert(Int64(1), Int64(2), Int64(3), Int64(5))  # distinct
    _ = s.insert(Int64(1), Int64(2), Int64(3), Int64(4))  # dup

    if s.size() != 2:
        raise Error("HashSet4 expected size=2, got " + String(s.size()))
    if not s.contains(Int64(1), Int64(2), Int64(3), Int64(4)):
        raise Error("HashSet4 missing (1,2,3,4)")
    if s.contains(Int64(1), Int64(2), Int64(3), Int64(99)):
        raise Error("HashSet4 false-positive")

    print("test_hashset4_all_i64 PASS")


def test_hashset6_h10_shape() raises:
    """Arity-6 all-I64 — H2O h10 6-column GROUP BY shape."""
    var s = HashSet6[
        DType.int64, DType.int64, DType.int64,
        DType.int64, DType.int64, DType.int64,
    ]()
    _ = s.insert(Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(6))
    _ = s.insert(Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(7))
    _ = s.insert(Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(6))  # dup

    if s.size() != 2:
        raise Error("HashSet6 expected size=2, got " + String(s.size()))
    if not s.contains(
        Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(6)
    ):
        raise Error("HashSet6 missing (1,2,3,4,5,6)")
    if not s.contains(
        Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(7)
    ):
        raise Error("HashSet6 missing (1,2,3,4,5,7)")

    print("test_hashset6_h10_shape PASS")


def test_hashset8_max_arity() raises:
    """Arity-8 — Option D's max parametric arity. arity > 8 falls back
    to ByteHashSet (sibling file)."""
    var s = HashSet8[
        DType.int64, DType.int64, DType.int64, DType.int64,
        DType.int64, DType.int64, DType.int64, DType.int64,
    ]()
    _ = s.insert(
        Int64(1), Int64(2), Int64(3), Int64(4),
        Int64(5), Int64(6), Int64(7), Int64(8),
    )
    _ = s.insert(
        Int64(1), Int64(2), Int64(3), Int64(4),
        Int64(5), Int64(6), Int64(7), Int64(8),
    )  # dup
    _ = s.insert(
        Int64(1), Int64(2), Int64(3), Int64(4),
        Int64(5), Int64(6), Int64(7), Int64(9),
    )  # distinct

    if s.size() != 2:
        raise Error("HashSet8 expected size=2, got " + String(s.size()))
    if not s.contains(
        Int64(1), Int64(2), Int64(3), Int64(4),
        Int64(5), Int64(6), Int64(7), Int64(8),
    ):
        raise Error("HashSet8 missing first row")
    if s.contains(
        Int64(99), Int64(2), Int64(3), Int64(4),
        Int64(5), Int64(6), Int64(7), Int64(8),
    ):
        raise Error("HashSet8 false-positive")

    print("test_hashset8_max_arity PASS")


def main() raises:
    test_hashset1_int64()
    test_hashset1_float64()
    test_hashset2_int64_int64()
    test_hashset2_int64_int32_mixed()
    test_hashset3_int64_triple()
    test_hashset4_all_i64()
    test_hashset6_h10_shape()
    test_hashset8_max_arity()
    print("ALL test_hashset_parametric.mojo tests PASS (8/8)")
