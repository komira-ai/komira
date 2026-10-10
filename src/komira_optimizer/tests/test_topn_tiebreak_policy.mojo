# =============================================================================
# test_topn_tiebreak_policy.mojo -- the optimizer's reading of the TopN
# deterministic tie-break, checked directly.
# =============================================================================
#
# `push_topn_below_project` proves a rewrite safe by comparing two tie-break
# lists built by `append_deterministic_tiebreak_schema`, so a wrong list here
# turns that proof into a wrong answer on ties. These tests pin the rule the
# module header states: every INT64 / INT32 / FLOAT64 column that is not
# already a key, in schema order, ascending, appended after the given keys.
# (An agreement test against the executor's copy of the rule needs the
# executor, which is not in this tree; it is an integration test, not this
# module's coverage.)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_optimizer.topn_tiebreak_policy import (
    tiebreak_admits_type,
    append_deterministic_tiebreak_schema,
)


def test_admitted_types_are_exactly_int64_int32_float64() raises:
    # Defect: a dropped admitted type (the list misses a tie column) or a
    # widened one (a STRING key would turn the bounded heap the header describes
    # into a full sort, and the list would no longer match the header's rule).
    assert_true(tiebreak_admits_type(ArrowType.INT64))
    assert_true(tiebreak_admits_type(ArrowType.INT32))
    assert_true(tiebreak_admits_type(ArrowType.FLOAT64))
    assert_false(tiebreak_admits_type(ArrowType.FLOAT32))
    assert_false(tiebreak_admits_type(ArrowType.INT16))
    assert_false(tiebreak_admits_type(ArrowType.UINT64))
    assert_false(tiebreak_admits_type(ArrowType.STRING))
    assert_false(tiebreak_admits_type(ArrowType.BOOL))


def _schema() -> Schema:
    """[s STRING, a INT64, b FLOAT64, d INT16, c INT32]."""
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.FLOAT64, True))
    sb.add_field(Field("d", ArrowType.INT16, True))
    sb.add_field(Field("c", ArrowType.INT32, True))
    return sb.build()


def test_appends_admitted_non_key_columns_in_schema_order_ascending() raises:
    # keys [b DESC] over the schema above widens to [b DESC, a, c]: b is
    # already a key (skipped, not repeated), s and d are not admitted, a and c
    # are appended in schema order, ascending. Defect: a key repeated, schema
    # order lost, a non-admitted column appended, or a DESC tie-break.
    var keys = List[String]()
    keys.append("b")
    var desc = List[Bool]()
    desc.append(True)
    append_deterministic_tiebreak_schema(_schema(), keys, desc)
    assert_equal(len(keys), 3)
    assert_equal(len(desc), 3)
    assert_equal(keys[0], "b")
    assert_equal(keys[1], "a")
    assert_equal(keys[2], "c")
    assert_true(desc[0], "the explicit key keeps its direction")
    assert_false(desc[1])
    assert_false(desc[2])


def test_no_keys_appends_every_admitted_column() raises:
    # Defect: the already-key scan matches when the key list is empty.
    var keys = List[String]()
    var desc = List[Bool]()
    append_deterministic_tiebreak_schema(_schema(), keys, desc)
    assert_equal(len(keys), 3)
    assert_equal(keys[0], "a")
    assert_equal(keys[1], "b")
    assert_equal(keys[2], "c")


def test_every_admitted_column_already_a_key_appends_nothing() raises:
    # Defect: the inner scan stops at the first key and re-appends a later one.
    var keys = List[String]()
    keys.append("c")
    keys.append("a")
    keys.append("b")
    var desc = List[Bool]()
    desc.append(False)
    desc.append(True)
    desc.append(False)
    append_deterministic_tiebreak_schema(_schema(), keys, desc)
    assert_equal(len(keys), 3)
    assert_equal(len(desc), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
