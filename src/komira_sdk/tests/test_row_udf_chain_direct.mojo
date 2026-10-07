# =============================================================================
# row_udf_chain: the three chain states, their transitions and the plan each
# one carries.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * each chain hands back the scan plan it was built over (`take_plan`
#     returning a fresh plan, or the wrong one);
#   * `RowMapChain.filter[p]()` and `RowFilterChain.map[m]()` both reach a
#     `RowChain` over the same plan, carrying the map and the filter they were
#     given (a transition that drops the plan or a UDF);
#   * the map and filter UDF types derive their schemas from the row structs
#     and two different identities, so `check_identities` passes;
#   * an explicit `map_id` / `filter_id` changes the derived identity.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET
from komira_udf.auto_komira_schema import AutoKomiraSchema

from komira_sdk.row_udf_chain import RowChain, RowFilterChain, RowMapChain


@fieldwise_init
struct Order(AutoKomiraSchema, Copyable, Movable):
    var price: Float64
    var cost: Float64


@fieldwise_init
struct Priced(AutoKomiraSchema, Copyable, Movable):
    var margin: Float64


def margin(row: Order) -> Priced:
    return Priced((row.price - row.cost) / row.price)


def cheap(row: Order) -> Bool:
    return row.price < 100.0


def _scan(path: String) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("price", ArrowType.FLOAT64, False))
    sb.add_field(Field("cost", ArrowType.FLOAT64, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _path(plan: LogicalPlan) -> String:
    return plan.scan_data_ref().source_path


def test_map_chain_then_filter() raises:
    var m = RowMapChain[m=margin](Optional[LogicalPlan](_scan("m.parquet")))
    comptime MU = RowMapChain[m=margin].MapUdf
    assert_equal(MU.ARITY, 1, "the map's output row has one field")
    comptime n_in = MU.InputSchema.num_cols()
    comptime n_out = MU.OutputSchema.num_cols()
    assert_equal(n_in, 2, "the map reads the scan row")
    assert_equal(n_out, 1)
    var both = m^.filter[cheap]()
    assert_equal(_path(both.take_plan()), "m.parquet", "the plan is carried")


def test_filter_chain_then_map() raises:
    var f = RowFilterChain[p=cheap](Optional[LogicalPlan](_scan("f.parquet")))
    comptime FU = RowFilterChain[p=cheap].FilterUdf
    comptime n_in = FU.InputSchema.num_cols()
    assert_equal(n_in, 2)
    var both = f^.map[margin]()
    assert_equal(_path(both.take_plan()), "f.parquet")


def test_take_plan_on_each_state() raises:
    var m = RowMapChain[m=margin](Optional[LogicalPlan](_scan("a.parquet")))
    assert_equal(_path(m.take_plan()), "a.parquet")
    var f = RowFilterChain[p=cheap](Optional[LogicalPlan](_scan("b.parquet")))
    assert_equal(_path(f.take_plan()), "b.parquet")
    var c = RowChain[m=margin, p=cheap](Optional[LogicalPlan](_scan("c.parquet")))
    assert_equal(_path(c.take_plan()), "c.parquet")


def test_identities() raises:
    RowChain[m=margin, p=cheap].check_identities()
    comptime C = RowChain[m=margin, p=cheap]
    assert_true(C.MapUdf.UDF_ID != C.FilterUdf.UDF_ID, "map and filter differ")
    comptime Named = RowChain[m=margin, p=cheap, map_id="m1", filter_id="f1"]
    Named.check_identities()
    assert_true(Named.MapUdf.UDF_ID != C.MapUdf.UDF_ID, "an id changes the map's")
    assert_true(
        Named.FilterUdf.UDF_ID != C.FilterUdf.UDF_ID, "an id changes the filter's"
    )
    # The ids carry through the transitions.
    var m = RowMapChain[m=margin, map_id="m1"](Optional[LogicalPlan](_scan("x.parquet")))
    var both = m^.filter[cheap, filter_id="f1"]()
    both.check_identities()
    _ = both.take_plan()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
