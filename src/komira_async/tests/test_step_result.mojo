# =============================================================================
# test_step_result.mojo
# =============================================================================
# StepResult[T] discriminated
# value type tests.
#
# Covers:
#   * Each constructor returns the expected variant + payload.
#   * Variant predicates are mutually exclusive.
#   * Accessors return Optional for non-matching variants (no crash).
#   * StepResult[T] elaborates for multiple T (Int, Int64, String).
#   * StepResult is Movable + Copyable (round-trip through a List + copy).
#   * Hot-path constructors do not heap-allocate the unused payloads
#     (smoke; we just ensure they construct + drop without leaking).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.runtime.step_result import (
    StepResult,
    STEP_DONE,
    STEP_ERR,
    STEP_PARKED,
    STEP_YIELDED,
)


def test_step_result_yielded_int() raises:
    """yielded() carries the value; predicates + accessors agree."""
    var sr = StepResult[Int].yielded(value=42)
    assert_true(sr.is_yielded())
    assert_false(sr.is_parked())
    assert_false(sr.is_done())
    assert_false(sr.is_error())
    assert_equal(Int(sr.kind()), Int(STEP_YIELDED))
    var m = sr.morsel()
    assert_true(m.__bool__())
    assert_equal(m.value(), 42)
    # op_id() returns 0 sentinel for non-parked variants.
    assert_equal(sr.op_id(), Int64(0))
    # err() returns None for non-error variants.
    assert_false(sr.err().__bool__())


def test_step_result_parked() raises:
    """parked(op_id) carries the op_id; non-parked accessors return None."""
    var sr = StepResult[Int].parked(op_id=Int64(12345))
    assert_false(sr.is_yielded())
    assert_true(sr.is_parked())
    assert_false(sr.is_done())
    assert_false(sr.is_error())
    assert_equal(Int(sr.kind()), Int(STEP_PARKED))
    assert_equal(sr.op_id(), Int64(12345))
    # morsel() returns None for non-yielded variants.
    var m = sr.morsel()
    assert_false(m.__bool__())


def test_step_result_done() raises:
    """done() has no payload; predicates agree."""
    var sr = StepResult[Int].done()
    assert_false(sr.is_yielded())
    assert_false(sr.is_parked())
    assert_true(sr.is_done())
    assert_false(sr.is_error())
    assert_equal(Int(sr.kind()), Int(STEP_DONE))


def test_step_result_error() raises:
    """error(text) carries the error text; err() + err_text() agree."""
    var sr = StepResult[Int].error(err=String("EAGAIN op_id=42"))
    assert_false(sr.is_yielded())
    assert_false(sr.is_parked())
    assert_false(sr.is_done())
    assert_true(sr.is_error())
    assert_equal(Int(sr.kind()), Int(STEP_ERR))
    var e = sr.err()
    assert_true(e.__bool__())
    assert_equal(e.value(), String("EAGAIN op_id=42"))
    assert_equal(sr.err_text(), String("EAGAIN op_id=42"))


def test_step_result_int64_elaborates() raises:
    """T parameter elaborates for Int64."""
    var sr = StepResult[Int64].yielded(value=Int64(0xDEAD_BEEF))
    assert_true(sr.is_yielded())
    assert_equal(sr.morsel().value(), Int64(0xDEAD_BEEF))


def test_step_result_string_elaborates() raises:
    """T parameter elaborates for String (heap-tracking T)."""
    var sr = StepResult[String].yielded(value=String("hello, morsel"))
    assert_true(sr.is_yielded())
    assert_equal(sr.morsel().value(), String("hello, morsel"))


def test_step_result_copyable_smoke() raises:
    """StepResult IS Copyable — round-trip through an explicit copy ctor.
    NOT ImplicitlyCopyable (matches IoOp's invariant — call sites must be
    explicit when a copy is needed)."""
    var sr = StepResult[Int].yielded(value=7)
    var sr_copy = StepResult[Int](copy=sr)  # explicit copy ctor
    assert_true(sr_copy.is_yielded())
    assert_equal(sr_copy.morsel().value(), 7)
    # Original still valid (Copyable preserves the source).
    assert_true(sr.is_yielded())
    assert_equal(sr.morsel().value(), 7)


def test_step_result_movable_through_list() raises:
    """StepResult lives in a List; round-trip preserves variants."""
    var lst = List[StepResult[Int]]()
    lst.append(StepResult[Int].yielded(value=1))
    lst.append(StepResult[Int].parked(op_id=Int64(2)))
    lst.append(StepResult[Int].done())
    lst.append(StepResult[Int].error(err=String("e")))
    assert_equal(len(lst), 4)
    assert_true(lst[0].is_yielded())
    assert_equal(lst[0].morsel().value(), 1)
    assert_true(lst[1].is_parked())
    assert_equal(lst[1].op_id(), Int64(2))
    assert_true(lst[2].is_done())
    assert_true(lst[3].is_error())
    assert_equal(lst[3].err_text(), String("e"))


def test_step_result_drop_smoke() raises:
    """Construct + drop many in a tight loop — exercises String / Optional
    drop paths under the discriminated value. Smoke; failure mode is leak
    or crash."""
    var i = 0
    while i < 1024:
        var sr_y = StepResult[Int].yielded(value=i)
        _ = sr_y.morsel()
        var sr_p = StepResult[Int].parked(op_id=Int64(i))
        _ = sr_p.op_id()
        var sr_d = StepResult[Int].done()
        _ = sr_d.is_done()
        var sr_e = StepResult[Int].error(err=String("err"))
        _ = sr_e.err_text()
        i = i + 1
    assert_true(True)


def test_step_result_parked_any_single() raises:
    """parked_any(op_id) is the canonical depth=1 form; same observable
    shape as the back-compat parked(op_id) sugar."""
    var sr = StepResult[Int].parked_any(op_id=Int64(99))
    assert_true(sr.is_parked())
    assert_equal(sr.op_id(), Int64(99))
    assert_equal(sr.op_ids_len(), 1)
    var ids = sr.op_ids()
    assert_equal(len(ids), 1)
    assert_equal(ids[0], Int64(99))


def test_step_result_parked_any_multi() raises:
    """parked_any(List[Int64]) is the bulk-parallel form; the worker
    indexes the morsel under ALL ids in the set."""
    var ids = List[Int64](capacity=4)
    ids.append(Int64(11))
    ids.append(Int64(22))
    ids.append(Int64(33))
    ids.append(Int64(44))
    var sr = StepResult[Int].parked_any(op_ids=ids^)
    assert_true(sr.is_parked())
    # op_id() returns the first id (single-op call-site shape).
    assert_equal(sr.op_id(), Int64(11))
    assert_equal(sr.op_ids_len(), 4)
    var got = sr.op_ids()
    assert_equal(len(got), 4)
    assert_equal(got[0], Int64(11))
    assert_equal(got[1], Int64(22))
    assert_equal(got[2], Int64(33))
    assert_equal(got[3], Int64(44))


def test_step_result_parked_any_empty_list() raises:
    """parked_any with empty list is accepted; the worker treats this as
    a parked morsel with no wake source (typically caller error, but we
    don't crash). op_id() returns the 0 sentinel."""
    var sr = StepResult[Int].parked_any(op_ids=List[Int64]())
    assert_true(sr.is_parked())
    assert_equal(sr.op_id(), Int64(0))
    assert_equal(sr.op_ids_len(), 0)


def test_step_result_op_ids_empty_for_non_parked() raises:
    """op_ids() returns an empty list for non-PARKED variants; never
    crashes."""
    var sr_y = StepResult[Int].yielded(value=1)
    assert_equal(len(sr_y.op_ids()), 0)
    assert_equal(sr_y.op_ids_len(), 0)
    var sr_d = StepResult[Int].done()
    assert_equal(len(sr_d.op_ids()), 0)
    var sr_e = StepResult[Int].error(err=String("e"))
    assert_equal(len(sr_e.op_ids()), 0)


def main() raises:
    test_step_result_yielded_int()
    test_step_result_parked()
    test_step_result_done()
    test_step_result_error()
    test_step_result_int64_elaborates()
    test_step_result_string_elaborates()
    test_step_result_copyable_smoke()
    test_step_result_movable_through_list()
    test_step_result_drop_smoke()
    test_step_result_parked_any_single()
    test_step_result_parked_any_multi()
    test_step_result_parked_any_empty_list()
    test_step_result_op_ids_empty_for_non_parked()
    print("PASS komira_async.runtime.step_result (multi-op parked_any)")
