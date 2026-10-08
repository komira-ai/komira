"""`komira_pandas_door_e2e` -- the pandas door's wire contract, without Python.

A pandas-shaped frontend hands the engine `komira.plan.v1` plans. The
fixtures (`fixtures/<stem>.txtpb`) are those plans as protobuf text, in the
shapes such a frontend emits for `sort_values` (`na_position` first and last),
`merge` (`how` left and inner), `groupby` (`size()`, which is `count(*)`, and
`agg(n=(col, "count"))`, which is `count(col)`) and `read_csv`. protoc encodes
each one in a build action (`proto_encode`), so the bytes the test reads come
from the reference implementation, not from this repository's encoder.

The test, `tests/test_pandas_door_wire.mojo`, decodes each encoding with
`komira_plan_wire`, holds it to the structural and value admission gates, and
compares it with the same plan built here in Mojo (`door_plans`) field by field
(`plan_shape`), after asserting the field each fixture exists for. Nothing here
ships (`conda = False`).
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
    merge_plan,
    orders_scan,
    orders_schema,
    read_csv_plan,
    sort_values_plan,
)
from .plan_shape import (
    agg_shape,
    binding_shape,
    expr_shape,
    field_shape,
    plan_shape,
    schema_shape,
    source_shape,
    wire_bytes_from_hex,
)
