"""`komira_pandas_door_e2e` -- the pandas and polars doors' wire contract,
without Python.

A pandas-shaped and a polars-shaped frontend hand the engine `komira.plan.v1`
plans. The fixtures (`fixtures/<stem>.txtpb`) are those plans as protobuf
text. protoc encodes each one in a build action (`proto_encode`), so the bytes
the tests read come from the reference implementation, not from this
repository's encoder.

The pandas shapes: `sort_values` (`na_position` first and last), `merge`
(`how` left and inner), `groupby` (`size()`, which is `count(*)`, and
`agg(n=(col, "count"))`, which is `count(col)`), `groupby(...).agg({col:
"sum"})` with `sort=True` and `sort=False`, and `read_csv`. The polars shapes
(polars 1.44.2): scan, filter, with_columns, group_by.agg, sort and limit in
one pipeline; `is_in`; an aggregate `.over(...)`; `sum_horizontal`; the four
null-order cells of `sort`; `select(col.sum())`; and `group_by.agg`.

`tests/test_pandas_door_wire.mojo` and `tests/test_polars_door_wire.mojo`
decode each encoding with `komira_plan_wire`, hold it to the structural and
value admission gates, assert the fields the fixture exists for, and compare
it with the same plan built here in Mojo (`door_plans`, `polars_plans`) field
by field (`plan_shape`). The polars test also holds the two doors to each
other: pandas `groupby(sort=False)` and polars `group_by` are the same bytes,
and pandas' default `sort=True` differs from them by the SORT alone. Nothing
here ships (`conda = False`).
"""

from .door_plans import (
    DOOR_CSV_FINGERPRINT,
    DOOR_CSV_KIND_ID,
    DOOR_CSV_PATH,
    DOOR_MTIME_NS,
    csv_schema,
    customers_scan,
    customers_schema,
    groupby_count_col_plan,
    groupby_size_plan,
    groupby_sum_plan,
    merge_plan,
    orders_scan,
    orders_schema,
    read_csv_plan,
    sort_values_plan,
)
from .plan_shape import (
    agg_shape,
    binding_shape,
    bytes_hex,
    expr_shape,
    field_shape,
    literal_shape,
    partition_expr_shape,
    plan_shape,
    schema_shape,
    source_shape,
    wire_bytes_from_hex,
)
from .polars_plans import (
    dropped_sum_plan,
    polars_agg_over_plan,
    polars_group_by_sum_plan,
    polars_is_in_plan,
    polars_pipeline_plan,
    polars_select_sum_plan,
    polars_sort_plan,
    polars_sum_horizontal_plan,
    sales_scan,
    sales_schema,
)
