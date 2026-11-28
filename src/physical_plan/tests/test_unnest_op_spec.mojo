# =============================================================================
# test_unnest_op_spec: the OP_UNNEST arm of MorselOp
# =============================================================================
#
# Tests, and the behaviour each asserts:
#   test_the_unnest_tag_is_new_and_reuses_no_retired_or_live_tag
#       OP_UNNEST is 16 and differs from every live MorselOp tag and from the
#       retired values 4-13.
#   test_unnest_records_its_column_and_flag_and_no_other_arm
#       `MorselOp.unnest` keeps the column name and the keep-empty flag and
#       leaves the filter, project, limit, probe and udf fields at defaults.
#   test_every_other_op_carries_the_unnest_defaults
#       A filter-free op built from another factory has an empty unnest column
#       and keep_empty False.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from physical_plan.physical_plan import (
    MorselOp,
    OP_FILTER,
    OP_JOIN_PROBE,
    OP_LIMIT,
    OP_PROJECT,
    OP_UDF_APPLY,
    OP_UDF_FRAME,
    OP_UNNEST,
)


def test_the_unnest_tag_is_new_and_reuses_no_retired_or_live_tag() raises:
    assert_equal(Int(OP_UNNEST), 16)
    var live = List[Int]()
    live.append(Int(OP_FILTER))
    live.append(Int(OP_PROJECT))
    live.append(Int(OP_LIMIT))
    live.append(Int(OP_JOIN_PROBE))
    live.append(Int(OP_UDF_APPLY))
    live.append(Int(OP_UDF_FRAME))
    for i in range(len(live)):
        assert_true(live[i] != Int(OP_UNNEST))
    for retired in range(4, 14):
        assert_true(retired != Int(OP_UNNEST))


def test_unnest_records_its_column_and_flag_and_no_other_arm() raises:
    var op = MorselOp.unnest("tags", True)
    assert_equal(Int(op.tag), Int(OP_UNNEST))
    assert_equal(op.unnest_column, "tags")
    assert_true(op.unnest_keep_empty)
    assert_false(Bool(op.filter_predicate))
    assert_false(Bool(op.project_exprs))
    assert_false(Bool(op.project_names))
    assert_equal(op.limit_count, -1)
    assert_equal(op.probe_build_seg, -1)
    assert_equal(len(op.probe_left_keys), 0)
    assert_false(Bool(op.udf))
    var plain = MorselOp.unnest("xs", False)
    assert_false(plain.unnest_keep_empty)


def test_every_other_op_carries_the_unnest_defaults() raises:
    var lim = MorselOp.limit(3)
    assert_equal(lim.unnest_column, "")
    assert_false(lim.unnest_keep_empty)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
