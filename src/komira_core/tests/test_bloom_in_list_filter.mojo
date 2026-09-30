# =============================================================================
# Unit tests for InListFilter (bloom pushdown)
# =============================================================================
#
# Covers the Int64-key variant (the dominant TPC-H Q18 / SQL-PK shape).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_core.collections.in_list_filter import (
    IN_LIST_THRESHOLD,
    InListFilter,
)


# -----------------------------------------------------------------------------
# Scenario `in_list_i64_within_threshold`.
# 9 rows with 3 distinct values -> filter has 3 entries.
# -----------------------------------------------------------------------------
def test_within_threshold() raises:
    var values = List[Int64]()
    values.append(1)
    values.append(2)
    values.append(3)
    values.append(2)
    values.append(1)
    values.append(3)
    values.append(1)
    values.append(2)
    values.append(3)

    var maybe = InListFilter.try_from_int64(values)
    assert_true(maybe.__bool__())
    var filter = maybe.take()
    assert_equal(filter.size(), 3)
    assert_true(filter.contains_int64(1))
    assert_true(filter.contains_int64(2))
    assert_true(filter.contains_int64(3))
    assert_false(filter.contains_int64(4))


# -----------------------------------------------------------------------------
# Scenario `in_list_i64_exceeds_threshold`.
# 129 distinct values -> exceeds IN_LIST_THRESHOLD (128) -> None.
# -----------------------------------------------------------------------------
def test_exceeds_threshold() raises:
    var values = List[Int64]()
    for i in range(129):
        values.append(Int64(i))

    var maybe = InListFilter.try_from_int64(values)
    assert_false(maybe.__bool__())


# -----------------------------------------------------------------------------
# Scenario `in_list_i64_at_threshold_boundary`.
# 127 distinct values -> exactly at boundary, succeeds.
# -----------------------------------------------------------------------------
def test_at_threshold_boundary() raises:
    var values = List[Int64]()
    for i in range(127):
        values.append(Int64(i))

    var maybe = InListFilter.try_from_int64(values)
    assert_true(maybe.__bool__())
    var filter = maybe.take()
    assert_equal(filter.size(), 127)


# -----------------------------------------------------------------------------
# Scenario `in_list_empty_array`.
# Empty input -> None (in-list filter must have at least one element).
# -----------------------------------------------------------------------------
def test_empty_array() raises:
    var values = List[Int64]()
    var maybe = InListFilter.try_from_int64(values)
    assert_false(maybe.__bool__())


# -----------------------------------------------------------------------------
# All-duplicates array: 100 rows with 1 distinct value -> filter has 1 entry.
# -----------------------------------------------------------------------------
def test_all_duplicates() raises:
    var values = List[Int64]()
    for _ in range(100):
        values.append(42)

    var maybe = InListFilter.try_from_int64(values)
    assert_true(maybe.__bool__())
    var filter = maybe.take()
    assert_equal(filter.size(), 1)
    assert_true(filter.contains_int64(42))
    assert_false(filter.contains_int64(43))


# -----------------------------------------------------------------------------
# IN_LIST_THRESHOLD constant.
# -----------------------------------------------------------------------------
def test_threshold_constant() raises:
    assert_equal(IN_LIST_THRESHOLD, 128)


# -----------------------------------------------------------------------------
# Filter is Movable + Copyable: clone preserves contents.
# -----------------------------------------------------------------------------
def test_copy_semantics() raises:
    var values = List[Int64]()
    values.append(10)
    values.append(20)
    values.append(30)

    var maybe = InListFilter.try_from_int64(values)
    assert_true(maybe.__bool__())
    var f1 = maybe.take()
    var f2 = f1.copy()
    assert_equal(f1.size(), f2.size())
    assert_true(f2.contains_int64(20))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
