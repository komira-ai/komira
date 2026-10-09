"""`komira_udf_e2e` -- the user-defined-function traits run end to end over
in-memory Arrow columns, and a declared UDF across the plan wire.

This package exists for its tests. Its one source, `columns.mojo`, builds
nullable Arrow columns (a null slot holds 0) for them. The tests:

- `test_udf_e2e_map_filter`: `Map1` sugar through `MapFnRT` and
  `ProjectList.emit_projected`, over the rows a `FilterFn` keeps, for the four
  input dtypes; `Map2` through `run_row`; a raising UDF's own error.
- `test_udf_e2e_agg_fn`: a stateful custom `AggFn` per group through
  `AggFnAgg`, three workers' partials merged in three orders, groups with
  nulls, with only nulls and with no rows.
- `test_udf_e2e_window_fn`: two `WindowFn`s over `ROWS BETWEEN 1 PRECEDING
  AND 2 FOLLOWING` frames clipped at partition edges, read through
  `FrameView`.
- `test_udf_e2e_plan_wire`: a declared scalar UDF call and a MAP UDF node
  through `plan_to_bytes` / `plan_from_bytes`, byte-stable, unbound on the
  far side; a live closure refused at encode.

Each test's header names what komira does not provide (null propagation
through a map, a frame scan, a typed `MapFn` -> `UdfData` builder) and so
what it does not claim. Nothing here ships (`conda = False`).
"""

from .columns import (
    all_valid,
    f32_column,
    f64_column,
    i32_column,
    i64_column,
    nullable_column,
)
