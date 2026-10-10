# =============================================================================
# test_optimizer_scalar_deps -- the dependency channel, in isolation
# =============================================================================
#
# `ScalarDepTable` carries requests from the passes to a caller that executes
# plans (not in this tree) and bindings back. These tests pin its four contracts:
#   * a request is de-duplicated by (kind, key), keeping the FIRST plan;
#   * `clear_requests` drops requests and keeps bindings;
#   * a lookup matches kind AND key;
#   * a broadcast binding reaches its batch, schema and name through its own
#     aux index, not through the binding index.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.record_batch import RecordBatch
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET
from komira_scan_source.in_memory_source import InMemorySource

from komira_optimizer.optimizer_scalar_deps import (
    ScalarDepTable,
    DEP_SCALAR_SUBQUERY,
    DEP_SCALAR_BROADCAST,
)


def _schema(col: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(col, ArrowType.INT64, False))
    return sb.build()


def _scan(path: String, col: String) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(col))


def _source(col: String) raises -> InMemorySource:
    return InMemorySource.from_record_batch(
        RecordBatch.empty_from_schema(_schema(col))
    )


def test_a_fresh_table_is_empty() raises:
    # Catches: a constructor that pre-seeds a row, or `has_requests` reading
    # the bindings instead of the requests.
    var deps = ScalarDepTable()
    assert_equal(deps.num_requests(), 0)
    assert_false(deps.has_requests())
    assert_equal(deps.num_bindings(), 0)
    assert_equal(deps.binding_index(DEP_SCALAR_SUBQUERY, 1), -1)


def test_a_repeated_request_is_dropped_and_the_first_plan_kept() raises:
    # Catches: de-dup removed (two executions of one subquery), or de-dup that
    # overwrites the first request with the second.
    var deps = ScalarDepTable()
    var first = _scan(String("a.parquet"), String("x"))
    var first_hash = first.structural_hash()
    deps.request(DEP_SCALAR_SUBQUERY, 7, first^)
    deps.request(DEP_SCALAR_SUBQUERY, 7, _scan(String("b.parquet"), String("y")))
    assert_equal(deps.num_requests(), 1)
    assert_true(deps.has_requests())
    assert_equal(deps.request_plan(0).structural_hash(), first_hash)
    # A copy, not a move: asking twice returns the same plan twice.
    assert_equal(deps.request_plan(0).structural_hash(), first_hash)


def test_the_same_key_under_another_kind_is_a_second_request() raises:
    # Catches: de-dup on the key alone, which would drop a broadcast request
    # whose inner plan hashes like a scalar-subquery request.
    var deps = ScalarDepTable()
    deps.request(DEP_SCALAR_SUBQUERY, 7, _scan(String("a.parquet"), String("x")))
    deps.request(
        DEP_SCALAR_BROADCAST,
        7,
        _scan(String("a.parquet"), String("x")),
        3,
        String("total"),
    )
    assert_equal(deps.num_requests(), 2)
    assert_equal(Int(deps.request_kind(0)), Int(DEP_SCALAR_SUBQUERY))
    assert_equal(Int(deps.request_kind(1)), Int(DEP_SCALAR_BROADCAST))
    assert_equal(Int(deps.request_key(1)), 7)
    # The scalar-subquery row carries the defaults; the broadcast row its op.
    assert_equal(Int(deps.request_op(0)), 0)
    assert_equal(deps.request_col(0), String(""))
    assert_equal(Int(deps.request_op(1)), 3)
    assert_equal(deps.request_col(1), String("total"))


def test_clear_requests_keeps_the_bindings() raises:
    # Catches: `clear_requests` that also clears the bindings (the second
    # run of the passes would then miss again and the protocol loop never
    # ends).
    var deps = ScalarDepTable()
    deps.bind_scalar(5, ScalarValue.from_int(42))
    deps.request(DEP_SCALAR_SUBQUERY, 9, _scan(String("a.parquet"), String("x")))
    deps.clear_requests()
    assert_equal(deps.num_requests(), 0)
    assert_false(deps.has_requests())
    assert_equal(deps.num_bindings(), 1)
    var bi = deps.binding_index(DEP_SCALAR_SUBQUERY, 5)
    assert_equal(bi, 0)
    assert_equal(Int(deps.bound_scalar(bi).int_val), 42)
    # A request after the clear starts a fresh list.
    deps.request(DEP_SCALAR_SUBQUERY, 9, _scan(String("a.parquet"), String("x")))
    assert_equal(deps.num_requests(), 1)


def test_binding_lookup_matches_kind_and_key() raises:
    # Catches: a lookup on the key alone (a broadcast site would then read a
    # scalar binding that has no batch) or on the kind alone.
    var deps = ScalarDepTable()
    deps.bind_scalar(9, ScalarValue.from_int(1))
    assert_equal(deps.binding_index(DEP_SCALAR_SUBQUERY, 9), 0)
    assert_equal(deps.binding_index(DEP_SCALAR_BROADCAST, 9), -1)
    assert_equal(deps.binding_index(DEP_SCALAR_SUBQUERY, 10), -1)


def test_broadcast_bindings_reach_their_own_aux_rows() raises:
    # Catches: `bound_source` / `bound_schema` / `bound_name` indexing the aux
    # lists by the BINDING index. Binding 0 is a scalar row with no aux row, so
    # binding 1 owns aux row 0 and binding 2 owns aux row 1; indexing by the
    # binding index reads the wrong row or runs off the end.
    var deps = ScalarDepTable()
    deps.bind_scalar(1, ScalarValue.from_int(10))
    deps.bind_broadcast(
        2, ScalarValue.from_int(20), _source(String("g")), _schema(String("g")),
        String("cache_a"),
    )
    deps.bind_broadcast(
        3, ScalarValue.from_int(30), _source(String("h")), _schema(String("h")),
        String("cache_b"),
    )
    assert_equal(deps.num_bindings(), 3)
    var b2 = deps.binding_index(DEP_SCALAR_BROADCAST, 2)
    var b3 = deps.binding_index(DEP_SCALAR_BROADCAST, 3)
    assert_equal(b2, 1)
    assert_equal(b3, 2)
    assert_equal(Int(deps.bound_scalar(b2).int_val), 20)
    assert_equal(deps.bound_name(b2), String("cache_a"))
    assert_equal(deps.bound_schema(b2).field_name(0), String("g"))
    assert_equal(deps.bound_source(b2).schema().field_name(0), String("g"))
    assert_equal(Int(deps.bound_scalar(b3).int_val), 30)
    assert_equal(deps.bound_name(b3), String("cache_b"))
    assert_equal(deps.bound_schema(b3).field_name(0), String("h"))
    assert_equal(deps.bound_source(b3).schema().field_name(0), String("h"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
